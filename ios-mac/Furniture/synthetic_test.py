"""Checks lift.py and assemble.py on a synthetic room, no GPU or models needed.

    python synthetic_test.py [output dir]

A floor with a chair-sized and a table-sized box is "scanned" by 24 keyframes
on a circle, written exactly like the app writes them (sideways photos, ARKit
poses, 256x192 depth). SAM 3 is replaced by the true object masks, grown by a
few pixels the way real masks bleed, and SAM 3D Objects by the true boxes,
moved, turned and resized a little. The test then checks that lift.py finds
both objects and only their vertices, and that assemble.py fits the models
back, cuts the scanned boxes out and keeps the floor.
"""

import json
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image

import scan_io

HERE = os.path.dirname(os.path.abspath(__file__))
BOXES = {"chair": (np.array([0.2, 0.0, 0.3]), np.array([0.7, 0.9, 0.8]), (200, 60, 60)),
         "table": (np.array([-1.2, 0.0, -0.4]), np.array([-0.2, 0.75, 0.4]), (140, 100, 60))}
IMAGE_SIZE, DEPTH_SIZE = (1920, 1440), (256, 192)
K_IMAGE = np.array([1450.0, 1450.0, 959.5, 719.5])


def grid(origin, u, v, nu, nv):
    """Vertices and triangles of a regular grid origin + i*u + j*v."""
    i, j = np.meshgrid(np.arange(nu), np.arange(nv), indexing="ij")
    points = origin + i[..., None] * u + j[..., None] * v
    index = np.arange(nu * nv).reshape(nu, nv)
    a, b, c, d = index[:-1, :-1], index[1:, :-1], index[:-1, 1:], index[1:, 1:]
    faces = np.concatenate([np.stack([a, b, c], -1).reshape(-1, 3), np.stack([b, d, c], -1).reshape(-1, 3)])
    return points.reshape(-1, 3), faces


def box_mesh(lo, hi, step=0.02, bottom=False):
    parts = []
    size = hi - lo
    for axis in range(3):
        for side in (0, 1):
            if axis == 1 and side == 0 and not bottom:
                continue
            u_axis, v_axis = [a for a in range(3) if a != axis]
            origin = lo.copy()
            origin[axis] = (lo if side == 0 else hi)[axis]
            u, v = np.zeros(3), np.zeros(3)
            nu, nv = int(round(size[u_axis] / step)) + 1, int(round(size[v_axis] / step)) + 1
            u[u_axis], v[v_axis] = size[u_axis] / (nu - 1), size[v_axis] / (nv - 1)
            parts.append(grid(origin, u, v, nu, nv))
    return merge(parts)


def merge(parts):
    offsets = np.cumsum([0] + [len(p[0]) for p in parts])
    return np.concatenate([p[0] for p in parts]), np.concatenate([p[1] + o for p, o in zip(parts, offsets)])


def raycast(origins, directions):
    """Distance and hit id (0 floor, 1.. boxes, -1 nothing) along each ray."""
    t_best = np.full(len(directions), np.inf)
    hit = np.full(len(directions), -1)
    with np.errstate(divide="ignore", invalid="ignore"):
        t_floor = -origins[1] / directions[:, 1]
        floor = (t_floor > 0) & (np.abs(origins[0] + t_floor * directions[:, 0]) < 2.5) \
            & (np.abs(origins[2] + t_floor * directions[:, 2]) < 2.5)
        t_best[floor], hit[floor] = t_floor[floor], 0
        for k, (lo, hi, _) in enumerate(BOXES.values(), start=1):
            t1, t2 = (lo - origins) / directions, (hi - origins) / directions
            near = np.minimum(t1, t2).max(axis=1)
            far = np.maximum(t1, t2).min(axis=1)
            box = (near <= far) & (near > 0) & (near < t_best)
            t_best[box], hit[box] = near[box], k
    return t_best, hit


def render(cam_to_world_arkit, K, size):
    """Depth along the optical axis and hit ids for a raw (sensor-oriented) image."""
    width, height = size
    v, u = np.mgrid[0:height, 0:width]
    rays_cam = np.stack([(u - K[2]) / K[0], (v - K[3]) / K[1], np.ones_like(u, dtype=float)], -1).reshape(-1, 3)
    cam_to_world = cam_to_world_arkit @ scan_io.ARKIT_TO_CV
    directions = rays_cam @ cam_to_world[:3, :3].T
    t, hit = raycast(cam_to_world[:3, 3], directions)
    return t.reshape(height, width), hit.reshape(height, width)   # rays_cam has z = 1, so t is depth


def make_scan(scan_dir):
    floor = grid(np.array([-2.5, 0.0, -2.5]), np.array([0.02, 0.0, 0.0]), np.array([0.0, 0.0, 0.02]), 251, 251)
    parts, colors, truth = [floor], [np.full((len(floor[0]), 3), 128)], [np.full(len(floor[0]), -1)]
    for k, (lo, hi, color) in enumerate(BOXES.values()):
        part = box_mesh(lo, hi)
        parts.append(part)
        colors.append(np.tile(color, (len(part[0]), 1)))
        truth.append(np.full(len(part[0]), k))
    positions, faces = merge(parts)
    scan_io.write_ply(os.path.join(scan_dir, "RoomTwin-2026-01-01-000000.ply"), positions.astype(np.float32),
                      np.concatenate(colors).astype(np.uint8), faces)

    os.makedirs(os.path.join(scan_dir, "keyframes"))
    os.makedirs(os.path.join(scan_dir, "segments"))
    entries = []
    rng = np.random.default_rng(0)
    for index in range(24):
        angle = 2 * np.pi * index / 24
        eye = np.array([2.4 * np.cos(angle), 1.4 + 0.1 * rng.standard_normal(), 2.4 * np.sin(angle)])
        back = eye - np.array([-0.2, 0.4, 0.1])
        back /= np.linalg.norm(back)
        right = np.cross([0.0, 1.0, 0.0], back)
        right /= np.linalg.norm(right)
        up = np.cross(back, right)
        # Phone held upright: the sensor's +x points up (or down) in the world.
        roll = 1 if index % 2 else -1
        cam_to_world = np.eye(4)
        cam_to_world[:3, 0], cam_to_world[:3, 1], cam_to_world[:3, 2] = roll * up, -roll * right, back
        cam_to_world[:3, 3] = eye

        depth_K = K_IMAGE * DEPTH_SIZE[0] / IMAGE_SIZE[0]
        depth, _ = render(cam_to_world, depth_K, DEPTH_SIZE)
        _, ids = render(cam_to_world, K_IMAGE, IMAGE_SIZE)
        name = f"keyframes/{index:06d}"
        Image.fromarray(np.array([90, 90, 90], np.uint8)[None, None].repeat(IMAGE_SIZE[1], 0).repeat(IMAGE_SIZE[0], 1)) \
            .save(os.path.join(scan_dir, name + ".jpg"))
        depth = np.where(np.isfinite(depth), depth + rng.normal(0, 0.004, depth.shape), 0).astype("<f4")
        depth.tofile(os.path.join(scan_dir, name + ".depth"))
        np.full(depth.shape, 2, np.uint8).tofile(os.path.join(scan_dir, name + ".conf"))
        entry = dict(index=index, timestamp=float(index), image=name + ".jpg", depth=name + ".depth",
                     confidence=name + ".conf", imageWidth=IMAGE_SIZE[0], imageHeight=IMAGE_SIZE[1],
                     depthWidth=DEPTH_SIZE[0], depthHeight=DEPTH_SIZE[1], intrinsics=K_IMAGE.tolist(),
                     cameraToWorld=cam_to_world.flatten(order="F").tolist())
        entries.append(entry)

        # SAM 3 stand-in: true masks in the upright keyframe, grown by 4 px.
        turns = scan_io.Keyframe(scan_dir, entry).turns
        ids = np.rot90(ids, turns)
        labels, masks = [], []
        for k, label in enumerate(BOXES, start=1):
            mask = ids == k
            for _ in range(4):
                mask = mask | np.roll(mask, 1, 0) | np.roll(mask, -1, 0) | np.roll(mask, 1, 1) | np.roll(mask, -1, 1)
            if mask.sum() > 500:
                labels.append(label)
                masks.append(mask)
        np.savez_compressed(os.path.join(scan_dir, "segments", f"{index:06d}.npz"),
                            labels=np.array(labels, dtype=object), scores=np.full(len(labels), 0.9, np.float32),
                            boxes=np.zeros((len(labels), 4), np.float32),
                            masks=np.packbits(np.array(masks, bool).reshape(-1, *ids.shape), axis=-1),
                            shape=np.array(ids.shape))
    with open(os.path.join(scan_dir, "keyframes.json"), "w") as f:
        json.dump(entries, f)
    return positions, np.concatenate(truth)


def make_generated(scan_dir, objects):
    """SAM 3D stand-in: each true box, closed, turned 6 degrees, moved 5 cm and 4% too big."""
    os.makedirs(os.path.join(scan_dir, "generated"))
    angle = np.radians(6)
    rotation = np.array([[np.cos(angle), 0, np.sin(angle)], [0, 1, 0], [-np.sin(angle), 0, np.cos(angle)]])
    for obj in objects:
        lo, hi, color = BOXES[obj["category"]]
        positions, faces = box_mesh(lo, hi, step=0.04, bottom=True)
        center = (lo + hi) / 2
        positions = (positions - center) @ rotation.T * 1.04 + center + np.array([0.05, 0.03, -0.02])
        scan_io.write_ply(os.path.join(scan_dir, "generated", f"object_{obj['id']:02d}.ply"),
                          positions, np.tile(color, (len(positions), 1)).astype(np.uint8), faces)


def run(script, scan_dir):
    result = subprocess.run([sys.executable, os.path.join(HERE, script), scan_dir], capture_output=True, text=True)
    print(result.stdout, end="")
    if result.returncode:
        print(result.stderr)
        raise SystemExit(f"{script} failed")


def main():
    scan_dir = sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp(prefix="roomtwin-synthetic-")
    os.makedirs(scan_dir, exist_ok=True)
    positions, truth = make_scan(scan_dir)
    failures = []

    run("lift.py", scan_dir)
    with open(os.path.join(scan_dir, "objects.json")) as f:
        objects = json.load(f)
    found = sorted(o["category"] for o in objects)
    if found != sorted(BOXES):
        failures.append(f"lift found {found}, expected {sorted(BOXES)}")
    assigned = np.load(os.path.join(scan_dir, "vertex_objects.npy"))
    for obj in objects:
        k = list(BOXES).index(obj["category"])
        mine = assigned == obj["id"]
        true = truth == k
        # Only vertices some keyframe could see count toward recall.
        seen = np.zeros(len(positions), bool)
        for kf in scan_io.load_keyframes(scan_dir):
            seen |= kf.visible(positions)[0]
        recall = (mine & true).sum() / max((true & seen).sum(), 1)
        precision = (mine & true).sum() / max(mine.sum(), 1)
        print(f"check: {obj['category']}: recall {recall:.3f}, precision {precision:.3f} of seen vertices")
        if recall < 0.9 or precision < 0.98:
            failures.append(f"{obj['category']}: recall {recall:.3f}, precision {precision:.3f}")

    make_generated(scan_dir, objects)
    run("assemble.py", scan_dir)
    with open(os.path.join(scan_dir, "twin", "placement.json")) as f:
        placement = json.load(f)
    if abs(placement["floor_y"]) > 0.01:
        failures.append(f"floor at {placement['floor_y']:.3f}, expected 0")
    for report in placement["objects"]:
        if not report.get("fit_accepted") or report["scan_to_model_median_after_m"] > 0.01:
            failures.append(f"fit of {report['category']}: {report}")
    room, _, room_faces = scan_io.read_ply(os.path.join(scan_dir, "twin", "room_without_furniture.ply"))
    leftover_box = sum(((room > lo + 0.03) & (room < hi - 0.03)).all(axis=1).sum() for lo, hi, _ in BOXES.values())
    floor_kept = np.mean(np.abs(room[:, 1]) < 0.001) if len(room) else 0
    print(f"check: room_without_furniture has {len(room)} vertices; {leftover_box} left inside the boxes; "
          f"{floor_kept:.3f} of them are floor")
    if leftover_box > 20:
        failures.append(f"{leftover_box} scanned box vertices survived the cut")
    if (np.abs(positions[:, 1]) < 0.001).sum() - (np.abs(room[:, 1]) < 0.001).sum() > 0.05 * (np.abs(positions[:, 1]) < 0.001).sum():
        failures.append("the cut removed more than 5% of the floor")
    twin = scan_io.read_ply(os.path.join(scan_dir, "twin", "room_twin.ply"))
    print(f"check: room_twin.ply reads back: {len(twin[0])} vertices, {len(twin[2])} triangles")

    print("\n" + ("PASS" if not failures else "FAIL:\n  " + "\n  ".join(failures)) + f"  ({scan_dir})")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
