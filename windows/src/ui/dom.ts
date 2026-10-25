/** Small DOM helpers: the UI is plain TypeScript with Tailwind classes. */
import { icon } from "./icons";

type Child = Node | string | null | undefined | false;

/** An element with classes, attributes or event handlers (on…), and children. */
export function h<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  props: Record<string, any> = {},
  ...children: (Child | Child[])[]
): HTMLElementTagNameMap[K] {
  const element = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (value === undefined || value === null || value === false) continue;
    if (key === "class") element.className = value;
    else if (key.startsWith("on") && typeof value === "function") element.addEventListener(key.slice(2).toLowerCase(), value);
    else if (key in element && typeof value !== "string") (element as any)[key] = value;
    else element.setAttribute(key, String(value));
  }
  for (const child of children.flat()) {
    if (child) element.append(child);
  }
  return element;
}

export const $ = <T extends HTMLElement = HTMLElement>(selector: string) => document.querySelector<T>(selector)!;

let toastTimer: number | undefined;

/** A note at the bottom of the view; click it to dismiss. Errors stay longer. */
export function toast(message: string, kind: "info" | "error" = "info") {
  const element = $("#toast");
  const error = kind === "error";
  const working = !error && message.endsWith("…");
  element.replaceChildren(
    h("span", { class: `flex size-6 shrink-0 items-center justify-center rounded-full ${error ? "bg-red-500/20 text-red-300"
      : working ? "text-[#a99cff]" : "bg-gradient-to-br from-[#8b7bff] to-[#38bdf8] text-white"}` },
      icon(error ? "alert" : working ? "spinner" : "check", working ? "animate-spin" : "size-3.5")),
    h("span", { class: error ? "text-red-200" : "text-zinc-100" }, message));
  element.classList.remove("hidden");
  element.classList.add("flex");
  // Replays the entrance animation for each new note.
  element.style.animation = "none";
  void element.offsetWidth;
  element.style.animation = "";
  const hide = () => element.classList.replace("flex", "hidden");
  element.onclick = hide;
  clearTimeout(toastTimer);
  toastTimer = window.setTimeout(hide, error ? 9000 : 4500);
}

export function errorText(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

/** Runs `work`, showing a spinner and `label` on the button meanwhile. */
export async function busy<T>(button: HTMLButtonElement | null, label: string, work: () => Promise<T>): Promise<T> {
  const old = button ? [...button.childNodes] : [];
  if (button) {
    button.disabled = true;
    button.replaceChildren(icon("spinner", "animate-spin"), label === "…" ? "" : label);
  }
  try {
    return await work();
  } finally {
    if (button) {
      button.disabled = false;
      button.replaceChildren(...old);
    }
  }
}

/** A grid card with a picture (or an icon) and a name. */
export function card(title: string, picture: string | null, onClick: () => void, subtitle?: string) {
  return h("button", { class: "card group", onclick: onClick, title },
    h("div", { class: "relative aspect-square w-full overflow-hidden bg-gradient-to-br from-white/[0.06] to-white/[0.01]" },
      picture?.startsWith("http") || picture?.startsWith("blob:")
        ? h("img", { src: picture, class: "size-full object-cover", loading: "lazy", alt: "" })
        : h("div", { class: "card-art flex size-full items-center justify-center text-3xl" }, picture ?? "📦"),
      h("div", { class: "absolute inset-0 flex items-center justify-center opacity-0 transition duration-300 group-hover:bg-[#7c5cff]/25 group-hover:opacity-100" },
        h("span", { class: "flex size-8 items-center justify-center rounded-full bg-white text-zinc-900 shadow-lg" }, icon("plus", "size-4")))),
    h("div", { class: "truncate px-2 pt-2 font-medium text-zinc-200" }, title),
    h("div", { class: "truncate px-2 pb-2 text-[11px] text-zinc-500" }, subtitle ?? ""));
}

/** A labelled on/off switch. */
export function toggle(label: string, checked: boolean, onChange: (on: boolean) => void, hint?: string) {
  const input = h("input", { type: "checkbox", checked, onchange: () => onChange(input.checked) });
  return h("label", { class: "flex cursor-pointer items-center justify-between gap-3 rounded-xl px-1 py-1.5 text-sm text-zinc-300 transition hover:text-white" },
    h("span", { class: "min-w-0" }, label, hint ? h("span", { class: "block text-[11px] text-zinc-500" }, hint) : ""), input);
}

/** A dialog's title row: a glowing icon, the title and a line under it. */
export function dialogHeader(name: Parameters<typeof icon>[0], title: string, subtitle: string, colours = "from-[#7c5cff] to-[#2563eb]") {
  return h("div", { class: "flex items-center gap-3" },
    h("div", { class: `flex size-11 shrink-0 items-center justify-center rounded-2xl bg-gradient-to-br ${colours} text-white shadow-[0_8px_24px_-8px_rgb(124_92_255/0.9)]` },
      icon(name, "size-5")),
    h("div", { class: "min-w-0" },
      h("h2", { class: "font-display text-xl font-semibold tracking-tight" }, title),
      h("p", { class: "text-xs text-zinc-400" }, subtitle)));
}
