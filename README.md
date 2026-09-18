# weldz-mobile

iOS. Aim, capture, read the verdict. All inference is on the server.

## What it does

One persistent `ARSession` backs the preview. Capture grabs the current
`ARFrame` — so the RGB photo and the LiDAR depth map come from the **same
instant**, by construction — and posts both to the server with the camera
intrinsics. The server turns, crops, segments, measures, judges and draws, then
returns a finished JPEG plus millimetre figures and an acceptance verdict.

The phone does **no inference and no coordinate arithmetic on the result**. That
is deliberate: when the model ran on-device, every bug came from tensor strides,
a mask flip and normalised→screen mapping. Returning a drawn image costs ~400 kB
down and removes that whole class of problem.

## Run

```bash
flutter pub get
ruby tool/add_sources.rb        # registers the Swift files with the Xcode target
flutter run -d <your-iphone>
```

`add_sources.rb` matters: `project.pbxproj` lists compiled sources explicitly, so
a `.swift` file written by anything other than Xcode is invisible to the build.
The symptom is `Cannot find 'ARSessionManager' in scope`.

Needs **iOS 16+** and a LiDAR device (iPhone 12 Pro or newer Pro). There is no
simulator path — there is no LiDAR in the simulator, and a capture without depth
has nothing to measure with.

It also needs `weldz-server` reachable over HTTPS. Nothing in this repo runs
standalone beyond the camera preview.

## The server URL

Lives in **Settings → Server**, asked for once and then remembered. Not on every
launch and not on every capture — a `cloudflared` quick tunnel issues a new
hostname each time it starts, so that works out to once per tunnel.

The dialog has a **Test** button that calls `/health` — worth using, because
otherwise a stale URL is only discovered *after* a capture has been taken and
thrown away. It reports whether the server answered **and** whether the model
loaded, which are different failures.

`https://` is assumed if you leave it off. Clearing the field forgets the stored
URL. `Token` is only needed if the server was started with `WELDZ_TOKEN` set.

There is deliberately **no URL on the capture screen**. It used to float there,
and it was the wrong thing to give screen space to: it changes once a session,
while framing changes every shot.

### Making it permanent later

```dart
// lib/settings.dart
static const defaultUrl = 'your-host.example.com';
```

A stored value still wins, so it is only a fallback. A named Cloudflare tunnel
needs a domain on their nameservers; `tailscale funnel 8000` gives a stable
`*.ts.net` hostname without one.

## Hold the phone portrait

The part should lie **across** the frame, and you hold the phone upright. Those
two things are consistent, and the reason is worth knowing because it was the
single biggest correctness bug in the project.

ARKit applies the interface-orientation transform to `ARSCNView`, so the preview
looks right. It does **not** apply it to `frame.capturedImage`, which comes out
in the sensor's own orientation. The operator and the model were looking at the
same part 90° apart — an orientation absent from all 102 training images.

The fix is a quarter turn on the server, not here, because the server also has to
turn the depth map and the confidence map by the same amount, and doing it in one
place is the only way they stay in step. The phone just reports `rotate` (270)
with each capture.

In the result view that leaves two kinds of image:

- **Segments** comes back already turned — it is drawn in the analysed space — so
  it is shown as-is (`upright: true`).
- **RGB, Depth, Cloud, Part** are built from raw phone buffers, so they get
  `RotatedBox(quarterTurns: 1)` to match what you saw through the viewfinder.

Getting this wrong is invisible in code review and obvious on screen, so if you
touch it, take one capture and look at all five tabs.

## The ROI box is not decoration

The live view draws the exact square the server will crop to. Everything outside
it is discarded before the model ever sees the frame.

The model was trained on welds that **fill the frame**; a small part at distance
scores badly and finds no seam. Measured over real captures, framing is worth
more than every other lever in the app — which is why the region is on screen
rather than only in this file.

A centred square crop keeps the same pixels whichever way the frame is turned, so
the box can be drawn before any rotation is applied.

## Settings

| section | |
|---|---|
| **Server** | URL, token, Test |
| **Model** | confidence threshold, rotation, crop side — sent with every capture |
| **Inspection** | material thickness, quality level — inert placeholders |
| **About** | model, inference size, depth grid |

The Model values ride along in `meta` on each `POST /measure`, so the server's
env vars are only a fallback for an older build. Defaults: conf `0.25`, rotate
`270`, crop `1380`.

**1380, not 1392.** The depth grid is an exact 7.5× reduction of the colour
frame, so a 1392 crop would begin at depth pixel 3.2 — which does not exist. The
server snaps whatever it is given down to a side whose edges land on whole depth
pixels, so an odd number here is corrected rather than rejected; the field only
shows what was asked for.

## History

`history_screen.dart` reads the real archive from `GET /captures` — paged, newest
first, filterable by verdict. A row opens `history_detail.dart`, which fetches the
stored record and its files and hands them to the **same `ResultView`** the
capture screen uses, so a capture from last week looks exactly like one taken a
second ago and there is only one result UI to maintain.

A stored capture whose binaries are missing renders a reduced view — findings and
verdict without the image tabs — rather than an error page. The provenance line
names the ruleset version the verdict was made under, because with editable rules
two captures are not automatically comparable.

## Files

```
lib/
  main.dart              nav shell: Capture · History · Settings
  theme.dart             blue + Poppins, the class palette, PageTitle

  capture_screen.dart    preview, ROI overlay, shutter, result
  roi.dart               crop geometry, shared with the cloud views
  capture.dart           MethodChannel "weldz/capture"
  ar_preview.dart        UiKitView over the shared session
  api.dart               multipart POST, typed responses, /captures
  result.dart            the five views + the findings list
  verdict_card.dart      verdict, gate, utilisation bars

  depth_view.dart        colourised LiDAR depth
  point_cloud.dart       unprojection, colouring, mask cropping
  point_cloud_view.dart  orbiting viewer (drawRawAtlas)

  settings.dart          URL, token, conf, rotate, crop — persisted
  settings_screen.dart   the four sections above
  history_screen.dart    the archive, from the server
  history_detail.dart    one stored capture, through ResultView

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
**lazily**, on first visit, because unprojecting 49k points and decoding the JPEG
for colour is not work to do for a tab nobody opens.

**Part** needs the mask, which is the one thing the server adds beyond numbers:
each detection carries `mask_png`, already downsampled to the depth grid. A
typical blob is ~300 bytes, so it costs nothing — and cropping happens in depth
space anyway, so a full-resolution mask would be pointless.

`mask_png` is also the **one** thing the server sends back un-turned, because a
mask is not looked at, it is *indexed* — against the raw depth buffer this phone
still holds. Crop that depth to `geometry.depth_crop_box_source` before indexing,
or the two are different grids (33,856 entries against 49,152) and Part comes back
empty. `roi.dart` does that; `weldz-dashboard/cloud.js` mirrors it, and the two
have to stay in step.

If the model finds no `workpiece` or `weld_seam`, Part shows an empty cloud and
says why, rather than quietly showing the full frame under a label claiming
otherwise.

## The verdict

`verdict_card.dart` shows the server's decision — approve, rework or reject — the
headline cause, and a utilisation bar per rule with the marker at 100%.

Two things it shows that are easy to drop:

**The gate.** If the assessment judged the capture unusable — too blurred, badly
framed — the card says so above the verdict. A grade on a frame nobody could read
is worse than no grade.

**Indeterminate is not a pass.** A rule needing a weld seam, on a capture with no
measurable seam, is drawn as indeterminate and drags the verdict down. It is
never rendered as a satisfied rule.

The phone computes none of this. It displays what `POST /measure` returned.

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
| `meta` | JSON: image size, depth size, `fx fy cx cy`, `conf`, `rotate`, `crop` |
| `color` | JPEG, quality 0.85 |
| `depth` | `uint16` LE **millimetres**, 0 = no reading |
| `confidence` | `uint8`, ARKit levels |

`uint16` mm rather than float32 halves the depth part and compresses far better —
millimetre integers are not near-random the way float mantissas are. The 1 mm
quantisation sits an order of magnitude below ARKit's own ~3 mm noise.

## Not here, on purpose

On-device inference fallback, class toggling in the overlay, offline capture
queueing. Each is self-contained and none is on the critical path to proving the
loop: the phone's job is to take one honest frame and show what came back.
