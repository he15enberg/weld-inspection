# rfdetr-test

RF-DETR Seg weld inspection with LiDAR measurement, for iOS.

Aim → **Capture** → masks, millimetre sizes, depth map, point cloud. One
ARSession serves all of it.

## The one structural difference from `yolo_test`

`yolo_test` has a camera hand-off: `YOLOView` owns the camera, ARKit cannot open
it at the same time, so Measure unmounts the live view, waits 250 ms, then runs
a one-shot depth capture. The RGB and the depth therefore come from **different
moments**.

Nothing here competes for the camera. `ARFrame` already carries `capturedImage`
*and* `sceneDepth`, and Core ML runs on the frame ARKit handed us — so one
persistent session covers preview, RGB, depth and inference, and every view in
the result screen describes the same instant.

There is no live inference. RF-DETR at 1272 is far too heavy per frame on a
phone; the preview is for aiming.

## Status

| | |
|---|---|
| Dart | **complete** — analyzes clean, tests pass |
| Swift | **written, never compiled** — needs a Mac |
| Model | **not yet exported** — no `.mlpackage` in the project |

Until the model is added, `RFDetrRunner` throws `modelMissing`, which surfaces
as a badge on the result screen. The capture, depth map, point cloud and the
whole Dart path still work — inference failure is deliberately non-fatal.

On Android and desktop `FakeCaptureSource` returns a synthetic frame with two
plausible detections, so the UI and the measurement maths run with no Mac.

## Layout

```
lib/
  main.dart            preview + Capture, three modes
  ar_preview.dart      UiKitView over the shared ARSession
  capture_source.dart  the weld/capture channel; DepthFrame; the fake source
  detection.dart       Detection + the palette (mirrors train/overlay.py)
  capture.dart         everything one press produces
  measure_screen.dart  RGB / Annotated / Sizes / Depth / Cloud
  overlay_painter.dart boxes + labels + mm, drawn over the native composite
  measurement.dart     mm sizing from depth        ported unchanged
  point_cloud.dart     unprojection + colouring    ported unchanged
  point_cloud_view.dart                            ported unchanged
  depth_map_view.dart                              ported unchanged

ios/Runner/
  ARSessionManager.swift  the persistent session, the channel, the payload
  RFDetrRunner.swift      Core ML load, preprocess, predict, postprocess
  MaskCompositor.swift    masks drawn onto the frame, returned as PNG
  ARPreviewFactory.swift  the platform view
```

Seven Dart files came across from `yolo_test` untouched. Only `main.dart` was
ever coupled to the YOLO plugin — `measureAll()` takes a plain record, not a
`YOLOResult`, so the measurement maths and its 12 tests moved verbatim.

## Where the work is split

Masks are composited **natively**; boxes and millimetre labels are drawn in
**Dart**. That split is deliberate: 100 queries × 318×318 float masks is ~40 MB
per capture and would dominate the channel round trip, while the mm figures are
computed in Dart from the depth frame and need to sit beside the box they
describe.

## Adding the model

1. Export on a Mac — `pip install "rfdetr[coreml]"`, then export at **1272**
   (divisible by 24: patch 12 × 2 windows). Note the `torch<2.12` pin; above it
   the CoreML/eager parity divergence rate jumps sharply.
2. **Before writing any more Swift**, run the exported `.mlpackage` in Python
   and diff it against `model.predict()`. If that fails it is a model problem,
   and finding out after the Swift is in play costs far more.
3. Drag the `.mlpackage` into **Runner.xcworkspace**, ticking the Runner
   *target*, and name it `weld_rfdetr`. Xcode compiles it to `.mlmodelc` at
   build time. Do **not** put it in Flutter `assets/` — an asset is an
   uncompiled file needing `MLModel.compileModel` on every cold start.
4. Update `RFDetrRunner.classNames` if the checkpoint is the 8-class combined
   one. The background slot is detected, not hardcoded, but the class *order*
   is not — `discontinuity` inserts at index 1 and shifts everything after it.

## Parity

`RFDetrRunner.postprocess` is a port of
`train/rfdetr/reference_postprocess.py`, which was verified bit-for-bit against
`model.predict()` (box delta 0.00, mask IoU 1.00000) before the Swift was
written. Change the Python first and re-run its check.

Two things in there are load-bearing and easy to "simplify" wrongly:

- **Top-k over the flattened (Q, C) grid, not an argmax per query.** Measured on
  real welds: harmless at conf 0.25, loses ~20% of detections at 0.05, collapses
  at 0.01. It would pass every test you would think to run at the default
  threshold.
- **Bilinear resize with antialiasing OFF.** `vImageScale` and Core Image both
  antialias when downscaling, which shifts confidences with no error. The
  preprocessor samples by hand for exactly this reason.

## Running

```
flutter analyze
flutter test
flutter run -d <ios-device>     # needs a Mac
```

Android builds and runs against the synthetic source.
