import * as THREE from "three";
import type { Piece } from "./furniture";
import { Gizmo } from "./gizmo";
import { poseOf, Undo, type Pose } from "./undo";
import type { Viewer } from "./viewer";

/**
 * Moving furniture with the mouse. Click a piece to select it and drag it
 * across the floor (or across whatever it stands on). Dragging empty space
 * orbits in Orbit mode and looks round in Walk mode. With a piece selected:
 * R / Shift+R turns it 15°, [ and ] scale it, PageUp / PageDown raise and
 * lower it, Ctrl+D duplicates it and Delete removes it; Ctrl+Z undoes and
 * Ctrl+Shift+Z (or Ctrl+Y) redoes. The gizmo adds handles to move, turn and
 * stretch it. Unless collisions are off (Layout tab), a piece stops at walls
 * and at other pieces, slides along them when dragged, and lands on whatever
 * is below when lowered. With snapping on, a piece let go near a wall backs
 * onto it, and anything else drops onto what's under it.
 */
export class Editor {
  selected: Piece | null = null;
  onSelect?: (piece: Piece | null) => void;
  /** Says why a change didn't happen, like no room to turn. */
  onRefuse?: (message: string) => void;
  readonly undo: Undo;
  readonly gizmo: Gizmo;
  /** Snap pieces to walls and onto what's below when they're let go. */
  snapping = false;
  private outline = new THREE.BoxHelper(new THREE.Object3D(), 0xffcc00);
  private raycaster = new THREE.Raycaster();
  private drag?: { piece: Piece; plane: THREE.Plane; offset: THREE.Vector3; moved: boolean; before: Pose };
  private looking?: { x: number; y: number };
  private down?: { x: number; y: number };

  constructor(private viewer: Viewer) {
    this.undo = new Undo(() => viewer.furniture);
    this.gizmo = new Gizmo(viewer);
    this.gizmo.onRelease = (piece, before) => this.finish(piece, before);
    this.outline.visible = false;
    (this.outline.material as THREE.LineBasicMaterial).depthTest = false;
    this.outline.renderOrder = 10;
    viewer.scene.add(this.outline);
    const canvas = viewer.renderer.domElement;
    // Capture, so a press on a piece is ours before the orbit controls see it.
    canvas.addEventListener("pointerdown", (event) => this.pointerDown(event), { capture: true });
    canvas.addEventListener("pointermove", (event) => this.pointerMove(event));
    canvas.addEventListener("pointerup", (event) => this.pointerUp(event));
    canvas.addEventListener("pointercancel", (event) => this.pointerUp(event));
    canvas.addEventListener("contextmenu", (event) => event.preventDefault());
    addEventListener("keydown", (event) => this.key(event));
    viewer.onFrame.push(() => {
      if (this.selected && !this.selected.parent) this.select(null);
      if (this.selected) this.outline.setFromObject(this.selected);
    });
  }

  select(piece: Piece | null) {
    this.selected = piece;
    this.outline.visible = Boolean(piece);
    if (piece) this.outline.setFromObject(piece);
    this.gizmo.attach(piece);
    this.onSelect?.(piece);
  }

  undoLast() {
    const piece = this.undo.undo();
    this.select(piece);
  }

  redoLast() {
    const piece = this.undo.redo();
    this.select(piece);
  }

  /** Turns the selected piece about its centre. */
  rotate(degrees: number) {
    const piece = this.selected;
    if (!piece) return;
    this.change(() => (piece.rotation.y += THREE.MathUtils.degToRad(degrees)), "turn");
  }

  scaleBy(factor: number) {
    if (!this.selected) return;
    this.setScale(this.selected.scale.x * factor);
  }

  setScale(scale: number) {
    const piece = this.selected;
    if (!piece) return;
    this.change(() => piece.scale.setScalar(THREE.MathUtils.clamp(scale, 0.1, 10)), "grow");
  }

  raise(metres: number) {
    const piece = this.selected, furniture = this.viewer.furniture;
    if (!piece || !furniture) return;
    const before = poseOf(piece);
    furniture.lift(piece, metres);
    this.undo.moved(piece, before);
    this.changed();
  }

  /** Lowers the selected piece until it lands on the floor or on whatever is under it. */
  dropToFloor() {
    const piece = this.selected, furniture = this.viewer.furniture;
    if (!piece || !furniture) return;
    const before = poseOf(piece);
    furniture.lift(piece, -100);
    this.undo.moved(piece, before);
    this.changed();
  }

  duplicate() {
    const furniture = this.viewer.furniture, piece = this.selected;
    if (!furniture || !piece) return;
    const model = piece.children[0].clone();
    // Beside it, to its right.
    const right = new THREE.Vector3(1, 0, 0).applyAxisAngle(new THREE.Vector3(0, 1, 0), piece.rotation.y);
    const width = (piece.userData.box.max.x - piece.userData.box.min.x) * piece.scale.x;
    const copy = furniture.add(model, { ...piece.userData, box: piece.userData.box.clone() },
      piece.position.clone().addScaledVector(right, width + 0.1).toArray(), piece.rotation.y, piece.scale.x);
    copy.name = piece.name;
    // Beside it on its right, else its left, else the nearest clear spot.
    if (furniture.collides(copy)) {
      copy.position.copy(piece.position).addScaledVector(right, -(width + 0.1));
      if (!furniture.nudge(copy, 1.5)) {
        furniture.remove(copy);
        this.onRefuse?.(`There's no room for another ${piece.name} nearby.`);
        return;
      }
    }
    this.select(copy);
  }

  remove() {
    if (!this.selected || !this.viewer.furniture) return;
    const piece = this.selected;
    this.select(null);
    this.viewer.furniture.remove(piece);
    this.undo.removed(piece);
  }

  private changed() {
    this.viewer.furniture?.onChange?.();
  }

  /** Makes a change to the selected piece, shifting it a little or undoing it if it would go into something. */
  private change(apply: () => void, verb: string) {
    const piece = this.selected, furniture = this.viewer.furniture;
    if (!piece || !furniture) return;
    const before = poseOf(piece);
    if (furniture.tryChange(piece, apply, 0.3)) {
      this.undo.moved(piece, before);
    } else {
      this.onRefuse?.(`There isn't room to ${verb} the ${piece.name} there. Move it into the open first, or turn collisions off in the Layout tab.`);
    }
    this.changed();
  }

  /**
   * Grabbing by a point on the view rather than the mouse (the hand
   * tracker): `ndc` is from -1 to 1 across the view. Returns the piece
   * grabbed, if there's one there.
   */
  grabAt(ndc: THREE.Vector2): Piece | null {
    const furniture = this.viewer.furniture;
    if (!furniture || this.drag) return null;
    this.raycaster.setFromCamera(ndc, this.viewer.camera);
    const piece = furniture.pieceAt(this.raycaster);
    if (!piece) return null;
    this.select(piece);
    const plane = new THREE.Plane(new THREE.Vector3(0, 1, 0), -piece.position.y);
    const hit = this.raycaster.ray.intersectPlane(plane, new THREE.Vector3());
    this.drag = { piece, plane, offset: hit ? piece.position.clone().sub(hit) : new THREE.Vector3(), moved: false,
      before: poseOf(piece) };
    return piece;
  }

  /** Carries what `grabAt` grabbed to under another point of the view. */
  dragTo(ndc: THREE.Vector2) {
    if (!this.drag) return;
    this.raycaster.setFromCamera(ndc, this.viewer.camera);
    const hit = this.raycaster.ray.intersectPlane(this.drag.plane, new THREE.Vector3());
    if (!hit) return;
    const { piece, offset } = this.drag;
    this.viewer.furniture?.slide(piece, hit.x + offset.x - piece.position.x, hit.z + offset.z - piece.position.z);
    this.drag.moved = true;
  }

  /** Lets go of what `grabAt` grabbed. */
  letGo() {
    if (this.drag?.moved) this.finish(this.drag.piece, this.drag.before);
    this.drag = undefined;
  }

  /** The piece under a point of the view, without grabbing it. */
  pieceUnder(ndc: THREE.Vector2): Piece | null {
    this.raycaster.setFromCamera(ndc, this.viewer.camera);
    return this.viewer.furniture?.pieceAt(this.raycaster) ?? null;
  }

  /** A piece was let go after a drag or a handle: snap it if snapping is on, and remember the edit. */
  private finish(piece: Piece, before: Pose) {
    if (this.snapping) this.viewer.furniture?.snap(piece);
    this.undo.moved(piece, before);
    this.changed();
  }

  private ray(event: PointerEvent) {
    const rect = this.viewer.renderer.domElement.getBoundingClientRect();
    const ndc = new THREE.Vector2(((event.clientX - rect.left) / rect.width) * 2 - 1,
      -((event.clientY - rect.top) / rect.height) * 2 + 1);
    this.raycaster.setFromCamera(ndc, this.viewer.camera);
    return this.raycaster;
  }

  private pointerDown(event: PointerEvent) {
    const furniture = this.viewer.furniture;
    // A press on a gizmo handle is the gizmo's.
    if (!furniture || this.viewer.inVR || this.gizmo.isHovered) return;
    this.down = { x: event.clientX, y: event.clientY };
    const canvas = this.viewer.renderer.domElement;
    canvas.focus();
    const piece = event.button === 0 ? furniture.pieceAt(this.ray(event)) : null;
    if (piece) {
      this.select(piece);
      const plane = new THREE.Plane(new THREE.Vector3(0, 1, 0), -piece.position.y);
      const hit = this.raycaster.ray.intersectPlane(plane, new THREE.Vector3());
      this.drag = { piece, plane, offset: hit ? piece.position.clone().sub(hit) : new THREE.Vector3(), moved: false,
        before: poseOf(piece) };
      this.viewer.controls.enabled = false;
      canvas.setPointerCapture(event.pointerId);
      event.stopImmediatePropagation();
    } else if (this.viewer.mode === "walk") {
      this.looking = { x: event.clientX, y: event.clientY };
      canvas.setPointerCapture(event.pointerId);
    }
  }

  private pointerMove(event: PointerEvent) {
    if (this.drag) {
      const hit = this.ray(event).ray.intersectPlane(this.drag.plane, new THREE.Vector3());
      if (!hit) return;
      const { piece, offset } = this.drag;
      // Slides along walls and other pieces rather than through them.
      this.viewer.furniture?.slide(piece, hit.x + offset.x - piece.position.x, hit.z + offset.z - piece.position.z);
      this.drag.moved = true;
    } else if (this.looking) {
      this.viewer.look(event.clientX - this.looking.x, event.clientY - this.looking.y);
      this.looking = { x: event.clientX, y: event.clientY };
    }
  }

  private pointerUp(event: PointerEvent) {
    if (this.drag) {
      if (this.drag.moved) this.finish(this.drag.piece, this.drag.before);
      this.drag = undefined;
      this.viewer.controls.enabled = this.viewer.mode === "orbit";
    } else if (this.down && Math.hypot(event.clientX - this.down.x, event.clientY - this.down.y) < 4) {
      // A click on nothing deselects.
      this.select(null);
    }
    this.looking = undefined;
    this.down = undefined;
  }

  private key(event: KeyboardEvent) {
    // Typing, or a dialog in front (whose Escape closes it).
    if ((event.target as HTMLElement | null)?.closest("input, textarea, select") || document.querySelector("dialog[open]")) return;
    if ((event.ctrlKey || event.metaKey) && (event.code === "KeyZ" || event.code === "KeyY")) {
      if (event.code === "KeyY" || event.shiftKey) this.redoLast();
      else this.undoLast();
      event.preventDefault();
      return;
    }
    if (!this.selected) return;
    const step = event.shiftKey ? -15 : 15;
    switch (event.code) {
      case "KeyR": this.rotate(step); break;
      case "BracketRight": this.scaleBy(1.1); break;
      case "BracketLeft": this.scaleBy(1 / 1.1); break;
      case "PageUp": this.raise(0.05); break;
      case "PageDown": this.raise(-0.05); break;
      case "Delete":
      case "Backspace": this.remove(); break;
      case "Escape": this.select(null); break;
      case "KeyD":
        if (!event.ctrlKey && !event.metaKey) return;
        this.duplicate();
        break;
      default:
        return;
    }
    event.preventDefault();
  }
}
