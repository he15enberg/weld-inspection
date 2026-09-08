"""RF-DETR postprocessing, written out by hand, and a parity check against
`model.predict()`.

Why this exists: on the phone there is no `predict()`. The exported CoreML model
hands Swift three raw tensors and Swift has to turn them into detections itself.
That conversion is ~40 lines of maths, and every way of getting it wrong produces
plausible-looking output rather than a crash. So it gets written here first, in
Python, where it can be diffed against the real thing -- then the Swift is a port
of something already proven.

`postprocess()` below is the part to port. It imports nothing from rfdetr and
takes plain arrays, so it reads as pseudocode for Swift.

Runs on CPU only (CUDA is hidden at import time) so it cannot disturb a training
run on the GPU.

    python reference_postprocess.py                 # 3 images, conf 0.25
    python reference_postprocess.py -n 5 --conf 0.4
"""

from __future__ import annotations

import os

# Before torch is imported by anything: keep this off the GPU entirely so a
# concurrent training run is untouched.
os.environ["CUDA_VISIBLE_DEVICES"] = "-1"   # "-1", not "": an empty value does not hide devices on Windows

import argparse
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
CKPT = HERE / "runs" / "rfdetr_seg_small_data40" / "checkpoint_best_ema.pth"
SOURCE = REPO / "welds" / "welds"

IMAGENET_MEAN = np.array([0.485, 0.456, 0.406], np.float32)
IMAGENET_STD = np.array([0.229, 0.224, 0.225], np.float32)
NUM_SELECT = 300


# --------------------------------------------------------------------------
# the two functions to port to Swift
# --------------------------------------------------------------------------

def preprocess(img: Image.Image, size: int) -> np.ndarray:
    """RGB image -> (1, 3, size, size) float32 NCHW.

    A plain STRETCH to square: no letterbox, no aspect preservation. That is
    what makes the box maths in postprocess() so simple -- normalised
    coordinates in model space are already normalised coordinates in the
    original image.

    The resize is bilinear with half-pixel centres and antialias OFF. Antialias
    off is the part Swift will get wrong by default: vImageScale and Core Image
    both antialias when downscaling, which shifts pixel values and therefore
    confidences. Nothing errors -- the scores just quietly drift.
    """
    rgb = np.asarray(img.convert("RGB"), dtype=np.float32) / 255.0     # HWC
    t = torch.from_numpy(rgb).permute(2, 0, 1).unsqueeze(0)            # 1CHW
    t = F.interpolate(t, size=(size, size), mode="bilinear",
                      align_corners=False, antialias=False)
    arr = t.squeeze(0).numpy()
    arr = (arr - IMAGENET_MEAN[:, None, None]) / IMAGENET_STD[:, None, None]
    return arr[None].astype(np.float32)


def postprocess(
    dets: np.ndarray,          # (Q, 4)      normalised cxcywh
    labels: np.ndarray,        # (Q, C)      RAW logits, not probabilities
    masks: np.ndarray | None,  # (Q, Hm, Wm) RAW mask logits
    orig_w: int,
    orig_h: int,
    threshold: float = 0.25,
    num_select: int = NUM_SELECT,
    background_class_id: int | None = None,
):
    """Three raw tensors -> (boxes_xyxy, scores, class_ids, masks_bool).

    Port this to Swift. Five things that are easy to get wrong, in order of how
    badly they bite:

    1. SIGMOID PER CLASS, not softmax. Classes are independent here.

    2. Top-k over the FLATTENED (Q, C) grid, not an argmax per query. A query
       can legitimately clear the threshold on more than one class; taking one
       class per query silently drops those. This is the bug that looks like
       nothing is wrong.

    3. The gathered query index CAN REPEAT, precisely because of (2). Boxes and
       masks must be gathered with a fancy index, never a boolean mask, or the
       repeats collapse and rows misalign with their scores.

    4. Boxes are cxcywh and normalised. Convert to xyxy, then multiply by the
       ORIGINAL image size -- correct only because preprocess() stretched.

    5. Masks are LOGITS. Threshold at 0 (equivalent to sigmoid > 0.5), after
       upsampling, not before.

    No NMS anywhere: RF-DETR is a set predictor and does not need it.
    """
    # 1. per-class sigmoid; the clip only guards exp() overflow
    scores_all = 1.0 / (1.0 + np.exp(-np.clip(labels, -88, 88)))       # (Q, C)

    # optional background slot, dropped while keeping original class ids
    class_ids = np.arange(scores_all.shape[1])
    if background_class_id is not None:
        keep_col = class_ids != (background_class_id % scores_all.shape[1])
        scores_all = scores_all[:, keep_col]
        class_ids = class_ids[keep_col]

    q, c = scores_all.shape
    flat = scores_all.ravel()

    # 2. top-k across the whole grid. Deterministic tie-break: score descending,
    #    then flattened index ascending -- matches PostProcess._select_topk so
    #    equal scores come out in a stable order.
    k = min(num_select, flat.size)
    order = np.lexsort((np.arange(flat.size), -flat))[:k]
    order = order[flat[order] > threshold]

    scores = flat[order]
    query_idx = order // c                                             # 3. repeats OK
    cls = class_ids[order % c]

    # 4. cxcywh (normalised) -> xyxy (pixels)
    cx, cy, bw, bh = dets[query_idx].T
    xyxy = np.stack([cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2], 1)
    xyxy = xyxy * np.array([orig_w, orig_h, orig_w, orig_h], np.float32)

    # 5. masks: gather, upsample bilinear (align_corners=False), threshold at 0
    out_masks = None
    if masks is not None and len(order):
        t = torch.from_numpy(masks[query_idx].astype(np.float32)).unsqueeze(0)
        t = F.interpolate(t, size=(orig_h, orig_w), mode="bilinear", align_corners=False)
        out_masks = t.squeeze(0).numpy() > 0.0

    return xyxy, scores, cls, out_masks


# --------------------------------------------------------------------------
# parity check
# --------------------------------------------------------------------------

def prepare_export(model, size: int):
    """Put the module into the exact state ONNX and CoreML trace.

    Mirrors RFDETR.export() (detr.py:1792): freeze each DinoV2 backbone to the
    export shape and switch it to export mode. Without this the backbone still
    expects a NestedTensor and forward_export() dies on `tensor_list.tensors`.
    Freezing the shape also keeps DINOv2's antialiased bicubic position-embedding
    interpolation out of the graph -- it has no ONNX symbolic.

    That loop is the whole preparation: export_onnx() adds nothing further, so
    this is a faithful stand-in for the exported artifact.
    """
    from rfdetr.models.backbone.dinov2 import DinoV2

    inner = model.model.model
    n = 0
    for m in inner.modules():
        if isinstance(m, DinoV2):
            m.shape = (size, size)
            n += 1
    # Then the cascade: LWDETR.export() swaps forward -> forward_export on
    # itself and on every submodule exposing export() (Backbone, DinoV2,
    # MSDeformAttn). Setting the DinoV2 shapes alone is not enough -- the
    # Backbone still expects a NestedTensor until its forward is swapped.
    # One-way by design; there is no unexport().
    inner.export()
    inner.eval()
    return inner, n


def raw_outputs(inner, tensor: np.ndarray):
    """The three tensors the exported model will emit."""
    with torch.no_grad():
        out = inner.forward_export(torch.from_numpy(tensor))
    return [o.detach().cpu().numpy() for o in out]


def iou(a: np.ndarray, b: np.ndarray) -> float:
    inter = np.logical_and(a, b).sum()
    union = np.logical_or(a, b).sum()
    return 1.0 if union == 0 else inter / union


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", default=str(CKPT))
    ap.add_argument("--source", default=str(SOURCE))
    ap.add_argument("-n", type=int, default=3)
    ap.add_argument("--conf", type=float, default=0.25)
    ap.add_argument("--argmax-check", action="store_true",
                    help="sweep thresholds showing what a per-query argmax would lose")
    ap.add_argument("--threads", type=int, default=4,
                    help="cap CPU threads so a concurrent training run keeps its cores")
    args = ap.parse_args()

    torch.set_num_threads(args.threads)
    if torch.cuda.is_available():
        raise SystemExit("CUDA is visible; refusing to run (training may be using it)")

    from rfdetr import RFDETR

    model = RFDETR.from_checkpoint(args.ckpt, trust_checkpoint=True)
    # The checkpoint records the device it trained on. Left alone, predict()
    # calls _move_model_context_to_device and dies on torch.cuda.current_device()
    # because CUDA is hidden. Pin the context to CPU.
    model.model.device = torch.device("cpu")
    model.model.model = model.model.model.to("cpu")
    model.model.model.eval()
    res = getattr(model.model_config, "resolution", 1272)
    _ = res
    nc = getattr(model.model_config, "num_classes", None)
    print(f"{type(model).__name__}  res {res}  num_classes {nc}  device CPU  "
          f"threads {args.threads}\n")

    images = sorted(p for p in Path(args.source).iterdir()
                    if p.suffix.lower() in {".jpg", ".jpeg", ".png"})[: args.n]

    worst_box, worst_iou, mismatches = 0.0, 1.0, 0
    inner = None

    for p in images:
        img = Image.open(p)
        ow, oh = img.size

        # predict() first: it needs the model in normal mode, and prepare_export
        # is one-way per the MSDeformAttn docs ("There is no unexport()").
        ref = model.predict(img, threshold=args.conf)

        if inner is None:
            inner, n_bb = prepare_export(model, res)
            print(f"  export mode on {n_bb} DinoV2 backbone(s)")

        raw = raw_outputs(inner, preprocess(img, res))
        shapes = [tuple(r.shape) for r in raw]

        # Bind by rank and last dim, exactly as Swift will have to: coremltools
        # does not preserve the ONNX output names.
        box_i = next(i for i, r in enumerate(raw) if r.ndim == 3 and r.shape[-1] == 4)
        log_i = next(i for i, r in enumerate(raw) if r.ndim == 3 and i != box_i)
        msk_i = next((i for i, r in enumerate(raw) if r.ndim == 4), None)

        dets, labels = raw[box_i][0], raw[log_i][0]
        masks = raw[msk_i][0] if msk_i is not None else None

        # Does the logits width imply a background slot?
        bg = None if labels.shape[-1] == nc else -1

        xyxy, scores, cls, mask = postprocess(
            dets, labels, masks, ow, oh, threshold=args.conf, background_class_id=bg)

        print(f"{p.name}   {ow}x{oh}   raw {shapes}")
        print(f"  logits width {labels.shape[-1]} vs num_classes {nc} -> "
              f"background slot: {'none' if bg is None else bg}")
        print(f"  mine {len(scores)} detections   predict() {len(ref)}")

        if len(scores) != len(ref):
            print("  COUNT MISMATCH")
            mismatches += 1
            continue

        # predict() returns descending score, same as this does
        db = np.abs(xyxy - ref.xyxy).max() if len(scores) else 0.0
        ds = np.abs(scores - ref.confidence).max() if len(scores) else 0.0
        same_cls = bool((cls == ref.class_id).all()) if len(scores) else True
        worst_box = max(worst_box, float(db))

        mi = 1.0
        if mask is not None and ref.mask is not None:
            mi = min(iou(mask[i], ref.mask[i]) for i in range(len(scores))) if len(scores) else 1.0
            worst_iou = min(worst_iou, mi)

        if args.argmax_check:
            # Negative control for trap 2. A per-query argmax keeps at most one
            # class per query; measure how many detections that actually loses,
            # so the Swift port knows whether the complexity is load-bearing.
            sc_all = 1.0 / (1.0 + np.exp(-np.clip(
                labels[:, :-1] if bg is not None else labels, -88, 88)))
            print("    threshold sweep -- correct vs per-query argmax")
            for th in (0.25, 0.10, 0.05, 0.01):
                _, s_ok, _, _ = postprocess(dets, labels, None, ow, oh, th,
                                            background_class_id=bg)
                n_am = int((sc_all.max(1) > th).sum())
                print(f"      conf {th:<5} correct {len(s_ok):>3}  argmax {n_am:>3}"
                      f"  lost {len(s_ok) - n_am:>3}")

        ok = db < 1e-3 and ds < 1e-4 and same_cls and mi > 0.999
        print(f"  box max|d| {db:.2e} px   score max|d| {ds:.2e}   "
              f"classes {'match' if same_cls else 'DIFFER'}   min mask IoU {mi:.5f}"
              f"   {'OK' if ok else 'FAIL'}\n")
        if not ok:
            mismatches += 1

    print("-" * 58)
    if mismatches:
        print(f"{mismatches}/{len(images)} images FAILED parity")
        raise SystemExit(1)
    print(f"all {len(images)} images match predict()")
    print(f"  worst box delta {worst_box:.2e} px, worst mask IoU {worst_iou:.5f}")
    print("\npostprocess() is a faithful reference -- port it to Swift.")


if __name__ == "__main__":
    main()
