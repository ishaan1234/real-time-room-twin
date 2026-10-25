"""Reads RoomTwin scan folders (mesh + keyframes); shared by the pipeline steps.

Coordinate frames
  world   ARKit world, metres, +y up. The exported mesh is in this frame.
  cam     OpenCV camera of an *upright* keyframe: +x right, +y down, +z forward.
  p3d     PyTorch3D camera: +x left, +y up, +z forward. SAM 3D Objects takes
          its point map and returns its poses in this frame.

ARKit stores photos in sensor orientation, so a photo taken with the phone
held upright is sideways. Keyframes are rotated by multiples of 90 degrees until
gravity points down the image, because SAM 3 and SAM 3D Objects expect upright
photos. Intrinsics and camera poses are rotated with them.
"""

import glob
import json
import os

import numpy as np
from PIL import Image

PLY_VERTEX = np.dtype([("x", "<f4"), ("y", "<f4"), ("z", "<f4"), ("r", "u1"), ("g", "u1"), ("b", "u1")])
PLY_FACE = np.dtype([("n", "u1"), ("i", "<i4", (3,))])

# ARKit camera (+y up, looking down -z) to OpenCV camera (+y down, looking down +z).
ARKIT_TO_CV = np.diag([1.0, -1.0, -1.0, 1.0])
# One np.rot90 turn: maps upright-camera coordinates to the coordinates before the turn.
ROT90_NEW_TO_OLD = np.array([[0.0, -1.0, 0.0], [1.0, 0.0, 0.0], [0.0, 0.0, 1.0]])


def read_ply(path):
    """Reads the binary PLY layout RoomTwin writes. Returns positions (N,3)
    float32, colors (N,3) uint8 and faces (M,3) int64."""
    with open(path, "rb") as f:
        data = f.read()
    end = data.index(b"end_header\n") + len(b"end_header\n")
    header = data[:end].decode("ascii").splitlines()
    count = {line.split()[1]: int(line.split()[2]) for line in header if line.startswith("element ")}
    vertices = np.frombuffer(data, PLY_VERTEX, count["vertex"], end)
    faces = np.frombuffer(data, PLY_FACE, count["face"], end + vertices.nbytes)
    assert (faces["n"] == 3).all(), "only triangle meshes are supported"
    positions = np.stack([vertices["x"], vertices["y"], vertices["z"]], axis=1)
    colors = np.stack([vertices["r"], vertices["g"], vertices["b"]], axis=1)
    return positions, colors, faces["i"].astype(np.int64)


def write_ply(path, positions, colors, faces, comment="RoomTwin furniture pipeline, metres, +y up"):
    vertices = np.empty(len(positions), PLY_VERTEX)
    for i, axis in enumerate("xyz"):
        vertices[axis] = positions[:, i]
    for i, channel in enumerate("rgb"):
        vertices[channel] = colors[:, i]
    packed = np.empty(len(faces), PLY_FACE)
    packed["n"] = 3
    packed["i"] = faces
    header = (f"ply\nformat binary_little_endian 1.0\ncomment {comment}\n"
              f"element vertex {len(vertices)}\nproperty float x\nproperty float y\nproperty float z\n"
              "property uchar red\nproperty uchar green\nproperty uchar blue\n"
              f"element face {len(faces)}\nproperty list uchar int vertex_indices\nend_header\n")
    with open(path, "wb") as f:
        f.write(header.encode("ascii"))
        f.write(vertices.tobytes())
        f.write(packed.tobytes())


FLOOR_MARGIN = 0.025   # vertices this close above the floor count as floor


def estimate_floor(positions, faces):
    """Height of the floor: the low end of the upward-facing surfaces."""
    a, b, c = (positions[faces[:, i]].astype(np.float64) for i in range(3))
    normals = np.cross(b - a, c - a)
    lengths = np.linalg.norm(normals, axis=1)
    up = normals[:, 1] > 0.9 * np.maximum(lengths, 1e-12)
    heights = ((a + b + c) / 3)[:, 1]
    # Whichever way the scan's triangles wind, the floor faces one consistent way.
    if np.count_nonzero(up) < np.count_nonzero(normals[:, 1] < -0.9 * np.maximum(lengths, 1e-12)):
        up = normals[:, 1] < -0.9 * np.maximum(lengths, 1e-12)
    return float(np.percentile(heights[up], 5)) if up.any() else float(np.percentile(positions[:, 1], 1))


def latest_mesh(scan_dir):
    """The scan's most recent export (exports are named by time)."""
    meshes = sorted(p for p in glob.glob(os.path.join(scan_dir, "RoomTwin-*.ply")))
    if not meshes:
        raise FileNotFoundError(f"no RoomTwin-*.ply export in {scan_dir}")
    return meshes[-1]


ROOMPLAN_PROMPTS = {
    "storage": "cabinet", "refrigerator": "refrigerator", "stove": "stove",
    "oven": "oven", "dishwasher": "dishwasher", "washerDryer": "washer dryer",
    "television": "television", "bathtub": "bathtub", "toilet": "toilet",
    "sink": "sink", "fireplace": "fireplace", "stairs": "stairs",
}


def sam_replacement_manifest(scan_dir):
    """The newest marker written by the app's SAM Furniture mode, or None."""
    paths = sorted(glob.glob(os.path.join(scan_dir, "RoomTwin-*.sam.json")))
    if not paths:
        return None
    with open(paths[-1]) as f:
        value = json.load(f)
    value["path"] = paths[-1]
    return value


def load_roomplan(scan_dir):
    """Loads the RoomPlan sidecar selected by the SAM manifest."""
    manifest = sam_replacement_manifest(scan_dir)
    if manifest and manifest.get("roomPlanFile"):
        path = os.path.join(scan_dir, manifest["roomPlanFile"])
    else:
        paths = sorted(glob.glob(os.path.join(scan_dir, "RoomTwin-*.roomplan.json")))
        path = paths[-1] if paths else None
    if not path or not os.path.exists(path):
        return None
    with open(path) as f:
        return json.load(f)


def _roomplan_category(value):
    category = value.get("category", {})
    return next(iter(category), "object") if isinstance(category, dict) else str(category)


def _roomplan_transform(value):
    return np.asarray(value["transform"], np.float64).reshape(4, 4, order="F")


def box_corners(target):
    """The eight world-space corners of a RoomPlan target."""
    signs = np.array([[x, y, z] for x in (-1, 1) for y in (-1, 1) for z in (-1, 1)], np.float64)
    local = signs * target["dimensions"] / 2
    return local @ target["transform"][:3, :3].T + target["transform"][:3, 3]


def points_in_target(points, target, margin=0.0):
    local = points @ target["inverse"][:3, :3].T + target["inverse"][:3, 3]
    return (np.abs(local) <= target["dimensions"] / 2 + margin).all(axis=1)


def roomplan_targets(scan_dir):
    """Furniture targets from RoomPlan, in stable sidecar order.

    This intentionally returns nothing for ordinary scans. The SAM Furniture
    marker is the user's consent to replace detected objects automatically.
    """
    if sam_replacement_manifest(scan_dir) is None:
        return []
    room = load_roomplan(scan_dir)
    if not room:
        return []
    targets = []
    for target_id, value in enumerate(room.get("objects", [])):
        category = _roomplan_category(value)
        transform = _roomplan_transform(value)
        targets.append(dict(
            id=target_id, identifier=value.get("identifier", str(target_id)), category=category,
            prompt=ROOMPLAN_PROMPTS.get(category, category),
            confidence=next(iter(value.get("confidence", {})), "unknown"),
            dimensions=np.asarray(value["dimensions"], np.float64), transform=transform,
            inverse=np.linalg.inv(transform)))
    return targets


def roomplan_surfaces(scan_dir):
    """RoomPlan wall/floor planes used only to fill a replaced object's hole."""
    room = load_roomplan(scan_dir)
    if not room:
        return []
    surfaces = []
    for kind in ("walls", "floors"):
        for value in room.get(kind, []):
            transform = _roomplan_transform(value)
            surfaces.append(dict(kind=kind[:-1], dimensions=np.asarray(value["dimensions"], np.float64),
                                 transform=transform, inverse=np.linalg.inv(transform)))
    return surfaces


def projected_target_box(kf, target):
    """Unclipped upright-image xyxy rectangle for a RoomPlan OBB."""
    u, v, z = kf.project(box_corners(target))
    in_front = z > 0.1
    if np.count_nonzero(in_front) < 4:
        return None
    return np.array([u[in_front].min(), v[in_front].min(), u[in_front].max(), v[in_front].max()], np.float32)


def rotate_intrinsics(K, width):
    """Intrinsics (fx, fy, cx, cy) after one np.rot90 of an image `width` pixels wide."""
    fx, fy, cx, cy = K
    return np.array([fy, fx, cy, width - 1 - cx])


def upright_turns(cam_to_world):
    """Number of np.rot90 turns that make world +y point up the image."""
    up = cam_to_world[:3, :3].T @ np.array([0.0, 1.0, 0.0])   # world up in camera axes
    direction = np.array([up[0], up[1]])                        # in image (u, v)
    best, best_turns = None, 0
    for turns in range(4):
        if best is None or direction[1] < best:
            best, best_turns = direction[1], turns
        direction = np.array([direction[1], -direction[0]])     # one turn: u' = v, v' = -u
    return best_turns


class Keyframe:
    """One keyframe, rotated upright. Images load on first use."""

    def __init__(self, scan_dir, entry):
        self.scan_dir = scan_dir
        self.entry = entry
        self.index = entry["index"]
        cam_to_world = np.array(entry["cameraToWorld"], dtype=np.float64).reshape(4, 4, order="F") @ ARKIT_TO_CV
        self.turns = upright_turns(cam_to_world)
        K = np.array(entry["intrinsics"], dtype=np.float64)
        width, height = entry["imageWidth"], entry["imageHeight"]
        for _ in range(self.turns):
            K = rotate_intrinsics(K, width)
            width, height = height, width
            cam_to_world[:3, :3] = cam_to_world[:3, :3] @ ROT90_NEW_TO_OLD
        self.K = K
        self.width, self.height = width, height
        self.cam_to_world = cam_to_world
        self.world_to_cam = np.linalg.inv(cam_to_world)
        scale = entry["depthWidth"] / entry["imageWidth"]
        self.depth_K = K * scale
        self.depth_width = round(width * scale)
        self.depth_height = round(height * scale)
        self._image = self._depth = self._confidence = None

    @property
    def image(self):
        """Upright RGB, uint8 (H, W, 3)."""
        if self._image is None:
            image = np.asarray(Image.open(os.path.join(self.scan_dir, self.entry["image"])).convert("RGB"))
            self._image = np.ascontiguousarray(np.rot90(image, self.turns))
        return self._image

    def _plane(self, key, dtype):
        raw = np.fromfile(os.path.join(self.scan_dir, self.entry[key]), dtype)
        plane = raw.reshape(self.entry["depthHeight"], self.entry["depthWidth"])
        return np.ascontiguousarray(np.rot90(plane, self.turns))

    @property
    def confidence(self):
        """Upright ARConfidenceLevel per depth pixel: 0 low, 1 medium, 2 high."""
        if self._confidence is None:
            self._confidence = self._plane("confidence", np.uint8)
        return self._confidence

    def depth(self, min_confidence=1):
        """Upright depth in metres, NaN where missing or below `min_confidence`."""
        if self._depth is None:
            self._depth = self._plane("depth", "<f4").astype(np.float32)
        depth = self._depth.copy()
        depth[(self.confidence < min_confidence) | ~(depth > 0)] = np.nan
        return depth

    def unproject_depth(self, min_confidence=1):
        """Camera-frame points (h, w, 3) for each depth pixel, NaN where invalid."""
        depth = self.depth(min_confidence)
        fx, fy, cx, cy = self.depth_K
        v, u = np.mgrid[0:depth.shape[0], 0:depth.shape[1]].astype(np.float32)
        return np.stack([(u - cx) / fx * depth, (v - cy) / fy * depth, depth], axis=-1)

    def pointmap_p3d(self, min_confidence=1):
        """The point map SAM 3D Objects takes: PyTorch3D camera axes, (h, w, 3)."""
        points = self.unproject_depth(min_confidence)
        return points * np.array([-1.0, -1.0, 1.0], dtype=np.float32)

    def project(self, points_world):
        """Upright-image pixel coordinates (u, v) and camera depth z of world points."""
        p = points_world @ self.world_to_cam[:3, :3].T + self.world_to_cam[:3, 3]
        z = p[:, 2]
        with np.errstate(divide="ignore", invalid="ignore"):
            u = self.K[0] * p[:, 0] / z + self.K[2]
            v = self.K[1] * p[:, 1] / z + self.K[3]
        return u, v, z

    def visible(self, points_world, tolerance=0.05, min_confidence=1):
        """Which points this keyframe saw: in frame, in front, and within
        `tolerance` (or 3% of the distance) of the LiDAR depth. Returns the
        mask and the integer pixel coordinates of all points."""
        u, v, z = self.project(points_world)
        with np.errstate(invalid="ignore"):
            ui = np.round(np.nan_to_num(u, nan=-1.0, posinf=-1.0, neginf=-1.0)).astype(np.int64)
            vi = np.round(np.nan_to_num(v, nan=-1.0, posinf=-1.0, neginf=-1.0)).astype(np.int64)
        inside = (z > 0.1) & (ui >= 0) & (ui < self.width) & (vi >= 0) & (vi < self.height)
        depth = self.depth(min_confidence)
        # Pixel centres sit on integer coordinates (OpenCV), in both images.
        scale = self.depth_width / self.width
        du = np.clip(np.round((ui + 0.5) * scale - 0.5).astype(np.int64), 0, self.depth_width - 1)
        dv = np.clip(np.round((vi + 0.5) * scale - 0.5).astype(np.int64), 0, self.depth_height - 1)
        measured = depth[dv, du]
        with np.errstate(invalid="ignore"):
            seen = inside & (np.abs(z - measured) < np.maximum(tolerance, 0.03 * z))
        return seen, ui, vi

    def cam_to_world_points(self, points_cam):
        return points_cam @ self.cam_to_world[:3, :3].T + self.cam_to_world[:3, 3]


def load_keyframes(scan_dir):
    with open(os.path.join(scan_dir, "keyframes.json")) as f:
        return [Keyframe(scan_dir, entry) for entry in json.load(f)]


def load_segments(scan_dir, index):
    """Masks (n, H, W) bool, labels, scores and boxes for one keyframe, or None."""
    path = os.path.join(scan_dir, "segments", f"{index:06d}.npz")
    if not os.path.exists(path):
        return None
    data = np.load(path, allow_pickle=True)
    height, width = data["shape"]
    masks = np.unpackbits(data["masks"], axis=-1, count=int(width)).astype(bool)
    target_ids = data["target_ids"].astype(np.int32) if "target_ids" in data else np.full(len(masks), -1, np.int32)
    return dict(masks=masks, labels=list(data["labels"]), scores=data["scores"], boxes=data["boxes"],
                target_ids=target_ids)


def p3d_to_cam(points):
    return points * np.array([-1.0, -1.0, 1.0])
