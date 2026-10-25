"""Builds the furniture the voice agent can add, from a room twin's SAM 3D models.

    python3 Voice/make_library.py [scans/<scan>/twin]

Takes the first model of each kind (object_NN_<kind>.ply) and writes
RoomTwin/Library/furniture-<kind>.ply, which the app bundles. Each model is
moved to stand on y = 0, centred on the origin, and turned to face +z: for
chairs and sofas, away from the backrest; for tables and stools, with their
long side along x. Defaults to the newest scan with a twin.
"""

import glob
import os
import re
import sys

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "Furniture"))
import scan_io  # noqa: E402

OUT = os.path.join(ROOT, "RoomTwin", "Library")
HAS_BACK = {"chair", "sofa", "armchair", "bench"}


def front_angle(positions, kind):
    """Rotation about +y that turns the model's front to +z."""
    xz = positions[:, [0, 2]]
    if kind in HAS_BACK:
        height = positions[:, 1].max()
        back = xz[positions[:, 1] > 0.6 * height].mean(axis=0) - xz.mean(axis=0)
        if np.linalg.norm(back) > 0.02:
            fx, fz = -back
            return np.arctan2(-fx, fz)
    # No backrest to go by: put the long side along x.
    _, vectors = np.linalg.eigh(np.cov((xz - xz.mean(axis=0)).T))
    long_side = vectors[:, -1]
    return np.arctan2(long_side[1], long_side[0])


def normalise(positions, kind):
    p = positions.astype(np.float64)
    angle = front_angle(p - [0, p[:, 1].min(), 0], kind)
    c, s = np.cos(angle), np.sin(angle)
    rotation = np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])
    p = p @ rotation.T
    lo, hi = p.min(axis=0), p.max(axis=0)
    p -= [(lo[0] + hi[0]) / 2, lo[1], (lo[2] + hi[2]) / 2]
    return p.astype(np.float32)


def main():
    twins = sys.argv[1:] or sorted(glob.glob(os.path.join(ROOT, "scans", "*", "twin")))[-1:]
    if not twins:
        sys.exit("no scans/<scan>/twin folder; run Furniture/run_on_colab.sh first")
    os.makedirs(OUT, exist_ok=True)
    done = set()
    for path in sorted(glob.glob(os.path.join(twins[0], "object_*_*.ply"))):
        kind = re.match(r"object_\d+_(.+)\.ply", os.path.basename(path)).group(1)
        if kind in done:
            continue
        positions, colors, faces = scan_io.read_ply(path)
        positions = normalise(positions, kind)
        out = os.path.join(OUT, f"furniture-{kind}.ply")
        scan_io.write_ply(out, positions, colors, faces,
                          comment="RoomTwin furniture library, metres, +y up, standing on y = 0, facing +z")
        size = positions.max(axis=0) - positions.min(axis=0)
        print(f"{kind}: {len(faces)} triangles, {size[0]:.2f} x {size[1]:.2f} x {size[2]:.2f} m -> {out}")
        done.add(kind)


if __name__ == "__main__":
    main()
