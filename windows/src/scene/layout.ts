import * as THREE from "three";
import type { Account } from "../account";
import * as Library from "../models/library";
import { asFurniture, parseModel } from "../models/loader";
import * as PolyHaven from "../models/polyHaven";
import * as Sketchfab from "../models/sketchfab";
import type { Origin } from "../models/search";
import type { Vec3 } from "../room/analysis";
import type { Room } from "../room/room";
import { coverPiece, stretch, type Furniture } from "./furniture";
import { defaultLighting, type Lighting } from "./lighting";

/**
 * What's been done to a room on this computer: the furniture (where each
 * piece came from, so it can be fetched again, its pose and material), the
 * wall and floor textures, the lighting, and any ceiling or walls added. Kept
 * per room in the browser, so reopening a room carries on where you left off.
 * Pieces opened from local files can't be fetched again, so they aren't kept.
 */
interface SavedPiece {
  name: string;
  origin: Origin;
  credit?: string;
  texture?: string;
  position: Vec3;
  yaw: number;
  scale: number;
  /** How the model is stretched inside its holder, if it is. */
  modelScale?: Vec3;
}

export interface Surfaces {
  /** Poly Haven texture ID by wall index. */
  walls: Record<number, string>;
  floor: string | null;
  lighting: Lighting;
  /** Whether the ceiling shows: null leaves it as scanned. */
  ceiling: boolean | null;
  closedSides: boolean;
}

interface SavedLayout extends Partial<Surfaces> {
  pieces: SavedPiece[];
}

const key = (roomKey: string) => `roomtwin-layout:${roomKey}`;

export class Layout {
  surfaces: Surfaces = { walls: {}, floor: null, lighting: { ...defaultLighting }, ceiling: null, closedSides: false };
  private timer?: number;

  constructor(private roomKey: string, private room: Room, private furniture: Furniture,
    private applyLighting: (lighting: Lighting) => void) {
    furniture.onChange = () => this.saveSoon();
  }

  /** Poly Haven texture ID by wall index, for walls that have one. */
  get walls() {
    return this.surfaces.walls;
  }

  setWalls(indices: number[], textureId: string | null) {
    for (const i of indices) {
      if (textureId) this.surfaces.walls[i] = textureId;
      else delete this.surfaces.walls[i];
    }
    this.saveSoon();
  }

  /** Records a change to the floor, lighting or enclosure. */
  update(change: Partial<Surfaces>) {
    Object.assign(this.surfaces, change);
    this.saveSoon();
  }

  /** Whether this computer has a layout saved for the room. */
  get isSaved() {
    try {
      return localStorage.getItem(key(this.roomKey)) !== null;
    } catch {
      return false;
    }
  }

  /** Puts back what was saved for this room. Returns how many things couldn't be fetched. */
  async restore(account: Account): Promise<number> {
    let saved: SavedLayout;
    try {
      saved = JSON.parse(localStorage.getItem(key(this.roomKey)) ?? "null");
    } catch {
      return 0;
    }
    if (!saved) return 0;
    let failed = 0;
    const onChange = this.furniture.onChange;
    this.furniture.onChange = undefined;
    // RoomPlan's pieces and the phone's are in the room already: put them where they were left, and take away the removed ones.
    const scanned = new Map(this.furniture.pieces.filter((p) => p.userData.origin.kind === "scan")
      .map((p) => [(p.userData.origin as { id: string }).id, p]));
    const kept = new Set(saved.pieces.flatMap((p) => (p.origin.kind === "scan" ? [p.origin.id] : [])));
    for (const [id, piece] of scanned) if (!kept.has(id)) this.furniture.remove(piece);
    await Promise.all(saved.pieces.map(async (piece) => {
      try {
        let added = piece.origin.kind === "scan" ? scanned.get(piece.origin.id) : undefined;
        if (added) {
          added.name = piece.name;
          added.position.set(...piece.position);
          added.rotation.y = piece.yaw;
          added.scale.setScalar(piece.scale);
        } else {
          const model = await fetchOrigin(piece.origin, account);
          model.name = piece.name;
          const box = new THREE.Box3().setFromObject(model);
          added = this.furniture.add(model, { origin: piece.origin, credit: piece.credit, box }, piece.position, piece.yaw, piece.scale);
        }
        if (piece.modelScale) stretch(added, piece.modelScale);
        if (piece.texture) {
          const { texture } = await PolyHaven.wallTexture(await PolyHaven.asset("textures", piece.texture));
          coverPiece(added, texture, piece.texture);
        }
      } catch {
        failed++;
      }
    }));

    const byTexture = new Map<string, number[]>();
    for (const [index, id] of Object.entries(saved.walls ?? {})) {
      byTexture.set(id, [...(byTexture.get(id) ?? []), Number(index)]);
    }
    for (const [id, indices] of byTexture) {
      try {
        const { texture, size } = await PolyHaven.wallTexture(await PolyHaven.asset("textures", id));
        this.room.setWallTexture(texture, size, indices);
        for (const i of indices) this.surfaces.walls[i] = id;
      } catch {
        failed++;
      }
    }
    if (saved.floor) {
      try {
        const { texture, size } = await PolyHaven.wallTexture(await PolyHaven.asset("textures", saved.floor));
        this.room.setFloorTexture(texture, size);
        this.surfaces.floor = saved.floor;
      } catch {
        failed++;
      }
    }
    if (saved.lighting) {
      this.surfaces.lighting = saved.lighting;
      this.applyLighting(saved.lighting);
    }
    if (typeof saved.ceiling === "boolean") {
      this.surfaces.ceiling = saved.ceiling;
      this.room.setCeiling(saved.ceiling);
    }
    if (saved.closedSides) {
      this.surfaces.closedSides = true;
      this.room.setOpenSidesClosed(true);
    }
    this.furniture.onChange = onChange;
    return failed;
  }

  /** The layout as JSON, for saving to a file. */
  toJSON(): SavedLayout {
    const pieces = this.furniture.pieces.filter((piece) => piece.userData.origin.kind !== "file").map((piece) => ({
      name: piece.name,
      origin: piece.userData.origin,
      credit: piece.userData.credit,
      texture: piece.userData.texture,
      position: piece.position.toArray() as Vec3,
      yaw: piece.rotation.y,
      scale: piece.scale.x,
      modelScale: piece.children[0]?.scale.equals(new THREE.Vector3(1, 1, 1)) ? undefined
        : piece.children[0].scale.toArray() as Vec3,
    }));
    return { pieces, ...this.surfaces };
  }

  save() {
    try {
      localStorage.setItem(key(this.roomKey), JSON.stringify(this.toJSON()));
    } catch {
      // Storage full or blocked: the layout lasts until the page closes.
    }
  }

  /** Forgets the saved layout for this room. */
  forget() {
    try {
      localStorage.removeItem(key(this.roomKey));
    } catch {
      // Nothing saved.
    }
  }

  private saveSoon() {
    clearTimeout(this.timer);
    this.timer = window.setTimeout(() => this.save(), 400);
  }
}

/** Fetches a piece of furniture again from where it came from. */
export async function fetchOrigin(origin: Origin, account: Account): Promise<THREE.Object3D> {
  switch (origin.kind) {
    case "polyhaven":
      return PolyHaven.model(await PolyHaven.asset("models", origin.id));
    case "sketchfab":
      return Sketchfab.model(origin, origin.height);
    case "account":
      return asFurniture(await parseModel(await account.file("objects", origin.path), origin.path));
    case "library":
      return Library.model(origin.id);
    case "file":
      throw new Error("Files opened from this computer can't be fetched again.");
    case "scan":
      throw new Error("That piece of the scan is no longer in the room.");
  }
}
