import { Account } from "./account";
import { asFurniture, parseModel } from "./models/loader";
import * as PolyHaven from "./models/polyHaven";
import type { Found } from "./models/search";
import { Room } from "./room/room";
import { buildRoomPlan, type CapturedRoom } from "./room/roomPlan";
import { addScannedPieces, applyPhoneEdits, type RoomEditMetadata } from "./scene/phoneEdits";
import type * as THREE from "three";
import { USDLoader } from "three/examples/jsm/loaders/USDLoader.js";
import { inSupabase, type SavedObject, type SavedRoomLayout } from "./account";
import { Editor } from "./scene/editor";
import { coverPiece, type Piece } from "./scene/furniture";
import { Layout } from "./scene/layout";
import { applyLighting, defaultLighting, type Lighting } from "./scene/lighting";
import { Viewer } from "./scene/viewer";
import { errorText, toast } from "./ui/dom";
import { VoiceAgent } from "./voice/agent";
import { voiceTools } from "./voice/tools";
import { VR } from "./vr/vr";

/**
 * Everything the UI works with: the account, the 3D view and its editor,
 * VR, the voice agent, and the open room's layout.
 */
export class App {
  readonly account = new Account();
  readonly viewer: Viewer;
  readonly editor: Editor;
  readonly vr: VR;
  readonly voice: VoiceAgent;
  layout?: Layout;
  /** Credits for added models whose licences need one (Sketchfab's CC BY). */
  readonly credits = new Set<string>();
  private listeners: (() => void)[] = [];

  constructor(stage: HTMLElement) {
    this.viewer = new Viewer(stage);
    this.editor = new Editor(this.viewer);
    this.editor.onRefuse = (message) => toast(message, "error");
    this.voice = new VoiceAgent(voiceTools({
      room: () => this.viewer.room,
      furniture: () => this.viewer.furniture,
      added: (piece, found) => {
        if (found.credit) this.credits.add(found.credit);
        this.editor.select(piece);
        this.changed();
      },
      wallsChanged: (indices, id) => this.layout?.setWalls(indices, id),
      surfacesChanged: (change) => {
        this.layout?.update(change);
        this.changed();
      },
      lighting: () => this.lighting,
      applyLighting: (lighting) => applyLighting(this.viewer, lighting),
      savedObjects: () => {
        if (!this.account.session) throw new Error("Nobody is logged in, so there are no saved objects. Log in on the Rooms tab.");
        return this.account.objects();
      },
      savedModel: (object) => this.savedModel(object),
    }));
    this.voice.onError = (message) => toast(message, "error");
    this.voice.describeRoom = () => {
      const furniture = this.viewer.furniture;
      if (!furniture) return "No room is open yet.";
      const names = furniture.names;
      const inventory = names.length
        ? "Whole-room editable names, for resolving edit targets only (do not claim all are visible): "
          + names.slice(-40).join(", ") + "."
        : "The room has no editable objects right now.";
      return `${furniture.describeView()}
${inventory}`;
    };
    this.vr = new VR(this.viewer, {
      talk: () => void this.voice.toggle(),
      moved: (piece, before) => this.editor.undo.moved(piece, before),
      isTalking: () => this.voice.isOn,
      caption: () => this.voice.caption,
      status: () => this.viewer.room
        ? `${this.viewer.room.name} · ${this.viewer.furniture?.pieces.length ?? 0} pieces${this.voice.isOn ? ` · voice: ${this.voice.status}` : ""}`
        : "No room open",
    });
    this.account.onChange = () => this.changed();
  }

  /** Calls `listener` whenever the room, the account or the furniture changes. */
  subscribe(listener: () => void) {
    this.listeners.push(listener);
  }

  changed() {
    for (const listener of this.listeners) listener();
  }

  /**
   * Opens a room from its PLY, and puts back what was done to it on this
   * computer before. `key` identifies the room across visits.
   */
  async openRoom(data: ArrayBuffer, name: string, key: string) {
    // Let the busy label paint before the heavy work.
    await new Promise((resolve) => setTimeout(resolve, 30));
    await this.show(Room.fromPLY(data, name), key);
  }

  /**
   * Opens a RoomPlan room from its JSON, as the phone opens a saved room
   * layout: rebuilt as scanned with every piece editable, then the phone's
   * saved edits (`edits`, with the USDZ `saved` beside them holding the
   * models added on the phone), then what was done to it on this computer.
   */
  async openRoomPlan(json: CapturedRoom, name: string, key: string, edits?: RoomEditMetadata, saved?: THREE.Object3D) {
    await new Promise((resolve) => setTimeout(resolve, 30));
    const { shell, pieces } = await buildRoomPlan(json);
    if (!shell.getAttribute("position").count) throw new Error("That RoomPlan file has no walls or floor in it.");
    const room = new Room(shell, name);
    await this.show(room, key, async () => {
      const furniture = this.viewer.furniture!;
      addScannedPieces(furniture, pieces);
      if (!edits) return 0;
      return applyPhoneEdits({
        room, furniture,
        applyLighting: (lighting) => applyLighting(this.viewer, lighting),
        record: (change) => this.layout?.update(change),
        setWalls: (indices, id) => this.layout?.setWalls(indices, id),
      }, edits, saved, !this.layout?.isSaved);
    });
  }

  /**
   * Opens a room layout saved to the account from the phone. Its RoomPlan
   * JSON rebuilds it with every piece editable; without one, the PLY opens.
   */
  async openRoomLayout(layout: SavedRoomLayout) {
    if (!inSupabase(layout)) {
      throw new Error(`${layout.name} was saved to the phone's Google Drive, so its files aren't in the account. `
        + "Export it from the phone (View › Export) and open the files here instead.");
    }
    const file = (path: string) => this.account.file("room-layouts", path);
    const key = `layout:${layout.id}`;
    let json: CapturedRoom | undefined;
    try {
      json = JSON.parse(new TextDecoder().decode(await file(layout.json_path)));
    } catch {
      // Opens from the PLY below.
    }
    if (!json) return this.openRoom(await file(layout.ply_path), layout.name, key);
    const [edits, saved] = await Promise.all([
      layout.edits_path ? file(layout.edits_path).then((data) => JSON.parse(new TextDecoder().decode(data))).catch(() => undefined)
        : undefined,
      file(layout.model_path).then(parseUSDZ).catch(() => undefined),
    ]);
    await this.openRoomPlan(json, layout.name, key, edits, saved);
    remember(lastRoomKey, layout.id);
  }

  /**
   * Opens a room from the account without being asked, when the app starts
   * or someone logs in: the one open last time if it's still there, else the
   * newest whose files are in Supabase. Returns whether one opened; nothing
   * happens if nobody is logged in, a room is open already, or there's none.
   */
  async openStartRoom(): Promise<boolean> {
    if (!this.account.session || this.viewer.room) return false;
    const layouts = (await this.account.roomLayouts()).filter(inSupabase);
    let last: string | null = null;
    try {
      last = localStorage.getItem(lastRoomKey);
    } catch {
      // Storage blocked: the newest opens.
    }
    const layout = layouts.find((l) => l.id === last) ?? layouts[0];
    if (!layout || this.viewer.room) return false;
    toast(`Opening ${layout.name}…`);
    await this.openRoomLayout(layout);
    return true;
  }

  /**
   * Opens a room from files exported from the phone: RoomPlan's .json (with
   * the .edits.json and .usdz beside it, if they're there too), or a .ply.
   */
  async openRoomFiles(files: File[]) {
    const named = (test: (name: string) => boolean) => files.find((file) => test(file.name.toLowerCase()));
    const edits = named((n) => n.endsWith(".edits.json") || n === "room-edits.json");
    const json = named((n) => n.endsWith(".json") && !n.endsWith(".edits.json") && n !== "room-edits.json"
      && !n.endsWith(".sam.json"));
    const ply = named((n) => n.endsWith(".ply"));
    const usdz = named((n) => n.endsWith(".usdz"));
    // A Hybrid or SAM scan's .roomplan.json only describes its detailed mesh: open the mesh.
    const roomPlan = json && !(ply && json.name.toLowerCase().endsWith(".roomplan.json")) ? json : undefined;
    const main = roomPlan ?? ply;
    if (!main) throw new Error("Choose a room's .json (RoomPlan) or .ply.");
    const name = main.name.replace(/(\.roomplan)?\.(json|ply)$/i, "");
    const key = `file:${main.name}:${main.size}`;
    if (!roomPlan) return this.openRoom(await main.arrayBuffer(), name, key);
    await this.openRoomPlan(JSON.parse(await roomPlan.text()), name, key,
      edits ? JSON.parse(await edits.text()) : undefined,
      usdz ? await parseUSDZ(await usdz.arrayBuffer()).catch(() => undefined) : undefined);
  }

  /** Shows a room, runs `setup` (which says how many things failed), then puts back this computer's layout. */
  private async show(room: Room, key: string, setup?: () => Promise<number>) {
    this.layout?.save();
    this.editor.select(null);
    this.editor.undo.clear();
    this.credits.clear();
    this.viewer.setRoom(room);
    applyLighting(this.viewer, defaultLighting);
    const furniture = this.viewer.furniture!;
    this.layout = new Layout(key, room, furniture, (lighting) => applyLighting(this.viewer, lighting));
    const onChange = furniture.onChange;
    furniture.onChange = undefined;
    let failed = (await setup?.()) ?? 0;
    furniture.onChange = onChange;
    this.changed();
    failed += await this.layout.restore(this.account);
    for (const piece of furniture.pieces) if (piece.userData.credit) this.credits.add(piece.userData.credit);
    this.changed();
    const found = room.walls.length, editable = furniture.pieces.length;
    toast(`Opened ${room.name}: ${found} wall${found === 1 ? "" : "s"} found`
      + (editable ? `, ${editable} piece${editable === 1 ? "" : "s"} of furniture you can edit.` : `, ${room.triangles.toLocaleString()} triangles.`)
      + (failed ? ` ${failed} saved change${failed === 1 ? "" : "s"} couldn't be put back.` : ""));
  }

  /** Stands a found model where the view points (in the middle of the room when orbiting). */
  place(found: Found) {
    const furniture = this.viewer.furniture;
    if (!furniture) throw new Error("Open a room first.");
    const { piece, words } = furniture.place(found.model, { origin: found.origin, credit: found.credit });
    if (found.credit) this.credits.add(found.credit);
    this.editor.select(piece);
    this.changed();
    toast(`Added ${piece.name} ${words}.`);
  }

  /** One of the account's My Objects, as furniture. */
  async savedModel(object: SavedObject): Promise<Found> {
    const model = asFurniture(await parseModel(await this.account.file("objects", object.model_path), object.model_path));
    model.name = object.name;
    return { model, source: "your account", origin: { kind: "account", id: object.id, path: object.model_path } };
  }

  /** Adds a model file from this computer. */
  async placeFile(file: File) {
    const model = asFurniture(await parseModel(await file.arrayBuffer(), file.name));
    model.name = file.name.replace(/\.[^.]+$/, "");
    this.place({ model, source: "this computer", origin: { kind: "file", filename: file.name } });
  }

  /** Covers walls with a Poly Haven texture: all of them, or the one in view. */
  async texture(asset: PolyHaven.Asset, inView: boolean) {
    const room = this.viewer.room, furniture = this.viewer.furniture;
    if (!room || !furniture) throw new Error("Open a room first.");
    if (!room.walls.length) throw new Error("No walls were found in this scan.");
    let which: number[] | undefined;
    if (inView) {
      const wall = furniture.wallInView();
      if (!wall) throw new Error("Look at a wall first (Walk mode helps).");
      which = [room.walls.indexOf(wall)];
    }
    const { texture, size } = await PolyHaven.wallTexture(asset);
    const count = room.setWallTexture(texture, size, which);
    this.layout?.setWalls(which ?? room.walls.map((_, i) => i), asset.id);
    toast(`Covered ${count === 1 ? "the wall" : `${count} walls`} with ${asset.name}.`);
  }

  /** Covers the floor with a Poly Haven texture, or puts the scanned floor back (null). */
  async floorTexture(asset: PolyHaven.Asset | null) {
    const room = this.viewer.room;
    if (!room) throw new Error("Open a room first.");
    if (!asset) {
      room.setFloorTexture(null);
      this.layout?.update({ floor: null });
      return;
    }
    const { texture, size } = await PolyHaven.wallTexture(asset);
    if (!room.setFloorTexture(texture, size)) throw new Error("No floor was found in this scan.");
    this.layout?.update({ floor: asset.id });
    toast(`Covered the floor with ${asset.name}.`);
  }

  get lighting(): Lighting {
    return this.layout?.surfaces.lighting ?? defaultLighting;
  }

  setLighting(lighting: Lighting) {
    applyLighting(this.viewer, lighting);
    this.layout?.update({ lighting });
  }

  setCeiling(on: boolean) {
    this.viewer.room?.setCeiling(on);
    this.layout?.update({ ceiling: on });
  }

  setClosedSides(on: boolean) {
    const count = this.viewer.room?.setOpenSidesClosed(on) ?? 0;
    this.layout?.update({ closedSides: on });
    if (on) toast(count ? `Closed ${count} open side${count === 1 ? "" : "s"}.` : "No open sides to close.");
  }

  /** Covers a piece in the Poly Haven material that best matches `query`, like "red velvet". */
  async material(piece: Piece, query: string) {
    const asset = (await PolyHaven.materialTextures(query))[0];
    if (!asset) throw new Error(`Couldn't find a material like ${query}.`);
    const { texture } = await PolyHaven.wallTexture(asset);
    coverPiece(piece, texture, asset.id);
    this.viewer.furniture?.onChange?.();
    toast(`Covered the ${piece.name} in ${asset.name}.`);
  }

  resetWalls() {
    const room = this.viewer.room;
    if (!room) return;
    room.setWallTexture(null);
    this.layout?.setWalls(room.walls.map((_, i) => i), null);
  }

  /** Runs an action from the UI, reporting failures. */
  async attempt(work: () => Promise<unknown> | unknown) {
    try {
      await work();
    } catch (error) {
      console.error(error);
      toast(errorText(error), "error");
    }
  }
}

const lastRoomKey = "roomtwin-last-room";

function remember(key: string, value: string) {
  try {
    localStorage.setItem(key, value);
  } catch {
    // Storage blocked: the newest room opens next time.
  }
}

/** A USDZ the phone saved, as a scene (to take the models added on the phone from). */
async function parseUSDZ(data: ArrayBuffer): Promise<THREE.Object3D> {
  return new USDLoader().parse(data);
}
