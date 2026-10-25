import * as THREE from "three";
import chairUrl from "@library/furniture-chair.ply?url";
import sofaUrl from "@library/furniture-sofa.ply?url";
import stoolUrl from "@library/furniture-stool.ply?url";
import tableUrl from "@library/furniture-table.ply?url";
import { asFurniture, parseModel } from "./loader";

/**
 * Things to add without searching: the SAM 3D furniture the iPhone app
 * bundles (RoomTwin/Library, each standing on y = 0 facing +z), and plain
 * shapes for blocking out a room.
 */
export interface LibraryItem {
  id: string;
  name: string;
  icon: string;
}

const scanned: Record<string, string> = { chair: chairUrl, sofa: sofaUrl, stool: stoolUrl, table: tableUrl };

export const items: LibraryItem[] = [
  { id: "chair", name: "Chair", icon: "🪑" },
  { id: "sofa", name: "Sofa", icon: "🛋️" },
  { id: "table", name: "Table", icon: "🟫" },
  { id: "stool", name: "Stool", icon: "🍄" },
  { id: "box", name: "Box", icon: "📦" },
  { id: "cylinder", name: "Cylinder", icon: "🛢️" },
  { id: "rug", name: "Rug", icon: "🟥" },
];

const loaded = new Map<string, Promise<THREE.Object3D>>();

export async function model(id: string): Promise<THREE.Object3D> {
  let pending = loaded.get(id);
  if (!pending) {
    pending = build(id);
    pending.catch(() => loaded.delete(id));
    loaded.set(id, pending);
  }
  const model = (await pending).clone();
  model.name = items.find((item) => item.id === id)?.name.toLowerCase() ?? id;
  return model;
}

async function build(id: string): Promise<THREE.Object3D> {
  if (scanned[id]) {
    const data = await (await fetch(scanned[id])).arrayBuffer();
    return asFurniture(await parseModel(data, `${id}.ply`));
  }
  const material = new THREE.MeshStandardMaterial({ color: 0xb8c4d6, roughness: 0.7 });
  switch (id) {
    case "box":
      return asFurniture(new THREE.Mesh(new THREE.BoxGeometry(0.5, 0.5, 0.5), material));
    case "cylinder":
      return asFurniture(new THREE.Mesh(new THREE.CylinderGeometry(0.25, 0.25, 0.8, 32), material));
    case "rug":
      material.color.set(0x9b3b3b);
      return asFurniture(new THREE.Mesh(new THREE.BoxGeometry(2, 0.01, 1.4), material));
    default:
      throw new Error(`There's nothing called ${id} in the library.`);
  }
}
