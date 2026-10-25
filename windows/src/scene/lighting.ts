import * as THREE from "three";
import { scanLighting } from "../room/room";
import type { Viewer } from "./viewer";

export interface Lighting {
  /** 0 dim to 1 bright; 0.5 is as scanned. */
  brightness: number;
  /** 0 cool daylight to 1 warm amber; 0.5 is neutral. */
  warmth: number;
}

export const defaultLighting: Lighting = { brightness: 0.5, warmth: 0.5 };

const cool = new THREE.Color(0.86, 0.93, 1.08), neutral = new THREE.Color(1, 1, 1), warm = new THREE.Color(1.12, 0.92, 0.68);

/**
 * Room-wide light, as the phone's set_lighting does it: brightness scales
 * the scan's colours and the lights on furniture, and warmth tints both
 * between daylight and amber.
 */
export function applyLighting(viewer: Viewer, { brightness, warmth }: Lighting) {
  const b = THREE.MathUtils.clamp(brightness, 0, 1), w = THREE.MathUtils.clamp(warmth, 0, 1);
  const tint = w < 0.5 ? cool.clone().lerp(neutral, w * 2) : neutral.clone().lerp(warm, (w - 0.5) * 2);
  const exposure = 0.35 + 1.3 * b;
  scanLighting.uExposure.value = exposure;
  scanLighting.uTint.value.copy(tint);
  viewer.sky.intensity = 1.2 * exposure;
  viewer.sun.intensity = 1.4 * exposure;
  viewer.sky.color.copy(tint);
  viewer.sun.color.copy(tint);
  viewer.scene.environmentIntensity = 0.6 * exposure;
}
