import * as THREE from "three";
import { Footprint, wallDistance, wallPoint, type Vec2, type Vec3, type Wall } from "../room/analysis";
import type { Room } from "../room/room";
import type { Origin } from "../models/search";

export type Placement =
  | { kind: "inView" }
  | { kind: "againstWall" }
  | { kind: "nextTo"; reference?: string }
  | { kind: "onTopOf"; reference?: string }
  /** Mounted on the wall in view, its bottom `elevation` metres above the floor. */
  | { kind: "onWall"; elevation?: number }
  /** Hung from the ceiling where the user is looking. */
  | { kind: "ceiling" };

export type Facing = "viewer" | "awayFromWall" | "towardWall" | "sameAsReference";

export interface PieceInfo {
  origin: Origin;
  credit?: string;
  /** The Poly Haven material it's covered with, if it's been changed. */
  texture?: string;
  /** The model's box in the holder's frame, before the holder's scale. */
  box: THREE.Box3;
}

/** A placed piece: a holder group (position, yaw, scale) around the model. */
export type Piece = THREE.Group & { userData: PieceInfo };

const up = new THREE.Vector3(0, 1, 0);

/**
 * The furniture added to a room, and where new pieces go: ported from the
 * iPhone app's PreviewScene.place, so voice requests behave the same. Each
 * spot is checked against the scan's floor plan and earlier pieces; if
 * something's in the way, it tries the nearest clear spot the viewer can see.
 */
export class Furniture {
  readonly group = new THREE.Group();
  /** Called whenever pieces are added, moved or removed. */
  onChange?: () => void;
  private raycaster = new THREE.Raycaster();
  private drops: { model: THREE.Object3D; start: number }[] = [];

  constructor(
    private room: Room,
    /** The camera the user is looking through: the desktop camera, or the headset's. */
    readonly viewCamera: () => THREE.Camera,
    /** Whether the user is standing in the room (walk or VR), rather than looking at it from outside. */
    private isInside: () => boolean,
    /** Whether moving, turning and resizing pieces by hand stops at the scan and other pieces. */
    private isSolid: () => boolean = () => true,
  ) {
    this.group.name = "furniture";
  }

  get pieces(): Piece[] {
    return this.group.children as Piece[];
  }

  get names() {
    return this.pieces.map((piece) => piece.name);
  }

  /**
   * Stands a model in the room and drops it in. `model` must stand on
   * y = 0, centred, front facing +z. Returns where it went, in words for the
   * voice agent; throws if there's nowhere to put it.
   */
  place(model: THREE.Object3D, info: Omit<PieceInfo, "box">, placement: Placement = { kind: "inView" },
    facing?: Facing): { piece: Piece; words: string } {
    const box = new THREE.Box3().setFromObject(model);
    const half: Vec2 = [(box.max.x - box.min.x) / 2, (box.max.z - box.min.z) / 2];
    const height = box.max.y - box.min.y;
    const { eye, gaze } = this.look();

    let spot: Vec3, yaw: number, words: string;
    switch (placement.kind) {
      case "inView": {
        const wall = facing === "awayFromWall" || facing === "towardWall" ? this.nearestWall(gaze.point) : undefined;
        const found = this.searchAround(gaze.point, eye, gaze.ahead, half, height,
          (candidate) => this.turn(facing ?? "viewer", candidate, eye, wall));
        ({ spot, yaw } = found);
        words = `on the floor ${horizontal(spot, eye).toFixed(1)} metres from the user, ${describe(facing ?? "viewer")}`
          + (found.visible ? "" : ", but out of sight behind something");
        break;
      }
      case "againstWall": {
        // The wall in view first, then the others nearest first.
        const others = this.room.walls.filter((w) => w !== gaze.wall)
          .sort((a, b) => cost(a, gaze.point) - cost(b, gaze.point));
        const candidates = gaze.wall ? [gaze.wall, ...others] : others;
        if (!candidates.length) throw new Error("No walls were found in the scan, only furniture and floor.");
        let placed: ReturnType<Furniture["searchAlong"]> | undefined;
        for (const wall of candidates) {
          try {
            placed = this.searchAlong(wall, gaze.point, eye, half, height, facing ?? "awayFromWall");
            break;
          } catch {
            // Try the next wall.
          }
        }
        if (!placed) throw new Error("No wall has a clear stretch of floor wide enough in front of it.");
        ({ spot, yaw } = placed);
        words = `against the wall ${this.direction(spot, eye)} of the user, ${describe(facing ?? "awayFromWall")}`
          + (placed.visible ? "" : ", out of sight behind something");
        break;
      }
      case "nextTo": {
        const reference = this.piece(placement.reference);
        const found = this.searchBeside(reference, eye, half, height, facing ?? "sameAsReference");
        ({ spot, yaw } = found);
        words = `next to the ${reference.name}, on its ${found.side}, ${describe(facing ?? "sameAsReference")}`;
        break;
      }
      case "onTopOf": {
        const reference = this.piece(placement.reference);
        const top = reference.position.y + reference.userData.box.max.y * reference.scale.y;
        spot = [reference.position.x, top, reference.position.z];
        yaw = this.turn(facing ?? "sameAsReference", spot, eye, undefined, reference);
        words = `on top of the ${reference.name}`;
        break;
      }
      case "onWall": {
        const wall = gaze.wall ?? this.nearestWall(gaze.point);
        if (!wall) throw new Error("No walls were found in the scan to mount it on.");
        const elevation = placement.elevation && placement.elevation > 0 ? placement.elevation : 1.2;
        const low = wall.span[0] + half[0], high = wall.span[1] - half[0];
        const along = gaze.point[0] * wall.along[0] + gaze.point[2] * wall.along[2];
        const start = low <= high ? Math.min(Math.max(along, low), high) : (low + high) / 2;
        yaw = Math.atan2(wall.normal[0], wall.normal[2]);
        // Its back against the wall, along it from where the user looks to clear of other pieces there.
        const bottom = this.room.floorY + elevation;
        spot = wallPoint(wall, start, half[1] + 0.01, bottom);
        for (let step = 0; step <= 40; step++) {
          const s = start + Math.floor((step + 1) / 2) * (step % 2 === 0 ? 1 : -1) * 0.1;
          if (low <= high && (s < low || s > high)) continue;
          const candidate = wallPoint(wall, s, half[1] + 0.01, bottom);
          if (this.hasRoom(new Footprint([candidate[0], candidate[2]], half, yaw), undefined, [bottom, bottom + height])) {
            spot = candidate;
            break;
          }
        }
        words = `on the wall ${this.direction(spot, eye)} of the user, ${elevation.toFixed(1)} metres up`;
        break;
      }
      case "ceiling": {
        spot = [gaze.point[0], Math.max(this.room.floorY + 0.3, this.room.ceilingY - height), gaze.point[2]];
        yaw = this.turn("viewer", spot, eye);
        words = `hanging from the ceiling ${horizontal(spot, eye).toFixed(1)} metres from the user`;
        break;
      }
    }

    // The holder takes its final place at once, so a request straight after
    // this one sees it where it'll be; the model inside drops in.
    const piece = this.add(model, { ...info, box }, spot, yaw);
    if (placement.kind === "ceiling") this.nudge(piece, 1);
    this.drop(model);
    return { piece, words };
  }

  /** Adds a model at a known pose, as when a saved layout is reopened. */
  add(model: THREE.Object3D, info: PieceInfo, at: Vec3, yaw: number, scale = 1): Piece {
    const piece = new THREE.Group() as Piece;
    piece.name = model.name || "piece";
    piece.userData = info;
    piece.position.set(...at);
    piece.rotation.y = yaw;
    piece.scale.setScalar(scale);
    piece.add(model);
    if (glows(piece.name)) {
      // Lamps light what's round them (the scan itself is unlit, so mainly furniture and textured surfaces).
      const light = new THREE.PointLight(0xffd9a0, 3, 6, 1.5);
      light.position.y = info.box.max.y * 0.85;
      light.name = "lamp light";
      piece.add(light);
    }
    this.group.add(piece);
    this.onChange?.();
    return piece;
  }

  /** Takes away the latest piece whose name contains `name`, or the latest of all. Returns its name. */
  remove(nameOrPiece?: string | Piece): string | null {
    let piece: Piece;
    try {
      piece = typeof nameOrPiece === "object" ? nameOrPiece : this.piece(nameOrPiece);
    } catch {
      return null;
    }
    this.group.remove(piece);
    piece.traverse((object) => {
      if (object instanceof THREE.Mesh) object.geometry.dispose();
    });
    this.onChange?.();
    return piece.name;
  }

  clear() {
    for (const piece of [...this.pieces]) this.group.remove(piece);
    this.onChange?.();
  }

  /** Runs the drop-in animations; call once a frame. */
  update(now: number) {
    this.drops = this.drops.filter(({ model, start }) => {
      const t = Math.min((now - start) / 350, 1);
      // Ease in, as SceneKit's drop did.
      model.position.y = 0.4 * (1 - t * t);
      return t < 1;
    });
  }

  /** The piece a ray hits first, if any. */
  pieceAt(raycaster: THREE.Raycaster): Piece | null {
    const hit = raycaster.intersectObjects(this.pieces, true)[0];
    let object: THREE.Object3D | null = hit?.object ?? null;
    while (object && object.parent !== this.group) object = object.parent;
    return (object as Piece) ?? null;
  }

  /** The latest piece whose name contains `name`, or the latest of all. */
  piece(name?: string): Piece {
    const pieces = [...this.pieces].reverse();
    const wanted = name?.toLowerCase().trim() ?? "";
    const match = !wanted ? pieces[0]
      : pieces.find((p) => p.name.toLowerCase().includes(wanted))
        ?? pieces.find((p) => wanted.split(" ").some((word) => p.name.toLowerCase().includes(word)));
    if (!match) {
      throw new Error(pieces.length ? `Nothing added is called ${wanted}. Added so far: ${this.names.join(", ")}.`
        : "Nothing has been added yet.");
    }
    return match;
  }

  /** The footprint a piece covers on the floor. */
  footprint(piece: Piece): Footprint {
    const { box } = piece.userData, s = piece.scale.x;
    return new Footprint([piece.position.x, piece.position.z],
      [((box.max.x - box.min.x) / 2) * s, ((box.max.z - box.min.z) / 2) * s], piece.rotation.y);
  }

  /** The heights a piece spans, bottom and top. */
  span(piece: Piece): [number, number] {
    const { box } = piece.userData, s = piece.scale.y;
    return [piece.position.y + box.min.y * s, piece.position.y + box.max.y * s];
  }

  /**
   * Whether a footprint spanning these heights (standing on the floor, a
   * metre tall, if not given) is on scanned floor and clear of the scan and
   * of other pieces. Pieces only meet when their heights overlap too, so a
   * lamp can stand on a table and a shelf hang over a sofa. Something as flat
   * as a rug is never in the way.
   */
  hasRoom(footprint: Footprint, ignoring?: Piece, span: [number, number] = [this.room.floorY, this.room.floorY + 1]) {
    if (!this.room.floorPlan.contains(footprint) || !this.room.floorPlan.isClear(footprint, span)) return false;
    return this.pieces.every((piece) => {
      if (piece === ignoring) return true;
      const [bottom, top] = this.span(piece);
      if (top - bottom < 0.05) return true;
      if (bottom >= span[1] - 0.02 || top <= span[0] + 0.02) return true;
      return !footprint.overlaps(this.footprint(piece));
    });
  }

  /**
   * Whether a piece, where it is now, sticks out of the room, or goes into
   * the scan or another piece (only leaving the room counts with collisions off).
   */
  collides(piece: Piece) {
    return this.outside(piece) || (this.isSolid() && !this.hasRoom(this.footprint(piece), piece, this.span(piece)));
  }

  /** Whether any of a piece is off the room's floor, under the floor or above the ceiling. */
  outside(piece: Piece) {
    const [bottom, top] = this.span(piece);
    return bottom < this.room.floorY - 0.02 || top > this.room.ceilingY + 0.05
      || !this.room.floorPlan.contains(this.footprint(piece));
  }

  /** How a piece stands now, to tell later whether a change made it worse. */
  clearance(piece: Piece) {
    return { clear: !this.collides(piece), inside: !this.outside(piece) };
  }

  /**
   * Whether a piece now goes into something it was clear of, or out of the
   * room it was in. One already overlapping something may move through it
   * to get clear, but never out of the room.
   */
  worsened(piece: Piece, before: { clear: boolean; inside: boolean }) {
    return before.clear ? this.collides(piece) : before.inside && this.outside(piece);
  }

  /**
   * Moves a piece to the nearest spot within `reach` metres where it
   * collides with nothing, keeping its height and turn, if where it is now
   * collides. Returns false, leaving it where it was, if there's none.
   */
  nudge(piece: Piece, reach: number): boolean {
    if (!this.collides(piece)) return true;
    const start = piece.position.clone();
    const footprint = this.footprint(piece), span = this.span(piece);
    for (let ring = 1; ring * 0.05 <= reach; ring++) {
      const count = 8 * ring;
      for (let i = 0; i < count; i++) {
        const angle = (i / count) * 2 * Math.PI;
        footprint.centre = [start.x + ring * 0.05 * Math.cos(angle), start.z + ring * 0.05 * Math.sin(angle)];
        if (this.hasRoom(footprint, piece, span)) {
          piece.position.x = footprint.centre[0];
          piece.position.z = footprint.centre[1];
          return true;
        }
      }
    }
    return false;
  }

  /**
   * Turns, resizes or otherwise changes a piece by `change`, then, if that
   * put it into something it was clear of, shifts it clear within `reach`
   * metres or undoes the change. Returns whether the change stayed.
   */
  tryChange(piece: Piece, change: () => void, reach = 0): boolean {
    const before = this.clearance(piece);
    const position = piece.position.clone(), rotation = piece.rotation.y, scale = piece.scale.x;
    change();
    if (!this.worsened(piece, before) || (before.clear && this.nudge(piece, reach))) return true;
    piece.position.copy(position);
    piece.rotation.y = rotation;
    piece.scale.setScalar(scale);
    return false;
  }

  /**
   * Moves a piece level by (dx, dz) in steps of at most 5 cm, stopping where
   * it would go into something. With `slide`, a blocked step goes on along
   * whatever is in the way, as walking does. A piece that already overlaps
   * something moves through it, so it can be pulled clear, but stays in the
   * room. Returns how far it went.
   */
  slide(piece: Piece, dx: number, dz: number, slide = true): number {
    const from = piece.position.clone();
    const before = this.clearance(piece);
    const steps = Math.max(1, Math.ceil(Math.hypot(dx, dz) / 0.05));
    const sx = dx / steps, sz = dz / steps;
    const tries: Vec2[] = slide ? [[sx, sz], [sx, 0], [0, sz]] : [[sx, sz]];
    for (let i = 0; i < steps; i++) {
      const moved = tries.some(([x, z]) => {
        if (!x && !z) return false;
        piece.position.x += x;
        piece.position.z += z;
        if (!this.worsened(piece, before)) return true;
        piece.position.x -= x;
        piece.position.z -= z;
        return false;
      });
      if (!moved) break;
    }
    return Math.hypot(piece.position.x - from.x, piece.position.z - from.z);
  }

  /**
   * Raises (or lowers) a piece by `dy` in centimetre steps, stopping at
   * whatever it would go into, so lowering it lands it on what's below; never
   * below the floor. Returns how far it went.
   */
  lift(piece: Piece, dy: number): number {
    const from = piece.position.y;
    const { box } = piece.userData, s = piece.scale.y;
    // Never below the floor, nor through the ceiling.
    const target = Math.max(this.room.floorY - box.min.y * s, Math.min(this.room.ceilingY - box.max.y * s, from + dy));
    if (this.collides(piece)) {
      piece.position.y = target;
      return target - from;
    }
    const steps = Math.max(1, Math.ceil(Math.abs(target - from) / 0.01));
    for (let i = 1; i <= steps; i++) {
      const before = piece.position.y;
      piece.position.y = from + ((target - from) * i) / steps;
      if (this.collides(piece)) {
        piece.position.y = before;
        // Overlaps under 2 cm don't count, so it may have sunk a little into what it landed on: sit on top.
        if (dy < 0) {
          const footprint = this.footprint(piece), bottom = this.span(piece)[0];
          const under = this.pieces.filter((other) => other !== piece && footprint.overlaps(this.footprint(other)))
            .map((other) => this.span(other)[1]).filter((top) => top > bottom && top < bottom + 0.03);
          if (under.length) piece.position.y += Math.max(...under) - bottom;
        }
        break;
      }
    }
    return piece.position.y - from;
  }

  /**
   * Snaps a piece where it was let go, as the phone's snapping does: within
   * 30 cm of a wall and turned roughly to face out from it, it backs onto
   * the wall, square to it; otherwise it drops onto the floor or whatever is
   * under it. Something hung up on a wall keeps its height.
   */
  snap(piece: Piece) {
    const at = piece.position.toArray() as Vec3;
    const { box } = piece.userData, s = piece.scale.x;
    const depth = ((box.max.z - box.min.z) / 2) * s;
    const forward: Vec2 = [Math.sin(piece.rotation.y), Math.cos(piece.rotation.y)];
    const wall = this.room.walls
      .filter((w) => forward[0] * w.normal[0] + forward[1] * w.normal[2] > Math.cos(THREE.MathUtils.degToRad(30)))
      .map((w) => ({ w, gap: wallDistance(w, at) - depth }))
      .filter(({ gap }) => gap > -0.15 && gap < 0.3)
      .sort((a, b) => Math.abs(a.gap) - Math.abs(b.gap))[0]?.w;
    const raised = this.span(piece)[0] > this.room.floorY + 0.3;
    if (wall) {
      const along = at[0] * wall.along[0] + at[2] * wall.along[2];
      const spot = wallPoint(wall, along, depth + 0.01, piece.position.y);
      this.tryChange(piece, () => {
        piece.position.set(spot[0], piece.position.y, spot[2]);
        piece.rotation.y = Math.atan2(wall.normal[0], wall.normal[2]);
      }, 0.1);
    }
    if (!wall || !raised) this.lift(piece, -100);
  }

  /**
   * Whether a walker `radius` metres round, standing at this floor point, is
   * in an added piece: one taller than a step and not overhead.
   */
  blocksWalker(point: Vec2, radius = 0.2) {
    const walker = new Footprint(point, [radius, radius], 0);
    return this.pieces.some((piece) => {
      const [bottom, top] = this.span(piece);
      return top > this.room.floorY + 0.15 && bottom < this.room.floorY + 1.7
        && walker.overlaps(this.footprint(piece), 0);
    });
  }

  /**
   * What the user can see now, for the voice agent's inspect_view: the
   * pieces in view and not hidden behind something, and the one under the
   * middle of the view, as the phone's describeCurrentView says it.
   */
  describeView(): string {
    const camera = this.viewCamera();
    camera.updateMatrixWorld();
    const eye = camera.getWorldPosition(new THREE.Vector3());
    const frustum = new THREE.Frustum().setFromProjectionMatrix(
      new THREE.Matrix4().multiplyMatrices(camera.projectionMatrix, camera.matrixWorldInverse));
    this.raycaster.setFromCamera(new THREE.Vector2(0, 0), camera);
    this.raycaster.far = 30;
    const first = this.raycaster.intersectObjects([...this.room.solids, ...this.pieces], true)[0];
    let centre: THREE.Object3D | null = first?.object ?? null;
    while (centre && centre.parent !== this.group) centre = centre.parent;
    const names: string[] = [];
    for (const piece of this.pieces) {
      const box = new THREE.Box3().setFromObject(piece);
      if (!frustum.intersectsBox(box)) continue;
      const middle = box.getCenter(new THREE.Vector3());
      const top = new THREE.Vector3(middle.x, box.max.y - 0.02, middle.z);
      const seen = [middle, top].some((point) => this.seesPiece(point, eye, piece));
      if (seen && !names.some((n) => n.toLowerCase() === piece.name.toLowerCase())) names.push(piece.name);
    }
    if (centre) {
      const others = names.filter((n) => n.toLowerCase() !== centre.name.toLowerCase());
      return `Viewport only: ${centre.name} is directly in front of the user.` + (others.length ? ` Also visible: ${others.join(", ")}.` : "");
    }
    return names.length
      ? `Viewport only: visible editable objects are ${names.join(", ")}. Nothing is directly under the screen centre.`
      : "Viewport only: no editable objects are visible.";
  }

  /** Which way a piece at `spot` should face to face the user, or a wall's way. */
  facingYaw(facing: Facing, spot: THREE.Vector3): number {
    const { eye } = this.look();
    const at = spot.toArray() as Vec3;
    return this.turn(facing, at, eye, this.nearestWall(at));
  }

  /** The wall the user is looking at, or the nearest to where they look. */
  wallInView(): Wall | undefined {
    const { gaze } = this.look();
    return gaze.wall ?? this.nearestWall(gaze.point);
  }

  // Where the user is looking

  private look() {
    const camera = this.viewCamera();
    camera.updateMatrixWorld();
    const eye = camera.getWorldPosition(new THREE.Vector3());
    const front = camera.getWorldDirection(new THREE.Vector3());
    return { eye: eye.toArray() as Vec3, gaze: this.gaze(eye, front) };
  }

  /**
   * Where the middle of the view points: the floor spot there (or just this
   * side of whatever it hits), the wall it hits if it's a wall, and the
   * level direction of view.
   */
  private gaze(eye: THREE.Vector3, front: THREE.Vector3) {
    const ahead = new THREE.Vector3(front.x, 0, front.z);
    if (ahead.length() > 1e-3) ahead.normalize();
    else ahead.set(0, 0, -1);
    const point = eye.clone().addScaledVector(ahead, 1.5);
    let wall: Wall | undefined;
    this.raycaster.set(eye, front);
    this.raycaster.far = 30;
    const hit = this.raycaster.intersectObjects([...this.room.solids, ...this.pieces], true)[0];
    if (hit) {
      point.copy(hit.point);
      const index = this.room.wallIndex(hit.object);
      wall = index >= 0 ? this.room.walls[index] : undefined;
      // Not floor: start clear of whatever it is.
      if (Math.abs(point.y - this.room.floorY) > 0.1) point.addScaledVector(ahead, -0.35);
    }
    point.y = this.room.floorY;
    return { point: point.toArray() as Vec3, wall, ahead: ahead.toArray() as Vec3 };
  }

  private nearestWall(point: Vec3): Wall | undefined {
    return this.room.walls.filter((wall) => wallDistance(wall, point) > -0.15)
      .sort((a, b) => cost(a, point) - cost(b, point))[0];
  }

  /**
   * The nearest clear spot to `target`, in rings 15 cm apart, each tried
   * from the viewer's side outwards; a spot the viewer can see wins over a
   * nearer one they can't.
   */
  private searchAround(target: Vec3, eye: Vec3, ahead: Vec3, half: Vec2, height: number, turn: (candidate: Vec3) => number) {
    const span: [number, number] = [this.room.floorY, this.room.floorY + height];
    let hidden: { spot: Vec3; yaw: number } | undefined;
    const towardsViewer = Math.atan2(-ahead[2], -ahead[0]);
    const inside = this.isInside();
    for (let ring = 0; ring <= 8; ring++) {
      const count = Math.max(1, 6 * ring);
      for (let i = 0; i < count; i++) {
        const angle = towardsViewer + Math.floor((i + 1) / 2) * (i % 2 === 0 ? 1 : -1) * 2 * Math.PI / count;
        const candidate: Vec3 = [target[0] + ring * 0.15 * Math.cos(angle), target[1], target[2] + ring * 0.15 * Math.sin(angle)];
        // Not behind the viewer, nor right at their feet when standing in the room.
        const forward = (candidate[0] - eye[0]) * ahead[0] + (candidate[2] - eye[2]) * ahead[2];
        if (forward < (inside ? 0.6 + half[1] : -Infinity)) continue;
        const heading = turn(candidate);
        if (!this.hasRoom(new Footprint([candidate[0], candidate[2]], half, heading), undefined, span)) continue;
        if (this.canSee([candidate[0], candidate[1] + 0.4, candidate[2]], eye)) return { spot: candidate, yaw: heading, visible: true };
        hidden ??= { spot: candidate, yaw: heading };
      }
    }
    if (!hidden) {
      throw new Error("There's no clear floor where the user is looking. They should look at an open bit of floor and ask again.");
    }
    return { ...hidden, visible: false };
  }

  /** The clear spot along a wall nearest to where `target` is beside it. */
  private searchAlong(wall: Wall, target: Vec3, eye: Vec3, half: Vec2, height: number, facing: Facing) {
    const span: [number, number] = [this.room.floorY, this.room.floorY + height];
    const towardWall = facing === "towardWall";
    // Backed up to the wall, or facing it with room to sit.
    const standoff = half[1] + (towardWall ? 0.45 : 0.03);
    const outward = Math.atan2(wall.normal[0], wall.normal[2]);
    const turn = towardWall ? outward + Math.PI : outward;
    const low = wall.span[0] + half[0], high = wall.span[1] - half[0];
    const along = target[0] * wall.along[0] + target[2] * wall.along[2];
    const start = low <= high ? Math.min(Math.max(along, low), high) : (low + high) / 2;
    let hidden: Vec3 | undefined;
    for (let step = 0; step <= 40; step++) {
      const s = start + Math.floor((step + 1) / 2) * (step % 2 === 0 ? 1 : -1) * 0.15;
      if (low <= high && (s < low || s > high)) continue;
      const candidate = wallPoint(wall, s, standoff, this.room.floorY);
      if (!this.hasRoom(new Footprint([candidate[0], candidate[2]], half, turn), undefined, span)) continue;
      if (this.canSee([candidate[0], candidate[1] + 0.4, candidate[2]], eye)) return { spot: candidate, yaw: turn, visible: true };
      hidden ??= candidate;
    }
    if (!hidden) throw new Error("That wall has no clear stretch of floor wide enough.");
    return { spot: hidden, yaw: turn, visible: false };
  }

  /** A clear spot beside a piece: on its right, then its left, moving out in 15 cm steps. Backs line up. */
  private searchBeside(reference: Piece, eye: Vec3, half: Vec2, height: number, facing: Facing) {
    const span: [number, number] = [this.room.floorY, this.room.floorY + height];
    const { box } = reference.userData, s = reference.scale.x;
    const referenceHalf: Vec2 = [((box.max.x - box.min.x) / 2) * s, ((box.max.z - box.min.z) / 2) * s];
    const right = new THREE.Vector3(1, 0, 0).applyAxisAngle(up, reference.rotation.y);
    const front = new THREE.Vector3(0, 0, 1).applyAxisAngle(up, reference.rotation.y);
    for (const gap of [0.1, 0.25, 0.4]) {
      for (const [sign, side] of [[1, "right"], [-1, "left"]] as const) {
        const candidate = reference.position.clone()
          .addScaledVector(right, sign * (referenceHalf[0] + half[0] + gap))
          .addScaledVector(front, half[1] - referenceHalf[1]);
        candidate.y = this.room.floorY;
        const spot = candidate.toArray() as Vec3;
        const yaw = this.turn(facing, spot, eye, this.nearestWall(spot), reference);
        if (this.hasRoom(new Footprint([spot[0], spot[2]], half, yaw), undefined, span)) return { spot, yaw, side };
      }
    }
    throw new Error(`There's no room on either side of the ${reference.name}.`);
  }

  private turn(facing: Facing, spot: Vec3, eye: Vec3, wall?: Wall, reference?: Piece): number {
    // Models face +z; a turn of a about +y points that at (sin a, cos a).
    if (facing === "awayFromWall" && wall) return Math.atan2(wall.normal[0], wall.normal[2]);
    if (facing === "towardWall" && wall) return Math.atan2(-wall.normal[0], -wall.normal[2]);
    if (facing === "sameAsReference" && reference) return reference.rotation.y;
    return Math.atan2(eye[0] - spot[0], eye[2] - spot[2]);
  }

  /** Where `point` is from the viewer: in front, on the left, … */
  private direction(point: Vec3, eye: Vec3) {
    const front = this.viewCamera().getWorldDirection(new THREE.Vector3());
    const forward: Vec2 = Math.hypot(front.x, front.z) > 1e-3 ? [front.x, front.z] : [0, -1];
    const length = Math.hypot(...forward);
    const f: Vec2 = [forward[0] / length, forward[1] / length], r: Vec2 = [-f[1], f[0]];
    const offset: Vec2 = [point[0] - eye[0], point[2] - eye[2]];
    const along = offset[0] * f[0] + offset[1] * f[1], across = offset[0] * r[0] + offset[1] * r[1];
    const side = Math.abs(along) >= Math.abs(across) ? (along >= 0 ? "in front" : "behind")
      : across >= 0 ? "to the right" : "to the left";
    return `${side}, ${Math.hypot(...offset).toFixed(1)} metres away,`;
  }

  private canSee(point: Vec3, eye: Vec3) {
    const from = new THREE.Vector3(...eye), to = new THREE.Vector3(...point);
    const distance = from.distanceTo(to);
    this.raycaster.set(from, to.sub(from).normalize());
    this.raycaster.far = distance;
    return this.raycaster.intersectObjects([...this.room.solids, ...this.pieces], true).length === 0;
  }

  /** Whether nothing but `piece` itself is between the eye and a point on it. */
  private seesPiece(point: THREE.Vector3, eye: THREE.Vector3, piece: Piece) {
    const distance = eye.distanceTo(point);
    this.raycaster.set(eye, point.clone().sub(eye).normalize());
    this.raycaster.far = distance;
    const hit = this.raycaster.intersectObjects([...this.room.solids, ...this.pieces], true)[0];
    if (!hit) return true;
    let object: THREE.Object3D | null = hit.object;
    while (object && object !== piece) object = object.parent;
    return object === piece || hit.distance > distance - 0.05;
  }

  private drop(model: THREE.Object3D) {
    model.position.y = 0.4;
    this.drops.push({ model, start: performance.now() });
  }
}

/**
 * Covers every part of a piece with one tiling material (set_object_texture).
 * Models' texture coordinates are their own, so it tiles a couple of times
 * across each part rather than at a true size.
 */
export function coverPiece(piece: Piece, texture: THREE.Texture, textureId: string) {
  const map = texture.clone();
  map.wrapS = map.wrapT = THREE.RepeatWrapping;
  map.repeat.set(2, 2);
  map.colorSpace = THREE.SRGBColorSpace;
  map.needsUpdate = true;
  const material = new THREE.MeshStandardMaterial({ map, roughness: 0.75 });
  piece.traverse((object) => {
    if (!(object instanceof THREE.Mesh)) return;
    if (!object.geometry.getAttribute("uv")) {
      // No texture coordinates (a scanned PLY): project from above, a tile per 50 cm.
      object.geometry = object.geometry.clone();
      const p = object.geometry.getAttribute("position");
      const uv = new Float32Array(p.count * 2);
      for (let i = 0; i < p.count; i++) {
        uv[2 * i] = p.getX(i) * 2;
        uv[2 * i + 1] = (p.getZ(i) + p.getY(i)) * 2;
      }
      object.geometry.setAttribute("uv", new THREE.BufferAttribute(uv, 2));
      if (!object.geometry.getAttribute("normal")) object.geometry.computeVertexNormals();
    }
    object.material = material;
  });
  piece.userData.texture = textureId;
}

/**
 * Stretches the model inside a piece (its own scale, apart from the
 * holder's even one), as the phone's stretch handles do, and measures it
 * again.
 */
export function stretch(piece: Piece, scale: [number, number, number]) {
  const model = piece.children[0];
  if (!model) return;
  model.scale.set(...scale);
  // A parentless copy measures in the holder's frame (geometry is shared, not copied).
  const copy = model.clone();
  copy.updateMatrixWorld(true);
  piece.userData.box = new THREE.Box3().setFromObject(copy);
}

/** Whether a piece is a light that should glow. */
export function glows(name: string) {
  return /lamp|light|chandelier|sconce|lantern|pendant/i.test(name);
}

function cost(wall: Wall, point: Vec3) {
  const s = point[0] * wall.along[0] + point[2] * wall.along[2];
  const beyond = Math.max(wall.span[0] - s, s - wall.span[1], 0);
  return Math.abs(wallDistance(wall, point)) + beyond;
}

function horizontal(a: Vec3, b: Vec3) {
  return Math.hypot(a[0] - b[0], a[2] - b[2]);
}

function describe(facing: Facing) {
  return { viewer: "facing the user", awayFromWall: "facing out into the room", towardWall: "facing the wall",
    sameAsReference: "facing the same way" }[facing];
}
