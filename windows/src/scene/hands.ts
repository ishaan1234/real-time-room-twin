import * as THREE from "three";
import { FilesetResolver, HandLandmarker } from "@mediapipe/tasks-vision";
import type { Editor } from "./editor";
import type { Viewer } from "./viewer";

const model = "https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/1/hand_landmarker.task";
// MediaPipe's hand points.
const WRIST = 0, THUMB_TIP = 4, INDEX_TIP = 8, MIDDLE_BASE = 9;

/**
 * Moving furniture with a hand in front of the webcam, as the phone's Hand
 * Tracking does with its camera: the index fingertip steers a cursor over
 * the view; pinch thumb and finger on a piece to grab it, move the hand to
 * carry it (with the same collisions, snapping and undo as the mouse), and
 * open the pinch to let go. It runs on this computer (MediaPipe), up to 15
 * times a second. As on the phone, a pinch is measured against the palm's
 * size, has to show in two frames running, and opens wider to let go than
 * to grab; a hand lost for a moment is waited for, then the piece is let go
 * where it was.
 */
export class Hands {
  isOn = false;
  onChange?: () => void;
  private landmarker?: HandLandmarker;
  private stream?: MediaStream;
  private readonly video = document.createElement("video");
  private readonly cursor: HTMLDivElement;
  private last = 0;
  private pinchFrames = 0;
  private grabbing = false;
  private lostSince = 0;
  private point = new THREE.Vector2();

  constructor(private viewer: Viewer, private editor: Editor, private preview: HTMLElement) {
    this.video.muted = true;
    this.video.playsInline = true;
    this.video.className = "h-full w-full -scale-x-100 object-cover";
    this.cursor = document.createElement("div");
    this.cursor.className = "pointer-events-none absolute z-10 hidden size-6 -translate-x-1/2 -translate-y-1/2 rounded-full border-2 border-white bg-blue-500/50 shadow";
    viewer.renderer.domElement.parentElement!.appendChild(this.cursor);
    viewer.onFrame.push(() => this.frame());
  }

  async toggle() {
    if (this.isOn) this.stop();
    else await this.start();
  }

  async start() {
    if (this.isOn) return;
    this.stream = await navigator.mediaDevices.getUserMedia({ video: { width: 640, height: 480 } });
    this.video.srcObject = this.stream;
    await this.video.play();
    if (!this.landmarker) {
      let files;
      try {
        files = await FilesetResolver.forVisionTasks("/node_modules/@mediapipe/tasks-vision/wasm");
      } catch {
        files = await FilesetResolver.forVisionTasks("https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@1.1.1/wasm");
      }
      this.landmarker = await HandLandmarker.createFromOptions(files, {
        baseOptions: { modelAssetPath: model, delegate: "GPU" },
        runningMode: "VIDEO",
        numHands: 1,
      });
    }
    this.preview.replaceChildren(this.video);
    this.preview.classList.remove("hidden");
    this.isOn = true;
    this.onChange?.();
  }

  stop() {
    this.release();
    this.stream?.getTracks().forEach((track) => track.stop());
    this.stream = undefined;
    this.preview.classList.add("hidden");
    this.cursor.classList.add("hidden");
    this.isOn = false;
    this.onChange?.();
  }

  private frame() {
    if (!this.isOn || !this.landmarker || this.video.readyState < 2) return;
    const now = performance.now();
    if (now - this.last < 1000 / 15) return;
    this.last = now;
    const hand = this.landmarker.detectForVideo(this.video, now).landmarks?.[0];
    if (!hand) {
      // Lost for a moment: wait; for longer, let go where it is.
      this.lostSince ||= now;
      if (now - this.lostSince > 600) {
        this.release();
        this.cursor.classList.add("hidden");
      }
      return;
    }
    this.lostSince = 0;
    // The view is mirrored, like a mirror: moving the hand right moves the cursor right.
    const tip = hand[INDEX_TIP];
    const x = 1 - tip.x, y = tip.y;
    // The middle of the camera's view covers the whole screen, so the hand needn't reach the edges.
    const sx = THREE.MathUtils.clamp((x - 0.5) * 1.6 + 0.5, 0, 1), sy = THREE.MathUtils.clamp((y - 0.5) * 1.6 + 0.5, 0, 1);
    this.point.set(sx * 2 - 1, -(sy * 2 - 1));
    const rect = this.viewer.renderer.domElement.getBoundingClientRect();
    this.cursor.style.left = `${sx * rect.width}px`;
    this.cursor.style.top = `${sy * rect.height}px`;
    this.cursor.classList.remove("hidden");

    const palm = distance(hand[WRIST], hand[MIDDLE_BASE]) || 1;
    const pinch = distance(hand[THUMB_TIP], hand[INDEX_TIP]) / palm;
    if (!this.grabbing) {
      this.pinchFrames = pinch < 0.3 ? this.pinchFrames + 1 : 0;
      const over = this.editor.pieceUnder(this.point);
      this.cursor.classList.toggle("bg-amber-400/70", Boolean(over));
      if (this.pinchFrames >= 2 && over) {
        this.grabbing = Boolean(this.editor.grabAt(this.point));
        this.pinchFrames = 0;
      }
    } else if (pinch > 0.5) {
      this.release();
    } else {
      this.editor.dragTo(this.point);
    }
    this.cursor.classList.toggle("scale-75", this.grabbing);
    this.cursor.classList.toggle("bg-green-500/70", this.grabbing);
  }

  private release() {
    if (!this.grabbing) return;
    this.grabbing = false;
    this.editor.letGo();
  }
}

function distance(a: { x: number; y: number; z: number }, b: { x: number; y: number; z: number }) {
  return Math.hypot(a.x - b.x, a.y - b.y, a.z - b.z);
}
