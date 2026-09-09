"""RF-DETR Seg: load once, run, turn three raw tensors into detections.

`preprocess` and `postprocess` are copied verbatim from
`reference_postprocess.py` on the `model_train` branch, which was verified
bit-for-bit against the model's own `predict()` on real weld images -- box delta
0.00, mask IoU 1.00000. Do not "tidy" them. Four things in there are
load-bearing and each fails silently when got wrong:

  1. per-class sigmoid, not softmax
  2. top-k over the flattened (Q, C) grid, not an argmax per query
  3. gathered query indices may repeat, so gather with a fancy index
  4. masks are logits: upsample first, threshold at 0 second

The model is loaded and warmed at import of `load()`, not on the first request:
the first inference pays CUDA context creation and kernel autotuning, and that
belongs in startup rather than in whichever capture happens to arrive first.
"""

from __future__ import annotations

import logging
import os
import threading
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image

log = logging.getLogger("weldz.model")

IMAGENET_MEAN = np.array([0.485, 0.456, 0.406], np.float32)
IMAGENET_STD = np.array([0.229, 0.224, 0.225], np.float32)
NUM_SELECT = 300

CKPT = Path(os.environ.get("WELDZ_CKPT", "checkpoint_best_ema.pth"))
DEVICE = os.environ.get("WELDZ_DEVICE", "cuda")

# Index order the dataset loader derives: annotated COCO categories, filtered,
# sorted, enumerated from 0. This is the dataset-combined (8-class) list; the
# older data-40 checkpoint had 7 and no `discontinuity`, and inserting it at
# index 1 shifts everything after it. Checked against the head width at load.
CLASSES = ["crack", "discontinuity", "overlap", "porosity",
           "spatter", "undercut", "weld_seam", "workpiece"]


# ---------------------------------------------------------------------------
# verified core -- copied, not rewritten
# ---------------------------------------------------------------------------

def preprocess(img: Image.Image, size: int) -> np.ndarray:
    """RGB image -> (1, 3, size, size) float32 NCHW.

    A plain STRETCH to square: no letterbox, no aspect preservation. That is
    what makes the box maths in postprocess() so simple -- normalised
    coordinates in model space are already normalised coordinates in the
    original image.

    Bilinear, half-pixel centres, antialias OFF -- matching what predict() does.
    """
    rgb = np.asarray(img.convert("RGB"), dtype=np.float32) / 255.0
    t = torch.from_numpy(rgb).permute(2, 0, 1).unsqueeze(0)
    t = F.interpolate(t, size=(size, size), mode="bilinear",
                      align_corners=False, antialias=False)
    arr = t.squeeze(0).numpy()
    arr = (arr - IMAGENET_MEAN[:, None, None]) / IMAGENET_STD[:, None, None]
    return arr[None].astype(np.float32)


def postprocess(dets, labels, masks, orig_w, orig_h,
                threshold=0.25, num_select=NUM_SELECT, background_class_id=None):
    """(Q,4) cxcywh + (Q,C) logits + (Q,Hm,Wm) mask logits -> detections."""
    scores_all = 1.0 / (1.0 + np.exp(-np.clip(labels, -88, 88)))

    class_ids = np.arange(scores_all.shape[1])
    if background_class_id is not None:
        keep = class_ids != (background_class_id % scores_all.shape[1])
        scores_all, class_ids = scores_all[:, keep], class_ids[keep]

    _, c = scores_all.shape
    flat = scores_all.ravel()

    k = min(num_select, flat.size)
    order = np.lexsort((np.arange(flat.size), -flat))[:k]
    order = order[flat[order] > threshold]

    scores = flat[order]
    query_idx = order // c
    cls = class_ids[order % c]

    cx, cy, bw, bh = dets[query_idx].T
    xyxy = np.stack([cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2], 1)
    xyxy = xyxy * np.array([orig_w, orig_h, orig_w, orig_h], np.float32)

    out_masks = None
    if masks is not None and len(order):
        t = torch.from_numpy(masks[query_idx].astype(np.float32)).unsqueeze(0)
        t = F.interpolate(t, size=(orig_h, orig_w), mode="bilinear", align_corners=False)
        out_masks = t.squeeze(0).numpy() > 0.0

    return xyxy, scores, cls, out_masks


# ---------------------------------------------------------------------------
# the service
# ---------------------------------------------------------------------------

class Model:
    def __init__(self) -> None:
        self.net = None
        self.res = 1272
        self.background: int | None = None
        self.error: str | None = None
        self.warmup_ms: float | None = None
        self.last_ms: float | None = None
        # The GPU serialises anyway and the module is not reentrant; two phones
        # capturing at once should queue rather than fail.
        self._lock = threading.Lock()

    @property
    def ready(self) -> bool:
        return self.net is not None

    def load(self) -> None:
        if not CKPT.exists():
            self.error = f"checkpoint not found: {CKPT} (set WELDZ_CKPT)"
            log.error(self.error)
            return
        try:
            from rfdetr import RFDETR

            t0 = time.perf_counter()
            model = RFDETR.from_checkpoint(str(CKPT), trust_checkpoint=True)
            self.res = int(getattr(model.model_config, "resolution", 1272))
            nc = int(getattr(model.model_config, "num_classes", len(CLASSES)))
            if nc != len(CLASSES):
                self.error = (f"checkpoint head has {nc} classes, CLASSES lists "
                              f"{len(CLASSES)} -- labels would be wrong")
                log.error(self.error)
                return

            self.net = _to_export_mode(model, self.res, DEVICE)

            # warm on a real-shaped tensor: the first call pays CUDA context
            # creation and autotuning, which belongs here
            dummy = np.zeros((1, 3, self.res, self.res), np.float32)
            out = self.forward(dummy)
            # a head one wider than the class list carries a background slot,
            # which sits in the LAST column for these checkpoints
            self.background = None if out[1].shape[-1] == len(CLASSES) else -1

            self.warmup_ms = (time.perf_counter() - t0) * 1000
            self.error = None
            log.info("model ready: %s classes %d res %d background %s, warm in %.0f ms",
                     CKPT.name, nc, self.res, self.background, self.warmup_ms)
        except Exception as exc:                                   # noqa: BLE001
            self.error = str(exc)
            self.net = None
            log.exception("could not load model")

    def forward(self, tensor: np.ndarray):
        """Raw (dets, logits, masks), the same three the exported model emits."""
        with self._lock:
            t0 = time.perf_counter()
            with torch.no_grad():
                x = torch.from_numpy(tensor).to(DEVICE)
                out = self.net.forward_export(x)
            self.last_ms = (time.perf_counter() - t0) * 1000
        return [o.detach().float().cpu().numpy() for o in out]

    def infer(self, img: Image.Image, threshold: float = 0.25):
        """Image -> (xyxy px, scores, class ids, bool masks at image size)."""
        w, h = img.size
        dets, logits, masks = self.forward(preprocess(img, self.res))
        return postprocess(dets[0], logits[0], masks[0] if masks is not None else None,
                           w, h, threshold, background_class_id=self.background)

    def info(self) -> dict:
        return {
            "ready": self.ready,
            "checkpoint": str(CKPT),
            "device": DEVICE,
            "resolution": self.res,
            "classes": CLASSES,
            "background_slot": self.background,
            "warmup_ms": round(self.warmup_ms, 1) if self.warmup_ms else None,
            "last_infer_ms": round(self.last_ms, 1) if self.last_ms else None,
            "error": self.error,
        }


def _to_export_mode(model, size: int, device: str):
    """Put the module in the state `forward_export` needs.

    Two steps, and the first alone is not enough. Freezing each DinoV2 backbone
    to the export shape keeps DINOv2's antialiased bicubic position-embedding
    interpolation out of the path; then LWDETR.export() swaps forward ->
    forward_export on itself and every submodule that exposes export(),
    including the Backbone -- which otherwise still expects a NestedTensor and
    dies on `tensor_list.tensors`. One-way by design: there is no unexport().
    """
    from rfdetr.models.backbone.dinov2 import DinoV2

    inner = model.model.model
    for m in inner.modules():
        if isinstance(m, DinoV2):
            m.shape = (size, size)
    inner.export()
    inner.eval()
    return inner.to(device)


model = Model()
