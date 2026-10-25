"""Step 2: decide which scan vertices belong to which piece of furniture.

    python lift.py SCAN_DIR [--min-vertices 300] [--min-ratio 0.5]

Each keyframe votes: every scan vertex it saw gets a vote for each category
whose SAM 3 mask covers it. A vertex covered in at least `min-ratio` of the
keyframes that saw it takes that category, and connected vertices of one
category form a piece (floor-height vertices excluded, since masks bleed
onto the floor around each base). Pieces that keep showing up inside the same instance
mask (a chair's seat and back, split by a thin unlabelled strip) are merged
into one object. For each object, the keyframe with the most complete,
least cluttered, unclipped view is picked for SAM 3D Objects.

Writes SCAN_DIR/objects.json, SCAN_DIR/vertex_objects.npy (object id per
scan vertex, -1 for none) and SCAN_DIR/debug/object_NN_<category>.jpg showing
the chosen view.
"""

import argparse
import json
import os

import numpy as np
from PIL import Image
from scipy.sparse import coo_matrix
from scipy.sparse.csgraph import connected_components

import scan_io

SYNONYMS = {"desk": "table", "couch": "sofa", "nightstand": "cabinet", "dresser": "cabinet"}


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("scan_dir")
    parser.add_argument("--min-vertices", type=int, default=300)
    parser.add_argument("--min-ratio", type=float, default=0.5)
    args = parser.parse_args()

    positions, _, faces = scan_io.read_ply(scan_io.latest_mesh(args.scan_dir))
    keyframes = {kf.index: kf for kf in scan_io.load_keyframes(args.scan_dir)}
    targets = scan_io.roomplan_targets(args.scan_dir)
    if targets:
        lift_roomplan_targets(args.scan_dir, positions, faces, keyframes, targets,
                              args.min_vertices, args.min_ratio)
        return
    n = len(positions)

    # Pass 1: votes per vertex, and the vertices inside each instance mask.
    seen = np.zeros(n, np.uint16)
    votes = {}
    instances = []
    visible_ids = {}
    for kf in keyframes.values():
        segments = scan_io.load_segments(args.scan_dir, kf.index)
        if segments is None:
            continue
        visible, ui, vi = kf.visible(positions)
        ids = np.flatnonzero(visible).astype(np.int32)
        visible_ids[kf.index] = ids
        seen[ids] += 1
        covered = {}
        for j, (label, score, mask) in enumerate(zip(segments["labels"], segments["scores"], segments["masks"])):
            category = SYNONYMS.get(label, label)
            inside = mask[vi[ids], ui[ids]]
            covered[category] = covered.get(category, np.zeros(len(ids), bool)) | inside
            clipped = mask[0].any() or mask[-1].any() or mask[:, 0].any() or mask[:, -1].any()
            instances.append(dict(frame=kf.index, instance=j, category=category, label=label,
                                  score=float(score), members=ids[inside], clipped=bool(clipped)))
        for category, inside in covered.items():
            votes.setdefault(category, np.zeros(n, np.uint16))[ids[inside]] += 1
    print(f"lift: {len(visible_ids)} segmented keyframes, {len(instances)} instances, {n} scan vertices")
    if not votes:
        raise SystemExit("lift: SAM 3 found no furniture")

    categories = sorted(votes)
    table = np.stack([votes[c] for c in categories], axis=1)
    best = table.argmax(axis=1)
    label = np.where((seen >= 2) & (table[np.arange(n), best] >= args.min_ratio * np.maximum(seen, 1)), best, -1)
    # Masks bleed onto the floor around each piece's base; the floor is never furniture.
    floor_y = scan_io.estimate_floor(positions, faces)
    label[positions[:, 1] < floor_y + scan_io.FLOOR_MARGIN] = -1

    # Connected pieces of one category.
    edges = np.concatenate([faces[:, [0, 1]], faces[:, [1, 2]], faces[:, [2, 0]]])
    edges = edges[(label[edges[:, 0]] >= 0) & (label[edges[:, 0]] == label[edges[:, 1]])]
    graph = coo_matrix((np.ones(len(edges)), (edges[:, 0], edges[:, 1])), shape=(n, n))
    _, components = connected_components(graph, directed=False)
    labelled = label >= 0
    _, compact = np.unique(components[labelled], return_inverse=True)
    piece = np.full(n, -1, np.int64)
    piece[labelled] = compact
    sizes = np.bincount(compact)
    piece_label = np.zeros(len(sizes), np.int64)
    piece_label[compact] = label[labelled]

    # Pass 2: merge pieces that one instance mask covers at least half of, at least twice.
    parent = np.arange(len(sizes))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    together = {}
    for inst in instances:
        ids = visible_ids[inst["frame"]]
        visible_count = np.bincount(piece[ids][piece[ids] >= 0], minlength=len(sizes))
        member_pieces = piece[inst["members"]]
        inside_count = np.bincount(member_pieces[member_pieces >= 0], minlength=len(sizes))
        mostly = np.flatnonzero((inside_count >= 0.5 * np.maximum(visible_count, 1)) & (inside_count >= 20))
        for a in mostly:
            for b in mostly:
                if a < b and piece_label[a] == piece_label[b]:
                    together[(a, b)] = together.get((a, b), 0) + 1
    for (a, b), count in together.items():
        if count >= 2:
            parent[find(a)] = find(b)

    roots = np.array([find(p) for p in range(len(sizes))])
    vertex_root = np.where(piece >= 0, roots[np.maximum(piece, 0)], -1)
    root_sizes = np.bincount(vertex_root[vertex_root >= 0], minlength=len(sizes))
    keep = [r for r in np.flatnonzero(root_sizes >= args.min_vertices)]
    keep.sort(key=lambda r: -root_sizes[r])

    vertex_objects = np.full(n, -1, np.int32)
    objects = []
    debug_dir = os.path.join(args.scan_dir, "debug")
    os.makedirs(debug_dir, exist_ok=True)
    for object_id, root in enumerate(keep):
        members = np.flatnonzero(vertex_root == root)
        category = categories[np.bincount(label[members]).argmax()]
        in_object = np.zeros(n, bool)
        in_object[members] = True

        # Most complete and least cluttered view; clipped masks only as a last resort.
        best_view, best_score = None, 0.0
        for inst in instances:
            if inst["category"] != category or not len(inst["members"]):
                continue
            overlap = in_object[inst["members"]].sum()
            precision = overlap / len(inst["members"])
            coverage = overlap / len(members)
            score = coverage * precision * inst["score"] * (0.3 if inst["clipped"] else 1.0)
            if score > best_score:
                best_view, best_score = dict(inst, precision=float(precision), coverage=float(coverage)), score
        if best_view is None:
            print(f"lift: object {object_id} ({category}, {len(members)} vertices) has no usable view; skipped")
            continue

        vertex_objects[members] = len(objects)
        p = positions[members]
        objects.append(dict(id=len(objects), category=category, vertices=int(len(members)),
                            frame=best_view["frame"], instance=best_view["instance"],
                            label=best_view["label"], view_score=round(float(best_score), 4),
                            coverage=round(best_view["coverage"], 3), precision=round(best_view["precision"], 3),
                            clipped=best_view["clipped"],
                            centroid=p.mean(axis=0).round(4).tolist(),
                            bbox_min=p.min(axis=0).round(4).tolist(), bbox_max=p.max(axis=0).round(4).tolist()))
        save_debug_view(os.path.join(debug_dir, f"object_{len(objects) - 1:02d}_{category.replace(' ', '_')}.jpg"),
                        keyframes[best_view["frame"]], scan_io.load_segments(args.scan_dir, best_view["frame"]),
                        best_view["instance"], positions[members])
        o = objects[-1]
        print(f"lift: object {o['id']:2d} {category:12s} {o['vertices']:6d} vertices, view keyframe {o['frame']} "
              f"(coverage {o['coverage']:.2f}, precision {o['precision']:.2f}{', clipped' if o['clipped'] else ''})")

    np.save(os.path.join(args.scan_dir, "vertex_objects.npy"), vertex_objects)
    with open(os.path.join(args.scan_dir, "objects.json"), "w") as f:
        json.dump(objects, f, indent=1)
    print(f"lift: {len(objects)} objects, {np.count_nonzero(vertex_objects >= 0)} of {n} vertices assigned")


def lift_roomplan_targets(scan_dir, positions, faces, keyframes, targets, min_vertices, min_ratio):
    """Assigns scan vertices to explicit RoomPlan furniture instances.

    Unlike the legacy category/connected-component path, this cannot invent a
    new chair or merge two nearby chairs: every output object must have one
    RoomPlan target id and stay inside that target's expanded OBB.
    """
    n = len(positions)
    target_by_id = {target["id"]: target for target in targets}
    seen = {target["id"]: np.zeros(n, np.uint16) for target in targets}
    votes = {target["id"]: np.zeros(n, np.uint16) for target in targets}
    instances = []

    for kf in keyframes.values():
        segments = scan_io.load_segments(scan_dir, kf.index)
        if segments is None:
            continue
        visible, ui, vi = kf.visible(positions)
        ids = np.flatnonzero(visible).astype(np.int32)
        target_members = {}
        for target in targets:
            members = ids[scan_io.points_in_target(positions[ids], target, margin=0.08)]
            target_members[target["id"]] = members
            seen[target["id"]][members] += 1
        for instance, (label, score, mask, target_id) in enumerate(zip(
                segments["labels"], segments["scores"], segments["masks"], segments["target_ids"])):
            target_id = int(target_id)
            if target_id not in target_by_id:
                continue
            candidates = target_members[target_id]
            inside = mask[vi[candidates], ui[candidates]]
            members = candidates[inside]
            votes[target_id][members] += 1
            clipped = mask[0].any() or mask[-1].any() or mask[:, 0].any() or mask[:, -1].any()
            instances.append(dict(frame=kf.index, instance=instance, target=target_id,
                                  score=float(score), members=members, clipped=bool(clipped)))

    floor_y = scan_io.estimate_floor(positions, faces)
    target_ids = [target["id"] for target in targets]
    accepted = []
    for target_id in target_ids:
        # SAM Furniture capture intentionally records exactly one high-quality
        # frame after at least 80% of a stable RoomPlan box enters the viewport.
        enough = (seen[target_id] >= 1) & (votes[target_id] >= min_ratio * np.maximum(seen[target_id], 1))
        enough &= positions[:, 1] >= floor_y + scan_io.FLOOR_MARGIN
        accepted.append(enough)
    table = np.stack([votes[target_id] for target_id in target_ids], axis=1)
    label = np.full(n, -1, np.int32)
    if len(target_ids):
        best = table.argmax(axis=1)
        for column, mask in enumerate(accepted):
            label[mask & (best == column)] = column

    vertex_objects = np.full(n, -1, np.int32)
    objects = []
    debug_dir = os.path.join(scan_dir, "debug")
    os.makedirs(debug_dir, exist_ok=True)
    for column, target in enumerate(targets):
        members = np.flatnonzero(label == column)
        if len(members) < min_vertices:
            print(f"lift: RoomPlan target {target['id']} {target['category']} has only {len(members)} vertices; skipped")
            continue
        in_object = np.zeros(n, bool)
        in_object[members] = True
        best_view, best_score = None, 0.0
        for inst in instances:
            if inst["target"] != target["id"] or not len(inst["members"]):
                continue
            overlap = in_object[inst["members"]].sum()
            precision = overlap / len(inst["members"])
            coverage = overlap / len(members)
            score = coverage * precision * inst["score"] * (0.3 if inst["clipped"] else 1.0)
            if score > best_score:
                best_view = dict(inst, precision=float(precision), coverage=float(coverage))
                best_score = score
        if best_view is None:
            print(f"lift: RoomPlan target {target['id']} {target['category']} has no usable photo; skipped")
            continue
        object_id = len(objects)
        vertex_objects[members] = object_id
        p = positions[members]
        objects.append(dict(
            id=object_id, category=target["category"], roomplan_target=target["id"],
            roomplan_identifier=target["identifier"], vertices=int(len(members)),
            frame=best_view["frame"], instance=best_view["instance"], label=target["prompt"],
            view_score=round(float(best_score), 4), coverage=round(best_view["coverage"], 3),
            precision=round(best_view["precision"], 3), clipped=best_view["clipped"],
            centroid=p.mean(axis=0).round(4).tolist(), bbox_min=p.min(axis=0).round(4).tolist(),
            bbox_max=p.max(axis=0).round(4).tolist()))
        save_debug_view(os.path.join(debug_dir, f"object_{object_id:02d}_{target['category'].replace(' ', '_')}.jpg"),
                        keyframes[best_view["frame"]], scan_io.load_segments(scan_dir, best_view["frame"]),
                        best_view["instance"], positions[members])
        print(f"lift: target {target['id']:2d} -> object {object_id:2d} {target['category']:12s} "
              f"{len(members):6d} vertices, keyframe {best_view['frame']}")

    np.save(os.path.join(scan_dir, "vertex_objects.npy"), vertex_objects)
    with open(os.path.join(scan_dir, "objects.json"), "w") as f:
        json.dump(objects, f, indent=1)
    print(f"lift: {len(objects)} of {len(targets)} RoomPlan targets ready; "
          f"{np.count_nonzero(vertex_objects >= 0)} of {n} vertices assigned")


def save_debug_view(path, kf, segments, instance, object_points):
    """The chosen keyframe with the SAM 3 mask tinted and the object's scan vertices dotted."""
    image = kf.image.astype(np.float32)
    mask = segments["masks"][instance]
    image[mask] = 0.5 * image[mask] + 0.5 * np.array([255, 60, 60])
    u, v, z = kf.project(object_points)
    ok = (z > 0) & (u >= 0) & (u < kf.width - 1) & (v >= 0) & (v < kf.height - 1)
    image[v[ok].astype(int), u[ok].astype(int)] = [60, 255, 60]
    small = Image.fromarray(image.clip(0, 255).astype(np.uint8))
    small.thumbnail((720, 720))
    small.save(path, quality=85)


if __name__ == "__main__":
    main()
