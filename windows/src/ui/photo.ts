import type { App } from "../app";
import * as Fal from "../models/fal";
import { $, busy, dialogHeader, errorText, h, toast } from "./dom";
import { icon } from "./icons";

/**
 * Photo mode on the computer: a photo of one object (a file, or the webcam),
 * clicks on the object, SAM 3's guesses at it (Large, Medium, Small, as on
 * the phone), then SAM 3D Objects builds the whole thing, back included, and
 * it stands in the room. A laptop can't measure the object, so it's made the
 * height given.
 */
export async function openPhoto(app: App) {
  const dialog = $<HTMLDialogElement>("#photo-dialog");
  const configured = await Fal.isConfigured();
  let photo: { url: string; width: number; height: number } | null = null;
  let image: HTMLImageElement | null = null;
  let points: Fal.Point[] = [];
  let masks: Fal.Mask[] = [];
  let chosen = 0;

  const canvas = h("canvas", { class: "max-h-[50vh] w-full cursor-crosshair rounded-2xl border border-white/[0.06] bg-black/40 object-contain" }) as HTMLCanvasElement;
  const message = h("p", { class: "text-sm text-zinc-400" });
  const choices = h("div", { class: "segmented text-sm" });
  const name = h("input", { class: "field", value: "Photo object", placeholder: "What it is" }) as HTMLInputElement;
  const height = h("input", { class: "field", type: "number", min: "0.05", max: "3", step: "0.05", value: "0.8" }) as HTMLInputElement;
  const find = h("button", { class: "btn" }, icon("search"), "Find object") as HTMLButtonElement;
  const make = h("button", { class: "btn btn-primary" }, icon("sparkles"), "Make 3D") as HTMLButtonElement;
  const clear = h("button", { class: "btn" }, "Clear") as HTMLButtonElement;
  const download = h("a", { class: "text-sm text-blue-400 hidden", target: "_blank", rel: "noopener" }, "Download the GLB") as HTMLAnchorElement;

  const draw = () => {
    const context = canvas.getContext("2d")!;
    if (!photo || !image) {
      canvas.width = 640;
      canvas.height = 360;
      context.fillStyle = "#71717a";
      context.font = "500 16px 'Inter Variable', system-ui";
      context.textAlign = "center";
      context.fillText("Choose a photo of one object", 320, 180);
      return;
    }
    canvas.width = photo.width;
    canvas.height = photo.height;
    context.drawImage(image, 0, 0);
    if (masks[chosen]) context.drawImage(masks[chosen].canvas, 0, 0);
    const radius = Math.max(8, photo.width / 70);
    points.forEach((p, i) => {
      context.beginPath();
      context.arc(p.x, p.y, radius, 0, 2 * Math.PI);
      context.fillStyle = "#0a84ff";
      context.fill();
      context.lineWidth = radius / 4;
      context.strokeStyle = "white";
      context.stroke();
      context.fillStyle = "white";
      context.font = `bold ${radius * 1.2}px system-ui`;
      context.textAlign = "center";
      context.textBaseline = "middle";
      context.fillText(String(i + 1), p.x, p.y + 1);
    });
  };
  const refresh = () => {
    find.disabled = !points.length;
    clear.disabled = !points.length && !masks.length;
    make.disabled = !masks.length;
    const labels = ["Large", "Medium", "Small"];
    choices.replaceChildren(...masks.map((_, i) => {
      const button = h("button", { class: "seg flex-1", "aria-pressed": String(i === chosen) }, labels[i] ?? `Mask ${i + 1}`);
      button.onclick = () => {
        chosen = i;
        refresh();
      };
      return button;
    }));
    choices.classList.toggle("hidden", !masks.length);
    draw();
  };
  const usePhoto = async (blob: Blob) => {
    photo = await Fal.preparePhoto(blob);
    image = new Image();
    image.src = photo.url;
    await image.decode();
    points = [];
    masks = [];
    download.classList.add("hidden");
    message.textContent = "Click the object, once or a few times on different parts of it, then Find object.";
    refresh();
  };

  canvas.onclick = (event) => {
    if (!photo) return;
    const rect = canvas.getBoundingClientRect();
    points.push({ x: ((event.clientX - rect.left) / rect.width) * photo.width, y: ((event.clientY - rect.top) / rect.height) * photo.height });
    masks = [];
    refresh();
  };
  clear.onclick = () => {
    points = [];
    masks = [];
    refresh();
  };
  find.onclick = () => photo && busy(find, "Finding…", async () => {
    try {
      masks = await Fal.segment(photo!.url, points, photo!);
      chosen = 0;
      message.textContent = "Pick the guess that covers the whole object, give it a height, then Make 3D.";
    } catch (error) {
      message.textContent = errorText(error);
    }
    refresh();
  });
  make.onclick = () => photo && masks[chosen] && busy(make, "Building… (about 30 s)", async () => {
    try {
      const metres = Math.min(Math.max(Number(height.value) || 0.8, 0.05), 3);
      const { model, glb } = await Fal.generate(photo!.url, masks[chosen], metres);
      model.name = name.value.trim() || "Photo object";
      app.place({ model, source: "fal.ai SAM 3D", origin: { kind: "file", filename: `${model.name} (fal.ai)` } });
      download.href = glb;
      download.classList.remove("hidden");
      message.textContent = `Added ${model.name} where you're looking. Save the GLB to keep it: layouts don't keep models made here.`;
    } catch (error) {
      message.textContent = errorText(error);
    }
  });

  const choose = h("button", { class: "btn" }, icon("image"), "Choose photo…");
  choose.onclick = () => {
    const input = h("input", { type: "file", accept: "image/*" }) as HTMLInputElement;
    input.onchange = () => input.files?.[0] && usePhoto(input.files[0]).catch((e) => toast(errorText(e), "error"));
    input.click();
  };
  const webcam = h("button", { class: "btn" }, icon("camera"), "Webcam photo");
  webcam.onclick = () => snapshot().then(usePhoto, (e) => toast(errorText(e), "error"));

  dialog.replaceChildren(h("div", { class: "flex flex-col gap-4 p-6" },
    dialogHeader("wand", "Photo → 3D object", "SAM 3 finds it, SAM 3D Objects builds it, back and all", "from-amber-400 to-pink-500"),
    configured ? "" : h("p", { class: "rounded-2xl border border-amber-400/20 bg-amber-500/10 p-3 text-sm text-amber-200" },
      "This needs a fal.ai API key: add FALKEY=… to .env.local in the repo (the same line the phone's Mac server uses). "
      + "It stays on this computer; the page never sees it. Each model costs a little on the fal.ai account."),
    h("div", { class: "flex flex-wrap gap-2" }, choose, webcam, clear),
    canvas, message, choices,
    h("div", { class: "grid grid-cols-2 gap-2" },
      h("label", {}, h("span", { class: "label" }, "Name"), name),
      h("label", {}, h("span", { class: "label" }, "Height (metres)"), height)),
    h("div", { class: "flex flex-wrap items-center justify-between gap-2" }, download,
      h("div", { class: "ml-auto flex gap-2" }, find, make,
        h("button", { class: "btn", onclick: () => dialog.close() }, "Close")))));
  refresh();
  message.textContent = "One object, well lit, filling a good part of the photo works best.";
  dialog.showModal();
}

/** A still from the webcam. */
async function snapshot(): Promise<Blob> {
  const stream = await navigator.mediaDevices.getUserMedia({ video: { width: 1280, height: 720 } });
  try {
    const video = document.createElement("video");
    video.srcObject = stream;
    video.muted = true;
    await video.play();
    // Give the camera a moment to set its exposure.
    await new Promise((resolve) => setTimeout(resolve, 700));
    const canvas = document.createElement("canvas");
    canvas.width = video.videoWidth;
    canvas.height = video.videoHeight;
    canvas.getContext("2d")!.drawImage(video, 0, 0);
    return await new Promise<Blob>((resolve, reject) => canvas.toBlob((b) => (b ? resolve(b) : reject(new Error("No picture."))), "image/jpeg", 0.92));
  } finally {
    stream.getTracks().forEach((track) => track.stop());
  }
}
