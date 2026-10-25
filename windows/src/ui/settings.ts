import type { App } from "../app";
import { defaults, saveSettings, settings, type Settings } from "../config";
import { $, dialogHeader, h } from "./dom";

const fields: { key: keyof Settings; label: string; hint: string; secret?: boolean }[] = [
  { key: "supabaseUrl", label: "Supabase URL", hint: "https://<project>.supabase.co, as in RoomTwin/supabase.json (\"url\")" },
  { key: "supabaseAnonKey", label: "Supabase anon key", hint: "The public key from the same file (\"anonKey\"). Safe to share; it only does what the account allows.", secret: true },
  { key: "agentId", label: "ElevenLabs agent ID", hint: "ELEVENLABS_AGENT_ID (or ELEVENLABS_DESKTOP_AGENT_ID) from .env.local. Not the API key." },
  { key: "sketchfabToken", label: "Sketchfab API token", hint: "Optional. Sketchfab › Settings › Password & API. Downloads count as that account's.", secret: true },
];

/**
 * Where the app finds the account, the voice agent and Sketchfab. Values from
 * the repo's .env.local are filled in already; anything typed here is kept in
 * this browser and wins.
 */
export function openSettings(app: App, onSaved: () => void) {
  const dialog = $<HTMLDialogElement>("#settings-dialog");
  const current = settings();
  const inputs = Object.fromEntries(fields.map(({ key, secret }) => [key,
    h("input", { class: "field font-mono", type: secret ? "password" : "text", value: current[key], placeholder: defaults[key] ? "(from .env.local)" : "" })]));
  const save = () => {
    saveSettings(Object.fromEntries(fields.map(({ key }) => [key, inputs[key].value.trim()])));
    if (app.account.session && (settings().supabaseUrl !== current.supabaseUrl)) app.account.signOut();
    dialog.close();
    onSaved();
  };
  dialog.replaceChildren(h("form", {
    method: "dialog",
    class: "flex flex-col gap-5 p-6",
    onsubmit: (event: Event) => {
      event.preventDefault();
      save();
    },
  },
  dialogHeader("settings", "Settings", "Where RoomTwin finds the account, the voice agent and Sketchfab"),
  fields.map(({ key, label, hint }) => h("label", {},
    h("span", { class: "label" }, label), inputs[key], h("span", { class: "note mt-1.5 block" }, hint))),
  h("div", { class: "flex justify-end gap-2" },
    h("button", { class: "btn", type: "button", onclick: () => dialog.close() }, "Cancel"),
    h("button", { class: "btn btn-primary", type: "submit" }, "Save"))));
  dialog.showModal();
}
