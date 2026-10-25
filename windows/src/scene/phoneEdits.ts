import * as THREE from "three";
import * as PolyHaven from "../models/polyHaven";
import type { Room } from "../room/room";
import { geometryOf, type ScannedPiece } from "../room/roomPlan";
import { scanMaterial } from "../room/room";
import { coverPiece, stretch, type Furniture, type Piece } from "./furniture";
import type { Surfaces } from "./layout";
import type { Lighting } from "./lighting";

/**
 * The edits saved beside a room by the phone (RoomEditMetadata.swift,
 * room-edits.json), and the USDZ saved with them, which holds the meshes of
 * the models added on the phone.
 */
export interface RoomEditMetadata {
  version: number;
  furniture: {
    /** "scan:3" for RoomPlan's pieces, "added:<uuid>" for models added on the phone. */
    id: string;
    name: string;
    modelName: string;
    source: string;
    /** The holder's node in the USDZ (USD turns its spaces into underscores). */
    exportNodeName: string;
    /** The holder's 4×4 transform, column by column. */
    transform: number[];
    modelScale: number[];
    material?: MaterialReference | null;
  }[];
  wallMaterials: { wallIndex: number; exportNodeName: string; material?: MaterialReference | null }[];
  floorMaterial?: { exportNodeName: string; material?: MaterialReference | null } | null;
  lighting?: Lighting | null;
  enclosure: { ceiling: boolean; openWalls: boolean };
  snappingEnabled: boolean;
}

interface MaterialReference {
  assetID?: string | null;
  name?: string | null;
  size: number[];
}

/**
 * Puts RoomPlan's furniture in the room as pieces, each standing where it
 * was found, its holder at the bottom middle of the piece as on the phone, so
 * the phone's saved transforms apply as they are.
 */
export function addScannedPieces(furniture: Furniture, pieces: ScannedPiece[]) {
  for (const scanned of pieces) {
    const p = scanned.mesh.positions;
    if (!p.length) continue;
    let lx = Infinity, ly = Infinity, lz = Infinity, hx = -Infinity, hz = -Infinity;
    for (let i = 0; i < p.length; i += 3) {
      lx = Math.min(lx, p[i]);
      hx = Math.max(hx, p[i]);
      ly = Math.min(ly, p[i + 1]);
      lz = Math.min(lz, p[i + 2]);
      hz = Math.max(hz, p[i + 2]);
    }
    const origin: [number, number, number] = [(lx + hx) / 2, ly, (lz + hz) / 2];
    const geometry = geometryOf(scanned.mesh, origin);
    geometry.computeVertexNormals();
    const model = new THREE.Mesh(geometry, scanMaterial());
    model.name = scanned.name;
    const box = new THREE.Box3().setFromObject(model);
    furniture.add(model, { origin: { kind: "scan", id: scanned.id }, box }, origin, 0);
  }
}

export interface PhoneEditTarget {
  room: Room;
  furniture: Furniture;
  applyLighting(lighting: Lighting): void;
  record(change: Partial<Surfaces>): void;
  setWalls(indices: number[], textureId: string): void;
}

/**
 * Applies the phone's saved edits: RoomPlan's pieces go where they were
 * left (or stay removed), models added on the phone come back from the
 * USDZ, and the wall and floor materials, lighting and enclosure are set
 * again (unless `surfaces` is false, when this computer has its own say on
 * those). Returns how many things couldn't be put back.
 */
export async function applyPhoneEdits(target: PhoneEditTarget, edits: RoomEditMetadata, saved?: THREE.Object3D,
  surfaces = true): Promise<number> {
  const { room, furniture } = target;
  let failed = 0;
  const scanned = new Map(furniture.pieces.filter((p) => p.userData.origin.kind === "scan")
    .map((p) => [(p.userData.origin as { id: string }).id, p]));
  const group = saved && findNode(saved, "RoomTwin furniture");
  const kept = new Set<string>();
  for (const item of edits.furniture ?? []) {
    let piece: Piece | undefined = scanned.get(item.id);
    if (!piece) {
      const holder = group && findNode(group, item.exportNodeName);
      if (!holder?.children.length) {
        failed++;
        continue;
      }
      const model = holder.children.length === 1 ? holder.children[0].clone() : wrap(holder.children);
      model.position.set(0, 0, 0);
      model.name = item.modelName || item.name;
      piece = furniture.add(model, { origin: { kind: "scan", id: item.id }, box: new THREE.Box3().setFromObject(model) },
        [0, 0, 0], 0);
    }
    piece.name = item.name;
    pose(piece, item.transform);
    if (item.modelScale?.length === 3) stretch(piece, item.modelScale as [number, number, number]);
    kept.add(item.id);
    const id = item.material?.assetID;
    if (id) {
      try {
        const { texture } = await PolyHaven.wallTexture(await PolyHaven.asset("textures", id));
        coverPiece(piece, texture, id);
      } catch {
        failed++;
      }
    }
  }
  // The phone saves every piece still in the room, so one not listed was removed there.
  if (edits.furniture?.length) {
    for (const [id, piece] of scanned) if (!kept.has(id)) furniture.remove(piece);
  }
  if (!surfaces) return failed;

  const walls = new Map<string, number[]>();
  for (const wall of edits.wallMaterials ?? []) {
    const id = wall.material?.assetID;
    if (id && wall.wallIndex < room.walls.length) walls.set(id, [...(walls.get(id) ?? []), wall.wallIndex]);
  }
  for (const [id, indices] of walls) {
    try {
      const { texture, size } = await PolyHaven.wallTexture(await PolyHaven.asset("textures", id));
      room.setWallTexture(texture, size, indices);
      target.setWalls(indices, id);
    } catch {
      failed++;
    }
  }
  const floor = edits.floorMaterial?.material?.assetID;
  if (floor) {
    try {
      const { texture, size } = await PolyHaven.wallTexture(await PolyHaven.asset("textures", floor));
      if (room.setFloorTexture(texture, size)) target.record({ floor });
    } catch {
      failed++;
    }
  }
  if (edits.lighting) {
    const lighting = { brightness: edits.lighting.brightness, warmth: edits.lighting.warmth };
    target.applyLighting(lighting);
    target.record({ lighting });
  }
  if (edits.enclosure?.ceiling) {
    room.setCeiling(true);
    target.record({ ceiling: true });
  }
  if (edits.enclosure?.openWalls) {
    room.setOpenSidesClosed(true);
    target.record({ closedSides: true });
  }
  return failed;
}

/** Sets a piece's place and heading from the phone's holder transform (any tilt is dropped). */
function pose(piece: Piece, values: number[]) {
  if (values?.length !== 16) return;
  const m = new THREE.Matrix4().fromArray(values);
  const position = new THREE.Vector3(), rotation = new THREE.Quaternion(), scale = new THREE.Vector3();
  m.decompose(position, rotation, scale);
  piece.position.copy(position);
  const forward = new THREE.Vector3(0, 0, 1).applyQuaternion(rotation);
  piece.rotation.set(0, Math.atan2(forward.x, forward.z), 0);
  piece.scale.setScalar(scale.y || 1);
}

function findNode(root: THREE.Object3D, name: string): THREE.Object3D | undefined {
  const plain = (text: string) => text.replace(/_/g, " ").trim().toLowerCase();
  const wanted = plain(name);
  let match: THREE.Object3D | undefined;
  root.traverse((node) => {
    if (!match && plain(node.name) === wanted) match = node;
  });
  return match;
}

function wrap(children: THREE.Object3D[]) {
  const group = new THREE.Group();
  for (const child of children) group.add(child.clone());
  return group;
}
