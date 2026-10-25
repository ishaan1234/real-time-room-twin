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
    targets = scan_io.roomplan_targets(args.scan_dir)
    prompts = sorted({target["prompt"] for target in targets}) if targets \
        else [p.strip() for p in args.prompts.split(",") if p.strip()]
    if targets:
        print(f"segment: SAM Furniture mode, {len(targets)} RoomPlan targets, prompts {prompts}")

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
            labels, scores, boxes, masks, target_ids = [], [], [], [], []
            targeted = {}
            for prompt in prompts:
                output = processor.set_text_prompt(state=state, prompt=prompt)
                for score, box, mask in zip(output["scores"], output["boxes"], output["masks"]):
                    box = box.float().cpu().numpy()
                    if box.max(initial=0) <= 2:  # tolerate normalized xyxy output
                        box = box * np.array([kf.width, kf.height, kf.width, kf.height], np.float32)
                    if targets:
                        candidates = [target for target in targets if target["prompt"] == prompt]
                        match = best_target(kf, box, candidates)
                        if match is None:
                            continue
                        target, overlap = match
                        rank = float(score) * overlap
                        if target["id"] in targeted and targeted[target["id"]][0] >= rank:
                            continue
                        targeted[target["id"]] = (rank, target, float(score), box, mask[0].cpu().numpy())
                    else:
                        labels.append(prompt)
                        scores.append(float(score))
                        boxes.append(box)
                        masks.append(mask[0].cpu().numpy())
                        target_ids.append(-1)
            if targets:
                for _, target, score, box, mask in sorted(targeted.values(), key=lambda item: item[1]["id"]):
                    labels.append(target["category"])
                    scores.append(score)
                    boxes.append(box)
                    masks.append(mask)
                    target_ids.append(target["id"])
        found += len(labels)
        np.savez_compressed(
            os.path.join(out_dir, f"{kf.index:06d}.npz"),
            labels=np.array(labels, dtype=object),
            scores=np.array(scores, dtype=np.float32),
            boxes=np.array(boxes, dtype=np.float32).reshape(-1, 4),
            target_ids=np.array(target_ids, dtype=np.int32),
            masks=np.packbits(np.array(masks, dtype=bool).reshape(-1, kf.height, kf.width), axis=-1),
            shape=np.array([kf.height, kf.width]))
        if n % 20 == 0 or n == len(keyframes) - 1:
            print(f"segment: {n + 1}/{len(keyframes)} keyframes, {found} instances, "
                  f"{(time.time() - start) / (n + 1):.2f} s per keyframe", flush=True)


def best_target(kf, detected, targets):
    """Matches one SAM detection to one projected RoomPlan box.

    RoomPlan boxes are deliberately loose, especially for chairs, so use the
    fraction of the SAM box inside the prediction instead of strict IoU.
    """
    best = None
    area = max(1.0, (detected[2] - detected[0]) * (detected[3] - detected[1]))
    centre = (detected[:2] + detected[2:]) / 2
    for target in targets:
        predicted = scan_io.projected_target_box(kf, target)
        if predicted is None:
            continue
        intersection = max(0.0, min(detected[2], predicted[2]) - max(detected[0], predicted[0])) \
            * max(0.0, min(detected[3], predicted[3]) - max(detected[1], predicted[1]))
        overlap = intersection / area
        pad = 0.15 * max(predicted[2] - predicted[0], predicted[3] - predicted[1])
        centre_inside = (predicted[0] - pad <= centre[0] <= predicted[2] + pad
                         and predicted[1] - pad <= centre[1] <= predicted[3] + pad)
        if overlap < 0.25 or not centre_inside:
            continue
        distance = np.linalg.norm(centre - (predicted[:2] + predicted[2:]) / 2) \
            / max(1.0, np.linalg.norm(predicted[2:] - predicted[:2]))
        rank = overlap - 0.1 * distance
        if best is None or rank > best[0]:
            best = (rank, target, overlap)
    return None if best is None else (best[1], best[2])


if __name__ == "__main__":
    main()
