# weldz-mobile

iOS. Aim, Capture, read the numbers. All inference is on the server.

## What it does

One persistent `ARSession` backs the preview. Capture grabs the current
`ARFrame` — so the RGB photo and the LiDAR depth map come from the **same
instant**, by construction — and posts both to the server with the camera
intrinsics. The server segments, measures, draws, and returns a finished JPEG
plus millimetre figures.

The phone does **no inference and no coordinate arithmetic**. That is deliberate:
when the model ran on-device, every bug came from tensor strides, a mask flip
and normalised→screen mapping. Returning a drawn image costs ~400 kB down and
removes that whole class of problem.

## Run

```bash
flutter pub get
ruby tool/add_sources.rb        # registers the Swift files with the Xcode target
flutter run -d <your-iphone>
```

`add_sources.rb` matters: `project.pbxproj` lists compiled sources explicitly, so
a `.swift` file written by anything other than Xcode is invisible to the build.
The symptom is `Cannot find 'ARSessionManager' in scope`.

Needs **iOS 16+** and a LiDAR device (iPhone 12 Pro or newer Pro).

On first launch, tap the pill at top-left to set the server URL — the
cloudflared quick tunnel hands out a new hostname each time it starts. `https://`
is assumed if you leave it off.

## Files

```
lib/
  main.dart        preview → capture → result, three states
  capture.dart     MethodChannel "weldz/capture"
  api.dart         multipart POST, typed response
  result.dart      annotated image + detection list
  settings.dart    server URL, persisted
  ar_preview.dart  UiKitView over the shared session

ios/Runner/
  ARSessionManager.swift   the session, the channel, the payload
  ARPreviewFactory.swift   the platform view
```

## Three things in the Swift that are hard-won

- **One persistent ARSession** for preview and capture. Two owners of the camera
  cannot coexist, and a start/warm-up/grab/tear-down cycle per capture means the
  RGB and the depth come from different moments.
- **`copyPlane` row by row.** `CVPixelBuffer` rows are padded; `bytesPerRow` is
  not `width × bytesPerPixel`.
- **Intrinsics describe the captured image, not the 256×192 depth grid.** Both
  sizes are sent; the server rescales. Mixing the two pixel spaces is the classic
  ARKit depth bug — it yields plausible, wrong millimetres.

## Wire format

`POST /measure`, multipart, ~600 kB up:

| part | content |
|---|---|
| `meta` | JSON: image size, depth size, `fx fy cx cy`, confidence threshold |
| `color` | JPEG, quality 0.85 |
| `depth` | `uint16` LE **millimetres**, 0 = no reading |
| `confidence` | `uint8`, ARKit levels |

`uint16` mm rather than float32 halves the depth part and compresses far better —
millimetre integers are not near-random the way float mantissas are. The 1 mm
quantisation sits an order of magnitude below ARKit's own ~3 mm noise.

## Not here, on purpose

Point cloud, on-device measurement fallback, acceptance verdicts, class toggling.
Each is self-contained and none is on the critical path to proving the loop. The
point cloud is a clean re-add from `rfdetr_test` if it is wanted back.
