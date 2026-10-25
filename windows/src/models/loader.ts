import * as THREE from "three";
import { GLTFLoader } from "three/examples/jsm/loaders/GLTFLoader.js";
import { OBJLoader } from "three/examples/jsm/loaders/OBJLoader.js";
import { PLYLoader } from "three/examples/jsm/loaders/PLYLoader.js";
import { USDLoader } from "three/examples/jsm/loaders/USDLoader.js";
import { scanMaterial } from "../room/room";

/**
 * Turns a loaded model into furniture: standing on y = 0, centred, front
 * towards +z, inside a group that placement can turn and move. `height` is
 * the model's real height in metres, if known: when it lies along z rather
 * than y, the model was exported z-up and is stood up. `fitHeight` scales a
 * model of unknown units (Sketchfab's) to that many metres tall.
 */
export function asFurniture(content: THREE.Object3D, options: { height?: number; fitHeight?: number } = {}) {
  const box = new THREE.Box3().setFromObject(content);
  const size = box.getSize(new THREE.Vector3());
  if (options.height && Math.abs(size.z - options.height) < Math.abs(size.y - options.height)) {
    content.rotation.x = -Math.PI / 2;
    content.updateMatrixWorld(true);
  }
  if (options.fitHeight) {
    const rotated = new THREE.Box3().setFromObject(content).getSize(new THREE.Vector3());
    content.scale.multiplyScalar(options.fitHeight / Math.max(rotated.y, 1e-4));
    content.updateMatrixWorld(true);
  }
  const model = new THREE.Group();
  model.add(content);
  const fitted = new THREE.Box3().setFromObject(model);
  content.position.sub(new THREE.Vector3((fitted.min.x + fitted.max.x) / 2, fitted.min.y, (fitted.min.z + fitted.max.z) / 2));
  model.traverse((object) => {
    if (object instanceof THREE.Mesh) {
      object.castShadow = true;
      object.receiveShadow = true;
    }
  });
  return model;
}

/** glTF from a URL. `files` maps the glTF's relative paths to where they really are (Poly Haven spreads them out). */
export async function loadGLTF(url: string, files?: Record<string, string>): Promise<THREE.Object3D> {
  const manager = new THREE.LoadingManager();
  if (files) {
    manager.setURLModifier((requested) => {
      const match = Object.keys(files).find((path) => requested.endsWith("/" + path) || requested === path);
      return match ? files[match] : requested;
    });
  }
  const gltf = await new GLTFLoader(manager).loadAsync(url);
  return gltf.scene;
}

/** A model file's bytes, by its extension: glb/gltf (self-contained), usdz/usdc/usda, obj or ply. */
export async function parseModel(data: ArrayBuffer, filename: string): Promise<THREE.Object3D> {
  const extension = filename.toLowerCase().split(".").pop() ?? "";
  switch (extension) {
    case "glb":
    case "gltf": {
      const gltf = await new GLTFLoader().parseAsync(data, "");
      return gltf.scene;
    }
    case "usdz":
    case "usdc":
    case "usda":
    case "usd":
      return new USDLoader().parse(data);
    case "obj":
      return new OBJLoader().parse(new TextDecoder().decode(data));
    case "ply": {
      const geometry = new PLYLoader().parse(data);
      if (geometry.getAttribute("color")) return new THREE.Mesh(geometry, scanMaterial());
      geometry.computeVertexNormals();
      return new THREE.Mesh(geometry, new THREE.MeshStandardMaterial({ color: 0xcccccc, roughness: 0.8 }));
    }
    default:
      throw new Error(`Can't open .${extension} files. Use GLB, glTF, USDZ, OBJ or PLY.`);
  }
}

/** Width, height and depth of a model as it stands. */
export function modelSize(model: THREE.Object3D) {
  return new THREE.Box3().setFromObject(model).getSize(new THREE.Vector3());
}
