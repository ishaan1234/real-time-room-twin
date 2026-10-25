import * as THREE from "three";
import type { Piece } from "../scene/furniture";
import { poseOf, type Pose } from "../scene/undo";
import type { Viewer } from "../scene/viewer";
import { Hud, type HudButton } from "./hud";

interface Hand {
  index: number;
  ray: THREE.XRTargetRaySpace;
  grip: THREE.XRGripSpace;
  laser: THREE.Line;
  reticle: THREE.Mesh;
  source?: XRInputSource;
  /** Buttons pressed last frame, for presses and releases. */
  was: boolean[];
  grabbing?: { piece: Piece; plane: THREE.Plane; offset: THREE.Vector3; before: Pose };
  gliding: boolean;
  aiming: boolean;
  /** Whether the stick was pushed sideways last frame, so a snap turn happens once per push. */
  turned: boolean;
}

/** What VR asks of the rest of the app. */
export interface VRActions {
  /** A piece was let go after being carried, with where it was before (for undo). */
  moved?(piece: Piece, before: Pose): void;
  talk(): void;
  isTalking(): boolean;
  caption(): string;
  status(): string;
}

// WebXR's standard gamepad mapping.
const TRIGGER = 0, SQUEEZE = 1, BUTTON_A = 4, BUTTON_B = 5;

/**
 * Touring the room in a headset, through WebXR: Chrome and Edge hand it to
 * the active OpenXR runtime, here SteamVR, which runs the PSVR through
 * iVRy. Controllers vary (PS Move wands under iVRy have no thumbstick, and
 * SteamVR may remap their buttons), so everything works with just a
 * trigger, and anything else a controller has is a shortcut:
 *
 * - Point and hold the trigger to glide that way; pull it on a piece of
 *   furniture to grab it and slide it round the floor.
 * - Hold the grip (the Move button) to aim a teleport arc; let go to jump there.
 * - Thumbstick or touchpad: move, and push sideways to snap-turn.
 * - The panel below your view has Talk, Turn, Higher/Lower and Exit, and shows
 *   which buttons are pressed.
 * - On the laptop, WASD/arrows walk and Q/E turn, in VR too.
 */
export class VR {
  hud = new Hud();
  /** How far above the floor the rig is raised, to fix a floor the tracking gets wrong. */
  heightOffset = 0;
  onDebug?: (lines: string[]) => void;
  onSessionChange?: (inVR: boolean) => void;
  private hands: Hand[] = [];
  private raycaster = new THREE.Raycaster();
  private arc: THREE.Line;
  private target: THREE.Mesh;
  private landing: THREE.Vector3 | null = null;
  private hudYaw = 0;
  private modeBefore: "orbit" | "walk" = "orbit";

  constructor(private viewer: Viewer, private actions: VRActions) {
    const { renderer, rig } = viewer;
    for (let index = 0; index < 2; index++) {
      const hand = this.buildHand(index);
      hand.ray.addEventListener("connected", (event) => (hand.source = event.data));
      hand.ray.addEventListener("disconnected", () => (hand.source = undefined));
      rig.add(hand.ray, hand.grip);
      this.hands.push(hand);
    }
    this.arc = new THREE.Line(new THREE.BufferGeometry().setFromPoints(new Array(48).fill(new THREE.Vector3())),
      new THREE.LineBasicMaterial({ color: 0x30d158 }));
    this.arc.frustumCulled = false;
    this.target = new THREE.Mesh(new THREE.RingGeometry(0.18, 0.25, 40).rotateX(-Math.PI / 2),
      new THREE.MeshBasicMaterial({ color: 0x30d158, side: THREE.DoubleSide }));
    this.arc.visible = this.target.visible = false;
    viewer.scene.add(this.arc, this.target);
    this.hud.mesh.visible = false;
    rig.add(this.hud.mesh);

    renderer.xr.addEventListener("sessionstart", () => this.started());
    renderer.xr.addEventListener("sessionend", () => this.ended());
    viewer.onFrame.push((dt) => this.viewer.inVR && this.frame(dt));
  }

  static async isSupported() {
    return Boolean(await navigator.xr?.isSessionSupported("immersive-vr").catch(() => false));
  }

  async enter() {
    if (!navigator.xr) throw new Error("This browser has no WebXR. Use Chrome or Edge, with SteamVR running.");
    const session = await navigator.xr.requestSession("immersive-vr", { optionalFeatures: ["local-floor", "bounded-floor"] });
    // Seated or 3DoF setups may have no floor; then the view starts at standing height above it.
    let floor = true;
    try {
      await session.requestReferenceSpace("local-floor");
    } catch {
      floor = false;
    }
    this.viewer.renderer.xr.setReferenceSpaceType(floor ? "local-floor" : "local");
    this.heightOffset = floor ? 0 : this.viewer.eyeHeight;
    await this.viewer.renderer.xr.setSession(session);
  }

  exit() {
    this.viewer.renderer.xr.getSession()?.end();
  }

  private started() {
    this.modeBefore = this.viewer.mode;
    this.viewer.setMode("walk");
    this.viewer.rig.position.y = (this.viewer.room?.floorY ?? 0) + this.heightOffset;
    this.hud.mesh.visible = true;
    this.hudYaw = Number.NaN;
    this.onSessionChange?.(true);
  }

  private ended() {
    for (const hand of this.hands) this.release(hand);
    this.arc.visible = this.target.visible = false;
    this.hud.mesh.visible = false;
    this.viewer.rig.position.y = this.viewer.room?.floorY ?? 0;
    this.viewer.resetWalkCamera();
    this.viewer.setMode(this.modeBefore);
    this.onSessionChange?.(false);
    // The canvas was sized for the headset; size it for the window again.
    dispatchEvent(new Event("resize"));
  }

  private frame(dt: number) {
    const viewer = this.viewer;
    viewer.rig.position.y = (viewer.room?.floorY ?? 0) + this.heightOffset;
    const head = viewer.walkCamera.getWorldPosition(new THREE.Vector3());
    const yaw = viewer.heading();
    const drift = Math.abs(THREE.MathUtils.euclideanModulo(yaw - this.hudYaw + Math.PI, 2 * Math.PI) - Math.PI);
    if (!(drift < 0.95)) {
      this.hudYaw = yaw;
      this.hud.place(head, yaw, viewer.rig);
    }

    const connected = this.hands.filter((hand) => hand.source?.gamepad);
    let hovered: string | null = null;
    for (const hand of connected) {
      const buttons = hand.source!.gamepad!.buttons.map((b) => Boolean(b?.pressed));
      const pressed = (i: number) => buttons[i] && !hand.was[i];
      const released = (i: number) => !buttons[i] && hand.was[i];
      const hit = this.point(hand);

      if (hit.button) hovered = hit.button;
      if (pressed(TRIGGER)) {
        if (hit.button) this.press(hit.button);
        else if (hit.piece) this.grab(hand, hit.piece);
        else hand.gliding = true;
      }
      if (released(TRIGGER)) {
        this.release(hand);
        hand.gliding = false;
      }
      if (hand.gliding) this.glide(hand, dt, hand.source!.gamepad!.buttons[TRIGGER]?.value || 1);
      if (hand.grabbing) this.drag(hand, dt);

      if (buttons[SQUEEZE]) {
        hand.aiming = true;
        this.aim(hand);
      } else if (hand.aiming) {
        hand.aiming = false;
        this.jump();
      }
      if (pressed(BUTTON_A)) this.actions.talk();
      if (pressed(BUTTON_B)) this.hudYaw = Number.NaN;
      if (!hand.grabbing) this.stick(hand, connected.length, dt);
      hand.was = buttons;
    }
    if (!connected.some((hand) => hand.aiming)) this.arc.visible = this.target.visible = false;

    this.hud.hover(hovered);
    this.hud.setButtons(this.buttons());
    const status = [
      this.actions.status(),
      connected.length ? "Trigger: glide / grab · Grip: teleport · Stick: move & turn" : "No controllers yet: WASD + Q/E on the laptop",
      ...this.debugLines(connected),
    ];
    this.hud.setText(status, this.actions.caption());
    this.hud.draw();
    this.onDebug?.(this.debugLines(connected));
  }

  private buttons(): HudButton[] {
    return [
      { id: "talk", label: this.actions.isTalking() ? "Hang up" : "Talk", active: this.actions.isTalking() },
      { id: "left", label: "⟲ Turn" },
      { id: "right", label: "Turn ⟳" },
      { id: "exit", label: "Exit VR" },
      { id: "up", label: "Higher" },
      { id: "down", label: "Lower" },
      { id: "centre", label: "To middle" },
      { id: "recenter", label: "Panel here" },
    ];
  }

  private press(id: string) {
    switch (id) {
      case "talk": this.actions.talk(); break;
      case "left": this.viewer.turn(Math.PI / 6); break;
      case "right": this.viewer.turn(-Math.PI / 6); break;
      case "up": this.heightOffset += 0.1; break;
      case "down": this.heightOffset -= 0.1; break;
      case "centre": {
        const start = this.viewer.room?.start;
        if (start) this.viewer.teleport(start.x, start.z);
        break;
      }
      case "recenter": this.hudYaw = Number.NaN; break;
      case "exit": this.exit(); break;
    }
  }

  /** What the hand's laser points at: a panel button, a piece of furniture, or a surface; and draws the laser to it. */
  private point(hand: Hand): { button?: string; piece?: Piece; distance: number } {
    const matrix = hand.ray.matrixWorld;
    const origin = new THREE.Vector3().setFromMatrixPosition(matrix);
    const direction = new THREE.Vector3(0, 0, -1).transformDirection(matrix);
    this.raycaster.set(origin, direction);
    this.raycaster.far = 20;
    let distance = 5;
    let result: { button?: string; piece?: Piece; distance: number } = { distance };
    const panel = this.hud.mesh.visible ? this.raycaster.intersectObject(this.hud.mesh)[0] : undefined;
    const furniture = this.viewer.furniture;
    const piece = furniture && !hand.grabbing ? furniture.pieceAt(this.raycaster) : null;
    const pieceDistance = piece ? this.raycaster.intersectObject(piece, true)[0]?.distance ?? Infinity : Infinity;
    const surface = this.viewer.room ? this.raycaster.intersectObjects(this.viewer.room.solids, false)[0] : undefined;
    if (panel?.uv && panel.distance < pieceDistance) {
      distance = panel.distance;
      result = { button: this.hud.buttonAt(panel.uv) ?? undefined, distance };
    } else if (piece && pieceDistance < (surface?.distance ?? Infinity)) {
      distance = pieceDistance;
      result = { piece, distance };
    } else if (surface) {
      distance = surface.distance;
      result = { distance };
    }
    hand.laser.scale.z = distance;
    (hand.laser.material as THREE.LineBasicMaterial).color.set(result.piece ? 0xffcc00 : result.button ? 0x0a84ff : 0xffffff);
    hand.reticle.position.set(0, 0, -distance);
    hand.reticle.visible = distance < 20;
    return result;
  }

  private grab(hand: Hand, piece: Piece) {
    const plane = new THREE.Plane(new THREE.Vector3(0, 1, 0), -piece.position.y);
    const hit = this.raycaster.ray.intersectPlane(plane, new THREE.Vector3());
    hand.grabbing = { piece, plane, offset: hit ? piece.position.clone().sub(hit) : new THREE.Vector3(), before: poseOf(piece) };
  }

  private drag(hand: Hand, dt: number) {
    const { piece, plane, offset } = hand.grabbing!;
    const matrix = hand.ray.matrixWorld;
    const ray = new THREE.Ray(new THREE.Vector3().setFromMatrixPosition(matrix),
      new THREE.Vector3(0, 0, -1).transformDirection(matrix));
    const hit = ray.intersectPlane(plane, new THREE.Vector3());
    // Pointing above the horizon: keep it where it is rather than flinging it away.
    const furniture = this.viewer.furniture;
    if (hit && hit.distanceTo(ray.origin) < 12 && furniture) {
      furniture.slide(piece, hit.x + offset.x - piece.position.x, hit.z + offset.z - piece.position.z);
    }
    // The stick turns what you're holding, unless that would turn it into something.
    const [x] = this.axes(hand);
    if (Math.abs(x) > 0.25) {
      if (furniture) furniture.tryChange(piece, () => (piece.rotation.y -= x * 2 * dt));
      else piece.rotation.y -= x * 2 * dt;
    }
  }

  private release(hand: Hand) {
    if (hand.grabbing) {
      this.actions.moved?.(hand.grabbing.piece, hand.grabbing.before);
      hand.grabbing = undefined;
      this.viewer.furniture?.onChange?.();
    }
  }

  /** Moves the rig level along where the hand points. */
  private glide(hand: Hand, dt: number, amount: number) {
    const direction = new THREE.Vector3(0, 0, -1).transformDirection(hand.ray.matrixWorld);
    direction.y = 0;
    if (direction.lengthSq() < 1e-4) return;
    direction.normalize().multiplyScalar(this.viewer.walkSpeed * amount * dt);
    this.viewer.moveBy(direction.x, direction.z);
  }

  /** Thumbstick or touchpad: one hand moves, the other turns; with one controller, up/down moves and sideways turns. */
  private stick(hand: Hand, handCount: number, dt: number) {
    const [x, y] = this.axes(hand);
    const turns = handCount === 1 || hand.source?.handedness === "right";
    const moves = handCount === 1 || hand.source?.handedness !== "right";
    if (turns) {
      if (Math.abs(x) > 0.6 && !hand.turned) this.viewer.turn(-Math.sign(x) * Math.PI / 6);
      hand.turned = Math.abs(x) > 0.6;
    }
    if (moves && (Math.abs(y) > 0.25 || (!turns && Math.abs(x) > 0.25))) {
      const heading = this.viewer.heading();
      const forward = -y, strafe = turns ? 0 : x;
      const speed = this.viewer.walkSpeed * dt;
      this.viewer.moveBy((-Math.sin(heading) * forward + Math.cos(heading) * strafe) * speed,
        (-Math.cos(heading) * forward - Math.sin(heading) * strafe) * speed);
    }
  }

  /** The thumbstick if the controller has one in use, else the touchpad. */
  private axes(hand: Hand): [number, number] {
    const a = hand.source?.gamepad?.axes ?? [];
    const stick: [number, number] = [a[2] ?? 0, a[3] ?? 0], pad: [number, number] = [a[0] ?? 0, a[1] ?? 0];
    return Math.hypot(...stick) >= Math.hypot(...pad) ? stick : pad;
  }

  /** Draws the teleport arc from the hand and finds where it lands on the floor. */
  private aim(hand: Hand) {
    const room = this.viewer.room;
    if (!room) return;
    const matrix = hand.ray.matrixWorld;
    const origin = new THREE.Vector3().setFromMatrixPosition(matrix);
    const velocity = new THREE.Vector3(0, 0, -1).transformDirection(matrix).multiplyScalar(6);
    const points: THREE.Vector3[] = [];
    this.landing = null;
    for (let i = 0; i < 48; i++) {
      const t = i * 0.04;
      const point = origin.clone().addScaledVector(velocity, t);
      point.y -= 4.9 * t * t;
      if (point.y <= room.floorY) {
        point.y = room.floorY;
        points.push(point);
        this.landing = room.floorPlan.isBlocked([point.x, point.z]) || this.viewer.furniture?.blocksWalker([point.x, point.z]) ? null : point;
        break;
      }
      points.push(point);
    }
    while (points.length < 48) points.push(points[points.length - 1]);
    this.arc.geometry.setFromPoints(points);
    const color = this.landing ? 0x30d158 : 0xff453a;
    (this.arc.material as THREE.LineBasicMaterial).color.set(color);
    this.arc.visible = true;
    this.target.visible = Boolean(this.landing);
    if (this.landing) this.target.position.copy(this.landing).setY(room.floorY + 0.01);
  }

  private jump() {
    if (this.landing) this.viewer.teleport(this.landing.x, this.landing.z);
    this.landing = null;
    this.arc.visible = this.target.visible = false;
  }

  private debugLines(hands: Hand[]): string[] {
    return hands.map((hand) => {
      const gamepad = hand.source!.gamepad!;
      const pressed = gamepad.buttons.flatMap((b, i) => (b?.pressed ? [i] : []));
      const axes = gamepad.axes.map((v) => (v ?? 0).toFixed(1)).join(" ");
      return `${hand.source!.handedness} ${hand.source!.profiles[0] ?? "?"}: buttons [${pressed.join(",")}] axes [${axes}]`;
    });
  }

  /** A laser and reticle on the pointing ray, and a PS Move–like wand on the grip. */
  private buildHand(index: number): Hand {
    const { renderer } = this.viewer;
    const ray = renderer.xr.getController(index);
    const grip = renderer.xr.getControllerGrip(index);
    const laser = new THREE.Line(new THREE.BufferGeometry().setFromPoints([new THREE.Vector3(), new THREE.Vector3(0, 0, -1)]),
      new THREE.LineBasicMaterial({ color: 0xffffff, transparent: true, opacity: 0.8 }));
    const reticle = new THREE.Mesh(new THREE.SphereGeometry(0.012, 12, 8), new THREE.MeshBasicMaterial({ color: 0xffffff }));
    ray.add(laser, reticle);
    const wand = new THREE.Group();
    const handle = new THREE.Mesh(new THREE.CylinderGeometry(0.02, 0.018, 0.18, 20),
      new THREE.MeshStandardMaterial({ color: 0xf2f2f2, roughness: 0.4 }));
    handle.rotation.x = Math.PI / 2;
    handle.position.z = 0.03;
    const orb = new THREE.Mesh(new THREE.SphereGeometry(0.024, 20, 14),
      new THREE.MeshBasicMaterial({ color: index === 0 ? 0xff375f : 0x64d2ff }));
    orb.position.z = -0.07;
    wand.add(handle, orb);
    grip.add(wand);
    return { index, ray, grip, laser, reticle, was: [], gliding: false, aiming: false, turned: false };
  }
}
