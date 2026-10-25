"""Offline regression test for SAM Furniture's RoomPlan-constrained path.

    python sam_mode_test.py [output dir]

Reuses the synthetic room and masks from synthetic_test.py, adds the same
RoomPlan + .sam.json sidecars exported by the iOS mode, and verifies that the
pipeline creates exactly those detected targets plus local floor repair planes.
No GPU or SAM checkpoints are needed.
"""

import json
import os
import sys
import tempfile

import numpy as np

import scan_io
import synthetic_test


def roomplan_object(identifier, category, lo, hi):
    transform = np.eye(4)
    transform[:3, 3] = (lo + hi) / 2
    return dict(identifier=identifier, category={category: {}}, confidence={"high": {}},
                dimensions=(hi - lo).tolist(), transform=transform.flatten(order="F").tolist())


def install_sidecars(scan_dir):
    objects = []
    for target_id, (category, (lo, hi, _)) in enumerate(synthetic_test.BOXES.items()):
        objects.append(roomplan_object(f"target-{target_id}", category, lo, hi))

    # Local XY is world X/-Z and local Z is world up, matching RoomPlan's
    # convention that floor geometry lies on local z = 0.
    floor_transform = np.eye(4)
    floor_transform[:3, :3] = np.array([[1, 0, 0], [0, 0, 1], [0, -1, 0]], float)
    room = dict(objects=objects, walls=[], floors=[dict(
        identifier="floor-0", category={"floor": {}}, confidence={"high": {}},
        dimensions=[5.0, 5.0, 0.0], transform=floor_transform.flatten(order="F").tolist())])
    roomplan_name = "RoomTwin-2026-01-01-000000.roomplan.json"
    with open(os.path.join(scan_dir, roomplan_name), "w") as f:
        json.dump(room, f)
    with open(os.path.join(scan_dir, "RoomTwin-2026-01-01-000000.sam.json"), "w") as f:
        json.dump(dict(version=1, mode="samFurnitureReplacement", detectedFurnitureOnly=True,
                       localSurfaceFill=True, roomPlanFile=roomplan_name,
                       detailedMeshFile="RoomTwin-2026-01-01-000000.ply",
                       targetCount=len(objects)), f)

    target_by_category = {target["category"]: target["id"] for target in scan_io.roomplan_targets(scan_dir)}
    segment_dir = os.path.join(scan_dir, "segments")
    for name in os.listdir(segment_dir):
        if not name.endswith(".npz"):
            continue
        path = os.path.join(segment_dir, name)
        data = np.load(path, allow_pickle=True)
        labels = data["labels"]
        np.savez_compressed(path, labels=labels, scores=data["scores"], boxes=data["boxes"],
                            target_ids=np.array([target_by_category[str(label)] for label in labels], np.int32),
                            masks=data["masks"], shape=data["shape"])


def main():
    scan_dir = sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp(prefix="roomtwin-sam-mode-")
    os.makedirs(scan_dir, exist_ok=True)
    synthetic_test.make_scan(scan_dir)
    install_sidecars(scan_dir)
    synthetic_test.run("lift.py", scan_dir)
    with open(os.path.join(scan_dir, "objects.json")) as f:
        objects = json.load(f)
    failures = []
    if len(objects) != len(synthetic_test.BOXES):
        failures.append(f"lift created {len(objects)} objects for {len(synthetic_test.BOXES)} targets")
    if any("roomplan_target" not in obj for obj in objects):
        failures.append("one or more objects lost their RoomPlan target id")

    synthetic_test.make_generated(scan_dir, objects)
    synthetic_test.run("assemble.py", scan_dir)
    with open(os.path.join(scan_dir, "twin", "placement.json")) as f:
        placement = json.load(f)
    fills = placement.get("local_surface_fills", [])
    floor_targets = {fill["roomplan_target"] for fill in fills if fill["surface"] == "floor"}
    expected = {obj["roomplan_target"] for obj in objects}
    if floor_targets != expected:
        failures.append(f"local floor fills cover targets {sorted(floor_targets)}, expected {sorted(expected)}")
    if any("roomplan_target" not in report for report in placement["objects"]):
        failures.append("placement report lost a RoomPlan target id")

    print("\n" + ("PASS" if not failures else "FAIL:\n  " + "\n  ".join(failures)) + f"  ({scan_dir})")
    raise SystemExit(1 if failures else 0)


if __name__ == "__main__":
    main()
