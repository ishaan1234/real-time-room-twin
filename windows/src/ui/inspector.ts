import type { App } from "../app";
import type { Piece } from "../scene/furniture";
import type { GizmoMode } from "../scene/gizmo";
import { busy, h, toggle } from "./dom";
import { icon, type IconName } from "./icons";

const sources: Record<string, string> = {
  polyhaven: "Poly Haven (CC0)", sketchfab: "Sketchfab", account: "Your account", library: "Library", file: "This computer",
  scan: "In the room",
};
const modes: [GizmoMode, string, IconName][] = [["off", "Off", "close"], ["move", "Move", "move"], ["turn", "Turn", "turn"], ["stretch", "Stretch", "stretch"]];

/** The panel for the selected piece: turn, scale, raise, duplicate, delete. */
export function renderInspector(app: App, container: HTMLElement, piece: Piece | null) {
  container.classList.toggle("hidden", !piece);
  if (!piece) return container.replaceChildren();
  const { editor } = app;
  const percent = () => `${Math.round(piece.scale.x * 100)}%`;
  const scale = h("input", { type: "range", min: "0.25", max: "3", step: "0.05", value: String(piece.scale.x), class: "w-full",
    oninput: () => {
      editor.setScale(Number(scale.value));
      scaleLabel.textContent = percent();
    } });
  const scaleLabel = h("span", { class: "font-mono text-[11px] text-[#a99cff]" }, percent());
  const material = () => {
    const query = h("input", { class: "field py-2 pr-16 pl-8", placeholder: "red velvet, walnut…" });
    const go = h("button", { class: "btn btn-primary absolute top-1 right-1 bottom-1 px-2.5 py-0 text-xs", type: "submit" }, "Apply");
    return h("form", {
      class: "relative",
      onsubmit: (event: Event) => {
        event.preventDefault();
        if (query.value.trim()) app.attempt(() => busy(go, "…", () => app.material(piece, query.value)));
      },
    }, h("span", { class: "pointer-events-none absolute top-1/2 left-2.5 -translate-y-1/2 text-zinc-500" }, icon("paint", "size-3.5")), query, go);
  };
  const button = (content: (Node | string)[], onClick: () => void, extra = "", title = "") =>
    h("button", { class: `btn px-2 text-xs ${extra}`, onclick: onClick, title }, ...content);
  const section = (label: string, keys: string, ...children: Node[]) =>
    h("div", { class: "mt-4" },
      h("div", { class: "label flex items-center justify-between" }, h("span", {}, label),
        keys ? h("span", { class: "flex gap-1" }, keys.split(" ").map((key) => h("span", { class: "kbd" }, key))) : ""),
      ...children);
  const { gizmo } = editor;
  const lock = h("div", { class: gizmo.mode === "stretch" ? "mt-1" : "mt-1 hidden" },
    toggle("Keep its proportions", gizmo.lockScale, (on) => (gizmo.lockScale = on)));
  const handles = h("div", { class: "segmented text-xs" }, modes.map(([mode, label, name]) => {
    const segment = h("button", { class: "seg flex-1 flex-col gap-0.5 px-1 py-1.5", "aria-pressed": String(gizmo.mode === mode) },
      icon(name, "size-4"), label);
    segment.onclick = () => {
      gizmo.setMode(mode);
      for (const other of handles.children) other.setAttribute("aria-pressed", String(other === segment));
      lock.classList.toggle("hidden", mode !== "stretch");
    };
    return segment;
  }));
  const scanned = piece.userData.origin.kind === "scan";
  container.replaceChildren(
    h("div", { class: "flex items-start gap-3" },
      h("div", { class: "flex size-11 shrink-0 items-center justify-center rounded-xl bg-gradient-to-br from-[#7c5cff] to-[#38bdf8] text-white shadow-[0_6px_20px_-6px_rgb(124_92_255/0.9)]" },
        icon(scanned ? "scan" : "armchair", "size-5")),
      h("div", { class: "min-w-0 flex-1" },
        h("div", { class: "truncate font-display text-base font-semibold tracking-tight" }, piece.name),
        h("div", { class: "truncate text-[11px] text-zinc-500" }, sources[piece.userData.origin.kind])),
      h("button", { class: "btn btn-icon size-8 rounded-full", onclick: () => editor.select(null), title: "Deselect (Esc)" }, icon("close", "size-4"))),
    piece.userData.credit ? h("div", { class: "mt-2 text-[10px] text-zinc-500" }, piece.userData.credit) : "",
    section("Handles", "", handles, lock),
    section("Turn", "R ⇧R",
      h("div", { class: "grid grid-cols-4 gap-1" },
        button([icon("left", "size-3.5"), "90°"], () => editor.rotate(90)), button([icon("left", "size-3.5"), "15°"], () => editor.rotate(15)),
        button(["15°", icon("right", "size-3.5")], () => editor.rotate(-15)), button(["90°", icon("right", "size-3.5")], () => editor.rotate(-90)))),
    section("Size", "[ ]", h("div", { class: "flex items-center gap-3" }, scale, scaleLabel)),
    section("Height", "PgUp PgDn",
      h("div", { class: "grid grid-cols-3 gap-1" },
        button([icon("up", "size-3.5"), "Up"], () => editor.raise(0.05)), button([icon("down", "size-3.5"), "Down"], () => editor.raise(-0.05)),
        button([icon("drop", "size-3.5"), "Drop"], () => editor.dropToFloor(), "", "Onto the floor or what's below"))),
    section("Material", "", material()),
    h("div", { class: "mt-4 grid grid-cols-2 gap-1.5" },
      button([icon("copy", "size-3.5"), "Duplicate"], () => editor.duplicate(), "", "Ctrl+D"),
      button([icon("trash", "size-3.5"), "Delete"], () => editor.remove(), "btn-danger", "Delete")),
    h("p", { class: "mt-3 text-center text-[10px] text-zinc-500" }, "Drag it to move · Ctrl+Z undoes · Ctrl+Shift+Z redoes"),
  );
}
