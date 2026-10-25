"""Step 1: find furniture in every keyframe with SAM 3 text prompts.

    python segment.py SCAN_DIR [--prompts chair,sofa,...] [--threshold 0.5]

Writes SCAN_DIR/segments/<keyframe>.npz with, per instance: the prompt, its
score, its box (x0, y0, x1, y1) and its mask, all in the upright keyframe.
Runs in the SAM 3 environment (Python 3.12, PyTorch >= 2.7).
"""

import argparse
import os
import time

import numpy as np
import torch
from PIL import Image
from sam3.model.sam3_image_processor import Sam3Processor
from sam3.model_builder import build_sam3_image_model

import scan_io

DEFAULT_PROMPTS = ["chair", "armchair", "sofa", "table", "desk", "bed", "cabinet", "shelf", "dresser",
                   "nightstand", "stool", "bench", "ottoman", "lamp", "potted plant", "television"]


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("scan_dir")
    parser.add_argument("--prompts", default=",".join(DEFAULT_PROMPTS))
    parser.add_argument("--threshold", type=float, default=0.5)
    args = parser.parse_args()
    prompts = [p.strip() for p in args.prompts.split(",") if p.strip()]

    keyframes = scan_io.load_keyframes(args.scan_dir)
    out_dir = os.path.join(args.scan_dir, "segments")
    os.makedirs(out_dir, exist_ok=True)

    model = build_sam3_image_model()
    processor = Sam3Processor(model, confidence_threshold=args.threshold)
    start = time.time()
    found = 0
    for n, kf in enumerate(keyframes):
        with torch.autocast("cuda", dtype=torch.bfloat16):
            state = processor.set_image(Image.fromarray(kf.image))
            labels, scores, boxes, masks = [], [], [], []
            for prompt in prompts:
                output = processor.set_text_prompt(state=state, prompt=prompt)
                for score, box, mask in zip(output["scores"], output["boxes"], output["masks"]):
                    labels.append(prompt)
                    scores.append(float(score))
                    boxes.append(box.float().cpu().numpy())
                    masks.append(mask[0].cpu().numpy())
        found += len(labels)
        np.savez_compressed(
            os.path.join(out_dir, f"{kf.index:06d}.npz"),
            labels=np.array(labels, dtype=object),
            scores=np.array(scores, dtype=np.float32),
            boxes=np.array(boxes, dtype=np.float32).reshape(-1, 4),
            masks=np.packbits(np.array(masks, dtype=bool).reshape(-1, kf.height, kf.width), axis=-1),
            shape=np.array([kf.height, kf.width]))
        if n % 20 == 0 or n == len(keyframes) - 1:
            print(f"segment: {n + 1}/{len(keyframes)} keyframes, {found} instances, "
                  f"{(time.time() - start) / (n + 1):.2f} s per keyframe", flush=True)


if __name__ == "__main__":
    main()
