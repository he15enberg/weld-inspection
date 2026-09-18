# weldz-server

RF-DETR Seg + LiDAR depth fusion, a deterministic rule engine, and a
vision-language model that explains the result but never decides it.

This branch holds the backend **and** the dashboard's host: one process serves
the API and the static dashboard on one port.

```
POST /measure                     meta (JSON) + color (JPEG) + depth + confidence
                                  -> detections in millimetres, a verdict, an overlay
GET  /health                      model status
GET  /captures                    the index; filter by verdict, label, date
GET  /captures/{id}               one stored record
GET  /captures/{id}/file/{name}   color.jpg · overlay.jpg · depth.u16 · confidence.u8
GET  /stats                       what the dashboard charts
GET  /rules   PUT /rules          the five editable rules
POST /rescore                     re-judge stored captures under the current rules
GET  /                            the dashboard (../weldz-dashboard)
```

## Run

One command brings up both processes:

```powershell
.venv\Scripts\python.exe serve.py --hf-home D:\hf-cache
```

```
vlm/service.py   ->  127.0.0.1:8001   Qwen3-VL-4B, the advisory note
main.py          ->  127.0.0.1:8000   RF-DETR, rules, dashboard
```

`serve.py` checks CUDA once, starts both, prefixes both logs and stops both on
Ctrl+C. Every setting lives in one place — they used to be retyped into two
shells, which is how a capture ends up judged under a threshold nobody meant to
set.

```
serve.py --no-vlm            detector only; captures carry no assessment
serve.py --ckpt <path>       a different checkpoint
serve.py --rotate 270 --crop 1380
serve.py --host 0.0.0.0      bind wider (default is localhost + cloudflared)
```

**Use the venv's python by full path.** A bare `python` may find a `+cpu` build
of torch, which reports `cuda: False` no matter what the driver says and cannot
run this at all.

### Without the launcher

```powershell
$env:WELDZ_CKPT     = "...\checkpoint_best_ema.pth"
$env:WELDZ_CAPTURES = "...\weldz-app\captures"
$env:WELDZ_VLM_URL  = "http://localhost:8001"
$env:WELDZ_ROTATE   = "270"
$env:WELDZ_CROP     = "1380"
python -m uvicorn main:app --host 127.0.0.1 --port 8000
```

`$env:` — not `set`. In PowerShell `set` is an alias for `Set-Variable` and
silently does nothing here.

### Install

```bash
pip install -r requirements.txt
# torch and rfdetr are deliberately unpinned there -- install them the way the
# training box already has them, i.e. the CUDA build
```

The VLM needs nothing extra: `transformers`, `accelerate` and `safetensors`
come with the same environment, and `rfdetr` accepts `transformers<6`.

## Environment

| | |
|---|---|
| `WELDZ_CKPT` | checkpoint. Defaults to `checkpoint_best_ema.pth` beside `main.py` |
| `WELDZ_CAPTURES` | **set this.** Unset, `store.ROOT` falls back to `Path("")`, which resolves to the *current directory* — day-folders scatter wherever uvicorn was launched and the dashboard finds nothing |
| `WELDZ_ROTATE` | quarter turns before inference, anticlockwise degrees. 270 for this hardware |
| `WELDZ_CROP` | square crop side. 1380; the server snaps a request down to a size whose edges land on whole depth pixels |
| `WELDZ_VLM_URL` | unset disables the assessment cleanly |
| `WELDZ_TOKEN` | unset leaves the server open |
| `WELDZ_DEVICE` | `cuda` |
| `HF_HOME` | keeps the 8 GB of VLM weights off the system drive |

The phone sends `rotate`, `crop` and `conf` per capture; the env vars are the
fallback for an older app build.

## Rotation and crop — the single biggest correctness fix

ARKit hands over `frame.capturedImage` in the sensor's own orientation and
**nothing corrects it**, while `ARSCNView` applies the interface-orientation
transform to the live preview. So the operator sees the part lying across the
frame and the model receives it standing on end — an orientation absent from
all 102 training images.

Measured over the stored captures:

| | weld seam found | workpiece confidence |
|---|---|---|
| as captured | 3 of 9 | 0.85 |
| **turned 270° (clockwise)** | **9 of 9** | **0.94** |

Direction is not symmetric — 90° also finds the seam but drops workpiece
confidence to 0.61 — which is why the phone reports its orientation rather than
the server assuming one.

The crop is a second, smaller win: `preprocess` stretches whatever it is given
to a square 1272, so a 4:3 frame arrives squeezed 25% in x. Cropping to square
removes that and, because it discards bench rather than weld, raises how much
of the frame the part fills.

**`frame.snap()` picks the crop size.** The depth grid is an exact 7.5×
reduction of the colour frame, so 1392 would start at depth pixel 3.2 — there
is no such pixel, and rounding slides depth against colour by nearly 4 colour
pixels. 1380 divides cleanly (184 px, offsets 4 and 36), so the search walks
down from whatever was asked for until every edge is exact.

Everything the client receives is in **one space**: turned, cropped, and the
way the operator was looking at it. The one exception is `mask_png`, which is
turned back — a mask is not looked at, it is *indexed*, against the raw depth
buffer the phone still holds.

## The verdict

Three layers, in order. Only the first is code.

**1 · `rules.py` — fatal classes.** A crack or a discontinuity ends the
assessment. Deliberately not editable from a browser.

**2 · `ruleset.py` — five tunable rules**, stored as versioned JSON beside the
captures and edited from the dashboard. `metric` is a closed vocabulary, not an
expression: a rule editor accepting formulae would be a remote-code endpoint
with a nice UI.

| rule | measured from |
|---|---|
| largest defect | biggest `width_mm` on the seam |
| defect density | count ÷ seam length × 100 |
| defect area | Σ defect area ÷ seam area |
| bead width | seam mask width across the joint |
| seam continuity | seam length ÷ joint length |

**3 · `scoring.py` — a weighted score** against two editable bands. This is what
lets a sound weld carry a few small pores: three score ~10 and pass, thirty
score ~235 and don't.

**INDETERMINATE is never a pass.** A rule needing the seam, on a capture with no
usable seam, drags the verdict to at least rework. Silence must not read as
clean.

Every capture records its `ruleset_version`. The moment limits are editable,
two captures judged under different limits are not comparable — and `POST
/rescore` can re-judge the archive without re-running the model, because the
detections and their millimetres are already on disk. It never touches
`detections`, only the judgement.

## Seam geometry and the spatial gate

`geometry.py` measures the `weld_seam` mask the pipeline used to detect and
discard: length along the joint, width across it, area, and continuity against
the workpiece. All lateral — bead crown height would need a plane fit against a
184×184 depth grid, and a 0.3 mm crown sits under that noise floor.

It also marks every defect `on_seam`. A pore on a bench cable is not a weld
defect. Detections are **annotated, never dropped** — an exclusion you cannot
see is indistinguishable from a detection that was never made.

A bead is long and thin, so a mask below `MIN_ELONGATION` is not a bead
whatever it is labelled. That is not theoretical: replayed over the stored
captures, eleven seams measured 94–99 mm long and 6.5–10.8 mm wide, and one
came back 124 × 112 mm — a blob covering most of the part, which without the
gate would have handed a 112 mm "bead width" to a rule with a 12 mm limit.

## The assessment is advisory

`vlm/service.py` runs Qwen3-VL-4B in its own process. It receives the overlay,
the verdict, and the rule table **with the arithmetic already done**, and is
asked where on the weld the tightest rule is — a question a vision model can
answer. It is told the verdict is decided and never to estimate a size.

Its only route to the UI beyond text is `missed_rejectable` (a rejectable
defect it can see that the detector did not) and `usable: false`, which gates a
capture as too blurred or badly framed to grade.

**Every failure is soft.** `assess.py` turns a timeout, a 500 or an unreachable
service into a status string; nothing raises. That is why it runs in its own
process: when the GPU vanished from under the VLM one morning, every capture
still produced a full verdict and only the advisory paragraph was missing.

## Files

| | |
|---|---|
| `serve.py` | starts both processes; all settings in one place |
| `main.py` | the endpoints |
| `model.py` | load, preprocess, postprocess |
| `frame.py` | rotate + square-crop, and the depth-pixel snap |
| `measure.py` | depth fusion → millimetres |
| `geometry.py` | seam metrics, spatial gate |
| `rules.py` | fatal classes (code) |
| `ruleset.py` | the five editable rules (data, versioned) |
| `scoring.py` | utilisations + weighted score → verdict |
| `overlay.py` | draws the result; **canonical class palette** |
| `assess.py` | VLM client, fails soft |
| `store.py` | SQLite index + files on disk |
| `vlm/service.py` | Qwen3-VL-4B on :8001 |
| `seed_demo.py` · `seed_from_capture.py` | populate the store for layout work |

## Do not rewrite `preprocess` / `postprocess`

Copied verbatim from `reference_postprocess.py`, verified bit-for-bit against
the model's own `predict()` — box delta 0.00, mask IoU 1.00000. Four things are
load-bearing and each fails *silently*:

1. **per-class sigmoid, not softmax** — the classes are independent
2. **top-k over the flattened `(Q, C)` grid, not an argmax per query** — a query
   can clear the threshold on more than one class. Harmless at conf 0.25, loses
   ~20% of detections at 0.05, collapses at 0.01
3. **gathered query indices may repeat**, precisely because of (2)
4. **masks are logits** — upsample first, threshold at 0 second

## Four pixel spaces

Mixing them yields plausible wrong numbers rather than errors:

| space | size | what lives here |
|---|---|---|
| capture | 1920×1440 | what the phone uploads; `fx fy cx cy` are quoted for **this** |
| analysed | 1380×1380 | after the turn and the crop — the overlay, every box, every mask |
| model | 1272×1272 | a plain **stretch** of the analysed frame; no letterbox |
| depth | 184×184 | the crop of ARKit's 256×192, exactly 7.5× down from the colour |

A crop applied to colour but not depth breaks `measure.py`'s premise that the
two share one field of view — producing wrong millimetres, not an error. So
`frame.prepare` turns and crops all three together.

## Measurement

Depth per detection is the **median over the mask**, not the box — a box around
a diagonal seam is mostly not the seam. High-confidence samples only, and
`depth_fill` reports what fraction was usable.

```
mm_per_px = z / fx * 1000        # fx in ANALYSED-frame pixels
area_mm2  = mask_pixels * mm_per_px²
```

```
σ_edge  = 2 × mm_per_px ≈ 0.42 mm at 300 mm   ← dominates
σ_scale = 1% of the measurement
```

**Mask boundary precision is the limit, not LiDAR accuracy**, for anything under
~40 mm — which is every defect.

## Check

```bash
python -m pytest test_rules.py test_measure.py -q     # 16 tests, no GPU needed
```

Then photograph an object of **known** width at a known distance and compare.
That is the only real ground truth available.

`../../inf-test/` replays stored captures through the model — two code paths,
four rotations, two checkpoints — and is how the rotation finding above was
measured.

## Exposing it

```bash
cloudflared tunnel --url http://localhost:8000
```

The tunnel dials **out**, so there is no firewall rule to add, and the phone
gets HTTPS — which iOS App Transport Security requires anyway. A quick tunnel
issues a new random hostname on every restart; for a stable one use a named
tunnel (needs a domain on Cloudflare's nameservers) or `tailscale funnel 8000`,
which needs none.

Set `WELDZ_TOKEN` once the hostname is permanent. A stable public URL pointing
at this workstation otherwise lets anyone who learns it POST images to the GPU
and read the results back. When set, every endpoint requires `X-Weldz-Token`
and answers 401 without it, compared with `secrets.compare_digest` so a wrong
guess cannot be narrowed down by timing.
