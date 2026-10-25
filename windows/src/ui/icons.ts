import {
  Armchair, ArrowDown, ArrowDownToLine, ArrowUp, Box, Camera, Check, CircleAlert, Copy, Download, FolderOpen, Footprints,
  Glasses, Hand, History, House, Image, Info, Layers, LoaderCircle, LogOut, Mic, Move3d, Orbit, PaintRoller, Plus,
  Redo2, RefreshCw, Rotate3d, RotateCcw, RotateCw, Scaling, ScanLine, Search, Settings, Sofa, Sparkles, Sun, Trash2,
  Undo2, Upload, User, Volume2, WandSparkles, X, createElement, type IconNode,
} from "lucide";

/** The icons the UI uses (Lucide), by name. Only these are bundled. */
const icons = {
  armchair: Armchair, down: ArrowDown, drop: ArrowDownToLine, up: ArrowUp, box: Box, camera: Camera, check: Check,
  alert: CircleAlert, copy: Copy, download: Download, folder: FolderOpen, walk: Footprints, vr: Glasses, hand: Hand,
  history: History, house: House, image: Image, info: Info, layers: Layers, spinner: LoaderCircle, logout: LogOut,
  mic: Mic, move: Move3d, orbit: Orbit, paint: PaintRoller, plus: Plus, redo: Redo2, refresh: RefreshCw,
  turn: Rotate3d, left: RotateCcw, right: RotateCw, stretch: Scaling, scan: ScanLine, search: Search,
  settings: Settings, sofa: Sofa, sparkles: Sparkles, sun: Sun, trash: Trash2, undo: Undo2, upload: Upload,
  user: User, speaker: Volume2, wand: WandSparkles, close: X,
} satisfies Record<string, IconNode>;

export type IconName = keyof typeof icons;

/** An inline SVG icon, sized by `class` (1em square by default, so it follows the text). */
export function icon(name: IconName, className = "") {
  const svg = createElement(icons[name], { "stroke-width": 1.75, "aria-hidden": "true" });
  svg.setAttribute("class", `icon ${className}`.trim());
  return svg;
}

/** Fills every `[data-icon]` placeholder in the page with its icon. */
export function fillIcons(root: ParentNode = document) {
  for (const slot of root.querySelectorAll<HTMLElement>("[data-icon]")) {
    slot.replaceWith(icon(slot.dataset.icon as IconName, slot.className));
  }
}
