import type { VoiceAgent } from "../voice/agent";
import { $, dialogHeader, h } from "./dom";

/**
 * Everything said to and by the voice agent, kept in this browser like the
 * phone's History sheet. Export saves it as the same kind of JSON, to look
 * back on or to improve the agent with.
 */
export function openHistory(voice: VoiceAgent) {
  const dialog = $<HTMLDialogElement>("#history-dialog");
  const render = () => {
    const entries = voice.transcript;
    const list = entries.length
      ? h("div", { class: "flex max-h-[60vh] flex-col gap-2 overflow-y-auto pr-1" }, entries.map((entry) =>
        h("div", { class: `max-w-[85%] rounded-2xl px-3.5 py-2.5 text-sm ${entry.speaker === "user"
          ? "self-end rounded-br-md bg-gradient-to-br from-[#7c5cff] to-[#3b82f6] shadow-[0_6px_20px_-8px_rgb(124_92_255/0.8)]" : "self-start rounded-bl-md border border-white/[0.06] bg-white/[0.06]"}` },
          h("div", {}, entry.text),
          h("div", { class: "mt-0.5 text-[10px] text-zinc-300/70" },
            new Date(entry.date).toLocaleString(undefined, { dateStyle: "short", timeStyle: "short" })))))
      : h("p", { class: "rounded-2xl border border-dashed border-white/10 p-6 text-center text-sm text-zinc-500" }, "Nothing yet. Press Talk and say what to do.");
    dialog.replaceChildren(h("div", { class: "flex flex-col gap-5 p-6" },
      dialogHeader("history", "Voice history", `${entries.length} message${entries.length === 1 ? "" : "s"} with the room agent`, "from-fuchsia-500 to-[#7c5cff]"),
      list,
      h("div", { class: "flex justify-end gap-2" },
        h("button", {
          class: "btn btn-danger", disabled: !entries.length,
          onclick: () => confirm("Forget the whole voice history?") && (voice.clearTranscript(), render()),
        }, "Clear"),
        h("button", { class: "btn", disabled: !entries.length, onclick: () => exportJSON(voice) }, "Export"),
        h("button", { class: "btn btn-primary", onclick: () => dialog.close() }, "Done"))));
    list.scrollTop = list.scrollHeight;
  };
  render();
  dialog.showModal();
}

function exportJSON(voice: VoiceAgent) {
  const url = URL.createObjectURL(new Blob([JSON.stringify(voice.transcript, null, 2)], { type: "application/json" }));
  const link = h("a", { href: url, download: "RoomTwin Conversation History.json" });
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
