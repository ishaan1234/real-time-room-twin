import * as THREE from "three";
import { TransformControls } from "three/examples/jsm/controls/TransformControls.js";
import { stretch, type Piece } from "./furniture";
import { poseOf, type Pose } from "./undo";
import type { Viewer } from "./viewer";

export type GizmoMode = "off" | "move" | "turn" | "stretch";

/**
 * Handles on the selected piece, as the phone's Blender-style gizmo has:
 * arrows to move it along an axis (up included), a ring to turn it, and
 * cubes to stretch it along one of its own axes (the middle one scales it
 * evenly). Stretching changes the model inside the piece, the way the phone
 * saves it. With collisions on, a handle stops where the piece would go
 * into something; `lockScale` keeps stretching even.
 */
export class Gizmo {
  mode: GizmoMode = "off";
  lockScale = false;
  /** Called when a handle is let go, with the piece and where it was before. */
  onRelease?: (piece: Piece, before: Pose) => void;
  readonly controls: TransformControls;
  private piece: Piece | null = null;
  private before?: Pose;
  private clearBefore?: { clear: boolean; inside: boolean };
  private valid?: Pose;
  private lastScale = new THREE.Vector3(1, 1, 1);

  constructor(private viewer: Viewer) {
    this.controls = new TransformControls(viewer.camera, viewer.renderer.domElement);
    this.controls.setSize(0.8);
    viewer.scene.add(this.controls.getHelper());
    this.controls.addEventListener("dragging-changed", (event) => {
      viewer.controls.enabled = !event.value && viewer.mode === "orbit";
    });
    this.controls.addEventListener("mouseDown", () => this.grabbed());
    this.controls.addEventListener("objectChange", () => this.changed());
    this.controls.addEventListener("mouseUp", () => this.released());
    viewer.onFrame.push(() => {
      // The view's camera changes between Orbit and Walk.
      if (this.controls.camera !== viewer.camera) this.controls.camera = viewer.camera;
      if (this.piece && !this.piece.parent) this.attach(null);
      this.controls.enabled = !viewer.inVR;
    });
  }

  /** Whether the pointer is over a handle, so a press there is the gizmo's. */
  get isHovered() {
    return this.mode !== "off" && this.controls.axis !== null && Boolean(this.controls.object);
  }

  setMode(mode: GizmoMode) {
    this.mode = mode;
    this.attach(this.piece);
  }

  attach(piece: Piece | null) {
    this.piece = piece;
    const target = piece && this.mode !== "off" ? (this.mode === "stretch" ? piece.children[0] : piece) : null;
    if (!target) {
      this.controls.detach();
      return;
    }
    this.controls.setMode(this.mode === "move" ? "translate" : this.mode === "turn" ? "rotate" : "scale");
    // Turning is about the vertical only; stretching is along the piece's own axes.
    this.controls.setSpace(this.mode === "move" ? "world" : "local");
    this.controls.showX = this.mode !== "turn";
    this.controls.showZ = this.mode !== "turn";
    this.controls.showY = true;
    this.controls.attach(target);
  }

  private grabbed() {
    const piece = this.piece, furniture = this.viewer.furniture;
    if (!piece || !furniture) return;
    this.before = poseOf(piece);
    this.valid = poseOf(piece);
    this.lastScale.copy(piece.children[0]?.scale ?? new THREE.Vector3(1, 1, 1));
    this.clearBefore = furniture.clearance(piece);
  }

  private changed() {
    const piece = this.piece, furniture = this.viewer.furniture, room = this.viewer.room;
    if (!piece || !furniture || !room || !this.valid) return;
    if (this.mode === "stretch") {
      const model = piece.children[0];
      const scale = model.scale;
      if (this.lockScale) {
        // Even: whichever handle moved most sets all three.
        const ratios = [scale.x / this.lastScale.x, scale.y / this.lastScale.y, scale.z / this.lastScale.z];
        const ratio = ratios.reduce((a, b) => (Math.abs(b - 1) > Math.abs(a - 1) ? b : a), 1);
        scale.copy(this.lastScale).multiplyScalar(ratio);
      }
      scale.set(Math.max(scale.x, 0.05), Math.max(scale.y, 0.05), Math.max(scale.z, 0.05));
      stretch(piece, scale.toArray());
      this.lastScale.copy(scale);
    }
    if (this.mode === "turn") {
      // Only the heading: a tilted piece doesn't stand.
      piece.rotation.set(0, piece.rotation.y, 0);
    }
    // Never below the floor.
    const bottom = furniture.span(piece)[0];
    if (bottom < room.floorY) piece.position.y += room.floorY - bottom;
    if (this.clearBefore && furniture.worsened(piece, this.clearBefore)) {
      const { position, yaw, scale, modelScale } = this.valid;
      piece.position.copy(position);
      piece.rotation.y = yaw;
      piece.scale.setScalar(scale);
      if (this.mode === "stretch") {
        stretch(piece, modelScale.toArray());
        this.lastScale.copy(modelScale);
      }
    } else {
      this.valid = poseOf(piece);
    }
  }

  private released() {
    if (this.piece && this.before) this.onRelease?.(this.piece, this.before);
    this.before = undefined;
  }
}
