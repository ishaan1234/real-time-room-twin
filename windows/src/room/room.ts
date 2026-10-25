import * as THREE from "three";
import { PLYLoader } from "three/examples/jsm/loaders/PLYLoader.js";
import { acceleratedRaycast, computeBoundsTree, disposeBoundsTree } from "three-mesh-bvh";
import { coreBounds, findWalls, FloorPlan, floorHeight, type MeshData, type Vec3, type Wall } from "./analysis";

// Scans run to millions of triangles; a BVH keeps ray casts against them quick.
THREE.BufferGeometry.prototype.computeBoundsTree = computeBoundsTree;
THREE.BufferGeometry.prototype.disposeBoundsTree = disposeBoundsTree;
THREE.Mesh.prototype.raycast = acceleratedRaycast;

/** Room-wide light on the scan, which set_lighting changes; shared by every scan material. */
export const scanLighting = {
  uExposure: { value: 1 },
  uTint: { value: new THREE.Color(1, 1, 1) },
};

/**
 * The scanned colours, unlit as they already hold the room's light, darker
 * where a face is seen edge-on, like the phone's Color view. The normal comes
 * from screen-space derivatives, so the mesh needs none.
 */
export function scanMaterial(side: THREE.Side = THREE.FrontSide) {
  return new THREE.ShaderMaterial({
    vertexColors: true,
    side,
    uniforms: scanLighting,
    vertexShader: /* glsl */ `
      varying vec3 vColor;
      varying vec3 vViewPosition;
      void main() {
        vColor = color;
        vec4 mv = modelViewMatrix * vec4(position, 1.0);
        vViewPosition = mv.xyz;
        gl_Position = projectionMatrix * mv;
      }`,
    fragmentShader: /* glsl */ `
      uniform float uExposure;
      uniform vec3 uTint;
      varying vec3 vColor;
      varying vec3 vViewPosition;
      void main() {
        vec3 n = normalize(cross(dFdx(vViewPosition), dFdy(vViewPosition)));
        float facing = abs(dot(n, normalize(-vViewPosition)));
        gl_FragColor = vec4(vColor * uTint * uExposure * (0.6 + 0.4 * facing), 1.0);
        #include <colorspace_fragment>
      }`,
  });
}

type SurfaceKind = "wall" | "floor" | "ceiling";

/** A part of the scan with its own mesh, so it can be textured or hidden: each wall, the floor, the ceiling. */
interface Surface {
  kind: SurfaceKind;
  mesh: THREE.Mesh;
  colored: THREE.Material;
}

/**
 * A scanned room as a three.js group: the scan minus its walls, floor and
 * ceiling as one mesh, and each of those as its own, so they can be
 * textured (and the ceiling hidden). Both kinds of scan from the phone (the
 * detailed mesh and RoomPlan's room) come as the same PLY: metres, +y up,
 * vertex colours, faces wound counter-clockwise seen from inside the room.
 * So with back faces culled, from outside the near walls and ceiling vanish
 * and it reads as a dollhouse.
 */
export class Room {
  readonly group = new THREE.Group();
  readonly floorY: number;
  /** Height of the ceiling, scanned or not. */
  readonly ceilingY: number;
  readonly walls: Wall[];
  readonly floorPlan: FloorPlan;
  readonly bounds: { lo: Vec3; hi: Vec3 };
  readonly triangles: number;
  /** What furniture can land on or against, for ray casts. */
  readonly solids: THREE.Mesh[] = [];
  private wallSurfaces: Surface[] = [];
  private floor?: Surface;
  private ceiling?: Surface;
  private rest: THREE.Mesh;
  /** Walls and a ceiling added where the scan has none (set_enclosure). */
  private added = { ceiling: null as THREE.Mesh | null, walls: [] as THREE.Mesh[] };
  /** The room's main directions and its extent along them, for closing open sides. */
  private frame: { axes: [Vec3, Vec3]; extent: [[number, number], [number, number]] };

  constructor(geometry: THREE.BufferGeometry, readonly name: string) {
    const positions = geometry.getAttribute("position").array as Float32Array;
    const faces = geometry.index ? new Uint32Array(geometry.index.array) : sequence(positions.length / 3);
    const mesh: MeshData = { positions, faces };
    this.triangles = faces.length / 3;
    this.bounds = coreBounds(mesh);
    this.floorY = floorHeight(mesh) ?? this.bounds.lo[1];
    this.floorPlan = new FloorPlan(mesh, this.floorY);
    this.walls = findWalls(mesh, this.floorY);
    const tallest = Math.max(this.bounds.hi[1], ...this.walls.map((w) => w.top));
    this.ceilingY = Math.max(this.floorY + 2.2, Math.min(tallest, this.floorY + 4));
    this.frame = mainFrame(positions, this.walls);
    if (!geometry.getAttribute("color")) {
      geometry.setAttribute("color", new THREE.Float32BufferAttribute(new Float32Array(positions.length).fill(0.8), 3));
    }

    // Which surface each face belongs to: 1 + wall index, or the floor or ceiling.
    const FLOOR = -1, CEILING = -2;
    const owner = new Int32Array(this.triangles);
    this.walls.forEach((wall, i) => wall.faces.forEach((face) => (owner[face] = i + 1)));
    const floorFaces: number[] = [], ceilingFaces: number[] = [], restIndex: number[] = [];
    for (let i = 0; i < this.triangles; i++) {
      if (owner[i] > 0) continue;
      const level = horizontalFace(positions, faces, i);
      if (level !== null && Math.abs(level - this.floorY) < 0.06) owner[i] = FLOOR;
      else if (level !== null && level > this.floorY + 1.9 && Math.abs(level - this.ceilingY) < 0.25) owner[i] = CEILING;
      if (owner[i] === FLOOR) floorFaces.push(i);
      else if (owner[i] === CEILING) ceilingFaces.push(i);
      else restIndex.push(faces[3 * i], faces[3 * i + 1], faces[3 * i + 2]);
    }
    // Only a ceiling that covers a fair part of the room counts: a RoomPlan room's wall tops are flat up there too.
    const area = (list: number[]) => list.reduce((sum, i) => sum + faceArea(positions, faces, i), 0);
    const room = (this.bounds.hi[0] - this.bounds.lo[0]) * (this.bounds.hi[2] - this.bounds.lo[2]);
    if (ceilingFaces.length && area(ceilingFaces) < 0.3 * Math.max(area(floorFaces), 0.5 * room)) {
      for (const i of ceilingFaces) restIndex.push(faces[3 * i], faces[3 * i + 1], faces[3 * i + 2]);
      ceilingFaces.length = 0;
    }
    const rest = new THREE.BufferGeometry();
    rest.setAttribute("position", geometry.getAttribute("position"));
    rest.setAttribute("color", geometry.getAttribute("color"));
    rest.setIndex(restIndex);
    this.rest = this.addSolid(rest, scanMaterial());
    this.rest.name = "scan";
    for (const wall of this.walls) {
      // Texture coordinates in metres along the wall and up from the floor; the wall is flat, so lit evenly.
      this.wallSurfaces.push(this.buildSurface("wall", wall.faces, geometry, faces, wall.normal,
        (x, y, z) => [x * wall.along[0] + z * wall.along[2] - wall.span[0], y - this.floorY]));
    }
    if (floorFaces.length) this.floor = this.buildSurface("floor", floorFaces, geometry, faces, [0, 1, 0], (x, _, z) => [x, -z]);
    if (ceilingFaces.length) this.ceiling = this.buildSurface("ceiling", ceilingFaces, geometry, faces, [0, -1, 0], (x, _, z) => [x, z]);
  }

  static fromPLY(data: ArrayBuffer, name: string) {
    const geometry = new PLYLoader().parse(data);
    if (!geometry.getAttribute("position")?.count) throw new Error("That file has no mesh in it.");
    return new Room(geometry, name);
  }

  /** Culls back faces (the dollhouse look) or shows both sides. */
  setDollhouse(on: boolean) {
    const side = on ? THREE.FrontSide : THREE.DoubleSide;
    const meshes = [this.rest, ...this.surfaces.map((s) => s.mesh), ...this.added.walls, ...(this.added.ceiling ? [this.added.ceiling] : [])];
    for (const mesh of meshes) {
      (mesh.material as THREE.Material).side = side;
      (mesh.material as THREE.Material).needsUpdate = true;
    }
    for (const surface of this.surfaces) {
      surface.colored.side = side;
      surface.colored.needsUpdate = true;
    }
  }

  /**
   * Covers walls with a tiling texture whose image spans `size` metres, or
   * puts the scanned colours back if `texture` is null. `which` limits it
   * to some walls by index; all by default. Returns how many changed.
   */
  setWallTexture(texture: THREE.Texture | null, size: [number, number] = [1, 1], which?: number[]) {
    const chosen = which ?? this.wallSurfaces.map((_, i) => i);
    for (const i of chosen) if (this.wallSurfaces[i]) cover(this.wallSurfaces[i], texture, size);
    return chosen.length;
  }

  /** The same for the floor. False if the scan has no floor to cover. */
  setFloorTexture(texture: THREE.Texture | null, size: [number, number] = [1, 1]) {
    if (!this.floor) return false;
    cover(this.floor, texture, size);
    return true;
  }

  /** Shows a ceiling (the scanned one, or a plain one where none was scanned) or takes it away. */
  setCeiling(on: boolean) {
    if (this.ceiling) this.ceiling.mesh.visible = on;
    if (on && !this.ceiling && !this.added.ceiling) {
      const { axes, extent } = this.frame;
      const panel = this.panel([extent[0][1] - extent[0][0], extent[1][1] - extent[1][0]]);
      panel.position.copy(this.framePoint((extent[0][0] + extent[0][1]) / 2, (extent[1][0] + extent[1][1]) / 2, this.ceilingY));
      // Facing down (first axis × second axis points down), its width along the first axis.
      panel.quaternion.setFromRotationMatrix(new THREE.Matrix4().makeBasis(
        new THREE.Vector3(...axes[0]), new THREE.Vector3(...axes[1]), new THREE.Vector3(0, -1, 0)));
      this.added.ceiling = panel;
    }
    if (this.added.ceiling) this.added.ceiling.visible = on;
  }

  /**
   * Closes the sides of the room the scan left open with plain walls, or takes
   * those away. Returns how many sides that is.
   */
  setOpenSidesClosed(on: boolean) {
    for (const wall of this.added.walls) this.removeSolid(wall);
    this.added.walls = [];
    if (!on) return 0;
    const { axes, extent } = this.frame;
    const height = this.ceilingY - this.floorY;
    for (const [axis, side] of [[0, 0], [0, 1], [1, 0], [1, 1]] as const) {
      // Into the room from this side.
      const inward = new THREE.Vector3(...axes[axis]).multiplyScalar(side === 0 ? 1 : -1);
      const at = extent[axis][side];
      const covered = this.walls.some((wall) =>
        new THREE.Vector3(...wall.normal).dot(inward) > 0.9 && Math.abs(wall.offset - (side === 0 ? at : -at)) < 0.4
        && wall.span[1] - wall.span[0] > 0.6 * (extent[1 - axis][1] - extent[1 - axis][0]));
      if (covered) continue;
      const other = 1 - axis;
      const panel = this.panel([extent[other][1] - extent[other][0], height]);
      const middle = (extent[other][0] + extent[other][1]) / 2;
      panel.position.copy(axis === 0 ? this.framePoint(at, middle, this.floorY + height / 2)
        : this.framePoint(middle, at, this.floorY + height / 2));
      const right = new THREE.Vector3(0, 1, 0).cross(inward);
      panel.quaternion.setFromRotationMatrix(new THREE.Matrix4().makeBasis(right, new THREE.Vector3(0, 1, 0), inward));
      this.added.walls.push(panel);
    }
    return this.added.walls.length;
  }

  /** Which wall a mesh is (its index in `walls`), or -1. */
  wallIndex(object: THREE.Object3D) {
    return this.wallSurfaces.findIndex((wall) => wall.mesh === object);
  }

  /** Where to stand at first: the middle of the room at eye height. */
  get start(): THREE.Vector3 {
    const { lo, hi } = this.bounds;
    return new THREE.Vector3((lo[0] + hi[0]) / 2, this.floorY + 1.6, (lo[2] + hi[2]) / 2);
  }

  get centre(): THREE.Vector3 {
    const { lo, hi } = this.bounds;
    return new THREE.Vector3((lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2);
  }

  dispose() {
    this.group.traverse((object) => {
      if (object instanceof THREE.Mesh) {
        object.geometry.disposeBoundsTree?.();
        object.geometry.dispose();
        (object.material as THREE.Material).dispose();
      }
    });
    for (const surface of this.surfaces) surface.colored.dispose();
  }

  private get surfaces(): Surface[] {
    return [...this.wallSurfaces, ...(this.floor ? [this.floor] : []), ...(this.ceiling ? [this.ceiling] : [])];
  }

  /** A surface's own copy of its faces' vertices, with texture coordinates from `uv` in metres. */
  private buildSurface(kind: SurfaceKind, faceList: number[], source: THREE.BufferGeometry, faces: Uint32Array,
    normal: Vec3, uv: (x: number, y: number, z: number) => [number, number]): Surface {
    const positions = source.getAttribute("position").array as Float32Array;
    // PLYLoader may keep colours as normalised bytes, so read them through the attribute.
    const colors = source.getAttribute("color");
    const remap = new Map<number, number>();
    const p: number[] = [], c: number[] = [], t: number[] = [], n: number[] = [], index: number[] = [];
    for (const face of faceList) {
      for (let j = 0; j < 3; j++) {
        const v = faces[3 * face + j];
        let mapped = remap.get(v);
        if (mapped === undefined) {
          mapped = p.length / 3;
          remap.set(v, mapped);
          const x = positions[3 * v], y = positions[3 * v + 1], z = positions[3 * v + 2];
          p.push(x, y, z);
          c.push(colors.getX(v), colors.getY(v), colors.getZ(v));
          t.push(...uv(x, y, z));
          n.push(...normal);
        }
        index.push(mapped);
      }
    }
    const geometry = new THREE.BufferGeometry();
    geometry.setAttribute("position", new THREE.Float32BufferAttribute(p, 3));
    geometry.setAttribute("color", new THREE.Float32BufferAttribute(c, 3));
    geometry.setAttribute("uv", new THREE.Float32BufferAttribute(t, 2));
    geometry.setAttribute("normal", new THREE.Float32BufferAttribute(n, 3));
    geometry.setIndex(index);
    const colored = scanMaterial();
    const mesh = this.addSolid(geometry, colored);
    mesh.name = kind;
    return { kind, mesh, colored };
  }

  /** A plain panel for added walls and ceilings, `size` metres. */
  private panel(size: [number, number]) {
    const geometry = new THREE.PlaneGeometry(size[0], size[1]);
    const mesh = this.addSolid(geometry, new THREE.MeshStandardMaterial({ color: 0xe8e4dc, roughness: 0.95 }));
    mesh.name = "added wall";
    return mesh;
  }

  /** A point given along the room's two main axes, at height y. */
  private framePoint(a: number, b: number, y: number) {
    const [u, v] = this.frame.axes;
    return new THREE.Vector3(a * u[0] + b * v[0], y, a * u[2] + b * v[2]);
  }

  private addSolid(geometry: THREE.BufferGeometry, material: THREE.Material) {
    geometry.computeBoundsTree();
    const mesh = new THREE.Mesh(geometry, material);
    this.group.add(mesh);
    this.solids.push(mesh);
    return mesh;
  }

  private removeSolid(mesh: THREE.Mesh) {
    this.group.remove(mesh);
    this.solids.splice(this.solids.indexOf(mesh), 1);
    mesh.geometry.dispose();
    (mesh.material as THREE.Material).dispose();
  }
}

/** Puts a tiling texture on a surface, its image spanning `size` metres, or the scanned colours back. */
function cover(surface: Surface, texture: THREE.Texture | null, size: [number, number]) {
  const old = surface.mesh.material as THREE.Material;
  if (old !== surface.colored) old.dispose();
  if (!texture) {
    surface.mesh.material = surface.colored;
    return;
  }
  const map = texture.clone();
  map.wrapS = map.wrapT = THREE.RepeatWrapping;
  map.repeat.set(1 / size[0], 1 / size[1]);
  map.colorSpace = THREE.SRGBColorSpace;
  map.anisotropy = 8;
  map.needsUpdate = true;
  surface.mesh.material = new THREE.MeshStandardMaterial({ map, roughness: 0.9, side: surface.colored.side });
}

/** The height of a level face (facing straight up or down), or null if it's not level. */
function horizontalFace(p: Float32Array, f: Uint32Array, i: number): number | null {
  const a = 3 * f[3 * i], b = 3 * f[3 * i + 1], c = 3 * f[3 * i + 2];
  const ux = p[b] - p[a], uy = p[b + 1] - p[a + 1], uz = p[b + 2] - p[a + 2];
  const vx = p[c] - p[a], vy = p[c + 1] - p[a + 1], vz = p[c + 2] - p[a + 2];
  const nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
  const length = Math.hypot(nx, ny, nz);
  if (length === 0 || Math.abs(ny) < 0.9 * length) return null;
  return (p[a + 1] + p[b + 1] + p[c + 1]) / 3;
}

/**
 * The room's two main horizontal directions (from its walls, or x and z if
 * none were found) and how far it reaches along each, ignoring the outermost
 * 2% of vertices.
 */
function mainFrame(positions: Float32Array, walls: Wall[]): { axes: [Vec3, Vec3]; extent: [[number, number], [number, number]] } {
  const u: Vec3 = walls[0] ? [...walls[0].normal] : [1, 0, 0];
  const v: Vec3 = [-u[2], 0, u[0]];
  const count = positions.length / 3, stride = Math.max(1, Math.floor(count / 20000));
  const a: number[] = [], b: number[] = [];
  for (let i = 0; i < count; i += stride) {
    const x = positions[3 * i], z = positions[3 * i + 2];
    a.push(x * u[0] + z * u[2]);
    b.push(x * v[0] + z * v[2]);
  }
  const range = (values: number[]): [number, number] => {
    values.sort((x, y) => x - y);
    return [values[Math.floor(values.length * 0.02)], values[Math.floor(values.length * 0.98)]];
  };
  return { axes: [u, v], extent: [range(a), range(b)] };
}

function sequence(count: number) {
  const faces = new Uint32Array(count);
  for (let i = 0; i < count; i++) faces[i] = i;
  return faces;
}

function faceArea(positions: ArrayLike<number>, faces: ArrayLike<number>, i: number) {
  const [a, b, c] = [faces[3 * i], faces[3 * i + 1], faces[3 * i + 2]].map((v) => new THREE.Vector3(positions[3 * v], positions[3 * v + 1], positions[3 * v + 2]));
  return b.sub(a).cross(c.sub(a)).length() / 2;
}
