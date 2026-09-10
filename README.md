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

## The server URL

Asked for **once, the first time it is needed**, then remembered. Not on every
launch and not on every capture — a `cloudflared` quick tunnel issues a new
hostname each time it starts, so that works out to once per tunnel.

The pill at **top-left** shows where captures are going and is the only way in.
Tap it when the tunnel restarts and paste the new hostname. `https://` is assumed
if you leave it off.

The dialog has a **Test** button that calls `/health` — worth using, because
otherwise a stale URL is only discovered *after* a capture has been taken and
thrown away. It reports whether the server answered **and** whether the model
loaded, which are different failures.

Clearing the field forgets the stored URL, so the next capture asks again.

`Token` is only needed if the server was started with `WELDZ_TOKEN` set.

### Making it permanent later

Put a hostname in `lib/settings.dart` and rebuild:

```dart
static const defaultUrl = 'your-host.example.com';
```

A stored value still wins, so it is only a fallback. A named Cloudflare tunnel
needs a domain on their nameservers; `tailscale funnel 8000` gives a stable
`*.ts.net` hostname without one.

## Files

```
lib/
  main.dart              nav shell: Capture · History · Settings
  theme.dart             blue + Poppins, the class palette, PageTitle

  capture_screen.dart    preview, reticle, shutter, result
  capture.dart           MethodChannel "weldz/capture"
  ar_preview.dart        UiKitView over the shared session
  api.dart               multipart POST, typed response
  result.dart            the five views + the findings list

  depth_view.dart        colourised LiDAR depth
  point_cloud.dart       unprojection, colouring, mask cropping
  point_cloud_view.dart  orbiting viewer (drawRawAtlas)

  settings.dart          server URL + token, persisted
  settings_screen.dart   server section (real) + the rest (inert)
  history_screen.dart    fixtures, clearly labelled as such

ios/Runner/
  ARSessionManager.swift   the session, the channel, the payload
  ARPreviewFactory.swift   the platform view
```

## The five result views

| tab | where it comes from |
|---|---|
| **RGB** | the capture's own JPEG |
| **Segments** | the server's annotated JPEG — masks and boxes already drawn |
| **Depth** | the depth map, colourised on-device over this frame's near/far |
| **Cloud** | every depth sample, unprojected here and coloured from the photo |
| **Part** | the same cloud, cropped to the workpiece mask |

Only *Segments* comes back drawn. The other four are built from bytes the phone
already holds, so nothing is round-tripped for them — and both clouds are built
**lazily**, on first visit, because unprojecting 49k points and decoding the
JPEG for colour is not work to do for a tab nobody opens.

**Part** needs the mask, which is the one thing the server adds beyond numbers:
each detection carries `mask_png`, already downsampled to the depth grid. A
typical blob is ~300 bytes, so it costs nothing — and cropping happens in depth
space anyway, so a full-resolution mask would be pointless.

If the model finds no `workpiece` or `weld_seam`, Part shows an empty cloud and
says why, rather than quietly showing the full frame under a label claiming
otherwise.

## Framing matters more than anything in this app

The reticle on the live view is not decoration. The model was trained on welds
that **fill the frame**; a small part at distance scores badly and finds no
seam. Getting the workpiece inside those brackets is the single largest lever on
result quality, which is why it is on screen rather than only in this file.

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
