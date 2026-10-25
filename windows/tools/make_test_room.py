"""Writes a small synthetic room as a PLY like the iPhone app's exports.

    python tools/make_test_room.py public/test-room.ply   (from windows/)

A 4 x 5 m room, 2.6 m high, with a doorway, a window gap, a table and a
sofa block, finely triangulated like a scan: binary little-endian, metres,
+y up, vertex colours, faces wound counter-clockwise seen from inside the
room (so their normals point into it). The desktop app's "Test room"
button opens it, for trying things without a real scan.
"""

import struct
import sys

STEP = 0.1
positions, colors, faces = [], [], []


def quad(origin, u, v, normal, color, holes=()):
    """A rectangle from `origin` spanning vectors u and v, cut into STEP squares, facing `normal`.

    `holes` are (u0, u1, v0, v1) ranges, as fractions, left open (a door, a window).
    """
    nu = max(1, round(length(u) / STEP))
    nv = max(1, round(length(v) / STEP))
    for i in range(nu):
        for j in range(nv):
            cu, cv = (i + 0.5) / nu, (j + 0.5) / nv
            if any(u0 <= cu <= u1 and v0 <= cv <= v1 for u0, u1, v0, v1 in holes):
                continue
            corners = [add(origin, scale(u, (i + a) / nu), scale(v, (j + b) / nv)) for a, b in ((0, 0), (1, 0), (1, 1), (0, 1))]
            shade = 0.92 + 0.08 * ((i * 7 + j * 3) % 5) / 4
            base = len(positions)
            for p in corners:
                positions.append(p)
                colors.append(tuple(min(255, int(c * shade)) for c in color))
            for tri in ((0, 1, 2), (0, 2, 3)):
                a, b, c = (corners[k] for k in tri)
                n = cross(sub(b, a), sub(c, a))
                order = tri if dot(n, normal) > 0 else (tri[0], tri[2], tri[1])
                faces.append(tuple(base + k for k in order))


def box(lo, hi, color):
    """A closed box, faces pointing outwards (into the room)."""
    (x0, y0, z0), (x1, y1, z1) = lo, hi
    quad((x0, y1, z0), (x1 - x0, 0, 0), (0, 0, z1 - z0), (0, 1, 0), color)
    quad((x0, y0, z1), (x1 - x0, 0, 0), (0, y1 - y0, 0), (0, 0, 1), color)
    quad((x0, y0, z0), (x1 - x0, 0, 0), (0, y1 - y0, 0), (0, 0, -1), color)
    quad((x1, y0, z0), (0, 0, z1 - z0), (0, y1 - y0, 0), (1, 0, 0), color)
    quad((x0, y0, z0), (0, 0, z1 - z0), (0, y1 - y0, 0), (-1, 0, 0), color)


def main(path):
    w, d, h = 4.0, 5.0, 2.6
    x0, z0 = -w / 2, -d / 2
    quad((x0, 0, z0), (w, 0, 0), (0, 0, d), (0, 1, 0), (150, 120, 90))          # floor
    quad((x0, h, z0), (w, 0, 0), (0, 0, d), (0, -1, 0), (235, 235, 230))        # ceiling
    quad((x0, 0, z0), (w, 0, 0), (0, h, 0), (0, 0, 1), (200, 190, 175),         # back wall, with a window
         holes=[(0.35, 0.65, 0.35, 0.75)])
    quad((x0, 0, z0 + d), (w, 0, 0), (0, h, 0), (0, 0, -1), (200, 190, 175),    # front wall, with a door
         holes=[(0.1, 0.32, 0.0, 0.8)])
    quad((x0, 0, z0), (0, 0, d), (0, h, 0), (1, 0, 0), (170, 185, 200))         # left wall
    quad((x0 + w, 0, z0), (0, 0, d), (0, h, 0), (-1, 0, 0), (170, 185, 200))    # right wall
    box((-0.5, 0, -0.4), (0.5, 0.75, 0.4), (120, 80, 50))                       # table
    box((0.9, 0, -2.45), (1.95, 0.85, -1.6), (70, 90, 140))                     # sofa block against the back wall

    with open(path, "wb") as f:
        f.write(("ply\nformat binary_little_endian 1.0\ncomment RoomTwin test room, metres, +y up\n"
                 f"element vertex {len(positions)}\nproperty float x\nproperty float y\nproperty float z\n"
                 "property uchar red\nproperty uchar green\nproperty uchar blue\n"
                 f"element face {len(faces)}\nproperty list uchar int vertex_indices\nend_header\n").encode("ascii"))
        for p, c in zip(positions, colors):
            f.write(struct.pack("<fffBBB", *p, *c))
        for face in faces:
            f.write(struct.pack("<Biii", 3, *face))
    print(f"wrote {path}: {len(positions)} vertices, {len(faces)} triangles")


def add(*vs): return tuple(sum(c) for c in zip(*vs))
def sub(a, b): return tuple(x - y for x, y in zip(a, b))
def scale(v, s): return tuple(x * s for x in v)
def dot(a, b): return sum(x * y for x, y in zip(a, b))
def length(v): return dot(v, v) ** 0.5
def cross(a, b): return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "test-room.ply")
