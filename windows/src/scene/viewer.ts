import * as THREE from "three";
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js";
import { RoomEnvironment } from "three/examples/jsm/environments/RoomEnvironment.js";
import type { Room } from "../room/room";
import { Furniture } from "./furniture";

export type Mode = "orbit" | "walk";

/**
 * The 3D view. Two ways to look, as on the phone: Orbit circles the room
 * like a dollhouse (the near walls and ceiling drop away), and Walk puts you
 * inside at standing height. Walking moves the `rig`, a group at your feet
 * holding the walking camera; in VR the headset drives that camera inside
 * the same rig, so moving the rig moves you in VR too.
 */
export class Viewer {
  readonly renderer: THREE.WebGLRenderer;
  readonly scene = new THREE.Scene();
  /** At the walker's feet, turned to their heading. */
  readonly rig = new THREE.Group();
  readonly walkCamera = new THREE.PerspectiveCamera(75, 1, 0.05, 200);
  readonly orbitCamera = new THREE.PerspectiveCamera(50, 1, 0.05, 500);
  readonly controls: OrbitControls;
  readonly sky = new THREE.HemisphereLight(0xffffff, 0x444444, 1.2);
  readonly sun = new THREE.DirectionalLight(0xffffff, 1.4);
  room?: Room;
  furniture?: Furniture;
  mode: Mode = "orbit";
  /** Metres per second at walking pace; Shift doubles it. */
  walkSpeed = 1.4;
  eyeHeight = 1.6;
  /** Walk through walls and furniture instead of stopping at them. */
  ghost = false;
  /** Pieces stop at the scan and at each other when moved, turned or resized by hand. */
  collisions = true;
  /** Called every frame with the seconds since the last, before rendering. */
  readonly onFrame: ((dt: number, frame?: XRFrame) => void)[] = [];
  onModeChange?: (mode: Mode) => void;
  /** Pixels of the view covered by the sidebar on the left: the cameras centre on the rest. */
  insetLeft = 0;

  private pitch = 0;
  private keys = new Set<string>();
  private marker = new THREE.Group();
  private glow = makeGlow();
  private last = performance.now();

  constructor(readonly container: HTMLElement) {
    this.renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
    this.renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
    this.renderer.outputColorSpace = THREE.SRGBColorSpace;
    this.renderer.toneMapping = THREE.NeutralToneMapping;
    this.renderer.xr.enabled = true;
    this.renderer.xr.setReferenceSpaceType("local-floor");
    container.appendChild(this.renderer.domElement);
    this.renderer.domElement.classList.add("block", "h-full", "w-full", "outline-none");
    this.renderer.domElement.tabIndex = 0;

    // Clear, so the page's backdrop shows round the room (VR puts a colour back).
    this.scene.background = null;
    const environment = new THREE.PMREMGenerator(this.renderer);
    this.scene.environment = environment.fromScene(new RoomEnvironment(), 0.04).texture;
    this.scene.environmentIntensity = 0.6;
    this.sun.position.set(1, 3, 0.6);
    this.scene.add(this.sky, this.sun, this.glow);

    this.walkCamera.position.y = this.eyeHeight;
    this.rig.add(this.walkCamera);
    this.scene.add(this.rig);
    buildMarker(this.marker);
    this.rig.add(this.marker);
    this.scene.add(this.orbitCamera);

    this.controls = new OrbitControls(this.orbitCamera, this.renderer.domElement);
    this.controls.enableDamping = true;
    this.controls.screenSpacePanning = true;
    this.controls.maxPolarAngle = Math.PI * 0.95;

    new ResizeObserver(() => this.resize()).observe(container);
    this.resize();
    addEventListener("keydown", (event) => {
      if (isTyping(event)) return;
      this.keys.add(event.code);
    });
    addEventListener("keyup", (event) => this.keys.delete(event.code));
    addEventListener("blur", () => this.keys.clear());
    this.renderer.setAnimationLoop((_, frame) => this.frame(frame));
  }

  /** The camera the desktop shows. */
  get camera(): THREE.PerspectiveCamera {
    return this.mode === "walk" || this.inVR ? this.walkCamera : this.orbitCamera;
  }

  get inVR() {
    return this.renderer.xr.isPresenting;
  }

  /** Whether the user is standing in the room, for placement. */
  get isInside() {
    return this.mode === "walk" || this.inVR;
  }

  setRoom(room: Room) {
    if (this.room) {
      this.scene.remove(this.room.group);
      this.room.dispose();
    }
    if (this.furniture) this.scene.remove(this.furniture.group);
    this.room = room;
    this.scene.add(room.group);
    this.furniture = new Furniture(room, () => this.camera, () => this.isInside, () => this.collisions);
    this.scene.add(this.furniture.group);

    // Walking starts in the middle of the room.
    const start = room.start;
    this.rig.position.set(start.x, room.floorY, start.z);
    this.rig.rotation.y = 0;
    this.pitch = 0;
    this.applyLook();

    // The orbit camera sits back and above, far enough to fit the room.
    const { lo, hi } = room.bounds;
    const target = room.centre;
    const radius = Math.max(Math.hypot(hi[0] - lo[0], hi[2] - lo[2]) / 2, 1);
    const distance = (1.35 * radius) / Math.tan(THREE.MathUtils.degToRad(25));
    // A soft glow on the "ground" the room stands on.
    this.glow.position.set(target.x, room.floorY - 0.02, target.z);
    this.glow.scale.setScalar(radius * 4.5);
    const elevation = 0.9;
    this.orbitCamera.position.copy(target).add(
      new THREE.Vector3(0, Math.sin(elevation), Math.cos(elevation)).multiplyScalar(distance));
    this.controls.target.copy(target);
    this.controls.maxDistance = distance * 4;
    this.controls.update();
    this.setMode("orbit");
  }

  setMode(mode: Mode) {
    this.mode = mode;
    this.marker.visible = mode === "orbit";
    this.controls.enabled = mode === "orbit";
    this.keys.clear();
    this.onModeChange?.(mode);
  }

  /** Turns the walking view by a mouse drag, in pixels. */
  look(dx: number, dy: number) {
    const radiansPerPixel = 0.004;
    this.rig.rotation.y -= dx * radiansPerPixel;
    this.pitch = THREE.MathUtils.clamp(this.pitch - dy * radiansPerPixel, -1.2, 1.2);
    this.applyLook();
  }

  /** Moves the walker by a level offset in the world, stopping at walls unless ghosting. */
  moveBy(dx: number, dz: number) {
    const room = this.room, furniture = this.furniture;
    const from = this.rig.position;
    const plan = room && {
      isBlocked: (point: [number, number]) => room.floorPlan.isBlocked(point) || Boolean(furniture?.blocksWalker(point)),
    };
    if (this.ghost || !plan || plan.isBlocked([from.x, from.z])) {
      from.x += dx;
      from.z += dz;
      return;
    }
    // Slide along whatever is in the way.
    if (!plan.isBlocked([from.x + dx, from.z + dz])) {
      from.x += dx;
      from.z += dz;
    } else if (!plan.isBlocked([from.x + dx, from.z])) {
      from.x += dx;
    } else if (!plan.isBlocked([from.x, from.z + dz])) {
      from.z += dz;
    }
  }

  /** Puts the walker at a floor point. */
  teleport(x: number, z: number) {
    // In VR, the head may be off the rig's centre: land the head on the spot.
    const head = this.inVR ? this.walkCamera.getWorldPosition(new THREE.Vector3()).sub(this.rig.position) : new THREE.Vector3();
    this.rig.position.x = x - head.x;
    this.rig.position.z = z - head.z;
  }

  /** Turns the walker about their head (in VR) or the rig's centre. */
  turn(radians: number) {
    const head = this.walkCamera.getWorldPosition(new THREE.Vector3());
    this.rig.rotation.y += radians;
    this.rig.updateMatrixWorld(true);
    const moved = this.walkCamera.getWorldPosition(new THREE.Vector3());
    this.rig.position.x += head.x - moved.x;
    this.rig.position.z += head.z - moved.z;
  }

  /** Back to the view the camera had before VR: standing height, level. */
  resetWalkCamera() {
    this.walkCamera.position.set(0, this.eyeHeight, 0);
    this.applyLook();
  }

  private applyLook() {
    this.walkCamera.rotation.set(this.pitch, 0, 0);
  }

  private frame(frame?: XRFrame) {
    const now = performance.now();
    const dt = Math.min((now - this.last) / 1000, 0.1);
    this.last = now;
    if (this.isInside) this.walkWithKeys(dt);
    if (this.mode === "orbit" && !this.inVR) this.controls.update();
    for (const callback of this.onFrame) callback(dt, frame);
    this.furniture?.update(now);
    this.renderer.render(this.scene, this.camera);
  }

  /** WASD or the arrows to walk, Q and E to turn; also works in VR from the laptop. */
  private walkWithKeys(dt: number) {
    const k = this.keys;
    const forward = (k.has("KeyW") || k.has("ArrowUp") ? 1 : 0) - (k.has("KeyS") || k.has("ArrowDown") ? 1 : 0);
    const strafe = (k.has("KeyD") ? 1 : 0) - (k.has("KeyA") ? 1 : 0);
    const turn = (k.has("KeyQ") || k.has("ArrowLeft") ? 1 : 0) - (k.has("KeyE") || k.has("ArrowRight") ? 1 : 0);
    if (turn) {
      if (this.inVR) this.turn(turn * 1.8 * dt);
      else this.rig.rotation.y += turn * 1.8 * dt;
    }
    if (!forward && !strafe) return;
    const heading = this.heading();
    const speed = this.walkSpeed * (k.has("ShiftLeft") || k.has("ShiftRight") ? 2 : 1) * dt;
    const dx = (-Math.sin(heading) * forward + Math.cos(heading) * strafe) * speed;
    const dz = (-Math.cos(heading) * forward - Math.sin(heading) * strafe) * speed;
    this.moveBy(dx, dz);
  }

  /** Which way the walker faces, as a turn about +y: the head's in VR, the rig's otherwise. */
  heading() {
    if (!this.inVR) return this.rig.rotation.y;
    const front = this.walkCamera.getWorldDirection(new THREE.Vector3());
    return Math.atan2(-front.x, -front.z);
  }

  /** Re-centres the cameras after the sidebar opens or closes. */
  setInset(pixels: number) {
    this.insetLeft = pixels;
    this.resize();
  }

  private resize() {
    const { clientWidth: width, clientHeight: height } = this.container;
    if (!width || !height || this.inVR) return;
    this.renderer.setSize(width, height, false);
    const inset = Math.min(this.insetLeft, width / 2);
    for (const camera of [this.walkCamera, this.orbitCamera]) {
      // As if the view were wider by the inset and cropped, so the centre sits in the open part.
      camera.aspect = (width + inset) / height;
      if (inset) camera.setViewOffset(width + inset, height, 0, 0, width, height);
      else camera.clearViewOffset();
      camera.updateProjectionMatrix();
    }
  }
}

/** An orange dot with a cone pointing the way the walker faces, seen when orbiting. */
function buildMarker(marker: THREE.Group) {
  const material = new THREE.MeshBasicMaterial({ color: 0xff9500 });
  const dot = new THREE.Mesh(new THREE.SphereGeometry(0.12, 24, 16), material);
  dot.position.y = 1.6;
  const cone = new THREE.Mesh(new THREE.ConeGeometry(0.09, 0.3, 24), material);
  cone.rotation.x = -Math.PI / 2;
  cone.position.set(0, 1.6, -0.22);
  marker.add(dot, cone);
}

function isTyping(event: KeyboardEvent) {
  const target = event.target as HTMLElement | null;
  return Boolean(target?.closest("input, textarea, select, [contenteditable]"));
}

/** A flat disc that fades from violet to nothing, under the room. */
function makeGlow() {
  const canvas = document.createElement("canvas");
  canvas.width = canvas.height = 256;
  const context = canvas.getContext("2d")!;
  const gradient = context.createRadialGradient(128, 128, 0, 128, 128, 128);
  gradient.addColorStop(0, "rgba(139,123,255,0.8)");
  gradient.addColorStop(0.35, "rgba(91,108,255,0.22)");
  gradient.addColorStop(0.7, "rgba(56,189,248,0.06)");
  gradient.addColorStop(1, "rgba(56,189,248,0)");
  context.fillStyle = gradient;
  context.fillRect(0, 0, 256, 256);
  const texture = new THREE.CanvasTexture(canvas);
  texture.colorSpace = THREE.SRGBColorSpace;
  const glow = new THREE.Mesh(new THREE.PlaneGeometry(1, 1),
    new THREE.MeshBasicMaterial({ map: texture, transparent: true, depthWrite: false, toneMapped: false }));
  glow.rotation.x = -Math.PI / 2;
  glow.renderOrder = -1;
  glow.raycast = () => {};
  return glow;
}
