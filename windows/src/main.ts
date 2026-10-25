import "./style.css";
import { App } from "./app";
import * as PolyHaven from "./models/polyHaven";
import { $, busy, h } from "./ui/dom";
import { fillIcons, icon, type IconName } from "./ui/icons";
import * as THREE from "three";
import { renderInspector } from "./ui/inspector";
import { Panels, type Tab } from "./ui/panels";
import { openSettings } from "./ui/settings";
import { openHistory } from "./ui/history";
import { Hands } from "./scene/hands";
import { VR } from "./vr/vr";

/**
 * RoomTwin on Windows. Opens rooms scanned with the iPhone app (from the
 * account, or a PLY file), furnishes them with the mouse or by voice, and
 * tours them in a VR headset through SteamVR.
 *
 * ?emulate in the address installs a pretend headset (IWER), to try the VR
 * mode without one.
 */
async function main() {
  if (new URLSearchParams(location.search).has("emulate")) {
    const { XRDevice, metaQuest3 } = await import("iwer");
    const device = new XRDevice(metaQuest3);
    device.installRuntime({ forceInstall: true });
    Object.assign(window, { xrDevice: device });
  }

  fillIcons();
  const app = new App($("#stage"));
  const panels = new Panels(app, $("#panel"));
  const { viewer, editor, voice, vr } = app;

  // Tabs
  const tabs = [...document.querySelectorAll<HTMLButtonElement>("#tabs [data-tab]")];
  const showTab = (tab: Tab) => {
    for (const button of tabs) button.setAttribute("aria-selected", String(button.dataset.tab === tab));
    panels.show(tab);
  };
  for (const button of tabs) button.onclick = () => showTab(button.dataset.tab as Tab);
  showTab("rooms");

  // The sidebar floats over the view: centre the room in what's left.
  const sidebar = $("aside");
  new ResizeObserver(() => viewer.setInset(sidebar.offsetParent ? sidebar.getBoundingClientRect().right : 0)).observe(document.body);

  // Orbit / Walk
  const modeButtons = [...document.querySelectorAll<HTMLButtonElement>("#mode [data-mode]")];
  const help = $("#help");
  viewer.onModeChange = (mode) => {
    for (const button of modeButtons) button.setAttribute("aria-pressed", String(button.dataset.mode === mode));
    const hints: [string, string][] = viewer.inVR ? [["WASD", "walk"], ["Q E", "turn"]]
      : mode === "orbit" ? [["Drag", "orbit"], ["Scroll", "zoom"], ["Right-drag", "pan"], ["Tab", "walk"]]
        : [["WASD", "walk"], ["Drag", "look"], ["Q E", "turn"], ["Shift", "run"], ["Tab", "orbit"]];
    help.replaceChildren(...hints.map(([keys, what]) => h("span", { class: "flex items-center gap-1" },
      ...keys.split(" ").map((key) => h("span", { class: "kbd" }, key)), what)));
  };
  for (const button of modeButtons) button.onclick = () => viewer.setMode(button.dataset.mode as "orbit" | "walk");
  viewer.setMode("orbit");
  addEventListener("keydown", (event) => {
    if ((event.target as HTMLElement).closest("input, textarea") || !viewer.room || viewer.inVR) return;
    if (event.code === "Tab") {
      event.preventDefault();
      viewer.setMode(viewer.mode === "orbit" ? "walk" : "orbit");
    }
  });

  // Voice
  const talk = $<HTMLButtonElement>("#talk");
  const caption = $("#caption");
  talk.onclick = () => voice.toggle();
  voice.onUpdate = () => {
    const labels = { off: "Talk to your room", connecting: "Connecting…", listening: "Listening…", speaking: "Speaking" };
    const live = voice.status === "listening" || voice.status === "speaking";
    talk.dataset.state = voice.status;
    talk.querySelector(".talk-label")!.textContent = labels[voice.status];
    talk.querySelector(".talk-rings")!.classList.toggle("hidden", !live);
    talk.querySelector(".talk-orb")!.replaceChildren(voice.status === "speaking"
      ? h("span", { class: "bars flex h-4 items-center gap-[3px]" }, [0, 0.15, 0.3, 0.45].map((delay) =>
        h("span", { class: "h-4", style: `animation-delay:${delay}s` })))
      : icon(voice.status === "connecting" ? "spinner" : "mic", `size-5 ${voice.status === "connecting" ? "animate-spin" : ""}`));
    caption.textContent = voice.caption;
    caption.classList.toggle("hidden", !voice.isOn || !voice.caption);
  };
  voice.onUpdate();

  // VR
  const vrButton = $<HTMLButtonElement>("#vr");
  const vrDebug = $("#vr-debug");
  VR.isSupported().then((supported) => {
    vrButton.disabled = !supported;
    vrButton.title = supported ? "Put the headset on after clicking" : "No headset found: start SteamVR, then reload this page in Chrome or Edge.";
  });
  vrButton.onclick = () => app.attempt(async () => {
    if (viewer.inVR) return vr.exit();
    if (!viewer.room) throw new Error("Open a room first.");
    await vr.enter();
  });
  vr.onSessionChange = (inVR) => {
    vrButton.replaceChildren(icon(inVR ? "close" : "vr", "size-5"), inVR ? "Exit VR" : "Enter VR");
    viewer.scene.background = inVR ? new THREE.Color(0x141416) : null;
    vrDebug.classList.toggle("hidden", !inVR);
    viewer.onModeChange?.(viewer.mode);
  };
  vr.onDebug = (lines) => (vrDebug.textContent = ["Controllers (for setting up buttons):", ...lines].join("\n"));
  vrDebug.style.whiteSpace = "pre";

  // Account
  const user = $<HTMLButtonElement>("#user");
  const showUser = () => {
    const session = app.account.session;
    user.classList.toggle("hidden", !session);
    user.replaceChildren(...session ? [h("span", { class: "flex size-6 items-center justify-center rounded-full bg-gradient-to-br from-fuchsia-500 to-[#7c5cff] text-[11px] font-bold text-white uppercase" },
      session.username.slice(0, 1)), h("span", { class: "max-w-24 truncate" }, session.username)] : []);
    user.title = "Log out";
  };
  user.onclick = () => {
    if (confirm(`Log out ${app.account.session?.username}?`)) {
      app.account.signOut();
      panels.reset();
    }
  };
  $("#settings").onclick = () => openSettings(app, () => panels.reset());
  $("#history").onclick = () => openHistory(voice);
  const hands = new Hands(app.viewer, app.editor, $("#hand-preview"));
  const handsButton = $<HTMLButtonElement>("#hands");
  hands.onChange = () => handsButton.classList.toggle("btn-primary", hands.isOn);
  Object.assign(window, { roomtwinHands: hands });
  handsButton.onclick = () => app.attempt(() => busy(handsButton, "Starting…", () => hands.toggle()));
  const undo = $<HTMLButtonElement>("#undo"), redo = $<HTMLButtonElement>("#redo");
  undo.onclick = () => app.editor.undoLast();
  redo.onclick = () => app.editor.redoLast();
  app.editor.undo.onChange = () => {
    undo.disabled = !app.editor.undo.canUndo;
    redo.disabled = !app.editor.undo.canRedo;
  };

  // Selection, room name, credits
  editor.onSelect = (piece) => {
    renderInspector(app, $("#inspector"), piece);
    showStats();
    if (panels.tab === "layout") panels.render();
  };
  const credits = $("#credits");
  const stats = $("#stats");
  const showStats = () => {
    const room = viewer.room;
    stats.classList.toggle("hidden", !room);
    stats.classList.toggle("flex", Boolean(room));
    if (!room) return;
    const pieces = viewer.furniture?.pieces.length ?? 0;
    const chip = (name: IconName, value: string | number, label: string) =>
      h("div", { class: "chip animate-rise" }, icon(name, "size-3.5 text-[#a99cff]"),
        h("span", { class: "font-semibold text-white tabular-nums" }, String(value)), label);
    stats.replaceChildren(chip("layers", room.walls.length, room.walls.length === 1 ? "wall" : "walls"),
      chip("armchair", pieces, pieces === 1 ? "piece" : "pieces"));
  };
  app.subscribe(() => {
    showUser();
    $("#room-name").textContent = viewer.room?.name ?? "No room open";
    $("#room-dot").className = `size-1.5 rounded-full ${viewer.room ? "bg-emerald-400 shadow-[0_0_8px_rgb(52_211_153)]" : "bg-zinc-600"}`;
    showStats();
    $("#empty").classList.toggle("hidden", Boolean(viewer.room));
    // Poly Haven's terms ask for this wherever its content shows; CC BY asks for each credit.
    credits.textContent = viewer.room ? [PolyHaven.credit, ...[...app.credits].slice(-3)].join(" · ") : "";
  });
  app.changed();

  // Drop a room PLY or a model file on the page.
  addEventListener("dragover", (event) => event.preventDefault());
  addEventListener("drop", (event) => {
    event.preventDefault();
    const files = [...(event.dataTransfer?.files ?? [])];
    const file = files[0];
    if (!file) return;
    app.attempt(async () => {
      const names = files.map((f) => f.name.toLowerCase());
      const isRoom = names.some((n) => n.endsWith(".json"))
        || (file.name.toLowerCase().endsWith(".ply") && (!viewer.room || file.size > 2_000_000));
      if (isRoom) await app.openRoomFiles(files);
      else await app.placeFile(file);
    });
  });

  // For poking at from the console.
  Object.assign(window, { roomtwin: app });
  // Logged in already: open the account's room without a click.
  void app.attempt(() => app.openStartRoom());
}

main();
