# WeldZ

**AI vision that turns a single photo into a measurable, repeatable weld verdict.**

Built for manual fillet welds — the most common structural joint, and the one
usually checked by eye and a tape measure. A human inspector's call is fast but
unrecorded, unrepeatable, and impossible to audit a month later. WeldZ takes one
press on a phone and returns a verdict backed by millimetres, a drawn overlay, and
a stored record.

**One phone. One verdict. A record every time.**

---

## The loop

| | | |
|---|---|---|
| **01 · CAPTURE** | Photo, LiDAR depth and lens data, in one press | Both come from the *same* `ARFrame`, so colour and depth are the same instant by construction |
| **02 · DETECT** | RF-DETR Seg outlines the workpiece, the seam and every defect | 8 classes, instance masks, not just boxes |
| **03 · MEASURE** | Each outline is read against the depth map to get millimetres | Median depth over the **mask**, not the box |
| **04 · DECIDE** | A rule table turns findings into one verdict | Deterministic, versioned, editable from the browser |
| **05 · RECORD** | Photo, depth, masks and verdict saved to the archive | `result.json` is the record of truth |

**The rules engine always decides.** An optional vision-language model can explain
the verdict and flag a frame as unusable, but it never overrules it. That split is
the whole design: a system where an LLM decides pass/fail is one you cannot defend
when it changes its mind on the same photo.

---

## How the pieces fit

Three parts: the phone captures, the server decides, the browser reviews.

```
   iPhone (LiDAR)                    Workstation (GPU)                  Browser
 ┌────────────────┐            ┌──────────────────────────┐        ┌─────────────┐
 │  WELDZ APP     │            │  WELDZ SERVER  :8000     │        │  DASHBOARD  │
 │  Flutter+ARKit │            │  FastAPI                 │        │  static JS  │
 │                │  POST      │                          │  GET   │             │
 │ live preview   │ /measure   │  rotate + square crop    │ /stats │  history    │
 │ + ROI overlay  ├───────────►│  RF-DETR Seg (8 classes) │◄───────┤  charts     │
 │                │  ~600 kB   │  depth fusion → mm       │ /rules │  rule editor│
 │ verdict, rules │            │  seam geometry           │        │  point cloud│
 │ point cloud    │◄───────────┤  rule engine → verdict   ├───────►│             │
 └────────────────┘  JSON +    │  overlay renderer        │  same  └─────────────┘
                     overlay   └───────┬──────────┬───────┘  port
                                       │          │
                              ┌────────▼───┐  ┌───▼──────────────────┐
                              │ VLM  :8001 │  │ STORAGE              │
                              │ Qwen3-VL-4B│  │ SQLite index +       │
                              │ advisory   │  │ color.jpg depth.u16  │
                              │ optional   │  │ confidence.u8        │
                              └────────────┘  │ result.json          │
                                              └──────────────────────┘
```

**One server on one port serves both the API and the dashboard** — there is nothing
to build and nothing to deploy but a laptop. No node, no bundler, no CORS, no second
origin. For something that has to run from a laptop over a tunnel, that matters
more than a component framework.

The VLM runs in its **own process** so that when the GPU falls over under it, every
capture still produces a full verdict and only the advisory paragraph goes missing.

---

## Branches

Each part of the system lives on its own branch. This branch is the front page.

| branch | what it is |
|---|---|
| [`weldz-server`](../../tree/weldz-server) | FastAPI: inference, depth fusion, seam geometry, rule engine, overlay, storage, VLM. Also hosts the dashboard. |
| [`weldz-dashboard`](../../tree/weldz-dashboard) | Static HTML + vanilla JS: history, charts, rule editor, 3D point cloud. |
| [`weldz-mobile`](../../tree/weldz-mobile) | Flutter + ARKit iOS app. Capture, result, archive. |
| [`model_train`](../../tree/model_train) | Training and export scripts — RF-DETR Seg, YOLO, CoreML conversion, the reference postprocess. |
| [`rfdetr-mobile`](../../tree/rfdetr-mobile) | Earlier prototype: RF-DETR running **on-device**. Kept for the comparison. |

Each branch has its own README covering what it does and how to run it alone.

### Quick start

```bash
git clone -b weldz-server    <repo> weldz-server
git clone -b weldz-dashboard <repo> weldz-dashboard    # sibling folder — the server mounts ../
cd weldz-server && python serve.py
```

Then `http://localhost:8000/` for the dashboard, and point the phone app at the
same host (over `cloudflared tunnel --url http://localhost:8000` for HTTPS, which
iOS requires).

---

## The model

**RF-DETR Seg Small**, fine-tuned on a dataset we photographed ourselves.

| | |
|---|---|
| images | **102** — 78 train / 24 validation |
| outlines | 872 instance masks |
| classes | 8 |
| resolution | 1272 × 1272 |
| best segm mAP@50 | **0.442** (epoch 35) |
| segm mAP@50-95 | 0.298 |
| run | 79 epochs, early stopping patience 40 |

```
crack   discontinuity   overlap   porosity   spatter   undercut   weld_seam   workpiece
└──── reject ────┘      └──── rework ────┘   └ acceptable ┘       └─ structure ─┘
```

`weld_seam` and `workpiece` are not defects — they are the reference frame. Without
the seam there is nothing to measure a defect *against*, and the verdict says
**indeterminate** rather than pretending the weld is clean.

**Why 1272?** RF-DETR Seg Small uses patch size 12 across 2 windows, so the input
must divide by 24. 1272 = 24 × 53. This is not a suggestion — an unaligned
resolution fails at load, which is why even Roboflow's own `resolution=640`
example does not work with this model.

**No letterboxing anywhere.** Preprocessing is a plain stretch to square, so the
frame the model sees is cropped square first — otherwise a 4:3 frame arrives
squeezed 25% in x.

---

## The verdict

Three layers, applied in order. Only the first is hard-coded.

**1 · Fatal classes.** A crack or a discontinuity ends the assessment. Not editable
from a browser, on purpose.

**2 · Five tunable rules**, stored as versioned JSON and edited from the dashboard:

| rule | measured from |
|---|---|
| largest defect | biggest width on the seam |
| defect density | count ÷ seam length |
| defect area | Σ defect area ÷ seam area |
| bead width | seam mask width across the joint |
| seam continuity | seam length ÷ joint length |

`metric` is a **closed vocabulary**, never an expression. A rule editor that
accepts formulae is a remote-code endpoint with a nice UI.

**3 · A weighted score** against two editable bands. This is what lets a sound weld
carry a few small pores: three score ~10 and pass, thirty score ~235 and don't. A
fixed defect→verdict lookup cannot express that.

Every capture records its `ruleset_version`, because the moment limits are editable,
two captures judged under different limits are not comparable. `POST /rescore`
re-judges the whole archive under new rules **without re-running the model** — the
detections and their millimetres are already on disk. It never touches the
detections, only the judgement.

---

## Three things that actually decide result quality

Measured on real captures, not assumed.

### 1 · Orientation — worth more than everything else combined

ARKit applies the interface-orientation transform to the live preview but **not** to
`frame.capturedImage`. The operator and the model were looking at the same part 90°
apart — an orientation absent from all 102 training images.

| | weld seam found | workpiece confidence |
|---|---|---|
| as captured | 3 of 9 | 0.85 |
| **turned 270°** | **9 of 9** | **0.94** |

The turn happens on the server, in one place, because the depth map and the
confidence map have to move with it.

### 2 · Framing

The model was trained on welds that fill the frame. A small part at distance costs
roughly **−39%**. The app draws the exact crop region on the live preview for this
reason — it is not decoration.

### 3 · Depth-pixel alignment

The depth grid is an exact 7.5× reduction of the colour frame, so a 1392 crop would
begin at depth pixel 3.2 — which does not exist, and rounding slides depth against
colour by nearly 4 pixels. The crop is snapped down to **1380**, whose edges land on
whole depth pixels (184, offsets 4 and 36).

None of these three produce an error. They produce plausible wrong numbers, which is
worse.

---

## Four pixel spaces

Mixing them is the single easiest way to get confident nonsense:

| space | size | what lives here |
|---|---|---|
| capture | 1920 × 1440 | what the phone uploads; `fx fy cx cy` are quoted for **this** |
| analysed | 1380 × 1380 | after the turn and the crop — the overlay, every box, every mask |
| model | 1272 × 1272 | a plain stretch of the analysed frame |
| depth | 184 × 184 | the crop of ARKit's 256×192 |

```
mm_per_px = z / fx * 1000
σ_edge    = 2 × mm_per_px ≈ 0.42 mm at 300 mm     ← dominates
σ_scale   = 1% of the measurement
```

**Mask boundary precision is the limit, not LiDAR accuracy**, for anything under
~40 mm — which is every defect we care about.

---

## Why an iPhone and not an industrial depth camera

- **Resolution.** 1920×1440 colour feeds a 1272 model; a RealSense D435 gives
  1280×720, and the defects here are millimetres wide.
- **Synchronised depth.** One `ARFrame` carries colour, depth, confidence and
  intrinsics from the same instant. No rig, no calibration step, no drift.
- **It is already in the inspector's pocket.** The deployment story is "install an
  app", not "mount a sensor on the line".

The trade is that LiDAR depth is coarse — 256×192, ~3 mm noise. So depth is used
for **scale**, not for surface profile: it converts pixels to millimetres and
crops the part out of the scene. Bead crown height would need a plane fit the grid
cannot support, so it is not claimed.

---

## What this is honest about

- The dataset is **102 images**. The model generalises to our parts and our
  lighting; it is not a certified instrument and does not claim to be one.
- The rules are **ISO-*like*, not ISO**. Five editable limits chosen to be legible
  and defensible, not a standards implementation.
- The VLM is **advisory** and off by default.
- Verdicts are only comparable within one `ruleset_version`.

Every one of those is visible in the UI rather than buried here.
