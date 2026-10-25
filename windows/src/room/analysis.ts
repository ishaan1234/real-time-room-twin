/**
 * What the room's mesh says about the room: the floor height, the core
 * bounds, its walls, and a floor plan of where things stand. Ported from the
 * iPhone app (PreviewScene.swift, RoomWalls.swift, FloorPlan.swift) so
 * furniture lands in the same places on both.
 */

export interface MeshData {
  positions: Float32Array;
  /** Three indices per face. */
  faces: Uint32Array;
}

export type Vec2 = [number, number];
export type Vec3 = [number, number, number];

const dot = (a: Vec3, b: Vec3) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const dot2 = (a: Vec2, b: Vec2) => a[0] * b[0] + a[1] * b[1];
const remainder = (x: number, y: number) => x - y * Math.round(x / y);

/** Visits each face with its corners, the cross product of two edges, and its length. */
function eachFace(mesh: MeshData, visit: (face: number, a: Vec3, b: Vec3, c: Vec3, n: Vec3, length: number) => void) {
  const p = mesh.positions, f = mesh.faces;
  for (let i = 0; i < f.length / 3; i++) {
    const ia = 3 * f[3 * i], ib = 3 * f[3 * i + 1], ic = 3 * f[3 * i + 2];
    const a: Vec3 = [p[ia], p[ia + 1], p[ia + 2]];
    const b: Vec3 = [p[ib], p[ib + 1], p[ib + 2]];
    const c: Vec3 = [p[ic], p[ic + 1], p[ic + 2]];
    const u = [b[0] - a[0], b[1] - a[1], b[2] - a[2]], v = [c[0] - a[0], c[1] - a[1], c[2] - a[2]];
    const n: Vec3 = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]];
    visit(i, a, b, c, n, Math.hypot(n[0], n[1], n[2]));
  }
}

/**
 * Height of the floor: the low end of the upward-facing surfaces, weighted by
 * area, so a floor of a few big triangles (RoomPlan's) outweighs finely
 * meshed furniture. Null if nothing faces up or down.
 */
export function floorHeight(mesh: MeshData): number | null {
  const up: [number, number][] = [], down: [number, number][] = [];
  eachFace(mesh, (_, a, b, c, n, length) => {
    if (length === 0) return;
    if (n[1] > 0.9 * length) up.push([(a[1] + b[1] + c[1]) / 3, length / 2]);
    else if (n[1] < -0.9 * length) down.push([(a[1] + b[1] + c[1]) / 3, length / 2]);
  });
  const sum = (list: [number, number][]) => list.reduce((total, [, area]) => total + area, 0);
  const upArea = sum(up), downArea = sum(down);
  // Whichever way the triangles wind, the floor faces one consistent way.
  const faces = (upArea >= downArea ? up : down).sort((x, y) => x[0] - y[0]);
  let area = 0.05 * Math.max(upArea, downArea);
  for (const [height, faceArea] of faces) {
    area -= faceArea;
    if (area <= 0) return height;
  }
  return faces.length ? faces[faces.length - 1][0] : null;
}

/**
 * The box holding all but the outermost 2% of the surface on each axis, so
 * stray bits seen through a doorway don't push the camera away.
 */
export function coreBounds(mesh: MeshData): { lo: Vec3; hi: Vec3 } {
  const running: number[] = [];
  let total = 0;
  eachFace(mesh, (_, _a, _b, _c, _n, length) => running.push((total += length / 2)));
  const count = Math.min(20_000, running.length);
  const p = mesh.positions, f = mesh.faces;
  const samples: Vec3[] = [];
  let face = 0;
  for (let k = 0; k < count; k++) {
    const target = ((k + 0.5) / count) * total;
    while (face < running.length - 1 && running[face] < target) face++;
    const centre: Vec3 = [0, 0, 0];
    for (let j = 0; j < 3; j++) for (let axis = 0; axis < 3; axis++) centre[axis] += p[3 * f[3 * face + j] + axis] / 3;
    samples.push(centre);
  }
  const lo: Vec3 = [0, 0, 0], hi: Vec3 = [0, 0, 0];
  if (!samples.length) return { lo, hi };
  for (let axis = 0; axis < 3; axis++) {
    const values = samples.map((s) => s[axis]).sort((x, y) => x - y);
    lo[axis] = values[Math.floor((values.length * 2) / 100)];
    hi[axis] = values[Math.floor((values.length * 98) / 100)];
  }
  return { lo, hi };
}

// Walls

/** A wall found in the mesh: a large vertical plane. */
export interface Wall {
  /** Horizontal unit vector out of the wall, into the room. */
  normal: Vec3;
  /** Horizontal unit vector along the wall: to your right as you face it. */
  along: Vec3;
  /** dot(p, normal) for points p on the wall. */
  offset: number;
  /** dot(p, along) over the wall's length. */
  span: [number, number];
  top: number;
  /** The mesh's faces that make it up. */
  faces: number[];
}

/** How far p is in front of the wall; negative behind it. */
export const wallDistance = (wall: Wall, p: Vec3) => dot(p, wall.normal) - wall.offset;

/** The floor point `standoff` metres out from the wall at `s` along it. */
export function wallPoint(wall: Wall, s: number, standoff: number, floorY: number): Vec3 {
  const k = wall.offset + standoff;
  return [s * wall.along[0] + k * wall.normal[0], floorY, s * wall.along[2] + k * wall.normal[2]];
}

/**
 * Finds walls: big vertical planes. Rooms are nearly always built on two
 * perpendicular directions, so the strongest direction of vertical surface
 * (mod 90°) gives four wall directions. Along each, surfaces at the same
 * distance from the origin form one wall. Face normals point into the room.
 */
export function findWalls(mesh: MeshData, floorY: number): Wall[] {
  interface Face { index: number; angle: number; centre: Vec3; area: number }
  const vertical: Face[] = [];
  eachFace(mesh, (index, a, b, c, n, length) => {
    if (length === 0 || Math.abs(n[1]) >= 0.3 * length) return;
    vertical.push({
      index,
      angle: Math.atan2(n[2], n[0]),
      centre: [(a[0] + b[0] + c[0]) / 3, (a[1] + b[1] + c[1]) / 3, (a[2] + b[2] + c[2]) / 3],
      area: length / 2,
    });
  });
  if (!vertical.length) return [];

  // The room's main direction: the angle mod 90° with the most vertical surface, in 1° bins.
  const quarter = Math.PI / 2;
  const bins = new Array<number>(90).fill(0);
  for (const face of vertical) {
    const a = face.angle - quarter * Math.floor(face.angle / quarter);
    bins[Math.min(Math.floor((a / quarter) * 90), 89)] += face.area;
  }
  const smoothed = bins.map((_, i) => bins[(i + 89) % 90] + bins[i] + bins[(i + 1) % 90]);
  const coarse = ((smoothed.indexOf(Math.max(...smoothed)) + 0.5) * quarter) / 90;
  // Refined to the area-weighted mean of faces within 3° of it.
  let sum = 0, weight = 0;
  for (const face of vertical) {
    const offset = remainder(face.angle - coarse, quarter);
    if (Math.abs(offset) < 0.05) {
      sum += offset * face.area;
      weight += face.area;
    }
  }
  const main = coarse + (weight > 0 ? sum / weight : 0);

  const p = mesh.positions, f = mesh.faces;
  const walls: Wall[] = [];
  for (let k = 0; k < 4; k++) {
    const angle = main + k * quarter;
    const normal: Vec3 = [Math.cos(angle), 0, Math.sin(angle)];
    // up × normal
    const along: Vec3 = [normal[2], 0, -normal[0]];
    // Faces within 15° of this direction, by their distance along it.
    let faces = vertical.filter((face) => Math.abs(remainder(face.angle - angle, 2 * Math.PI)) < 0.26);
    while (faces.length) {
      // The 4 cm slab holding the most surface.
      const offsets = faces.map((face) => dot(face.centre, normal));
      let low = Infinity, high = -Infinity;
      for (const d of offsets) {
        low = Math.min(low, d);
        high = Math.max(high, d);
      }
      const slabs = new Array<number>(Math.floor((high - low) / 0.02) + 2).fill(0);
      faces.forEach((face, i) => (slabs[Math.floor((offsets[i] - low) / 0.02)] += face.area));
      const paired = slabs.map((s, i) => s + (i + 1 < slabs.length ? slabs[i + 1] : 0));
      let best = 0;
      paired.forEach((value, i) => value > paired[best] && (best = i));
      if (paired[best] < 0.5) break;
      const centre = low + (best + 1) * 0.02;
      // Everything within 6 cm of it is this wall.
      const wallFaces = faces.filter((_, i) => Math.abs(offsets[i] - centre) < 0.06);
      faces = faces.filter((_, i) => Math.abs(offsets[i] - centre) >= 0.06);

      const area = wallFaces.reduce((total, face) => total + face.area, 0);
      const offset = wallFaces.reduce((total, face) => total + dot(face.centre, normal) * face.area, 0) / area;
      let top = -Infinity, bottom = Infinity, first = Infinity, last = -Infinity;
      for (const face of wallFaces) {
        for (let j = 0; j < 3; j++) {
          const v = 3 * f[3 * face.index + j];
          const point: Vec3 = [p[v], p[v + 1], p[v + 2]];
          top = Math.max(top, point[1]);
          bottom = Math.min(bottom, point[1]);
          const s = dot(point, along);
          first = Math.min(first, s);
          last = Math.max(last, s);
        }
      }
      // Tall and wide enough to be a wall, not a cupboard door or a sofa back.
      if (area < 0.8 || top - floorY < 1.2 || top - bottom < 0.9 || last - first < 0.6) continue;
      walls.push({ normal, along, offset, span: [first, last], top, faces: wallFaces.map((face) => face.index) });
    }
  }
  return walls;
}

// Floor plan

/** A rectangle on the floor: what a piece of furniture covers seen from above. */
export class Footprint {
  /** centre as (x, z); half the width (local x) and depth (local z); turn about +y. */
  constructor(public centre: Vec2, public half: Vec2, public yaw: number) {}

  /** The piece's local (x, z) in the world's (x, z). */
  point(x: number, z: number): Vec2 {
    // A turn by yaw about +y takes local +x to (cos, -sin) and +z to (sin, cos).
    const c = Math.cos(this.yaw), s = Math.sin(this.yaw);
    return [this.centre[0] + c * x + s * z, this.centre[1] - s * x + c * z];
  }

  /** Whether two footprints overlap by more than `tolerance`, by separating axes. */
  overlaps(other: Footprint, tolerance = 0.02) {
    const axes: Vec2[] = [this.yaw, other.yaw].flatMap((a) => [
      [Math.cos(a), -Math.sin(a)] as Vec2,
      [Math.sin(a), Math.cos(a)] as Vec2,
    ]);
    for (const axis of axes) {
      const [a0, a1] = this.projected(axis), [b0, b1] = other.projected(axis);
      if (a1 - tolerance <= b0 || b1 - tolerance <= a0) return false;
    }
    return true;
  }

  private projected(axis: Vec2): [number, number] {
    const { half } = this;
    const values = [
      this.point(-half[0], -half[1]), this.point(half[0], -half[1]),
      this.point(half[0], half[1]), this.point(-half[0], half[1]),
    ].map((corner) => dot2(corner, axis));
    return [Math.min(...values), Math.max(...values)];
  }
}

/**
 * The scan seen from above in 10 cm cells: where something stands between
 * 10 cm and 1.8 m above the floor, and where the floor itself was scanned.
 * Each cell also keeps the lowest and highest scanned point above the floor
 * (under the ceiling), so a piece can tell whether it's clear of, or on top
 * of, what was scanned there.
 */
export class FloorPlan {
  static readonly cell = 0.1;
  private origin: Vec2;
  private columns: number;
  private rows: number;
  private blocked: Uint8Array;
  private floor: Uint8Array;
  private low: Float32Array;
  private high: Float32Array;
  private interior: Uint8Array | null;

  constructor(mesh: MeshData, floorY: number) {
    const p = mesh.positions;
    let lx = Infinity, lz = Infinity, hx = -Infinity, hz = -Infinity, top = -Infinity;
    for (let i = 0; i < p.length; i += 3) {
      lx = Math.min(lx, p[i]);
      hx = Math.max(hx, p[i]);
      lz = Math.min(lz, p[i + 2]);
      hz = Math.max(hz, p[i + 2]);
      top = Math.max(top, p[i + 1]);
    }
    const cell = FloorPlan.cell;
    this.origin = [lx, lz];
    this.columns = Math.floor((hx - lx) / cell) + 1;
    this.rows = Math.floor((hz - lz) / cell) + 1;
    this.blocked = new Uint8Array(this.columns * this.rows);
    this.floor = new Uint8Array(this.columns * this.rows);
    this.low = new Float32Array(this.columns * this.rows).fill(Infinity);
    this.high = new Float32Array(this.columns * this.rows).fill(-Infinity);
    eachFace(mesh, (_, a, b, c) => {
      // Points at most half a cell apart, so a big triangle reaches every cell it crosses.
      const longest = Math.max(distance(a, b), distance(b, c), distance(c, a));
      const n = Math.max(1, Math.ceil(longest / (cell / 2)));
      for (let i = 0; i <= n; i++) {
        for (let j = 0; j <= n - i; j++) {
          const u = i / n, v = j / n;
          const x = a[0] + (b[0] - a[0]) * u + (c[0] - a[0]) * v;
          const y = a[1] + (b[1] - a[1]) * u + (c[1] - a[1]) * v;
          const z = a[2] + (b[2] - a[2]) * u + (c[2] - a[2]) * v;
          const index = this.index([x, z]);
          if (index === null) continue;
          if (Math.abs(y - floorY) < 0.05) this.floor[index] = 1;
          else if (y > floorY + 0.1 && y < floorY + 1.8) this.blocked[index] = 1;
          if (y > floorY + 0.1 && y < top - 0.15) {
            this.low[index] = Math.min(this.low[index], y);
            this.high[index] = Math.max(this.high[index], y);
          }
        }
      }
    });
    this.interior = this.findInterior();
  }

  /**
   * The room's floor area seen from above: the scanned floor, with gaps
   * under 60 cm closed (the edges of a rough scan) and holes filled (floor
   * hidden under furniture). Doorways stay shut, as no floor goes past them.
   */
  private findInterior() {
    const { columns, rows } = this;
    const r = 3;
    const grow = (from: Uint8Array, value: number) => {
      // A cell takes `value` if any cell within r does (square neighbourhood, in two passes).
      const across = new Uint8Array(from.length), out = new Uint8Array(from.length);
      for (let y = 0; y < rows; y++) for (let x = 0; x < columns; x++) {
        let hit = 0;
        for (let k = Math.max(0, x - r); k <= Math.min(columns - 1, x + r) && !hit; k++) hit = Number(from[y * columns + k] === value);
        across[y * columns + x] = hit ? value : 1 - value;
      }
      for (let y = 0; y < rows; y++) for (let x = 0; x < columns; x++) {
        let hit = 0;
        for (let k = Math.max(0, y - r); k <= Math.min(rows - 1, y + r) && !hit; k++) hit = Number(across[k * columns + x] === value);
        out[y * columns + x] = hit ? value : 1 - value;
      }
      return out;
    };
    // Off the grid counts as outside, so erode as if a border of empty cells surrounds it.
    const padded = grow(grow(this.floor, 1), 0);
    for (let y = 0; y < rows; y++) for (let x = 0; x < columns; x++) {
      if (x < r || y < r || x >= columns - r || y >= rows - r) padded[y * columns + x] &&= this.floor[y * columns + x];
    }
    // Fill holes: whatever outside the floor can't be reached from the grid's edge.
    const outside = new Uint8Array(padded.length);
    const queue: number[] = [];
    for (let y = 0; y < rows; y++) for (let x = 0; x < columns; x++) {
      const i = y * columns + x;
      if ((x === 0 || y === 0 || x === columns - 1 || y === rows - 1) && !padded[i]) {
        outside[i] = 1;
        queue.push(i);
      }
    }
    while (queue.length) {
      const i = queue.pop()!, x = i % columns, y = (i - x) / columns;
      for (const [nx, ny] of [[x + 1, y], [x - 1, y], [x, y + 1], [x, y - 1]]) {
        const j = ny * columns + nx;
        if (nx < 0 || ny < 0 || nx >= columns || ny >= rows || outside[j] || padded[j]) continue;
        outside[j] = 1;
        queue.push(j);
      }
    }
    const interior = outside.map((o) => 1 - o);
    // Hardly any floor scanned: no telling where the room ends, so don't hold anything in.
    return interior.reduce((n, v) => n + v, 0) < 20 ? null : interior;
  }

  /** Whether a footprint (less 5 cm all round, for the coarse cells) is all on the room's floor. */
  contains(footprint: Footprint) {
    if (!this.interior) return true;
    const inner: Vec2 = [Math.max(footprint.half[0] - 0.05, 0), Math.max(footprint.half[1] - 0.05, 0)];
    const step = FloorPlan.cell / 2;
    for (let z = -inner[1]; z <= inner[1] + 1e-6; z += step) {
      for (let x = -inner[0]; x <= inner[0] + 1e-6; x += step) {
        const i = this.index(footprint.point(x, z));
        if (i === null || !this.interior[i]) return false;
      }
    }
    const i = this.index(footprint.centre);
    return i !== null && this.interior[i] === 1;
  }

  private index(point: Vec2): number | null {
    const c = Math.floor((point[0] - this.origin[0]) / FloorPlan.cell);
    const r = Math.floor((point[1] - this.origin[1]) / FloorPlan.cell);
    return c >= 0 && c < this.columns && r >= 0 && r < this.rows ? r * this.columns + c : null;
  }

  /** Whether something stands at this floor point (for walking into walls). */
  isBlocked(point: Vec2) {
    const index = this.index(point);
    return index !== null && this.blocked[index] === 1;
  }

  /**
   * Whether a footprint is clear: nothing stands inside it (shrunk by 8 cm,
   * as the cells are coarse and scanned walls are a little rough), and
   * there's scanned floor in it or within 20 cm. Given the heights a piece
   * spans, only what was scanned at those heights is in the way.
   */
  isClear(footprint: Footprint, span?: [number, number]) {
    const inner: Vec2 = [Math.max(footprint.half[0] - 0.08, 0.05), Math.max(footprint.half[1] - 0.08, 0.05)];
    const step = FloorPlan.cell / 2;
    for (let z = -inner[1]; z <= inner[1] + 1e-6; z += step) {
      for (let x = -inner[0]; x <= inner[0] + 1e-6; x += step) {
        const i = this.index(footprint.point(x, z));
        if (i === null) continue;
        if (span ? this.low[i] < span[1] - 0.02 && this.high[i] > span[0] + 0.02 : this.blocked[i]) return false;
      }
    }
    const outer: Vec2 = [footprint.half[0] + 0.2, footprint.half[1] + 0.2];
    for (let z = -outer[1]; z <= outer[1] + 1e-6; z += FloorPlan.cell) {
      for (let x = -outer[0]; x <= outer[0] + 1e-6; x += FloorPlan.cell) {
        const i = this.index(footprint.point(x, z));
        if (i !== null && this.floor[i]) return true;
      }
    }
    return false;
  }
}

function distance(a: Vec3, b: Vec3) {
  return Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);
}
