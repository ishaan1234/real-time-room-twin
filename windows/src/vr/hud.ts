import * as THREE from "three";

export interface HudButton {
  id: string;
  label: string;
  /** Lit up, e.g. Talk while the agent is listening. */
  active?: boolean;
}

/**
 * The panel floating below your view in VR: what's going on, what the voice
 * agent said, which controller buttons are pressed (to learn how SteamVR
 * maps PS Move or other controllers), and buttons you point at and pull the
 * trigger on. It follows your head lazily, so it stays put until you turn
 * well away from it.
 */
export class Hud {
  readonly mesh: THREE.Mesh;
  private canvas = document.createElement("canvas");
  private context: CanvasRenderingContext2D;
  private texture: THREE.CanvasTexture;
  private buttons: (HudButton & { rect: [number, number, number, number] })[] = [];
  private hovered: string | null = null;
  private lines: string[] = [];
  private caption = "";
  private dirty = true;
  private static readonly width = 1024;
  private static readonly height = 600;

  constructor() {
    this.canvas.width = Hud.width;
    this.canvas.height = Hud.height;
    this.context = this.canvas.getContext("2d")!;
    this.texture = new THREE.CanvasTexture(this.canvas);
    this.texture.colorSpace = THREE.SRGBColorSpace;
    this.mesh = new THREE.Mesh(
      new THREE.PlaneGeometry(0.8, (0.8 * Hud.height) / Hud.width),
      new THREE.MeshBasicMaterial({ map: this.texture, transparent: true, depthTest: false }),
    );
    this.mesh.renderOrder = 20;
    this.mesh.name = "hud";
  }

  setButtons(buttons: HudButton[]) {
    const columns = 4, margin = 24, gap = 16, height = 92, top = Hud.height - 2 * (height + gap) - margin + gap;
    const width = (Hud.width - 2 * margin - (columns - 1) * gap) / columns;
    const next = buttons.map((button, i) => ({
      ...button,
      rect: [margin + (i % columns) * (width + gap), top + Math.floor(i / columns) * (height + gap), width, height] as [number, number, number, number],
    }));
    if (JSON.stringify(next) !== JSON.stringify(this.buttons)) {
      this.buttons = next;
      this.dirty = true;
    }
  }

  setText(lines: string[], caption: string) {
    if (lines.join("\n") !== this.lines.join("\n") || caption !== this.caption) {
      this.lines = lines;
      this.caption = caption;
      this.dirty = true;
    }
  }

  /** The button under a ray's hit on the panel, from its texture coordinates. */
  buttonAt(uv: THREE.Vector2): string | null {
    const x = uv.x * Hud.width, y = (1 - uv.y) * Hud.height;
    return this.buttons.find(({ rect: [bx, by, bw, bh] }) => x >= bx && x <= bx + bw && y >= by && y <= by + bh)?.id ?? null;
  }

  hover(id: string | null) {
    if (id !== this.hovered) {
      this.hovered = id;
      this.dirty = true;
    }
  }

  /** Brings the panel in front of the head, a little below eye level. */
  place(head: THREE.Vector3, yaw: number, parent: THREE.Object3D) {
    const forward = new THREE.Vector3(-Math.sin(yaw), 0, -Math.cos(yaw));
    const position = head.clone().addScaledVector(forward, 0.9);
    position.y -= 0.42;
    parent.worldToLocal(position);
    this.mesh.position.copy(position);
    const look = head.clone();
    look.y = this.mesh.getWorldPosition(new THREE.Vector3()).y + 0.3;
    this.mesh.lookAt(look);
  }

  /** Redraws if anything changed; call once a frame. */
  draw() {
    if (!this.dirty) return;
    this.dirty = false;
    const c = this.context, w = Hud.width, h = Hud.height;
    c.clearRect(0, 0, w, h);
    c.fillStyle = "rgba(18, 18, 22, 0.86)";
    roundRect(c, 0, 0, w, h, 36);
    c.fill();
    c.fillStyle = "#ffffff";
    c.font = "600 40px system-ui, sans-serif";
    c.fillText("RoomTwin", 32, 64);
    c.font = "30px system-ui, sans-serif";
    c.fillStyle = "#c7c7cc";
    this.lines.slice(0, 4).forEach((line, i) => c.fillText(line, 32, 110 + i * 38, w - 64));
    if (this.caption) {
      c.fillStyle = "#ffd60a";
      c.font = "italic 32px system-ui, sans-serif";
      wrap(c, this.caption, 32, 280, w - 64, 38, 2);
    }
    for (const button of this.buttons) {
      const [x, y, bw, bh] = button.rect;
      c.fillStyle = button.active ? "#ff453a" : button.id === this.hovered ? "#0a84ff" : "rgba(255,255,255,0.14)";
      roundRect(c, x, y, bw, bh, 20);
      c.fill();
      c.fillStyle = "#ffffff";
      c.font = "600 30px system-ui, sans-serif";
      c.textAlign = "center";
      c.fillText(button.label, x + bw / 2, y + bh / 2 + 11, bw - 16);
      c.textAlign = "left";
    }
    this.texture.needsUpdate = true;
  }
}

function roundRect(c: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number) {
  c.beginPath();
  c.roundRect(x, y, w, h, r);
}

function wrap(c: CanvasRenderingContext2D, text: string, x: number, y: number, width: number, lineHeight: number, maxLines: number) {
  const words = text.split(/\s+/);
  let line = "", lines = 0;
  for (const word of words) {
    const next = line ? `${line} ${word}` : word;
    if (c.measureText(next).width > width && line) {
      c.fillText(line, x, y + lines * lineHeight);
      if (++lines >= maxLines) return;
      line = word;
    } else {
      line = next;
    }
  }
  if (line) c.fillText(line, x, y + lines * lineHeight);
}
