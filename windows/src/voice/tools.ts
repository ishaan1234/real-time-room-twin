import * as THREE from "three";
import * as PolyHaven from "../models/polyHaven";
import { find, type Found, type Source } from "../models/search";
import { coverPiece, type Facing, type Furniture, type Piece, type Placement } from "../scene/furniture";
import type { Lighting } from "../scene/lighting";
import type { Surfaces } from "../scene/layout";
import type { Room } from "../room/room";
import type { Tool } from "./agent";
import type { SavedObject } from "../account";

/** What the tools act on; the room may change while a conversation is open. */
export interface ToolContext {
  room(): Room | undefined;
  furniture(): Furniture | undefined;
  /** A piece was added, with its credit if its licence needs one. */
  added(piece: Piece, found: Found): void;
  /** Walls were textured (indices, Poly Haven ID) or reset (null). */
  wallsChanged(indices: number[], textureId: string | null): void;
  /** The floor, lighting or enclosure changed. */
  surfacesChanged(change: Partial<Surfaces>): void;
  lighting(): Lighting;
  applyLighting(lighting: Lighting): void;
  /** The signed-in user's My Objects, and one of them as furniture. */
  savedObjects(): Promise<SavedObject[]>;
  savedModel(object: SavedObject): Promise<Found>;
}

/**
 * Matches a natural name like "my Hoka shoes" to one of the user's own
 * objects, as the phone does, without sending the list anywhere.
 */
export function bestSavedObject(request: string, objects: SavedObject[]): SavedObject | undefined {
  const normalized = (value: string) => value.toLowerCase().normalize("NFKD").replace(/[\u0300-\u036f]/g, "")
    .split(/[^\p{L}\p{N}]+/u).filter((w) => w && !["my", "saved", "imported", "object"].includes(w))
    .map((w) => (w.length > 3 && w.endsWith("s") ? w.slice(0, -1) : w)).join(" ");
  const wanted = normalized(request);
  if (!wanted) return objects[0];
  const exact = objects.find((o) => normalized(o.name) === wanted);
  if (exact) return exact;
  const contained = objects.find((o) => {
    const name = normalized(o.name);
    return name.includes(wanted) || wanted.includes(name);
  });
  if (contained) return contained;
  const words = new Set(wanted.split(" "));
  let best: SavedObject | undefined, score = 0;
  for (const object of objects) {
    const shared = normalized(object.name).split(" ").filter((w) => words.has(w)).length;
    if (shared > score) [best, score] = [object, shared];
  }
  return best;
}

/**
 * The voice agent's tools, doing what the iPhone app does with them: the
 * same names and parameters as the live ElevenLabs agent (see
 * Voice/setup_agent.py). A RoomPlan room's furniture is editable as on the
 * phone; a detailed mesh scan is one mesh, so there only added pieces are.
 */
export function voiceTools(context: ToolContext): Record<string, Tool> {
  const ready = () => {
    const room = context.room(), furniture = context.furniture();
    if (!room || !furniture) throw new Error("No room is open yet.");
    return { room, furniture };
  };
  const text = (parameters: Record<string, any>, key: string) => {
    const value = parameters[key];
    return typeof value === "string" && value.trim() ? value.trim() : undefined;
  };
  const number = (parameters: Record<string, any>, key: string) => {
    const value = Number(parameters[key]);
    return Number.isFinite(value) && parameters[key] !== null && parameters[key] !== "" ? value : undefined;
  };
  const placementOf = (parameters: Record<string, any>): Placement => {
    const reference = text(parameters, "reference");
    return ({
      against_wall: { kind: "againstWall" },
      next_to: { kind: "nextTo", reference },
      on_top_of: { kind: "onTopOf", reference },
      on_wall: { kind: "onWall", elevation: number(parameters, "elevation_m") },
      ceiling: { kind: "ceiling" },
    } as Record<string, Placement>)[text(parameters, "placement") ?? ""] ?? { kind: "inView" };
  };
  const facingOf = (parameters: Record<string, any>) => ({ user: "viewer", away_from_wall: "awayFromWall",
    toward_wall: "towardWall", same_as_reference: "sameAsReference" } as Record<string, Facing>)[text(parameters, "facing") ?? ""];
  const sourceOf = (parameters: Record<string, any>) =>
    (["polyhaven", "sketchfab"].includes(text(parameters, "source") ?? "") ? text(parameters, "source") : "any") as Source;
  /** A piece added here, by name; scanned furniture isn't separate here, so say so. */
  const pieceNamed = (furniture: Furniture, name?: string) => {
    try {
      return furniture.piece(name);
    } catch (error) {
      throw new Error(`${(error as Error).message} In a detailed mesh scan the scanned furniture is part of the mesh, so only added pieces can be changed.`);
    }
  };
  const sizeOf = (piece: Piece) => {
    const { box } = piece.userData;
    return new THREE.Vector3().subVectors(box.max, box.min).multiplyScalar(piece.scale.x);
  };

  return {
    async add_object(parameters) {
      const { furniture } = ready();
      const query = text(parameters, "query");
      if (!query) throw new Error("Say what to add.");
      const placement = placementOf(parameters), facing = facingOf(parameters);
      const height = (number(parameters, "height_m") ?? 0) > 0 ? number(parameters, "height_m")! : 0.9;
      const found = await find(query, height, sourceOf(parameters));
      const size = new THREE.Box3().setFromObject(found.model).getSize(new THREE.Vector3());
      const { piece, words } = furniture.place(found.model, { origin: found.origin, credit: found.credit }, placement, facing);
      context.added(piece, found);
      return `Added “${found.model.name || query}” from ${found.source}, ${size.x.toFixed(1)} m wide and ${size.y.toFixed(1)} m tall, ${words}.`;
    },

    async inspect_view() {
      return ready().furniture.describeView();
    },

    async place_saved_object(parameters) {
      const { furniture } = ready();
      const name = text(parameters, "name");
      if (!name) throw new Error("Say which saved object to place.");
      const saved = await context.savedObjects();
      const object = bestSavedObject(name, saved);
      if (!object) {
        throw new Error(saved.length ? `No saved object matches ${name}. Available: ${saved.slice(0, 20).map((o) => o.name).join(", ")}.`
          : "No saved objects were found. Scan or import it into My Objects first.");
      }
      const found = await context.savedModel(object);
      const { piece, words } = furniture.place(found.model, { origin: found.origin }, placementOf(parameters));
      context.added(piece, found);
      return `Placed your saved “${object.name}” ${words}.`;
    },

    async remove_object(parameters) {
      const { furniture } = ready();
      const piece = pieceNamed(furniture, text(parameters, "name"));
      furniture.remove(piece);
      return `Removed “${piece.name}”.`;
    },

    async move_object(parameters) {
      const { furniture } = ready();
      const piece = pieceNamed(furniture, text(parameters, "name"));
      const metres = (number(parameters, "distance_m") ?? 0) > 0 ? number(parameters, "distance_m")! : 0.3;
      const direction = text(parameters, "direction") ?? "forward";
      // Directions are the user's, from where they're looking.
      const front = furniture.viewCamera().getWorldDirection(new THREE.Vector3());
      front.y = 0;
      if (front.lengthSq() < 1e-6) front.set(0, 0, -1);
      front.normalize();
      const right = new THREE.Vector3(-front.z, 0, front.x);
      const steps: Record<string, THREE.Vector3> = {
        left: right.clone().negate(), right, forward: front, away: front,
        backward: front.clone().negate(), closer: front.clone().negate(),
        up: new THREE.Vector3(0, 1, 0), down: new THREE.Vector3(0, -1, 0),
      };
      const step = steps[direction];
      if (!step) throw new Error("Say left, right, forward, backward, up or down.");
      // It goes until something's in the way: a wall, another piece, the floor, or what's under it.
      const moved = Math.abs(step.y ? furniture.lift(piece, step.y * metres)
        : furniture.slide(piece, step.x * metres, step.z * metres, false));
      furniture.onChange?.();
      if (moved < 0.01) throw new Error(`Something's in the way ${direction}, so the ${piece.name} stayed where it was.`);
      if (moved < metres - 0.02) return `Moved the ${piece.name} ${moved.toFixed(2)} metres ${direction}, then it hit something, so it stopped there.`;
      return `Moved the ${piece.name} ${metres.toFixed(1)} metres ${direction}.`;
    },

    async replace_object(parameters) {
      const { furniture } = ready();
      const old = pieceNamed(furniture, text(parameters, "name"));
      const query = text(parameters, "query");
      if (!query) throw new Error("Say what to replace it with.");
      const height = (number(parameters, "height_m") ?? 0) > 0 ? number(parameters, "height_m")! : sizeOf(old).y;
      const found = await find(query, height, sourceOf(parameters));
      const facing = text(parameters, "facing") === "preserve" ? undefined : facingOf(parameters);
      let piece: Piece, where = "in the same spot";
      if (text(parameters, "placement") === "against_wall") {
        furniture.remove(old);
        ({ piece, words: where } = furniture.place(found.model, { origin: found.origin, credit: found.credit },
          { kind: "againstWall" }, facing ?? "awayFromWall"));
      } else {
        const box = new THREE.Box3().setFromObject(found.model);
        piece = furniture.add(found.model, { origin: found.origin, credit: found.credit, box },
          old.position.toArray() as [number, number, number], old.rotation.y);
        furniture.remove(old);
        if (facing) piece.rotation.y = furniture.facingYaw(facing, piece.position);
        // Bigger than what it replaces: shift it clear of its neighbours if it can.
        furniture.nudge(piece, 0.6);
      }
      context.added(piece, found);
      return `Replaced the ${old.name} with “${piece.name}” from ${found.source}, ${where}.`;
    },

    async set_wall_texture(parameters) {
      const { room, furniture } = ready();
      const query = text(parameters, "query");
      const asset = query ? (await PolyHaven.wallTextures(query))[0] : undefined;
      if (!asset) throw new Error("Couldn't find a wall texture like that.");
      if (!room.walls.length) throw new Error("No wall was found in the scan.");
      let which: number[] | undefined;
      if (text(parameters, "walls") === "in_view") {
        const wall = furniture.wallInView();
        if (!wall) throw new Error("The user isn't looking at a wall.");
        which = [room.walls.indexOf(wall)];
      }
      const { texture, size } = await PolyHaven.wallTexture(asset);
      const count = room.setWallTexture(texture, size, which);
      context.wallsChanged(which ?? room.walls.map((_, i) => i), asset.id);
      return `Covered ${count === 1 ? "the wall" : `${count} walls`} with “${asset.name}” from Poly Haven.`;
    },

    async reset_walls() {
      const { room } = ready();
      room.setWallTexture(null);
      context.wallsChanged(room.walls.map((_, i) => i), null);
      return "The walls are back to their scanned look.";
    },

    async set_floor_texture(parameters) {
      const { room } = ready();
      const query = text(parameters, "query");
      const asset = query ? (await PolyHaven.floorTextures(query))[0] : undefined;
      if (!asset) throw new Error("Couldn't find a floor material like that.");
      const { texture, size } = await PolyHaven.wallTexture(asset);
      if (!room.setFloorTexture(texture, size)) throw new Error("No floor was found in the scan.");
      context.surfacesChanged({ floor: asset.id });
      return `Covered the floor with “${asset.name}” from Poly Haven.`;
    },

    async reset_floor() {
      const { room } = ready();
      room.setFloorTexture(null);
      context.surfacesChanged({ floor: null });
      return "The floor is back to its scanned look.";
    },

    async set_object_texture(parameters) {
      const { furniture } = ready();
      const piece = pieceNamed(furniture, text(parameters, "name"));
      const query = text(parameters, "query");
      const asset = query ? (await PolyHaven.materialTextures(query))[0] : undefined;
      if (!asset) throw new Error("Couldn't find a material like that.");
      const { texture } = await PolyHaven.wallTexture(asset);
      coverPiece(piece, texture, asset.id);
      furniture.onChange?.();
      return `Covered the ${piece.name} in “${asset.name}” from Poly Haven.`;
    },

    async resize_object(parameters) {
      const { furniture } = ready();
      const piece = pieceNamed(furniture, text(parameters, "name"));
      const height = number(parameters, "height_m");
      if (!height || height <= 0) throw new Error("Say how tall it should be.");
      const natural = piece.userData.box.max.y - piece.userData.box.min.y;
      // Growing against a wall or a neighbour: shift it clear, as the phone does.
      if (!furniture.tryChange(piece, () => piece.scale.setScalar(THREE.MathUtils.clamp(height / Math.max(natural, 1e-3), 0.05, 20)), 0.6)) {
        throw new Error(`There isn't room for the ${piece.name} at that size.`);
      }
      furniture.onChange?.();
      const size = sizeOf(piece);
      return `The ${piece.name} is now ${size.y.toFixed(2)} m tall and ${size.x.toFixed(2)} m wide.`;
    },

    async set_lighting(parameters) {
      ready();
      const lighting = { ...context.lighting() };
      const brightness = number(parameters, "brightness"), warmth = number(parameters, "warmth");
      if (brightness !== undefined) lighting.brightness = THREE.MathUtils.clamp(brightness, 0, 1);
      if (warmth !== undefined) lighting.warmth = THREE.MathUtils.clamp(warmth, 0, 1);
      context.applyLighting(lighting);
      context.surfacesChanged({ lighting });
      return `Lighting set to ${Math.round(lighting.brightness * 100)}% brightness, ${lighting.warmth > 0.6 ? "warm" : lighting.warmth < 0.4 ? "cool" : "neutral"} colour.`;
    },

    async set_enclosure(parameters) {
      const { room } = ready();
      const said: string[] = [];
      if (typeof parameters.ceiling === "boolean") {
        room.setCeiling(parameters.ceiling);
        context.surfacesChanged({ ceiling: parameters.ceiling });
        said.push(parameters.ceiling ? "added the ceiling" : "took the ceiling off");
      }
      if (typeof parameters.open_walls === "boolean") {
        const closed = room.setOpenSidesClosed(parameters.open_walls);
        context.surfacesChanged({ closedSides: parameters.open_walls });
        said.push(parameters.open_walls ? (closed ? `closed ${closed} open side${closed === 1 ? "" : "s"} with walls` : "found no open sides to close")
          : "took the added walls away");
      }
      if (!said.length) throw new Error("Say whether to add or remove the ceiling, or close the open walls.");
      return `Done: ${said.join(" and ")}.`;
    },
  };
}
