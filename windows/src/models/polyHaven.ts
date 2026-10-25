import * as THREE from "three";
import { asFurniture, loadGLTF } from "./loader";

/**
 * Furniture and wall textures from Poly Haven (polyhaven.com), all CC0,
 * through its public API, ranked the same way as the iPhone app's
 * PolyHaven.swift. Models come as glTF at 1k, about a megabyte each. The
 * API's terms ask for a visible "Powered by Poly Haven" wherever its content
 * shows. (Browsers don't let a page set User-Agent, so none is sent.)
 */
export interface Asset {
  id: string;
  name: string;
  categories: string[];
  tags: string[];
  /** Millimetres. Models: width, depth, height. Textures: the width and height the image covers. */
  dimensions?: number[];
}

export const credit = "Powered by Poly Haven";
const api = "https://api.polyhaven.com";
const catalogs = new Map<string, Promise<Asset[]>>();

/** A model's real height in metres. */
export const assetHeight = (asset: Asset) => (asset.dimensions?.length === 3 ? asset.dimensions[2] / 1000 : undefined);

export const thumbnail = (asset: Asset) => `https://cdn.polyhaven.com/asset_img/thumbs/${asset.id}.png?width=256&height=256`;

// Searching

/** Models matching a request like "floor lamp" or "wooden dining table", best first. */
export async function models(query: string) {
  return rank(await catalog("models"), query, preferredModels, misplaced);
}

/** Textures for walls matching a request like "red brick" or "white plaster". */
export async function wallTextures(query: string) {
  return rank(await catalog("textures"), query, preferredTextures, new Set());
}

/** Textures for a floor, like "oak boards" or "white marble". */
export async function floorTextures(query: string) {
  return rank(await catalog("textures"), query, preferredFloors, new Set());
}

/** Materials for furniture, like "red velvet" or "black leather". */
export async function materialTextures(query: string) {
  return rank(await catalog("textures"), query, preferredMaterials, new Set());
}

/** An asset by its ID, as saved in a layout. */
export async function asset(type: "models" | "textures", id: string): Promise<Asset> {
  return (await catalog(type)).find((a) => a.id === id) ?? { id, name: id, categories: [], tags: [] };
}

function catalog(type: "models" | "textures"): Promise<Asset[]> {
  let cached = catalogs.get(type);
  if (!cached) {
    cached = fetchJSON(`${api}/assets?t=${type}`).then((json: Record<string, any>) =>
      Object.entries(json).map(([id, info]) => ({
        id,
        name: info.name ?? id,
        categories: info.categories ?? [],
        tags: info.tags ?? [],
        dimensions: info.dimensions,
      })),
    );
    cached.catch(() => catalogs.delete(type));
    catalogs.set(type, cached);
  }
  return cached;
}

const preferredModels = new Set(["furniture", "seating", "table", "lighting", "decorative", "shelves", "appliances",
  "electronics", "plants", "containers", "storage", "bed"]);
const preferredTextures = new Set(["wall", "indoor", "plaster", "plaster-concrete", "brick", "wood", "tiles", "fabric", "clean"]);
const preferredFloors = new Set(["floor", "wood", "tiles", "marble", "carpet", "stone", "concrete", "indoor"]);
const preferredMaterials = new Set(["fabric", "wood", "leather", "metal", "plastic", "marble", "man made"]);
const synonyms: Record<string, string> = {
  couch: "sofa", settee: "sofa", desk: "table", bookcase: "shelf", bookshelf: "shelf", shelving: "shelf",
  tv: "television", light: "lamp", bedside: "nightstand", wallpaper: "wall", paint: "painted", wooden: "wood",
};
/** Things that don't stand in a room: hung up, or outdoors. They rank low unless asked for by name. */
const misplaced = new Set(["hanging", "ceiling", "chandelier", "sconce", "mounted", "wall", "outdoor", "exterior",
  "street", "lamppost", "forest", "field", "woodland", "karoo", "desert", "garden", "shrub"]);
const filler = new Set(["a", "an", "the", "some", "with", "of", "and", "for", "in", "on", "please", "one", "new",
  "nice", "kind"]);

function words(text: string) {
  return text.toLowerCase().split(/[^\p{L}]+/u).filter(Boolean).map((word) => {
    let w = word;
    if (w.length > 3 && w.endsWith("s") && !w.endsWith("ss")) w = w.slice(0, -1);
    return synonyms[w] ?? w;
  });
}

/**
 * Scores each asset by how many of the request's words it has, in its name
 * (most), tags or categories. The last word is usually the thing itself, so
 * it counts double. Unwanted kinds, and anything over 3 m, drop.
 */
function rank(assets: Asset[], query: string, prefer: Set<string>, avoid: Set<string>) {
  const wanted = words(query).filter((w) => !filler.has(w));
  if (!wanted.length) return [];
  const thing = wanted[wanted.length - 1];
  const unwanted = [...avoid].filter((w) => !wanted.includes(w));
  const scored: [Asset, number][] = [];
  for (const asset of assets) {
    const name = new Set(words(asset.name));
    const tags = new Set(asset.tags.flatMap(words));
    const categories = new Set(asset.categories.flatMap(words));
    let score = 0;
    wanted.forEach((word, i) => {
      const weight = i === wanted.length - 1 ? 2 : 1;
      score += weight * (name.has(word) ? 3 : tags.has(word) ? 2 : categories.has(word) ? 1.5 : 0);
    });
    if (score > 0 && asset.categories.some((c) => prefer.has(c))) score += 1;
    if (unwanted.some((w) => name.has(w) || tags.has(w) || categories.has(w))) score -= 3;
    if (Math.max(0, ...(asset.dimensions ?? [])) > 3000) score -= 3;
    // The thing itself must match, not just an adjective.
    if (score > 0 && (name.has(thing) || tags.has(thing) || categories.has(thing))) scored.push([asset, score]);
  }
  return scored.sort((a, b) => b[1] - a[1] || a[0].name.localeCompare(b[0].name)).map(([asset]) => asset);
}

/** Whether the asset's name has the thing asked for: the request's last word, "shelf" in "floating wall bookshelf". */
export function namesThing(asset: Asset, query: string) {
  const wanted = words(query).filter((w) => !filler.has(w));
  return wanted.length > 0 && words(asset.name).includes(wanted[wanted.length - 1]);
}

/** Whether every word of the request is in the asset's name, tags or categories. */
export function isCloseMatch(asset: Asset, query: string) {
  const has = new Set([...words(asset.name), ...asset.tags.flatMap(words), ...asset.categories.flatMap(words)]);
  return words(query).filter((w) => !filler.has(w)).every((w) => has.has(w));
}

// Downloading

const loaded = new Map<string, Promise<THREE.Object3D>>();

/** The model as furniture: upright on y = 0, front towards +z. */
export async function model(asset: Asset): Promise<THREE.Object3D> {
  let pending = loaded.get(asset.id);
  if (!pending) {
    pending = (async () => {
      const files = await fetchJSON(`${api}/files/${asset.id}`);
      const entry = files?.gltf?.["1k"]?.gltf;
      if (!entry?.url) throw new Error(`Poly Haven has no glTF of ${asset.name}.`);
      const include: Record<string, string> = {};
      for (const [path, info] of Object.entries<any>(entry.include ?? {})) include[path] = info.url;
      return asFurniture(await loadGLTF(entry.url, include), { height: assetHeight(asset) });
    })();
    pending.catch(() => loaded.delete(asset.id));
    loaded.set(asset.id, pending);
  }
  const model = (await pending).clone();
  model.name = asset.name;
  return model;
}

/** A wall texture's colour map, and the size in metres it covers. */
export async function wallTexture(asset: Asset): Promise<{ texture: THREE.Texture; size: [number, number] }> {
  const files = await fetchJSON(`${api}/files/${asset.id}`);
  const url = files?.Diffuse?.["1k"]?.jpg?.url;
  if (!url) throw new Error(`Poly Haven has no colour map for ${asset.name}.`);
  const loader = new THREE.TextureLoader();
  loader.setCrossOrigin("anonymous");
  const texture = await loader.loadAsync(url);
  const size: [number, number] = asset.dimensions && asset.dimensions.length >= 2
    ? [asset.dimensions[0] / 1000, asset.dimensions[1] / 1000]
    : [2, 2];
  return { texture, size };
}

async function fetchJSON(url: string): Promise<any> {
  const reply = await fetch(url);
  if (!reply.ok) throw new Error(`Poly Haven didn't answer (HTTP ${reply.status}).`);
  return reply.json();
}
