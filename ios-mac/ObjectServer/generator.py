"""Generation worker for server.py: runs SAM 3D Objects on queued jobs.

    MAMBA_ROOT_PREFIX=/content/mamba micromamba run -n sam3d-objects python generator.py

Loads the model once, then watches /content/objects/*/job-*/ for a
request.json without a status.json. For each job it generates the object from
the photo, the chosen SAM 3 mask and the LiDAR point map, so the model comes
out at its real size. The model is turned into the ARKit world frame (gravity
along -y), stood on the origin and written to job-N/model.ply.
"""

import glob
import json
import os
import sys
import time
import traceback

import numpy as np

FURNITURE_DIR = os.environ.get("FURNITURE_DIR", "/content/Furniture")
sys.path.insert(0, FURNITURE_DIR)

import torch  # noqa: E402
from generate import GLB_TO_MODEL, decimate  # noqa: E402  (also sets up the SAM 3D imports)
from inference import Inference  # noqa: E402
from pytorch3d.transforms import quaternion_to_matrix  # noqa: E402
from sam3d_objects.data.dataset.tdfy.transforms_3d import compose_transform  # noqa: E402

import scan_io  # noqa: E402

ROOT = os.environ.get("OBJECTS_DIR", "/content/objects")
SAM3D_REPO = os.environ.get("SAM3D_REPO", "/content/sam-3d-objects")
MAX_FACES = 60000


def write_json(path, value):
    with open(path + ".tmp", "w") as f:
        json.dump(value, f)
    os.replace(path + ".tmp", path)


def run(job_dir, inference, status):
    photo_dir = os.path.dirname(job_dir)
    with open(os.path.join(job_dir, "request.json")) as f:
        request = json.load(f)
    with open(os.path.join(photo_dir, "entry.json")) as f:
        kf = scan_io.Keyframe(photo_dir, json.load(f))
    data = np.load(os.path.join(photo_dir, "masks.npz"))
    height, width = data["shape"]
    mask = np.unpackbits(data["masks"], axis=-1, count=int(width)).astype(bool)[request["mask"]]

    status("Generating the model")
    output = inference(kf.image, mask, seed=42, pointmap=torch.from_numpy(kf.pointmap_p3d()))
    glb = output["glb"]
    model_points = torch.tensor(np.asarray(glb.vertices) @ GLB_TO_MODEL, dtype=torch.float32, device="cuda")
    pose = compose_transform(scale=output["scale"], rotation=quaternion_to_matrix(output["rotation"]),
                             translation=output["translation"])
    vertices_p3d = pose.transform_points(model_points[None])[0].cpu().numpy().astype(np.float64)
    vertices = kf.cam_to_world_points(scan_io.p3d_to_cam(vertices_p3d))
    colors = np.asarray(glb.visual.vertex_colors)[:, :3]
    faces = np.asarray(glb.faces)

    if len(faces) > MAX_FACES:
        status(f"Simplifying {len(faces):,} triangles")
        vertices, colors, faces = decimate(vertices, colors, faces, MAX_FACES)
    # Viewers light the side triangles wind counter-clockwise on; make that the outside.
    a, b, c = (vertices[faces[:, i]] for i in range(3))
    if np.einsum("ij,ij->i", a, np.cross(b, c)).sum() < 0:
        faces = faces[:, ::-1]
    low, high = vertices.min(0), vertices.max(0)
    if not request.get("preserveWorld", False):
        # Photo mode wants a reusable model standing at the origin. SAM
        # Furniture instead keeps the ARKit world pose so it replaces the
        # scanned object before the room preview is revealed.
        vertices = vertices - np.array([(low[0] + high[0]) / 2, low[1], (low[2] + high[2]) / 2])
    scan_io.write_ply(os.path.join(job_dir, "model.ply"), vertices, colors, faces,
                      comment="RoomTwin object, metres, +y up")
    return dict(faces=int(len(faces)), size=np.round(high - low, 3).tolist())


def main():
    os.makedirs(ROOT, exist_ok=True)
    state_path = os.path.join(ROOT, "generator.json")
    write_json(state_path, dict(state="loading", since=time.time()))
    start = time.time()
    inference = Inference(os.path.join(SAM3D_REPO, "checkpoints/hf/pipeline.yaml"), compile=False)
    print(f"generator: SAM 3D Objects loaded in {time.time() - start:.0f} s", flush=True)
    write_json(state_path, dict(state="ready", since=time.time()))

    while True:
        pending = [path for path in sorted(glob.glob(os.path.join(ROOT, "*", "job-*", "request.json")),
                                           key=os.path.getmtime)
                   if not os.path.exists(os.path.join(os.path.dirname(path), "status.json"))]
        if not pending:
            time.sleep(0.5)
            continue
        job_dir = os.path.dirname(pending[0])
        status_path = os.path.join(job_dir, "status.json")
        start = time.time()

        def status(message):
            write_json(status_path, dict(state="running", message=message, seconds=round(time.time() - start)))

        status("Starting")
        try:
            result = run(job_dir, inference, status)
            result.update(state="done", message="Done", seconds=round(time.time() - start, 1))
            write_json(status_path, result)
            print(f"generator: {job_dir} {result}", flush=True)
        except Exception as error:
            traceback.print_exc()
            write_json(status_path, dict(state="failed", message=f"{type(error).__name__}: {error}"))
        torch.cuda.empty_cache()


if __name__ == "__main__":
    main()
