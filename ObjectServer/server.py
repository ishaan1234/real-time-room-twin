"""Object server: one photo -> click mask (SAM 3) -> 3D model (SAM 3D Objects).

    OBJECT_SERVER_TOKEN=... /content/envs/sam3/bin/python server.py [--port 8000]

Runs on the Colab VM in the SAM 3 environment. generator.py runs next to it
in the SAM 3D environment and picks up generation jobs from the photo folders.
ObjectServer/start.sh on the Mac starts both and tunnels the port to the phone.

Every request must carry the token in an X-Token header.

  GET  /health                  {"generator": {"state": "loading" | "ready", ...}}
  POST /photos                  {"entry": keyframe entry (KeyframeRecorder format),
                                 "image": JPEG, "depth": Float32 plane, "confidence": UInt8 plane}
                                 (the three files base64) -> {"id", "turns", "width", "height"}
                                 `turns` is how many np.rot90 turns make the photo upright.
  POST /photos/ID/select        {"x", "y"}: the tap, 0...1 across the upright photo
                                 -> {"masks": [{"overlay": RGBA PNG base64, "score", "area"}],
                                     "best"}: SAM 3's three candidates, largest first
  POST /photos/ID/generate      {"mask": index into masks} -> {"job"}
  GET  /jobs/JOB                {"state": "queued" | "running" | "done" | "failed", "message", ...}
  GET  /jobs/JOB/model.ply      the model: metres, +y up, standing on the origin

Files live in /content/objects/ID/, laid out like a one-keyframe scan so
scan_io.Keyframe reads them; each generation job gets ID/job-N/.
"""

import argparse
import base64
import io
import json
import os
import re
import sys
import threading
import time
import traceback
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import cv2
import numpy as np
import torch
from PIL import Image
from sam3 import build_sam3_image_model
from sam3.model.sam3_image_processor import Sam3Processor

sys.path.insert(0, os.environ.get("FURNITURE_DIR", "/content/Furniture"))
import scan_io  # noqa: E402

ROOT = os.environ.get("OBJECTS_DIR", "/content/objects")
TOKEN = os.environ["OBJECT_SERVER_TOKEN"]
OVERLAY_COLOR = (10, 132, 255)   # systemBlue
OVERLAY_SCALE = 0.5              # overlays are drawn at half resolution; the phone scales them up


class Segmenter:
    """SAM 3 with point prompts. Keeps the image features of the latest photo."""

    def __init__(self):
        self.model = build_sam3_image_model(enable_inst_interactivity=True)
        self.processor = Sam3Processor(self.model)
        self.lock = threading.Lock()
        self.photo = None
        self.state = None

    def select(self, photo_id, image, x, y):
        with self.lock, torch.autocast("cuda", dtype=torch.bfloat16):
            if self.photo != photo_id:
                self.state = self.processor.set_image(Image.fromarray(image))
                self.photo = photo_id
            masks, scores, _ = self.model.predict_inst(
                self.state, point_coords=np.array([[x, y]], dtype=np.float32),
                point_labels=np.array([1]), multimask_output=True)
        return np.asarray(masks) > 0, np.asarray(scores, dtype=np.float32)


def overlay_png(mask):
    """The mask tinted, with a white outline, as a half-size RGBA PNG."""
    height, width = mask.shape
    small = cv2.resize(mask.astype(np.uint8), (round(width * OVERLAY_SCALE), round(height * OVERLAY_SCALE)),
                       interpolation=cv2.INTER_NEAREST)
    rgba = np.zeros(small.shape + (4,), np.uint8)
    rgba[small > 0] = OVERLAY_COLOR + (110,)
    contours, _ = cv2.findContours(small, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    cv2.drawContours(rgba, contours, -1, (255, 255, 255, 255), thickness=3)
    buffer = io.BytesIO()
    Image.fromarray(rgba, "RGBA").save(buffer, "PNG", optimize=False)
    return base64.b64encode(buffer.getvalue()).decode("ascii")


def photo_dir(photo_id):
    if not re.fullmatch(r"[0-9a-f]{12}", photo_id):
        raise LookupError(photo_id)
    path = os.path.join(ROOT, photo_id)
    if not os.path.isdir(path):
        raise LookupError(photo_id)
    return path


def load_keyframe(photo_id):
    path = photo_dir(photo_id)
    with open(os.path.join(path, "entry.json")) as f:
        return scan_io.Keyframe(path, json.load(f))


def add_photo(body):
    photo_id = uuid.uuid4().hex[:12]
    path = os.path.join(ROOT, photo_id)
    os.makedirs(os.path.join(path, "keyframes"))
    entry = dict(body["entry"], index=0, image="keyframes/000000.jpg", depth="keyframes/000000.depth",
                 confidence="keyframes/000000.conf")
    for key in ("image", "depth", "confidence"):
        with open(os.path.join(path, entry[key]), "wb") as f:
            f.write(base64.b64decode(body[key]))
    with open(os.path.join(path, "entry.json"), "w") as f:
        json.dump(entry, f)
    kf = load_keyframe(photo_id)
    return dict(id=photo_id, turns=kf.turns, width=kf.width, height=kf.height)


def select(segmenter, photo_id, body):
    kf = load_keyframe(photo_id)
    x = float(np.clip(body["x"], 0, 1)) * (kf.width - 1)
    y = float(np.clip(body["y"], 0, 1)) * (kf.height - 1)
    start = time.time()
    masks, scores = segmenter.select(photo_id, kf.image, x, y)
    order = np.argsort([-m.sum() for m in masks])   # largest first
    masks, scores = masks[order], scores[order]
    np.savez_compressed(os.path.join(photo_dir(photo_id), "masks.npz"), masks=np.packbits(masks, axis=-1),
                        shape=np.array(masks.shape[1:]))
    print(f"select {photo_id} ({x:.0f}, {y:.0f}): scores {np.round(scores, 3).tolist()} "
          f"in {time.time() - start:.2f} s", flush=True)
    return dict(masks=[dict(overlay=overlay_png(m), score=float(s), area=float(m.mean())) for m, s in zip(masks, scores)],
                best=int(np.argmax(scores)))


def generate(photo_id, body):
    path = photo_dir(photo_id)
    if not os.path.exists(os.path.join(path, "masks.npz")):
        raise ValueError("select the object first")
    number = len([name for name in os.listdir(path) if name.startswith("job-")])
    job_dir = os.path.join(path, f"job-{number}")
    os.makedirs(job_dir)
    with open(os.path.join(job_dir, "request.json.tmp"), "w") as f:
        json.dump(dict(mask=int(body["mask"]), created=time.time()), f)
    os.replace(os.path.join(job_dir, "request.json.tmp"), os.path.join(job_dir, "request.json"))
    return dict(job=f"{photo_id}-{number}")


def job_dir(job):
    match = re.fullmatch(r"([0-9a-f]{12})-(\d+)", job)
    if not match:
        raise LookupError(job)
    path = os.path.join(photo_dir(match[1]), f"job-{match[2]}")
    if not os.path.isdir(path):
        raise LookupError(job)
    return path


def generator_status():
    try:
        with open(os.path.join(ROOT, "generator.json")) as f:
            return json.load(f)
    except FileNotFoundError:
        return dict(state="stopped")


def job_status(job):
    try:
        with open(os.path.join(job_dir(job), "status.json")) as f:
            return json.load(f)
    except FileNotFoundError:
        generator = generator_status()
        waiting = "Loading SAM 3D Objects (about a minute)" if generator["state"] == "loading" \
            else "Waiting for the generator" if generator["state"] == "ready" else "The generator isn't running"
        return dict(state="queued", message=waiting)


def make_handler(segmenter):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):
            self.route("GET")

        def do_POST(self):
            self.route("POST")

        def route(self, method):
            try:
                if self.headers.get("X-Token") != TOKEN:
                    return self.reply(403, dict(error="wrong token"))
                length = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(length)) if length else {}
                path = self.path.split("?")[0].strip("/").split("/")
                if method == "GET" and path == ["health"]:
                    return self.reply(200, dict(generator=generator_status()))
                if method == "POST" and path == ["photos"]:
                    return self.reply(200, add_photo(body))
                if method == "POST" and len(path) == 3 and path[0] == "photos" and path[2] == "select":
                    return self.reply(200, select(segmenter, path[1], body))
                if method == "POST" and len(path) == 3 and path[0] == "photos" and path[2] == "generate":
                    return self.reply(200, generate(path[1], body))
                if method == "GET" and len(path) == 2 and path[0] == "jobs":
                    return self.reply(200, job_status(path[1]))
                if method == "GET" and len(path) == 3 and path[0] == "jobs" and path[2] == "model.ply":
                    with open(os.path.join(job_dir(path[1]), "model.ply"), "rb") as f:
                        return self.reply(200, f.read(), "application/octet-stream")
                self.reply(404, dict(error="no such endpoint"))
            except (LookupError, FileNotFoundError) as error:
                self.reply(404, dict(error=f"not found: {error}"))
            except (KeyError, ValueError) as error:
                self.reply(400, dict(error=str(error)))
            except Exception as error:
                traceback.print_exc()
                self.reply(500, dict(error=f"{type(error).__name__}: {error}"))

        def reply(self, status, body, content_type="application/json"):
            data = body if isinstance(body, bytes) else json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, format, *args):
            print(f"{self.address_string()} {format % args}", flush=True)

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()
    os.makedirs(ROOT, exist_ok=True)
    start = time.time()
    segmenter = Segmenter()
    print(f"SAM 3 loaded in {time.time() - start:.0f} s; listening on 127.0.0.1:{args.port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(segmenter)).serve_forever()


if __name__ == "__main__":
    main()
