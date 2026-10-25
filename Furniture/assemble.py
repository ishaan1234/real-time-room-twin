"""Step 4: fit each generated model to the scan, cut the scanned furniture out,
and merge everything into one mesh.

    python assemble.py SCAN_DIR [--no-fit] [--keep 0,3]

The pose from SAM 3D Objects comes from one photo, so each model is then
fitted to its scanned surface (ICP from the scanned points to the model,
since the scan only covers the sides the camera saw) and dropped onto
the floor if it is hovering just above or below it. The scanned furniture is
then removed: every vertex lift.py assigned to a replaced object, plus
anything within 3 cm of the fitted model, but never the floor.

Writes SCAN_DIR/twin/room_twin.ply (the merged result), room_without_furniture.ply,
object_NN_<category>.ply (fitted, world frame) and placement.json.
"""

import argparse
import glob
import json
import os

import numpy as np
from scipy.spatial import cKDTree

import scan_io


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("scan_dir")
    parser.add_argument("--no-fit", action="store_true", help="use SAM 3D's poses as they are")
    parser.add_argument("--keep", help="comma-separated object ids to leave as scanned")
    parser.add_argument("--cut-distance", type=float, default=0.03)
    args = parser.parse_args()
    keep = {int(i) for i in args.keep.split(",")} if args.keep else set()

    positions, colors, faces = scan_io.read_ply(scan_io.latest_mesh(args.scan_dir))
    vertex_objects = np.load(os.path.join(args.scan_dir, "vertex_objects.npy"))
    with open(os.path.join(args.scan_dir, "objects.json")) as f:
        objects = {o["id"]: o for o in json.load(f)}
    floor_y = scan_io.estimate_floor(positions, faces)
    print(f"assemble: floor at y = {floor_y:.3f} m")

    out_dir = os.path.join(args.scan_dir, "twin")
    os.makedirs(out_dir, exist_ok=True)
    remove_vertex = np.zeros(len(positions), bool)
    fitted, placement = [], []
    replaced_target_ids = set()
    for path in sorted(glob.glob(os.path.join(args.scan_dir, "generated", "object_*.ply"))):
        object_id = int(os.path.basename(path)[7:9])
        if object_id in keep or object_id not in objects:
            continue
        obj = objects[object_id]
        model, model_colors, model_faces = scan_io.read_ply(path)
        model = model.astype(np.float64)
        scanned = positions[vertex_objects == object_id].astype(np.float64)
        report = dict(id=object_id, category=obj["category"], scanned_vertices=int(len(scanned)))
        if "roomplan_target" in obj:
            report["roomplan_target"] = int(obj["roomplan_target"])

        if not args.no_fit and len(scanned) >= 50:
            transform, before, after, coverage = fit_to_scan(model, model_faces, scanned)
            accepted = after < before and rotation_degrees(transform) < 30 and np.linalg.norm(transform[:3, 3]) < 0.5
            if accepted:
                model = apply(transform, model)
            report.update(fit_accepted=bool(accepted), scan_coverage=round(coverage, 3),
                          scan_to_model_median_before_m=round(before, 4),
                          scan_to_model_median_after_m=round(after, 4),
                          fit_scale=round(float(np.cbrt(np.linalg.det(transform[:3, :3]))), 4),
                          fit_rotation_deg=round(rotation_degrees(transform), 2),
                          fit_shift_m=round(float(np.linalg.norm(transform[:3, 3])), 4))

        bottom = np.percentile(model[:, 1], 0.5)
        if abs(bottom - floor_y) < 0.15:
            model[:, 1] += floor_y - bottom
            report["floor_shift_m"] = round(float(floor_y - bottom), 4)

        # Remove the scanned object, and scan surface hugging the model, but never the floor.
        near = surface_distance(model, model_faces, positions) < args.cut_distance
        remove = ((vertex_objects == object_id) | near) & (positions[:, 1] > floor_y + scan_io.FLOOR_MARGIN)
        report["scan_vertices_removed"] = int(remove.sum())
        remove_vertex |= remove

        name = f"object_{object_id:02d}_{obj['category'].replace(' ', '_')}.ply"
        scan_io.write_ply(os.path.join(out_dir, name), model, model_colors, model_faces)
        fitted.append((model, model_colors, model_faces))
        placement.append(report)
        if "roomplan_target" in obj:
            replaced_target_ids.add(int(obj["roomplan_target"]))
        print("assemble: " + ", ".join(f"{k} {v}" for k, v in report.items()))

    keep_face = ~remove_vertex[faces].any(axis=1)
    room, room_colors, room_faces = compact(positions, colors, faces[keep_face])
    targets = [target for target in scan_io.roomplan_targets(args.scan_dir)
               if target["id"] in replaced_target_ids]
    fills, fill_reports = local_surface_patches(
        positions, colors, targets, scan_io.roomplan_surfaces(args.scan_dir))

    room_parts = [(room, room_colors, room_faces)] + fills
    room_with_fills = merge_parts(room_parts)
    scan_io.write_ply(os.path.join(out_dir, "room_without_furniture.ply"), *room_with_fills)

    parts = room_parts + fitted
    scan_io.write_ply(os.path.join(out_dir, "room_twin.ply"), *merge_parts(parts))
    with open(os.path.join(out_dir, "placement.json"), "w") as f:
        json.dump(dict(floor_y=floor_y, objects=placement, local_surface_fills=fill_reports), f, indent=1)
    print(f"assemble: {len(fitted)} models placed; removed {np.count_nonzero(~keep_face)} of {len(faces)} scan triangles; "
          f"added {len(fills)} local RoomPlan fills; room_twin.ply has {sum(len(p[2]) for p in parts)} triangles")


def local_surface_patches(positions, colors, targets, surfaces, margin=0.08):
    """Small RoomPlan planes behind furniture that was actually replaced.

    The detailed scan remains authoritative everywhere else.  A floor patch is
    emitted only when the bottom of a target reaches a RoomPlan floor; a wall
    patch only when its OBB reaches that wall.  Its colour comes from nearby
    detailed-mesh samples outside the furniture box, so this is a local hole
    repair rather than a clean RoomPlan reconstruction of the whole room.
    """
    parts, reports = [], []
    defaults = {"floor": np.array([176, 160, 138], np.uint8),
                "wall": np.array([226, 222, 214], np.uint8)}
    for target in targets:
        corners = scan_io.box_corners(target)
        for surface in surfaces:
            local = apply(surface["inverse"], corners)
            maximum_gap = 0.18 if surface["kind"] == "floor" else 0.22
            if np.min(np.abs(local[:, 2])) > maximum_gap:
                continue

            half = surface["dimensions"][:2] / 2
            lo = np.maximum(local[:, :2].min(axis=0) - margin, -half)
            hi = np.minimum(local[:, :2].max(axis=0) + margin, half)
            if np.any(hi - lo < 0.05):
                continue

            # Use a single median colour sampled from the detailed surface
            # surrounding the hole. Exclude the target itself so a red chair
            # does not turn its repaired wall red.
            scan_local = apply(surface["inverse"], positions)
            sample_margin = 0.25
            around = (np.abs(scan_local[:, 2]) < 0.08) \
                & (scan_local[:, 0] >= lo[0] - sample_margin) \
                & (scan_local[:, 0] <= hi[0] + sample_margin) \
                & (scan_local[:, 1] >= lo[1] - sample_margin) \
                & (scan_local[:, 1] <= hi[1] + sample_margin)
            outside_hole = (scan_local[:, 0] < lo[0]) | (scan_local[:, 0] > hi[0]) \
                | (scan_local[:, 1] < lo[1]) | (scan_local[:, 1] > hi[1])
            outside_object = ~scan_io.points_in_target(positions, target, margin=0.025)
            samples = colors[around & outside_hole & outside_object]
            colour = np.median(samples, axis=0).astype(np.uint8) if len(samples) >= 12 \
                else defaults[surface["kind"]]

            patch_local = np.array([
                [lo[0], lo[1], 0], [hi[0], lo[1], 0],
                [hi[0], hi[1], 0], [lo[0], hi[1], 0],
            ], np.float64)
            patch = apply(surface["transform"], patch_local)
            # Both windings make the repair visible from either side without
            # assuming how a downstream PLY viewer configures face culling.
            patch_faces = np.array([[0, 1, 2], [0, 2, 3],
                                    [2, 1, 0], [3, 2, 0]], np.int64)
            patch_colors = np.tile(colour, (4, 1))
            parts.append((patch, patch_colors, patch_faces))
            reports.append(dict(
                roomplan_target=int(target["id"]), surface=surface["kind"],
                width_m=round(float(hi[0] - lo[0]), 4),
                height_m=round(float(hi[1] - lo[1]), 4),
                sampled_vertices=int(len(samples)), colour=colour.tolist()))
    return parts, reports


def merge_parts(parts):
    offsets = np.cumsum([0] + [len(part[0]) for part in parts])
    return (np.concatenate([part[0] for part in parts]),
            np.concatenate([part[1] for part in parts]),
            np.concatenate([part[2] + offset for part, offset in zip(parts, offsets)]))


def sample_surface(positions, faces, count=200_000, seed=0):
    rng = np.random.default_rng(seed)
    a, b, c = (positions[faces[:, i]] for i in range(3))
    areas = 0.5 * np.linalg.norm(np.cross(b - a, c - a), axis=1)
    chosen = rng.choice(len(faces), size=count, p=areas / areas.sum())
    r1, r2 = rng.random(count), rng.random(count)
    flip = r1 + r2 > 1
    r1[flip], r2[flip] = 1 - r1[flip], 1 - r2[flip]
    return a[chosen] + r1[:, None] * (b[chosen] - a[chosen]) + r2[:, None] * (c[chosen] - a[chosen])


def surface_distance(model, model_faces, points):
    samples = np.concatenate([model, sample_surface(model, model_faces)])
    return cKDTree(samples).query(points, distance_upper_bound=0.5)[0]


def fit_to_scan(model, model_faces, scanned, iterations=40, min_coverage=0.6):
    """ICP from the scanned points to the model. Returns the 4x4 transform that
    moves the model onto the scan, the median scan-to-model distance before and
    after, and the fraction of the model's surface the scan covers.

    A partial scan can't pin down scale (a bigger chair fits its front and seat
    just as well), so the fit is rigid unless the scan covers `min_coverage`
    of the model; SAM 3D's scale is already metric from the LiDAR point map."""
    samples = np.concatenate([model, sample_surface(model, model_faces)])
    tree = cKDTree(samples)
    before = float(np.median(tree.query(scanned)[0]))
    transform = icp(tree, samples, scanned, np.eye(4), iterations, allow_scale=False)
    coverage = float(np.mean(cKDTree(scanned).query(apply(transform, samples))[0] < 0.08))
    if coverage >= min_coverage:
        transform = icp(tree, samples, scanned, transform, iterations, allow_scale=True)
    _, nearest = tree.query(apply(np.linalg.inv(transform), scanned))
    after = float(np.median(np.linalg.norm(apply(transform, samples[nearest]) - scanned, axis=1)))
    return transform, before, after, coverage


def icp(tree, samples, scanned, transform, iterations, allow_scale):
    for i in range(iterations):
        _, nearest = tree.query(apply(np.linalg.inv(transform), scanned))
        targets = apply(transform, samples[nearest])
        distances = np.linalg.norm(targets - scanned, axis=1)
        inliers = distances < max(0.02, 0.15 * (1 - i / iterations))
        if inliers.sum() < 30:
            break
        transform = similarity(targets[inliers], scanned[inliers], allow_scale) @ transform
    return transform


def similarity(source, target, allow_scale, scale_range=(0.8, 1.25)):
    """Umeyama: the (optionally scaled) rigid transform taking source onto target."""
    mu_s, mu_t = source.mean(0), target.mean(0)
    s, t = source - mu_s, target - mu_t
    u, d, vt = np.linalg.svd(t.T @ s / len(s))
    sign = np.eye(3)
    if np.linalg.det(u) * np.linalg.det(vt) < 0:
        sign[2, 2] = -1
    rotation = u @ sign @ vt
    scale = np.trace(np.diag(d) @ sign) / (s ** 2).sum(axis=1).mean()
    if not allow_scale or not scale_range[0] <= scale <= scale_range[1]:
        scale = 1.0
    result = np.eye(4)
    result[:3, :3] = scale * rotation
    result[:3, 3] = mu_t - scale * rotation @ mu_s
    return result


def apply(transform, points):
    return points @ transform[:3, :3].T + transform[:3, 3]


def rotation_degrees(transform):
    rotation = transform[:3, :3] / np.cbrt(np.linalg.det(transform[:3, :3]))
    return float(np.degrees(np.arccos(np.clip((np.trace(rotation) - 1) / 2, -1, 1))))


def compact(positions, colors, faces):
    used = np.unique(faces)
    remap = np.full(len(positions), -1, np.int64)
    remap[used] = np.arange(len(used))
    return positions[used], colors[used], remap[faces]


if __name__ == "__main__":
    main()
