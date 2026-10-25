import * as THREE from "three";
import { PLYLoader } from "three/examples/jsm/loaders/PLYLoader.js";
import chairUrl from "@library/furniture-chair.ply?url";
import sofaUrl from "@library/furniture-sofa.ply?url";
import stoolUrl from "@library/furniture-stool.ply?url";
import tableUrl from "@library/furniture-table.ply?url";

/**
 * A RoomPlan room from its JSON (the phone's Export, or a saved room
 * layout), built the way the iPhone app's RoomPlanMesh.swift builds it:
 * walls with their doors, windows and openings cut out, doors and windows
 * as panels, the floor, and each piece of furniture as the matching library
 * model stretched to RoomPlan's box, or a box. Wound counter-clockwise seen
 * from inside, like a scan. The shell and the furniture come apart, so every
 * piece can be edited, and pieces are numbered per kind as on the phone
 * ("chair 1", "chair 2"), with the phone's IDs ("scan:0", …) so its saved
 * edits find them.
 */
export interface Mesh {
  positions: number[];
  colors: number[];
  faces: number[];
}

export interface ScannedPiece {
  id: string;
  name: string;
  kind: string;
  mesh: Mesh;
}

interface Surface {
  identifier?: string;
  parentIdentifier?: string | null;
  dimensions: number[];
  transform: number[] | number[][];
  polygonCorners?: number[][];
  category?: unknown;
}

export interface CapturedRoom {
  walls?: Surface[];
  doors?: Surface[];
  windows?: Surface[];
  openings?: Surface[];
  floors?: Surface[];
  objects?: Surface[];
}

type V2 = [number, number];
type V3 = [number, number, number];

const colour = {
  wall: [226, 222, 214],
  floor: [176, 160, 138],
  door: [146, 104, 72],
  window: [170, 206, 232],
};

function objectColour(kind: string): number[] {
  switch (kind) {
    case "bed": return [150, 170, 200];
    case "sofa": case "chair": return [196, 150, 120];
    case "table": return [170, 130, 95];
    case "storage": return [205, 190, 160];
    case "television": return [60, 60, 66];
    case "refrigerator": case "stove": case "oven": case "dishwasher": case "washerDryer": return [210, 214, 218];
    case "sink": case "toilet": case "bathtub": return [235, 238, 240];
    case "fireplace": return [150, 90, 70];
    case "stairs": return [160, 150, 140];
    default: return [180, 180, 180];
  }
}

/** RoomPlan's category, encoded by Swift as {"chair": {}} (or a plain string). */
export function categoryName(category: unknown): string {
  if (typeof category === "string") return category;
  if (category && typeof category === "object") return Object.keys(category)[0] ?? "object";
  return "object";
}

/** The library models, as the phone bundles them (RoomTwin/Library). */
const libraryUrls: Record<string, string> = { chair: chairUrl, sofa: sofaUrl, stool: stoolUrl, table: tableUrl };
let library: Promise<Record<string, Mesh>> | undefined;

function loadLibrary(): Promise<Record<string, Mesh>> {
  library ??= Promise.all(Object.entries(libraryUrls).map(async ([kind, url]) => {
    const geometry = new PLYLoader().parse(await (await fetch(url)).arrayBuffer());
    return [kind, meshOf(geometry)] as const;
  })).then(Object.fromEntries);
  library.catch(() => (library = undefined));
  return library;
}

function meshOf(geometry: THREE.BufferGeometry): Mesh {
  const p = geometry.getAttribute("position"), c = geometry.getAttribute("color");
  const positions: number[] = [], colors: number[] = [];
  for (let i = 0; i < p.count; i++) {
    positions.push(p.getX(i), p.getY(i), p.getZ(i));
    // Colours come back normalised (0–1); kept as bytes, like the phone's.
    colors.push(...(c ? [c.getX(i) * 255, c.getY(i) * 255, c.getZ(i) * 255] : [200, 200, 200]));
  }
  const faces = geometry.index ? Array.from(geometry.index.array) : positions.map((_, i) => i).slice(0, p.count);
  return { positions, colors, faces };
}

export async function buildRoomPlan(room: CapturedRoom) {
  const models = await loadLibrary();
  const shell = new Builder();
  const walls = room.walls ?? [];
  const centre: V3 = walls.length
    ? walls.map((w) => position(matrix(w.transform))).reduce((a, b) => add(a, b), [0, 0, 0] as V3).map((v) => v / walls.length) as V3
    : [0, 0, 0];
  const holes = [...(room.doors ?? []), ...(room.windows ?? []), ...(room.openings ?? [])];
  for (const wall of walls) shell.addWall(wall, holes.filter((hole) => belongs(hole, wall)), centre);
  for (const door of room.doors ?? []) shell.addPanel(door, colour.door, centre);
  for (const window of room.windows ?? []) shell.addPanel(window, colour.window, centre);
  if (room.floors?.length) for (const floor of room.floors) shell.addFloor(floor);
  else shell.addFloorUnder(walls);

  const counts: Record<string, number> = {};
  const pieces: ScannedPiece[] = (room.objects ?? []).map((object, index) => {
    const kind = categoryName(object.category);
    counts[kind] = (counts[kind] ?? 0) + 1;
    const builder = new Builder();
    if (models[kind]) builder.addModel(models[kind], object);
    else builder.addBox(object, objectColour(kind));
    return { id: `scan:${index}`, name: `${kind} ${counts[kind]}`, kind, mesh: builder.mesh };
  });
  return { shell: geometryOf(shell.mesh), pieces };
}

/** A mesh as vertex-coloured geometry (colours 0–1). */
export function geometryOf(mesh: Mesh, offset: V3 = [0, 0, 0]) {
  const geometry = new THREE.BufferGeometry();
  const positions = new Float32Array(mesh.positions.length);
  for (let i = 0; i < positions.length; i++) positions[i] = mesh.positions[i] - offset[i % 3];
  geometry.setAttribute("position", new THREE.BufferAttribute(positions, 3));
  geometry.setAttribute("color", new THREE.BufferAttribute(new Float32Array(mesh.colors.map((c) => c / 255)), 3));
  geometry.setIndex(mesh.faces);
  return geometry;
}

/** Whether a door, window or opening sits in `wall`. */
function belongs(hole: Surface, wall: Surface) {
  if (hole.parentIdentifier) return hole.parentIdentifier === wall.identifier;
  const local = transformPoint(matrix(wall.transform).invert(), position(matrix(hole.transform)));
  return Math.abs(local[2]) < 0.15 && Math.abs(local[0]) <= wall.dimensions[0] / 2 + 0.05;
}

class Builder {
  mesh: Mesh = { positions: [], colors: [], faces: [] };

  addWall(wall: Surface, holes: Surface[], centre: V3) {
    const transform = matrix(wall.transform);
    const half: V2 = [wall.dimensions[0] / 2, wall.dimensions[1] / 2];
    // RoomPlan may give a non-rectangular outline (a gable, a sloped ceiling): keep it.
    let outline: V2[] = (wall.polygonCorners?.length ?? 0) >= 3
      ? wall.polygonCorners!.map((p) => [p[0], p[1]] as V2)
      : [[-half[0], -half[1]], [half[0], -half[1]], [half[0], half[1]], [-half[0], half[1]]];
    if (signedArea(outline) < 0) outline = outline.reverse();
    const lowX = Math.min(...outline.map((p) => p[0])), highX = Math.max(...outline.map((p) => p[0]));
    const lowY = Math.min(...outline.map((p) => p[1])), highY = Math.max(...outline.map((p) => p[1]));
    const inverse = transform.clone().invert();
    // Each hole as a rectangle in the wall's own plane.
    const cuts = holes.map((hole) => {
      const corners = cornersOf(hole).map((c) => transformPoint(inverse, c));
      const xs = corners.map((c) => c[0]), ys = corners.map((c) => c[1]);
      return {
        low: [clamp(Math.min(...xs), lowX, highX), clamp(Math.min(...ys), lowY, highY)] as V2,
        high: [clamp(Math.max(...xs), lowX, highX), clamp(Math.max(...ys), lowY, highY)] as V2,
      };
    });
    // Split on every outline coordinate and hole edge, clipping each cell back to the outline.
    const xs = [...new Set([...outline.map((p) => p[0]), ...cuts.flatMap((c) => [c.low[0], c.high[0]])])].sort((a, b) => a - b);
    const ys = [...new Set([...outline.map((p) => p[1]), ...cuts.flatMap((c) => [c.low[1], c.high[1]])])].sort((a, b) => a - b);
    const normal = normalOf(transform);
    const flip = dot(normal, sub(centre, position(transform))) < 0;
    for (let i = 0; i < xs.length - 1; i++) {
      for (let j = 0; j < ys.length - 1; j++) {
        const low: V2 = [xs[i], ys[j]], high: V2 = [xs[i + 1], ys[j + 1]];
        const middle: V2 = [(low[0] + high[0]) / 2, (low[1] + high[1]) / 2];
        if (high[0] - low[0] <= 1e-4 || high[1] - low[1] <= 1e-4) continue;
        if (cuts.some((c) => middle[0] > c.low[0] && middle[1] > c.low[1] && middle[0] < c.high[0] && middle[1] < c.high[1])) continue;
        const clipped = clip(outline, low, high);
        if (clipped.length < 3) continue;
        const corners = clipped.map((p) => transformPoint(transform, [p[0], p[1], 0]));
        this.addPolygon(flip ? corners.reverse() : corners, colour.wall);
      }
    }
    // The narrow top (or sloped top) cap RoomPlan's own view shows, without an outside face.
    const depth = flip ? 0.08 : -0.08;
    outline.forEach((a, k) => {
      const b = outline[(k + 1) % outline.length];
      const edge: V2 = [b[0] - a[0], b[1] - a[1]];
      const length = Math.hypot(...edge) || 1;
      const outward: V2 = [edge[1] / length, -edge[0] / length];
      if (outward[1] <= 0.15) return;
      const corners = ([[a[0], a[1], 0], [b[0], b[1], 0], [b[0], b[1], depth], [a[0], a[1], depth]] as V3[])
        .map((p) => transformPoint(transform, p));
      const desired = normalize(transformDirection(transform, [outward[0], outward[1], 0]));
      this.addPolygonFacing(corners, colour.wall, desired);
    });
  }

  /** A door or window filling its hole, just inside the wall. */
  addPanel(surface: Surface, rgb: number[], centre: V3) {
    const transform = matrix(surface.transform);
    const half: V2 = [surface.dimensions[0] / 2, surface.dimensions[1] / 2];
    const inward = dot(normalOf(transform), sub(centre, position(transform))) < 0 ? -1 : 1;
    const corners = ([[-half[0], -half[1]], [half[0], -half[1]], [half[0], half[1]], [-half[0], half[1]]] as V2[])
      .map((p) => transformPoint(transform, [p[0], p[1], 0.01 * inward]));
    this.addPolygon(inward < 0 ? corners.reverse() : corners, rgb);
  }

  addFloor(floor: Surface) {
    const transform = matrix(floor.transform);
    const corners = (floor.polygonCorners?.length ?? 0) >= 3
      ? floor.polygonCorners!.map((p) => transformPoint(transform, [p[0], p[1], p[2] ?? 0]))
      : cornersOf(floor);
    this.addFacingUp(corners, colour.floor);
  }

  /** Without a floor from RoomPlan, the outline round the bottoms of the walls. */
  addFloorUnder(walls: Surface[]) {
    const bottoms = walls.flatMap((wall) => {
      const transform = matrix(wall.transform), half = wall.dimensions.map((d) => d / 2);
      return [[-half[0], -half[1], 0], [half[0], -half[1], 0]].map((p) => transformPoint(transform, p as V3));
    });
    if (!bottoms.length) return;
    const height = Math.min(...bottoms.map((p) => p[1]));
    this.addFacingUp(convexHull(bottoms.map((p) => [p[0], p[2]] as V2)).map((p) => [p[0], height, p[1]] as V3), colour.floor);
  }

  addBox(object: Surface, rgb: number[]) {
    const half = object.dimensions.map((d) => d / 2);
    const transform = upright(matrix(object.transform));
    const centre = position(transform);
    for (let axis = 0; axis < 3; axis++) {
      for (const sign of [-1, 1]) {
        const u = (axis + 1) % 3, v = (axis + 2) % 3;
        const corners = ([[-1, -1], [1, -1], [1, 1], [-1, 1]] as V2[]).map(([a, b]) => {
          const p: V3 = [0, 0, 0];
          p[axis] = sign * half[axis];
          p[u] = a * half[u];
          p[v] = b * half[v];
          return transformPoint(transform, p);
        });
        const faceCentre = corners.reduce((s, c) => add(s, c), [0, 0, 0] as V3).map((x) => x / 4) as V3;
        const outward = dot(cross(sub(corners[1], corners[0]), sub(corners[2], corners[0])), sub(faceCentre, centre)) > 0;
        this.addPolygon(outward ? corners : corners.reverse(), rgb);
      }
    }
  }

  /** A library model (standing on y = 0, facing +z) stretched to fill the object's box. */
  addModel(model: Mesh, object: Surface) {
    const p = model.positions;
    const low: V3 = [Infinity, Infinity, Infinity], high: V3 = [-Infinity, -Infinity, -Infinity];
    for (let i = 0; i < p.length; i += 3) {
      for (let k = 0; k < 3; k++) {
        low[k] = Math.min(low[k], p[i + k]);
        high[k] = Math.max(high[k], p[i + k]);
      }
    }
    const middle = low.map((l, k) => (l + high[k]) / 2);
    const scale = object.dimensions.map((d, k) => d / Math.max(high[k] - low[k], 1e-4));
    const transform = upright(matrix(object.transform));
    const base = this.mesh.positions.length / 3;
    for (let i = 0; i < p.length; i += 3) {
      const local: V3 = [(p[i] - middle[0]) * scale[0], (p[i + 1] - middle[1]) * scale[1], (p[i + 2] - middle[2]) * scale[2]];
      this.mesh.positions.push(...transformPoint(transform, local));
    }
    this.mesh.colors.push(...model.colors);
    for (const f of model.faces) this.mesh.faces.push(f + base);
  }

  /** A horizontal polygon, wound to face up. */
  private addFacingUp(corners: V3[], rgb: number[]) {
    const flat = corners.map((c) => [c[0], c[2]] as V2);
    let area = 0;
    flat.forEach((a, i) => {
      const b = flat[(i + 1) % flat.length];
      area += a[0] * b[1] - b[0] * a[1];
    });
    // Counter-clockwise seen from above is clockwise in (x, z), whose area is negative.
    const ordered = area > 0 ? [...corners].reverse() : corners;
    const base = this.mesh.positions.length / 3;
    for (const c of ordered) {
      this.mesh.positions.push(...c);
      this.mesh.colors.push(...rgb);
    }
    for (const [a, b, c] of earClip(ordered.map((p) => [p[0], -p[2]] as V2))) this.mesh.faces.push(base + a, base + b, base + c);
  }

  /** A convex polygon, as a fan, keeping its winding. */
  private addPolygon(corners: V3[], rgb: number[]) {
    const base = this.mesh.positions.length / 3;
    for (const c of corners) {
      this.mesh.positions.push(...c);
      this.mesh.colors.push(...rgb);
    }
    for (let i = 1; i < corners.length - 1; i++) this.mesh.faces.push(base, base + i, base + i + 1);
  }

  private addPolygonFacing(corners: V3[], rgb: number[], normal: V3) {
    if (corners.length < 3) return;
    const forward = dot(cross(sub(corners[1], corners[0]), sub(corners[2], corners[0])), normal) >= 0;
    this.addPolygon(forward ? corners : corners.reverse(), rgb);
  }
}

// Geometry helpers

/** RoomPlan's transforms: 16 numbers, column by column (or four columns). */
function matrix(values: number[] | number[][]) {
  const flat = (values as (number | number[])[]).flat() as number[];
  return new THREE.Matrix4().fromArray(flat.length === 16 ? flat : new THREE.Matrix4().toArray());
}

/** Keeps only a piece's heading and position: furniture stands under gravity even if RoomPlan reports a tilt. */
function upright(transform: THREE.Matrix4) {
  const e = transform.elements;
  let forward: V3 = [e[8], 0, e[10]];
  if (forward[0] ** 2 + forward[2] ** 2 < 1e-5) forward = [-e[2], 0, e[0]];
  forward = normalize(forward);
  const right: V3 = normalize([forward[2], 0, -forward[0]]);
  return new THREE.Matrix4().set(
    right[0], 0, forward[0], e[12],
    right[1], 1, forward[1], e[13],
    right[2], 0, forward[2], e[14],
    0, 0, 0, 1);
}

function cornersOf(surface: Surface): V3[] {
  const transform = matrix(surface.transform);
  const half: V2 = [surface.dimensions[0] / 2, surface.dimensions[1] / 2];
  return ([[-half[0], -half[1]], [half[0], -half[1]], [half[0], half[1]], [-half[0], half[1]]] as V2[])
    .map((p) => transformPoint(transform, [p[0], p[1], 0]));
}

const position = (m: THREE.Matrix4): V3 => [m.elements[12], m.elements[13], m.elements[14]];
const normalOf = (m: THREE.Matrix4): V3 => normalize([m.elements[8], m.elements[9], m.elements[10]]);
const transformPoint = (m: THREE.Matrix4, p: V3): V3 => new THREE.Vector3(...p).applyMatrix4(m).toArray() as V3;
const transformDirection = (m: THREE.Matrix4, d: V3): V3 => {
  const e = m.elements;
  return [e[0] * d[0] + e[4] * d[1] + e[8] * d[2], e[1] * d[0] + e[5] * d[1] + e[9] * d[2], e[2] * d[0] + e[6] * d[1] + e[10] * d[2]];
};
const add = (a: V3, b: V3): V3 => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
const sub = (a: V3, b: V3): V3 => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const dot = (a: V3, b: V3) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const cross = (a: V3, b: V3): V3 => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const normalize = (a: V3): V3 => {
  const length = Math.hypot(...a) || 1;
  return [a[0] / length, a[1] / length, a[2] / length];
};
const clamp = (v: number, lo: number, hi: number) => Math.min(Math.max(v, lo), hi);

function signedArea(points: V2[]) {
  let area = 0;
  points.forEach((a, i) => {
    const b = points[(i + 1) % points.length];
    area += a[0] * b[1] - b[0] * a[1];
  });
  return area / 2;
}

/** Sutherland–Hodgman clipping against an axis-aligned rectangle. */
function clip(polygon: V2[], low: V2, high: V2): V2[] {
  const halfPlane = (input: V2[], inside: (p: V2) => boolean, crossing: (a: V2, b: V2) => V2) => {
    if (!input.length) return [];
    const output: V2[] = [];
    let previous = input[input.length - 1], previousInside = inside(previous);
    for (const point of input) {
      const pointInside = inside(point);
      if (pointInside !== previousInside) output.push(crossing(previous, point));
      if (pointInside) output.push(point);
      previous = point;
      previousInside = pointInside;
    }
    return output;
  };
  const atX = (x: number, a: V2, b: V2): V2 => [x, a[1] + (b[1] - a[1]) * ((x - a[0]) / (b[0] - a[0]))];
  const atY = (y: number, a: V2, b: V2): V2 => [a[0] + (b[0] - a[0]) * ((y - a[1]) / (b[1] - a[1])), y];
  let result = polygon;
  result = halfPlane(result, (p) => p[0] >= low[0] - 1e-5, (a, b) => atX(low[0], a, b));
  result = halfPlane(result, (p) => p[0] <= high[0] + 1e-5, (a, b) => atX(high[0], a, b));
  result = halfPlane(result, (p) => p[1] >= low[1] - 1e-5, (a, b) => atY(low[1], a, b));
  result = halfPlane(result, (p) => p[1] <= high[1] + 1e-5, (a, b) => atY(high[1], a, b));
  return result;
}

/** Triangles of a simple polygon given counter-clockwise, as index triples. */
function earClip(points: V2[]): [number, number, number][] {
  const remaining = points.map((_, i) => i);
  const triangles: [number, number, number][] = [];
  const turn = (o: V2, a: V2, b: V2) => (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
  while (remaining.length > 3) {
    let clipped = false;
    for (let k = 0; k < remaining.length; k++) {
      const i = remaining[(k + remaining.length - 1) % remaining.length], j = remaining[k];
      const l = remaining[(k + 1) % remaining.length];
      const a = points[i], b = points[j], c = points[l];
      if (turn(a, b, c) <= 0) continue;
      const inside = remaining.some((m) => m !== i && m !== j && m !== l
        && turn(a, b, points[m]) >= 0 && turn(b, c, points[m]) >= 0 && turn(c, a, points[m]) >= 0);
      if (inside) continue;
      triangles.push([i, j, l]);
      remaining.splice(k, 1);
      clipped = true;
      break;
    }
    if (!clipped) break;
  }
  if (remaining.length === 3) triangles.push([remaining[0], remaining[1], remaining[2]]);
  return triangles;
}

/** Counter-clockwise convex hull (Andrew's monotone chain). */
function convexHull(points: V2[]): V2[] {
  const sorted = [...points].sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  if (sorted.length <= 2) return sorted;
  const turn = (o: V2, a: V2, b: V2) => (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
  const lower: V2[] = [], upper: V2[] = [];
  for (const p of sorted) {
    while (lower.length >= 2 && turn(lower[lower.length - 2], lower[lower.length - 1], p) <= 0) lower.pop();
    lower.push(p);
  }
  for (const p of [...sorted].reverse()) {
    while (upper.length >= 2 && turn(upper[upper.length - 2], upper[upper.length - 1], p) <= 0) upper.pop();
    upper.push(p);
  }
  return [...lower.slice(0, -1), ...upper.slice(0, -1)];
}
