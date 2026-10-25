import { inSupabase, type SavedObject, type SavedRoomLayout } from "../account";
import type { App } from "../app";
import * as Library from "../models/library";
import * as PolyHaven from "../models/polyHaven";
import { fromPolyHaven, fromSketchfab } from "../models/search";
import * as Sketchfab from "../models/sketchfab";
import { $, busy, card, errorText, h, toast, toggle } from "./dom";
import { icon, type IconName } from "./icons";
import { openSettings } from "./settings";
import { openPhoto } from "./photo";

export type Tab = "rooms" | "add" | "walls" | "layout";

/** Asks for a file from this computer. */
function pickFile(accept: string, onFile: (file: File) => void) {
  pickFiles(accept, (files) => onFile(files[0]), false);
}

function pickFiles(accept: string, onFiles: (files: File[]) => void, multiple = true) {
  const input = $<HTMLInputElement>("#file-input");
  input.accept = accept;
  input.multiple = multiple;
  input.value = "";
  input.onchange = () => input.files?.length && onFiles([...input.files]);
  input.click();
}

/** A big button with a coloured icon, a label and a hint. */
function tile(label: string, hint: string, name: IconName, colours: string, onClick: (e: Event) => void, extra = "") {
  return h("button", { class: `tile ${extra}`, onclick: onClick },
    h("span", { class: `tile-icon ${colours}` }, icon(name, "size-4")),
    h("span", { class: "min-w-0 flex-1" }, h("span", { class: "block" }, label),
      h("span", { class: "block text-[11px] font-normal text-zinc-500" }, hint)));
}

/** A search box with a magnifier and a button inside it. */
function searchBox(input: HTMLInputElement, go: HTMLButtonElement) {
  input.classList.add("pl-9", "pr-20");
  go.classList.add("absolute", "top-1", "right-1", "bottom-1", "py-0", "text-xs");
  return h("div", { class: "relative" },
    h("span", { class: "pointer-events-none absolute top-1/2 left-3 -translate-y-1/2 text-zinc-500" }, icon("search")), input, go);
}

/** The sidebar's four panels. Each renders afresh when shown or when the app changes. */
export class Panels {
  tab: Tab = "rooms";
  private rooms?: SavedRoomLayout[] | string;
  private loadingRooms = false;
  private objects?: SavedObject[] | string;
  private thumbnails = new Map<string, string | null>();
  /** The Add panel's last search, kept across re-renders. */
  private search = { query: "", height: "0.9", results: null as HTMLElement | null };
  private wallSearch = { query: "", target: "walls" as "walls" | "wall" | "floor", results: null as HTMLElement | null };
  private dollhouse = true;

  constructor(private app: App, private container: HTMLElement) {
    app.subscribe(() => this.tab === "layout" && this.render());
  }

  show(tab: Tab) {
    this.tab = tab;
    this.render();
  }

  render() {
    const panel = { rooms: () => this.roomsPanel(), add: () => this.addPanel(), walls: () => this.wallsPanel(),
      layout: () => this.layoutPanel() }[this.tab]();
    panel.classList.add("animate-rise");
    this.container.replaceChildren(panel);
  }

  /** Forgets cached lists, as after logging in or out. */
  reset() {
    this.rooms = this.objects = undefined;
    this.render();
  }

  // Rooms

  private roomsPanel() {
    const { account } = this.app;
    const local = h("div", {},
      h("div", { class: "heading" }, "From this computer"),
      h("div", { class: "grid grid-cols-2 gap-2" },
        h("button", { class: "tile col-span-2 flex-row items-center", onclick: () => this.openFile() },
          h("span", { class: "tile-icon from-[#7c5cff] to-[#4f46e5]" }, icon("folder", "size-4")),
          h("span", { class: "min-w-0 flex-1" }, h("span", { class: "block" }, "Open files…"),
            h("span", { class: "block text-[11px] font-normal text-zinc-500" }, ".json + .edits.json + .usdz, or a .ply")),
          h("span", { class: "kbd" }, "or drop")),
        tile("Test room", "Scanned mesh", "box", "from-cyan-400 to-blue-600", (e) => this.openTestRoom(e.currentTarget as HTMLButtonElement)),
        tile("Test RoomPlan", "Editable furniture", "sofa", "from-fuchsia-500 to-rose-500",
          (e) => this.openTestRoomPlan(e.currentTarget as HTMLButtonElement))),
      h("p", { class: "note mt-3" },
        "From the iPhone's Export (AirDrop, Files or email): pick a Room Layout's .json, with its .edits.json and "
          + ".usdz to keep what was done on the phone, or a scan's .ply."));

    if (!account.isConfigured) {
      return h("div", {},
        this.hero("Connect your account",
          "To fetch rooms from the iPhone app's account, add the Supabase URL and anon key (in RoomTwin/supabase.json on the Mac).",
          h("button", { class: "btn btn-primary w-full", onclick: () => openSettings(this.app, () => this.reset()) }, icon("settings"), "Open Settings")),
        local);
    }
    if (!account.session) return h("div", {}, this.loginForm(), local);

    if (this.rooms === undefined) {
      this.rooms = [];
      this.loadingRooms = true;
      account.roomLayouts().then((rooms) => (this.rooms = rooms), (error) => (this.rooms = errorText(error)))
        .then(() => {
          this.loadingRooms = false;
          if (this.tab === "rooms") this.render();
        });
    }
    const list = typeof this.rooms === "string"
      ? h("p", { class: "rounded-xl border border-red-400/20 bg-red-500/10 p-3 text-sm text-red-200" }, this.rooms)
      : this.loadingRooms
        ? h("div", { class: "flex flex-col gap-2" }, [0, 1, 2].map(() =>
          h("div", { class: "h-16 animate-pulse rounded-2xl border border-white/[0.05] bg-white/[0.04]" })))
        : this.rooms.length
          ? h("div", { class: "flex flex-col gap-2" }, this.rooms.map((room) => this.roomRow(room)))
          : h("p", { class: "note" }, "No rooms yet. On the iPhone, finish a Room Layout scan and tap Save to Account; it shows up here.");
    return h("div", {},
      h("div", { class: "heading" },
        h("span", {}, `${account.session.username}'s rooms`),
        h("button", { class: "order-last flex items-center gap-1 text-[11px] tracking-normal text-[#a99cff] normal-case hover:text-white",
          onclick: () => this.reset() }, icon("refresh", "size-3"), "Refresh")),
      list, local);
  }

  /** A card that introduces a step, with a glowing icon. */
  private hero(title: string, text: string, ...actions: Node[]) {
    return h("div", { class: "relative mt-1 overflow-hidden rounded-2xl border border-white/[0.08] bg-gradient-to-br from-[#7c5cff]/20 via-transparent to-[#38bdf8]/10 p-4" },
      h("div", { class: "pointer-events-none absolute -top-10 -right-10 size-32 rounded-full bg-[#8b7bff]/30 blur-3xl" }),
      h("div", { class: "relative" },
        h("div", { class: "mb-3 flex size-10 items-center justify-center rounded-xl bg-gradient-to-br from-[#7c5cff] to-[#2563eb] shadow-[0_6px_20px_-4px_rgb(124_92_255/0.8)]" },
          icon("scan", "size-5 text-white")),
        h("div", { class: "font-display text-lg font-semibold tracking-tight" }, title),
        h("p", { class: "note mt-1 mb-4" }, text),
        ...actions));
  }

  private roomRow(room: SavedRoomLayout) {
    const date = new Date(room.created_at).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
    const stored = inSupabase(room);
    const current = this.app.viewer.room?.name === room.name;
    const open = h("button", { class: `btn shrink-0 px-3 py-1.5 text-xs ${stored ? "btn-primary" : ""}`,
      title: stored ? "" : "Its files aren't in the account" }, stored ? "Open" : "Why not?");
    open.onclick = () => this.app.attempt(() => busy(open, "Loading…", () => this.app.openRoomLayout(room)));
    return h("div", { class: `flex items-center gap-3 rounded-2xl border p-2.5 transition duration-300 ${current
      ? "border-[#8b7bff]/50 bg-[#8b7bff]/10 shadow-[0_0_30px_-10px_rgb(124_92_255/0.7)]"
      : "border-white/[0.07] bg-white/[0.03] hover:border-white/15 hover:bg-white/[0.06]"}` },
      h("div", { class: `flex size-11 shrink-0 items-center justify-center rounded-xl ${stored
        ? "bg-gradient-to-br from-[#7c5cff]/80 to-[#38bdf8]/70 text-white" : "bg-white/[0.06] text-zinc-500"}` },
        icon(stored ? "scan" : "alert", "size-5")),
      h("div", { class: "min-w-0 flex-1" },
        h("div", { class: "truncate text-sm font-medium" }, room.name),
        h("div", { class: "mt-0.5 flex flex-wrap items-center gap-x-2 text-[11px] text-zinc-500" },
          h("span", {}, date),
          room.edits_path ? h("span", { class: "text-[#a99cff]" }, "• edited") : "",
          stored ? "" : h("span", { class: "text-amber-300/80" }, "• in Google Drive"),
          current ? h("span", { class: "text-emerald-300" }, "• open") : "")),
      open);
  }

  private loginForm() {
    const username = h("input", { class: "field", placeholder: "Username", autocomplete: "username" });
    const password = h("input", { class: "field", type: "password", placeholder: "Password", autocomplete: "current-password" });
    const message = h("p", { class: "text-sm text-red-300 empty:hidden" });
    const submit = async (create: boolean, button: HTMLButtonElement) => {
      message.textContent = "";
      try {
        await busy(button, create ? "Creating…" : "Logging in…", () =>
          create ? this.app.account.signUp(username.value, password.value) : this.app.account.signIn(username.value, password.value));
        this.reset();
        // Straight into the account's room, as on startup.
        void this.app.attempt(() => this.app.openStartRoom());
      } catch (error) {
        message.textContent = errorText(error);
      }
    };
    const logIn = h("button", { class: "btn btn-primary", type: "submit" }, "Log in");
    const create = h("button", { class: "btn", type: "button" }, "Create account");
    create.onclick = () => submit(true, create);
    return h("form", {
      onsubmit: (event: Event) => {
        event.preventDefault();
        submit(false, logIn);
      },
    }, this.hero("Your scanned rooms",
      "Log in with the same username and password as the iPhone app. To open a friend's rooms, use the account they scanned with.",
      h("div", { class: "flex flex-col gap-2" }, username, password, message, h("div", { class: "grid grid-cols-2 gap-2" }, logIn, create))));
  }

  private openFile() {
    pickFiles(".ply,.json,.usdz", (files) => this.app.attempt(async () => {
      toast(`Opening ${files.map((file) => file.name).join(", ")}…`);
      await this.app.openRoomFiles(files);
    }));
  }

  private openTestRoom(button: HTMLButtonElement) {
    this.app.attempt(() => busy(button, "Loading…", async () => {
      const reply = await fetch("/test-room.ply");
      if (!reply.ok) throw new Error("No test room: run pnpm test-room first.");
      await this.app.openRoom(await reply.arrayBuffer(), "Test room", "test-room");
    }));
  }

  private openTestRoomPlan(button: HTMLButtonElement) {
    this.app.attempt(() => busy(button, "Loading…", async () => {
      const room = await (await fetch("/test-roomplan.json")).json();
      await this.app.openRoomPlan(room, "Test RoomPlan room", "test-roomplan");
    }));
  }

  // Adding furniture

  private addPanel() {
    const query = h("input", { class: "field", placeholder: "floor lamp, red velvet sofa…", value: this.search.query });
    const height = h("input", { class: "field w-20 text-center", type: "number", step: "0.05", min: "0.05", value: this.search.height,
      title: "Height in metres, for scaling Sketchfab models" });
    const results = this.search.results ?? h("div");
    const go = h("button", { class: "btn btn-primary", type: "submit" }, "Search");
    const form = h("form", {
      class: "flex flex-col gap-2",
      onsubmit: (event: Event) => {
        event.preventDefault();
        this.search.query = query.value;
        this.search.height = height.value;
        this.app.attempt(() => busy(go, "…", () => this.runSearch(query.value, Number(height.value) || 0.9, results)));
      },
    },
    h("div", { class: "heading" }, "Search Poly Haven and Sketchfab"),
    h("div", { class: "flex gap-2" }, h("div", { class: "flex-1" }, searchBox(query, go)),
      h("label", { class: "relative" }, height,
        h("span", { class: "pointer-events-none absolute top-1/2 right-2 -translate-y-1/2 text-[10px] text-zinc-500" }, "m"))));
    this.search.results = results;

    const library = h("div", { class: "grid grid-cols-3 gap-2" }, Library.items.map((item) =>
      card(item.name, item.icon, () => this.app.attempt(async () =>
        this.app.place({ model: await Library.model(item.id), source: "library", origin: { kind: "library", id: item.id } })))));

    const photo = h("button", {
      class: "group relative w-full overflow-hidden rounded-2xl p-px text-left transition hover:-translate-y-0.5",
      onclick: () => this.app.attempt(() => openPhoto(this.app)),
    },
    h("span", { class: "absolute inset-0 animate-shine bg-[linear-gradient(110deg,#7c5cff,#38bdf8,#ec4899,#7c5cff)] bg-[length:200%_auto]" }),
    h("span", { class: "relative flex items-center gap-3 rounded-[15px] bg-[#0d0d16]/95 p-3" },
      h("span", { class: "tile-icon size-10 from-amber-400 to-pink-500" }, icon("wand", "size-5")),
      h("span", { class: "min-w-0 flex-1" },
        h("span", { class: "block text-sm font-semibold text-white" }, "Make an object from a photo…"),
        h("span", { class: "block text-[11px] text-zinc-400" }, "SAM 3D builds the whole thing from one picture")),
      icon("sparkles", "text-amber-300 transition group-hover:rotate-12")));

    return h("div", {},
      form, results,
      h("div", { class: "heading" }, "AI from a photo"), photo,
      h("div", { class: "heading" }, "Library"), library,
      this.myObjects(),
      h("div", { class: "heading" }, "From this computer"),
      tile("Add a model file…", "GLB, glTF, USDZ, OBJ or PLY", "upload", "from-emerald-400 to-teal-600",
        () => pickFile(".glb,.gltf,.usdz,.usdc,.usda,.obj,.ply", (file) => this.app.attempt(() => this.app.placeFile(file))),
        "w-full flex-row items-center"),
      h("p", { class: "note mt-3" },
        "New pieces land where you look (Walk), or in the middle of the room (Orbit). Drag them to move."));
  }

  private async runSearch(query: string, height: number, into: HTMLElement) {
    if (!query.trim()) return;
    into.replaceChildren(h("div", { class: "mt-3 grid grid-cols-3 gap-2" }, Array.from({ length: 6 }, () =>
      h("div", { class: "aspect-[3/4] animate-pulse rounded-xl bg-white/[0.05]" }))));
    const [polyHaven, sketchfab] = await Promise.all([
      PolyHaven.models(query).catch(() => []),
      Sketchfab.models(query).catch(() => []),
    ]);
    const add = (work: () => Promise<Parameters<App["place"]>[0]>) => () => this.app.attempt(async () => {
      toast("Downloading…");
      this.app.place(await work());
    });
    into.replaceChildren(
      h("div", { class: "heading" }, `Poly Haven · ${polyHaven.length}`),
      polyHaven.length
        ? h("div", { class: "grid grid-cols-3 gap-2" }, polyHaven.slice(0, 18).map((asset) => {
          const h_ = PolyHaven.assetHeight(asset);
          return card(asset.name, PolyHaven.thumbnail(asset), add(() => fromPolyHaven(asset)), h_ ? `${h_.toFixed(2)} m` : "CC0");
        }))
        : h("p", { class: "note" }, "Nothing close."),
      h("div", { class: "heading" }, `Sketchfab · ${sketchfab.length}`),
      !Sketchfab.hasToken()
        ? h("p", { class: "note mb-2" }, "Add a Sketchfab API token in Settings to download these.")
        : "",
      h("div", { class: "grid grid-cols-3 gap-2" }, sketchfab.slice(0, 18).map((model) =>
        card(model.name, model.thumbnail ?? null, add(() => fromSketchfab(model, height)), model.author))),
    );
  }

  private myObjects() {
    const { account } = this.app;
    if (!account.session) return null;
    if (this.objects === undefined) {
      this.objects = [];
      account.objects().then((objects) => (this.objects = objects), (error) => (this.objects = errorText(error)))
        .then(() => this.tab === "add" && this.render());
    }
    const objects = this.objects;
    return h("div", {},
      h("div", { class: "heading" }, "My Objects"),
      typeof objects === "string" ? h("p", { class: "text-sm text-red-300" }, objects)
        : !objects.length ? h("p", { class: "note" }, "Objects saved from Photo or Walk Around on the iPhone show up here.")
          : h("div", { class: "grid grid-cols-3 gap-2" }, objects.map((object) => {
            const thumb = this.thumbnails.get(object.id) ?? null;
            if (!this.thumbnails.has(object.id)) {
              this.thumbnails.set(object.id, null);
              account.thumbnail(object).then((url) => {
                this.thumbnails.set(object.id, url);
                if (url && this.tab === "add") this.render();
              });
            }
            return card(object.name, thumb ?? "🧸", () => this.app.attempt(async () => {
              toast(`Fetching ${object.name}…`);
              this.app.place(await this.app.savedModel(object));
            }), object.created_at.slice(0, 10));
          })));
  }

  // Walls

  private wallsPanel() {
    const room = this.app.viewer.room;
    const target = this.wallSearch.target;
    const query = h("input", { class: "field", value: this.wallSearch.query,
      placeholder: target === "floor" ? "oak boards, white marble…" : "red brick, white plaster…" });
    const targets: [typeof target, string, IconName][] = [["walls", "All walls", "layers"], ["wall", "Wall in view", "scan"], ["floor", "Floor", "box"]];
    const choose = h("div", { class: "segmented text-xs" }, targets.map(([value, label, name]) =>
      h("button", {
        type: "button", class: "seg flex-1 px-2", "aria-pressed": String(value === target),
        onclick: () => {
          this.wallSearch.target = value;
          this.wallSearch.results = null;
          this.render();
        },
      }, icon(name, "size-3.5"), label)));
    const results = this.wallSearch.results ?? h("div");
    this.wallSearch.results = results;
    const go = h("button", { class: "btn btn-primary", type: "submit" }, "Search");
    const apply = (asset: PolyHaven.Asset) => this.app.attempt(() =>
      target === "floor" ? this.app.floorTexture(asset) : this.app.texture(asset, target === "wall"));
    const search = async () => {
      results.replaceChildren(h("div", { class: "mt-3 grid grid-cols-3 gap-2" }, Array.from({ length: 6 }, () =>
        h("div", { class: "aspect-[3/4] animate-pulse rounded-xl bg-white/[0.05]" }))));
      const textures = target === "floor" ? await PolyHaven.floorTextures(query.value) : await PolyHaven.wallTextures(query.value);
      results.replaceChildren(textures.length
        ? h("div", { class: "mt-3 grid grid-cols-3 gap-2" }, textures.slice(0, 24).map((asset) =>
          card(asset.name, PolyHaven.thumbnail(asset), () => apply(asset))))
        : h("p", { class: "note mt-3" }, "Nothing close."));
    };
    return h("div", {},
      h("div", { class: "heading" }, "Wall and floor textures"),
      h("div", { class: "mb-3 flex items-center gap-2 text-xs text-zinc-400" },
        h("span", { class: `size-1.5 rounded-full ${room ? "bg-emerald-400" : "bg-zinc-600"}` }),
        room ? `${room.walls.length} wall${room.walls.length === 1 ? "" : "s"} found in this room` : "Open a room first"),
      h("form", {
        class: "flex flex-col gap-2",
        onsubmit: (event: Event) => {
          event.preventDefault();
          this.wallSearch.query = query.value;
          this.app.attempt(() => busy(go, "…", search));
        },
      }, choose, searchBox(query, go)),
      results,
      h("div", { class: "mt-4 grid grid-cols-2 gap-2" },
        h("button", { class: "btn", onclick: () => this.app.resetWalls() }, icon("refresh"), "Reset walls"),
        h("button", { class: "btn", onclick: () => this.app.attempt(() => this.app.floorTexture(null)) }, icon("refresh"), "Reset floor")),
      h("p", { class: "note mt-3" }, "Free CC0 textures from Poly Haven, scaled to real size."));
  }

  // Layout and view settings

  private layoutPanel() {
    const { viewer, editor, layout } = this.app;
    const pieces = viewer.furniture?.pieces ?? [];
    const speed = h("input", { type: "range", min: "0.5", max: "4", step: "0.1", value: String(viewer.walkSpeed), class: "w-full",
      oninput: () => (viewer.walkSpeed = Number(speed.value)) });
    return h("div", {},
      h("div", { class: "heading" }, `Furniture · ${pieces.length}`),
      pieces.length
        ? h("div", { class: "flex flex-col gap-0.5 rounded-2xl border border-white/[0.06] bg-black/20 p-1" }, pieces.map((piece) =>
          h("button", {
            class: `flex items-center gap-2.5 rounded-xl px-2.5 py-2 text-left text-sm transition ${editor.selected === piece
              ? "bg-gradient-to-r from-[#7c5cff]/30 to-transparent text-white" : "text-zinc-300 hover:bg-white/[0.06]"}`,
            onclick: () => editor.select(piece),
          }, h("span", { class: `flex size-6 items-center justify-center rounded-lg ${editor.selected === piece ? "bg-[#8b7bff] text-white" : "bg-white/[0.06] text-zinc-400"}` },
            icon(piece.userData.origin.kind === "scan" ? "scan" : "armchair", "size-3.5")),
          h("span", { class: "truncate" }, piece.name))))
        : h("p", { class: "note" }, "Nothing added yet."),
      h("div", { class: "mt-3 grid grid-cols-2 gap-2" },
        h("button", { class: "btn", onclick: () => this.exportLayout() }, icon("download"), "Save as file"),
        h("button", {
          class: "btn btn-danger",
          onclick: () => confirm("Remove all furniture and textures from this room?") && (viewer.furniture?.clear(), this.app.resetWalls(), editor.select(null)),
        }, icon("trash"), "Clear room")),
      h("p", { class: "note mt-2" }, layout
        ? "Changes are kept in this browser and come back when you reopen the room." : ""),
      h("div", { class: "heading" }, "Room"),
      this.roomControls(),
      h("div", { class: "heading" }, "View"),
      h("div", { class: "flex flex-col" },
        toggle("Dollhouse", this.dollhouse, (on) => {
          this.dollhouse = on;
          viewer.room?.setDollhouse(on);
        }, "Hide walls facing away"),
        toggle("Walk through walls and furniture", viewer.ghost, (on) => (viewer.ghost = on)),
        toggle("Furniture collides with walls and other furniture", viewer.collisions, (on) => (viewer.collisions = on)),
        toggle("Snap furniture to walls and onto what's below when let go", editor.snapping, (on) => (editor.snapping = on)),
        h("label", { class: "label mt-3" }, "Walking speed"), speed));
  }

  /** Lighting, and a ceiling or walls where the scan has none. */
  private roomControls() {
    const app = this.app;
    if (!app.layout) return h("p", { class: "note" }, "Open a room first.");
    const slider = (label: string, key: "brightness" | "warmth", left: string, right: string) => {
      const input = h("input", {
        type: "range", min: "0", max: "1", step: "0.05", value: String(app.lighting[key]), class: "w-full",
        oninput: () => app.setLighting({ ...app.lighting, [key]: Number(input.value) }),
      });
      return h("label", { class: "block" }, h("span", { class: "label" }, label), input,
        h("div", { class: "flex justify-between text-[10px] text-zinc-500" }, h("span", {}, left), h("span", {}, right)));
    };
    const { surfaces } = app.layout;
    return h("div", { class: "flex flex-col gap-3" },
      slider("Brightness", "brightness", "Dim", "Bright"),
      slider("Colour", "warmth", "Cool daylight", "Warm"),
      h("div", { class: "flex flex-col" },
        toggle("Ceiling", surfaces.ceiling ?? true, (on) => app.setCeiling(on)),
        toggle("Close the room's open sides", surfaces.closedSides, (on) => app.setClosedSides(on))));
  }

  private exportLayout() {
    const layout = this.app.layout;
    if (!layout) return toast("Open a room first.");
    const blob = new Blob([JSON.stringify(layout.toJSON(), null, 2)], { type: "application/json" });
    const link = h("a", { href: URL.createObjectURL(blob), download: `${this.app.viewer.room?.name ?? "room"}-layout.json` });
    link.click();
    URL.revokeObjectURL(link.href);
  }
}
