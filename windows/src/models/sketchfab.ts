import * as THREE from "three";
import { settings } from "../config";
import { asFurniture, parseModel } from "./loader";

/**
 * Models from Sketchfab, for things Poly Haven doesn't have. Searching is
 * open; downloading needs the owner's API token (Settings, or
 * SKETCHFAB_API_TOKEN in .env.local). Models come as GLB in whatever units
 * their author used, so each is scaled to a height. Most are CC BY: whoever
 * sees them must be told the model's name, author and licence.
 */
export interface Model {
  uid: string;
  name: string;
  author: string;
  license: string;
  thumbnail?: string;
}

export const attribution = (model: Model) => `“${model.name}” by ${model.author} (${model.license}) on Sketchfab`;

const api = "https://api.sketchfab.com/v3";
/** Bigger downloads take too long to wait for mid-conversation. */
const largestDownload = 15_000_000;

export const hasToken = () => Boolean(settings().sketchfabToken);

/** Downloadable models matching `query` with a GLB small enough to fetch quickly, most relevant first. */
export async function models(query: string): Promise<Model[]> {
  const url = `${api}/search?type=models&downloadable=true&count=24&q=${encodeURIComponent(query)}`;
  const reply = await fetch(url);
  if (!reply.ok) throw new Error(`Sketchfab didn't answer (HTTP ${reply.status}).`);
  const json = await reply.json();
  return (json.results ?? []).flatMap((result: any) => {
    const glb = result.archives?.glb;
    if (!result.uid || !glb?.size || glb.size > largestDownload) return [];
    const images: any[] = result.thumbnails?.images ?? [];
    const thumb = images.filter((image) => image.width >= 200).sort((a, b) => a.width - b.width)[0] ?? images[0];
    return [{
      uid: result.uid,
      name: result.name ?? "model",
      author: result.user?.username ?? "unknown",
      license: result.license?.label ?? "see Sketchfab",
      thumbnail: thumb?.url,
    }];
  });
}

const loaded = new Map<string, Promise<THREE.Object3D>>();

/** The model as furniture, `height` metres tall, upright on y = 0. */
export async function model(found: Model, height: number): Promise<THREE.Object3D> {
  let pending = loaded.get(found.uid);
  if (!pending) {
    pending = download(found).then((data) => parseModel(data, "model.glb"));
    pending.catch(() => loaded.delete(found.uid));
    loaded.set(found.uid, pending);
  }
  const model = asFurniture((await pending).clone(), { fitHeight: height });
  model.name = found.name;
  return model;
}

async function download(found: Model): Promise<ArrayBuffer> {
  const token = settings().sketchfabToken;
  if (!token) throw new Error("Sketchfab isn't set up: paste an API token in Settings.");
  const reply = await fetch(`${api}/models/${found.uid}/download`, { headers: { Authorization: `Token ${token}` } });
  const link = reply.ok ? (await reply.json())?.glb?.url : undefined;
  if (!link) throw new Error(`Sketchfab wouldn't hand over the model (HTTP ${reply.status}).`);
  // A short-lived link to the file itself, which needs no token. Its
  // storage doesn't always allow cross-origin reads, so vite fetches it if not.
  try {
    const file = await fetch(link);
    if (file.ok) return await file.arrayBuffer();
  } catch {
    // Blocked by CORS: go through the dev server.
  }
  const proxied = await fetch(`/__fetch?url=${encodeURIComponent(link)}`);
  if (!proxied.ok) throw new Error(`Couldn't download the model from Sketchfab (HTTP ${proxied.status}).`);
  return proxied.arrayBuffer();
}
