"""Step 3: generate a complete model of each object with SAM 3D Objects.

    python generate.py SCAN_DIR [--only 0,3] [--seed 42] [--max-faces 40000]

For each object in objects.json, runs SAM 3D Objects on its chosen keyframe
with the SAM 3 mask and a metric point map built from the LiDAR depth, then
moves the generated mesh into the world frame with the predicted pose.

Writes SCAN_DIR/generated/object_NN.ply (world frame, vertex colors) and
object_NN.json (pose and fit checks). Runs in Meta's sam3d-objects environment
(Python 3.11, PyTorch 2.5.1); set SAM3D_REPO if the repo isn't in
/content/sam-3d-objects.
"""

import argparse
import json
import os
import sys
import time
import traceback

import numpy as np

os.environ.setdefault("CONDA_PREFIX", sys.prefix)   # notebook/inference.py reads it
SAM3D_REPO = os.environ.get("SAM3D_REPO", "/content/sam-3d-objects")
sys.path.insert(0, os.path.join(SAM3D_REPO, "notebook"))

import open3d as o3d  # noqa: E402
import torch  # noqa: E402
from inference import Inference  # noqa: E402
from pytorch3d.transforms import quaternion_to_matrix  # noqa: E402
from sam3d_objects.data.dataset.tdfy.transforms_3d import compose_transform  # noqa: E402
from scipy.spatial import cKDTree  # noqa: E402

import scan_io  # noqa: E402

# SAM 3D's GLB export turns its z-up model frame to y-up (v_glb = v @ [[1,0,0],[0,0,-1],[0,1,0]]);
# the predicted pose applies to the z-up frame, so undo that first.
GLB_TO_MODEL = np.array([[1.0, 0.0, 0.0], [0.0, 0.0, 1.0], [0.0, -1.0, 0.0]])


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("scan_dir")
    parser.add_argument("--only", help="comma-separated object ids")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--max-faces", type=int, default=40000)
    args = parser.parse_args()

    with open(os.path.join(args.scan_dir, "objects.json")) as f:
        objects = json.load(f)
    if args.only:
        wanted = {int(i) for i in args.only.split(",")}
        objects = [o for o in objects if o["id"] in wanted]
    keyframes = {kf.index: kf for kf in scan_io.load_keyframes(args.scan_dir)}
    out_dir = os.path.join(args.scan_dir, "generated")
    os.makedirs(out_dir, exist_ok=True)

    start = time.time()
    inference = Inference(os.path.join(SAM3D_REPO, "checkpoints/hf/pipeline.yaml"), compile=False)
    print(f"generate: model loaded in {time.time() - start:.0f} s", flush=True)

    for obj in objects:
        name = f"object_{obj['id']:02d}"
        try:
            start = time.time()
            result = generate(inference, keyframes[obj["frame"]], args.scan_dir, obj, args)
            positions, colors, faces, info = result
            scan_io.write_ply(os.path.join(out_dir, name + ".ply"), positions, colors, faces)
            info.update(id=obj["id"], category=obj["category"], frame=obj["frame"], seconds=round(time.time() - start, 1))
            with open(os.path.join(out_dir, name + ".json"), "w") as f:
                json.dump(info, f, indent=1)
            print(f"generate: {name} {obj['category']:12s} {len(faces)} faces in {info['seconds']} s; "
                  f"scale {info['scale']:.3f}, mesh vs splat {info['mesh_vs_splat_m']:.3f} m, "
                  f"observed points to mesh: median {info['observed_to_mesh_median_m']:.3f} m", flush=True)
        except Exception:
            print(f"generate: {name} failed", flush=True)
            traceback.print_exc()


def generate(inference, kf, scan_dir, obj, args):
    mask = scan_io.load_segments(scan_dir, kf.index)["masks"][obj["instance"]]
    pointmap = kf.pointmap_p3d()
    output = inference(kf.image, mask, seed=args.seed, pointmap=torch.from_numpy(pointmap))

    glb = output["glb"]
    model_points = torch.tensor(np.asarray(glb.vertices) @ GLB_TO_MODEL, dtype=torch.float32, device="cuda")
    pose = compose_transform(scale=output["scale"], rotation=quaternion_to_matrix(output["rotation"]),
                             translation=output["translation"])
    vertices_p3d = pose.transform_points(model_points[None])[0].cpu().numpy().astype(np.float64)
    splat_p3d = pose.transform_points(output["gs"].get_xyz[None].float())[0].detach().cpu().numpy()

    # Checks: the posed mesh should sit on the posed splat (same model frame), and the
    # LiDAR points inside the mask should lie on the mesh surface.
    mesh_vs_splat = float(np.linalg.norm(np.median(vertices_p3d, 0) - np.median(splat_p3d, 0)))
    depth_mask = np.asarray(
        torch.nn.functional.interpolate(torch.from_numpy(mask)[None, None].float(), size=pointmap.shape[:2],
                                        mode="nearest")[0, 0].bool())
    observed = pointmap[depth_mask]
    observed = observed[np.isfinite(observed).all(axis=1)]
    distances = cKDTree(vertices_p3d).query(observed)[0] if len(observed) else np.array([np.nan])

    vertices_world = kf.cam_to_world_points(scan_io.p3d_to_cam(vertices_p3d))
    colors = np.asarray(glb.visual.vertex_colors)[:, :3]
    faces = np.asarray(glb.faces)
    raw_faces = len(faces)
    if len(faces) > args.max_faces:
        vertices_world, colors, faces = decimate(vertices_world, colors, faces, args.max_faces)

    scale = output["scale"][0].cpu().numpy()
    info = dict(rotation_wxyz=output["rotation"][0].cpu().numpy().round(6).tolist(),
                translation_p3d=output["translation"][0].cpu().numpy().round(6).tolist(),
                scale=float(scale.mean()), raw_faces=raw_faces, faces=int(len(faces)),
                mesh_vs_splat_m=round(mesh_vs_splat, 4),
                observed_points=int(len(observed)),
                observed_to_mesh_median_m=round(float(np.median(distances)), 4),
                observed_to_mesh_p90_m=round(float(np.percentile(distances, 90)), 4))
    return vertices_world, colors, faces, info


def decimate(positions, colors, faces, max_faces):
    mesh = o3d.geometry.TriangleMesh(o3d.utility.Vector3dVector(positions), o3d.utility.Vector3iVector(faces))
    mesh.vertex_colors = o3d.utility.Vector3dVector(colors / 255.0)
    mesh = mesh.simplify_quadric_decimation(target_number_of_triangles=max_faces)
    mesh.remove_degenerate_triangles()
    mesh.remove_unreferenced_vertices()
    return (np.asarray(mesh.vertices), (np.asarray(mesh.vertex_colors) * 255).round().clip(0, 255).astype(np.uint8),
            np.asarray(mesh.triangles))


if __name__ == "__main__":
    main()
