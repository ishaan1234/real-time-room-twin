import type * as THREE from "three";
import { asFurniture, loadGLTF } from "./loader";

/**
 * Photo mode's hosted models, fal.ai's SAM 3 (picking the object out of a
 * photo) and SAM 3D Objects (building all of it, back included, from that),
 * as ObjectServer/fal_server.py uses them for the phone. The calls go through
 * the dev server's /__fal, which holds the key. A laptop has no LiDAR, so the
 * size comes from the height the user gives.
 */
export interface Point {
  /** Pixels in the photo. */
  x: number;
  y: number;
}

export interface Mask {
  url: string;
  score: number;
  /** The share of the photo it covers, 0–1. */
  area: number;
  /** The mask as a canvas the size of the photo, for drawing over it. */
  canvas: HTMLCanvasElement;
}

/** Whether FALKEY is in .env.local. */
export async function isConfigured(): Promise<boolean> {
  try {
    return (await (await fetch("/__fal")).json()).configured === true;
  } catch {
    return false;
  }
}

/** A photo as a JPEG data URL at most 1280 pixels across, with its size. */
export async function preparePhoto(file: Blob): Promise<{ url: string; width: number; height: number }> {
  const bitmap = await createImageBitmap(file);
  const scale = Math.min(1, 1280 / Math.max(bitmap.width, bitmap.height));
  const canvas = document.createElement("canvas");
  canvas.width = Math.round(bitmap.width * scale);
  canvas.height = Math.round(bitmap.height * scale);
  canvas.getContext("2d")!.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  return { url: canvas.toDataURL("image/jpeg", 0.92), width: canvas.width, height: canvas.height };
}

/**
 * SAM 3's guesses at the object under the points (all on the same object),
 * up to three of them, biggest first: a whole chair, its seat, …
 */
export async function segment(photo: string, points: Point[], size: { width: number; height: number }): Promise<Mask[]> {
  // An explicit empty prompt: fal's sample default ("wheel") would otherwise join the points.
  const result = await run("sam-3/image", {
    image_url: photo, prompt: "", apply_mask: false, output_format: "png", return_multiple_masks: true,
    max_masks: 3, include_scores: true, include_boxes: true,
    point_prompts: points.map((p) => ({ x: Math.round(p.x), y: Math.round(p.y), label: 1, object_id: 0 })),
  });
  const scores: number[] = result.scores ?? [];
  const masks = await Promise.all((result.masks ?? []).map(async (mask: any, i: number) => {
    const url = typeof mask === "string" ? mask : mask?.url;
    if (!url) return null;
    const canvas = await maskCanvas(url, size);
    return { url, score: Number(scores[i] ?? result.metadata?.[i]?.score ?? 1), area: coverage(canvas), canvas };
  }));
  const found = masks.filter((m): m is Mask => Boolean(m) && m!.area > 0);
  if (!found.length) throw new Error("SAM 3 found nothing there. Click nearer the middle of the object and try again.");
  return found.sort((a, b) => b.area - a.area);
}

/** The whole object as furniture, `height` metres tall, from the photo and one of its masks. Takes about half a minute. */
export async function generate(photo: string, mask: Mask, height: number): Promise<{ model: THREE.Object3D; glb: string }> {
  const result = await run("sam-3/3d-objects", {
    image_url: photo, mask_urls: [mask.url], seed: 42, export_textured_glb: true, enable_safety_checker: true,
  });
  const glb = result.individual_glbs?.[0]?.url ?? result.model_glb?.url ?? result.model_mesh?.url;
  if (!glb) throw new Error("fal.ai sent back no model.");
  let content: THREE.Object3D;
  try {
    content = await loadGLTF(glb);
  } catch {
    content = await loadGLTF(`/__fetch?url=${encodeURIComponent(glb)}`);
  }
  return { model: asFurniture(content, { fitHeight: height }), glb };
}

async function run(endpoint: string, input: Record<string, unknown>): Promise<any> {
  const reply = await fetch("/__fal", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ endpoint, input }),
  });
  const body = await reply.json().catch(() => ({}));
  if (!reply.ok) throw new Error(body.error ?? `fal.ai didn't answer (HTTP ${reply.status}).`);
  return body;
}

/** A mask image (white where the object is) drawn at the photo's size. */
async function maskCanvas(url: string, size: { width: number; height: number }) {
  let blob: Blob;
  try {
    blob = await (await fetch(url)).blob();
  } catch {
    blob = await (await fetch(`/__fetch?url=${encodeURIComponent(url)}`)).blob();
  }
  const bitmap = await createImageBitmap(blob);
  const canvas = document.createElement("canvas");
  canvas.width = size.width;
  canvas.height = size.height;
  const context = canvas.getContext("2d")!;
  context.drawImage(bitmap, 0, 0, size.width, size.height);
  // Some masks are opaque grey images, some use transparency: either way, blue where the object is.
  const pixels = context.getImageData(0, 0, size.width, size.height);
  const d = pixels.data;
  let usesAlpha = false;
  for (let i = 3; i < d.length; i += 4) if (d[i] < 250) { usesAlpha = true; break; }
  for (let i = 0; i < d.length; i += 4) {
    const on = usesAlpha ? d[i + 3] >= 128 : d[i] >= 128;
    d[i] = 10; d[i + 1] = 132; d[i + 2] = 255; d[i + 3] = on ? 120 : 0;
  }
  context.putImageData(pixels, 0, 0);
  return canvas;
}

function coverage(canvas: HTMLCanvasElement) {
  const d = canvas.getContext("2d")!.getImageData(0, 0, canvas.width, canvas.height).data;
  let on = 0;
  for (let i = 3; i < d.length; i += 4) if (d[i] > 0) on++;
  return on / (canvas.width * canvas.height);
}
