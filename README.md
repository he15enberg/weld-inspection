# weldz-server

RF-DETR Seg + LiDAR depth fusion. One endpoint.

```
POST /measure   multipart: meta (JSON) + color (JPEG) + depth + confidence
                -> detections in millimetres + an annotated JPEG
GET  /health    model status
```

## Run

```bash
pip install -r requirements.txt
# torch and rfdetr are deliberately not pinned there -- install them the way the
# training box already has them, i.e. the CUDA build for the 5090

set WELDZ_CKPT=D:\path\to\checkpoint_best_ema.pth
uvicorn main:app --host 127.0.0.1 --port 8000
```

Bind to localhost and put cloudflared in front:

```bash
cloudflared tunnel --url http://localhost:8000
```

The tunnel dials **out**, so there is no firewall rule to add, and the phone
gets HTTPS — which iOS App Transport Security requires anyway.

### A permanent hostname

A quick tunnel issues a new random `*.trycloudflare.com` on every restart. For a
stable URL use a **named tunnel** — which needs a domain on Cloudflare's
nameservers:

```bash
cloudflared tunnel login
cloudflared tunnel create weldz
cloudflared tunnel route dns weldz weldz.<your-domain>
cloudflared tunnel run --url http://localhost:8000 weldz
```

Then put that hostname in `weldz-mobile/lib/settings.dart` as `defaultUrl`.

No domain? `tailscale funnel 8000` gives a stable `*.ts.net` hostname with a
valid cert and needs no domain at all. Don't reach for ngrok — its free tier
moved to 2-hour sessions and random URLs in early 2026.

### WELDZ_TOKEN

Optional, and **off by default** — unset leaves the server open, which keeps a
quick tunnel usable with no ceremony:

```bash
set WELDZ_TOKEN=some-shared-secret
```

Worth setting once the hostname is permanent. A stable public URL pointing at
this workstation otherwise lets anyone who learns it POST images to the GPU and
read the results back.

When set, both endpoints require an `X-Weldz-Token` header and answer 401
without it. The comparison uses `secrets.compare_digest`, so a wrong guess can't
be narrowed down by timing the reply. `/health` reports `"auth": true` when it
is on, and startup logs which mode it came up in.

## Files

| | |
|---|---|
| `model.py` | load, preprocess, postprocess |
| `measure.py` | depth fusion → millimetres |
| `overlay.py` | draws the result server-side |
| `main.py` | the endpoint |
| `test_measure.py` | millimetre maths, no GPU needed |

## Do not rewrite `preprocess` / `postprocess`

They are copied verbatim from `reference_postprocess.py` on the `model_train`
branch, which was verified bit-for-bit against the model's own `predict()` —
box delta 0.00, mask IoU 1.00000. Four things in there are load-bearing and each
fails *silently* when got wrong:

1. **per-class sigmoid, not softmax** — the classes are independent
2. **top-k over the flattened `(Q, C)` grid, not an argmax per query** — a query
   can clear the threshold on more than one class. Measured on real welds:
   harmless at conf 0.25, loses ~20% of detections at 0.05, collapses at 0.01
3. **gathered query indices may repeat**, precisely because of (2)
4. **masks are logits** — upsample first, threshold at 0 second

## Three pixel spaces

Mixing them yields plausible wrong numbers rather than errors:

| space | size | what lives here |
|---|---|---|
| image | 1920×1440 | the JPEG; `fx, fy, cx, cy` are quoted for **this** |
| model | 1272×1272 | what RF-DETR sees — a plain **stretch** of image space |
| depth | 256×192 | ARKit `sceneDepth` |

Two facts keep it simple. The model resize is a stretch, so normalised
coordinates pass through unchanged — no letterbox unpadding. And ARKit's depth
shares the camera's field of view, so normalised coordinates map 1:1 onto the
depth grid.

## Measurement

Depth per detection is the **median over the mask**, not the box — a box around a
diagonal seam is mostly not the seam. High-confidence samples only, and
`depth_fill` reports what fraction was usable.

```
mm_per_px = z / fx * 1000        # fx in IMAGE pixels
area_mm2  = mask_pixels * mm_per_px²
```

The uncertainty has a conclusion worth knowing:

```
σ_edge  = 2 × mm_per_px ≈ 0.42 mm at 300 mm   ← dominates
σ_scale = 1% of the measurement
```

**Mask boundary precision is the limit, not LiDAR accuracy**, for anything under
~40 mm — which is every defect.

## Check

```bash
python test_measure.py     # 40 x 20 mm at 300 mm must come back 40 x 20 mm
```

Then, before trusting anything: photograph an object of **known** width at a
known distance and compare. That is the only real ground truth available.
