import * as THREE from "three";
import { stretch, type Furniture, type Piece } from "./furniture";

/** Where a piece is, how it's turned, and how big: the holder's pose and the model's stretch. */
export interface Pose {
  position: THREE.Vector3;
  yaw: number;
  scale: number;
  modelScale: THREE.Vector3;
}

export function poseOf(piece: Piece): Pose {
  return {
    position: piece.position.clone(),
    yaw: piece.rotation.y,
    scale: piece.scale.x,
    modelScale: piece.children[0]?.scale.clone() ?? new THREE.Vector3(1, 1, 1),
  };
}

export function applyPose(piece: Piece, pose: Pose) {
  piece.position.copy(pose.position);
  piece.rotation.y = pose.yaw;
  piece.scale.setScalar(pose.scale);
  if (piece.children[0] && !piece.children[0].scale.equals(pose.modelScale)) stretch(piece, pose.modelScale.toArray());
}

const same = (a: Pose, b: Pose) => a.position.distanceTo(b.position) < 1e-4 && Math.abs(a.yaw - b.yaw) < 1e-4
  && Math.abs(a.scale - b.scale) < 1e-4 && a.modelScale.distanceTo(b.modelScale) < 1e-4;

type Edit =
  | { kind: "pose"; piece: Piece; before: Pose; after: Pose }
  | { kind: "remove"; piece: Piece };

/**
 * Undo and redo for edits made by hand, as on the phone: each finished
 * move, turn, resize or drop of a piece, plus deleting one.
 */
export class Undo {
  private done: Edit[] = [];
  private undone: Edit[] = [];
  onChange?: () => void;

  constructor(private furniture: () => Furniture | undefined) {}

  get canUndo() {
    return this.done.length > 0;
  }

  get canRedo() {
    return this.undone.length > 0;
  }

  /** Records that `piece` went from `before` to where it is now (nothing, if it didn't move). */
  moved(piece: Piece, before: Pose) {
    const after = poseOf(piece);
    if (same(before, after)) return;
    this.push({ kind: "pose", piece, before, after });
  }

  removed(piece: Piece) {
    this.push({ kind: "remove", piece });
  }

  undo(): Piece | null {
    const edit = this.done.pop();
    if (!edit) return null;
    this.undone.push(edit);
    return this.apply(edit, true);
  }

  redo(): Piece | null {
    const edit = this.undone.pop();
    if (!edit) return null;
    this.done.push(edit);
    return this.apply(edit, false);
  }

  /** A new room: what was done to the last one can't be undone here. */
  clear() {
    this.done = [];
    this.undone = [];
    this.onChange?.();
  }

  private push(edit: Edit) {
    this.done.push(edit);
    if (this.done.length > 100) this.done.shift();
    this.undone = [];
    this.onChange?.();
  }

  /** Undoes (or redoes) an edit; returns the piece it was about, if it's in the room afterwards. */
  private apply(edit: Edit, backwards: boolean): Piece | null {
    const furniture = this.furniture();
    let result: Piece | null = edit.piece;
    if (edit.kind === "pose") {
      applyPose(edit.piece, backwards ? edit.before : edit.after);
    } else if (backwards) {
      furniture?.group.add(edit.piece);
    } else {
      furniture?.remove(edit.piece);
      result = null;
    }
    furniture?.onChange?.();
    this.onChange?.();
    return result && result.parent ? result : null;
  }
}
