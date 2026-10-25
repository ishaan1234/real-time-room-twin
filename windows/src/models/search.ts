import * as THREE from "three";
import * as PolyHaven from "./polyHaven";
import * as Sketchfab from "./sketchfab";

export type Source = "any" | "polyhaven" | "sketchfab";

/** Where a piece of furniture came from, enough to fetch it again when the layout is reopened. */
export type Origin =
  | { kind: "polyhaven"; id: string }
  | { kind: "sketchfab"; uid: string; name: string; author: string; license: string; height: number }
  | { kind: "account"; id: string; path: string }
  | { kind: "library"; id: string }
  | { kind: "file"; filename: string }
  /**
   * In the room when it opens, by the phone's ID: RoomPlan's furniture
   * ("scan:0", …) and models added on the phone ("added:<uuid>").
   */
  | { kind: "scan"; id: string };

export interface Found {
  model: THREE.Object3D;
  /** The credit to show, for licences that need one. */
  credit?: string;
  source: string;
  origin: Origin;
}

/**
 * Finds a model for a spoken request, as the iPhone app does. Poly Haven
 * first when it has a close match of about the right size (within 2× of the
 * height the agent expects), as its models are CC0, true to scale and
 * consistently oriented. Otherwise Sketchfab, scaled to the expected height.
 * Poly Haven's nearest is the last resort.
 */
export async function find(query: string, height: number, source: Source = "any"): Promise<Found> {
  const polyHaven = source === "sketchfab" ? [] : await PolyHaven.models(query);
  const sized = polyHaven.filter((asset) => {
    const h = PolyHaven.assetHeight(asset);
    return h === undefined || (h > height / 2 && h < height * 2);
  });
  const best = source === "polyhaven" ? [...sized, ...polyHaven] : sized.filter((asset) => PolyHaven.isCloseMatch(asset, query));
  const found = await firstThatLoads(best);
  if (found) return found;
  if (source !== "polyhaven" && Sketchfab.hasToken()) {
    try {
      // A long request can find nothing ("floating wall bookshelf"): then its last two words.
      let models = await Sketchfab.models(query);
      const shorter = query.trim().split(/\s+/).slice(-2).join(" ");
      if (!models.length && shorter !== query.trim()) models = await Sketchfab.models(shorter);
      // The first few, in case one won't download.
      for (const model of models.slice(0, 3)) {
        try {
          return await fromSketchfab(model, height);
        } catch {
          // Try the next.
        }
      }
    } catch (error) {
      if (!polyHaven.length) throw error;
      // Fall back to Poly Haven's nearest.
    }
  }
  // The nearest: what's named as the thing first, then anything of about the right size.
  const named = polyHaven.filter((asset) => PolyHaven.namesThing(asset, query));
  const nearest = await firstThatLoads([...sized.filter((a) => named.includes(a)), ...named, ...sized, ...polyHaven]);
  if (!nearest) throw new Error(`Couldn't find a model of ${query}.`);
  // Not what was asked for, so at least make it the size that was.
  const size = new THREE.Box3().setFromObject(nearest.model).getSize(new THREE.Vector3());
  if (size.y > 0 && (size.y < height / 2 || size.y > height * 2)) nearest.model.scale.multiplyScalar(height / size.y);
  return nearest;
}

/** The first few Poly Haven candidates in turn: a few assets have no glTF to download. */
async function firstThatLoads(assets: PolyHaven.Asset[]): Promise<Found | null> {
  for (const asset of [...new Set(assets)].slice(0, 4)) {
    try {
      return await fromPolyHaven(asset);
    } catch {
      // Try the next.
    }
  }
  return null;
}

export async function fromPolyHaven(asset: PolyHaven.Asset): Promise<Found> {
  return { model: await PolyHaven.model(asset), source: "Poly Haven", origin: { kind: "polyhaven", id: asset.id } };
}

export async function fromSketchfab(model: Sketchfab.Model, height: number): Promise<Found> {
  return {
    model: await Sketchfab.model(model, height),
    credit: Sketchfab.attribution(model),
    source: "Sketchfab",
    origin: { kind: "sketchfab", uid: model.uid, name: model.name, author: model.author, license: model.license, height },
  };
}
