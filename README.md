# weldz-dashboard

Static HTML + vanilla JS, served by the same FastAPI that runs inference. No
build step, no node, no CORS, no second process — for something that has to run
from a laptop over a tunnel, one server on one port is worth more than a
component framework.

## Run

There is nothing to build and nothing to start. The server mounts this folder
at `/`:

```powershell
cd ..\weldz-server
.venv\Scripts\python.exe serve.py --hf-home D:\hf-cache
```

Then `http://localhost:8000/`. If the server runs with `WELDZ_TOKEN`, open
`http://localhost:8000/?t=YOUR_TOKEN` once — it moves into sessionStorage and
out of the URL bar.

**Cloned on its own?** The API is relative, so it needs a server beside it.
`weldz-server` mounts `../weldz-dashboard`, so clone both as siblings under one
parent. For pure layout work any static server will do, but every view will sit
empty — the charts, the captures and the rule editor all come from the API.

## Files

| | |
|---|---|
| `index.html` | structure; one `<script type="module">` |
| `style.css` | the phone app's tokens — Poppins, `#2F7FF0`, the dark surfaces |
| `app.js` | fetch, render, routing, the capture sheet |
| `charts.js` | inline SVG, no library; **the light class palette** |
| `rules.js` | the rule editor and the utilisation bar |
| `depth.js` | colourises a stored `depth.u16` onto a canvas |
| `cloud.js` | the orbiting point cloud, raw WebGL2 |

## Navigation

A left sidebar, four views:

| view | contents |
|---|---|
| **Overview** | verdict tiles, verdicts per day, the same three series as small multiples, reject rate, captures by hour |
| **Captures** | filterable list, newest first; a row opens the full record |
| **Quality** | defects by class, size per class, framing vs verdict, depth coverage, table view |
| **Rules** | the five editable rules, the score bands, and re-scoring the archive |

Routes are `#/overview`, `#/captures`, `#/quality`, `#/rules`,
`#/capture/<id>`. **The leading slash is load-bearing:** a bare `#captures`
matches `<section id="captures">` and the browser anchor-scrolls, sliding the
filter bar under the sticky header.

Overview and Quality share one `/stats` call; Rules loads its own. The sidebar
footer describes the whole store rather than one view, so it is filled from the
boot `/stats` call too — otherwise a deep link straight to `#/captures` opens
with a sidebar full of em-dashes.

## The rule editor

Five rules, each `metric · comparator · limit · weight · on-breach · enabled`,
plus two score bands. Saved with `PUT /rules`, which bumps a version.

Two things it deliberately does **not** do.

**It does not let you type a metric.** The server publishes the list of
quantities it knows how to compute and the editor offers only those. An editor
accepting an expression would be a remote-code endpoint with a nice UI.

**It does not save and re-score in one action.** *Preview impact* runs
`POST /rescore?dry_run=1` and shows what would move — "12 captures change
verdict: 8 approve→rework" — before anything is written. Overwriting an archive
of verdicts is not something to do by accident.

Saving changes how *future* captures are judged; the archive keeps the verdict
it was given until you apply a re-score. The editor says so, because otherwise
the charts look wrong for a reason nobody can find.

Limits for fractional metrics are shown as percentages — nobody thinks about
porosity in `0.02` — and converted back on save. Rules needing a measurable weld
seam say so in amber: without one they report **indeterminate**, not pass.

## The capture sheet

`overlay.jpg` carries the masks, and the boxes and labels are drawn again on
top as an SVG + HTML layer.

The reason is scale. The server bakes a 2 px stroke into a 1380 px image; shown
in a 380 px card that is a 0.28 scale, so the stroke lands at **half a pixel**
and the captions at four. The picture is correct and unreadable. Masks are
regions and scale fine, so they stay baked; strokes use
`vector-effect: non-scaling-stroke` and labels are HTML, so both keep their CSS
size at any card width.

`bbox_px` and `overlay.jpg` are in the same space — the turned, cropped frame
the model works in — which is what makes drawing one on the other exact rather
than approximately aligned.

**Not every box gets a caption.** Thirty porosity pits along one bead is a
normal result and thirty captions is an unreadable pile. Captions are placed
greedily — structural first, then defects by confidence — and one that would
land on a caption already placed is dropped while its box stays. The panel says
how many were hidden; the table below lists every detection.

The **raw captured frame sits the other way up** from the Segments panel, and
says so in its own caption. It is the camera buffer; the analysed region is
turned and cropped out of it.

Utilisation bars show each rule against its limit, the marker at 100%, a breach
running past it.

## Chart decisions

Form was picked per measure, before any colour:

| measure | form | why |
|---|---|---|
| verdict split | stat tiles | three numbers with a status meaning; a 3-slice donut of close values is harder to read than the numbers |
| captures per day | stacked bars | composition over time; 3 series, so a legend is mandatory and segments get a 2px surface gap |
| defects by class | ranked bars, **one colour** | colouring each bar by class would double-encode length as hue and burn the only free channel on what the axis already says |
| framing vs verdict | bars in the status colours | here the categories *are* the verdicts |
| verdict trend | **small multiples**, one shared scale | a stacked bar shows composition well and trend badly — only the bottom segment sits on a baseline. Three panels fix that; a second y-axis would invent a correlation |
| reject rate | line + dashed period average | a rate needs a reference to be read against |
| size per class | median + p5–p95 range | median, not mean — one large pore drags a mean and hides the typical case |
| captures by hour, depth coverage | histogram, one hue | the axis already carries the category, so a colour ramp would double-encode height |

Days with fewer than three captures are drawn as **hollow** points on the reject
rate and excluded from the axis scaling. A 100% rate from a single capture is
noise, and left in it pins the axis at 100% and flattens the real trend.

## Colour

`CLASS_COLOUR` here is the **light-surface stepping** of the palette in
`weldz-server/overlay.py`, which is canonical. Change both together, plus
`weldz-mobile/lib/theme.dart` and `train/overlay.py` (BGR).

Eight hues drawn on one photograph is an all-pairs problem, and **no eight-hue
set clears the colour-blind gates all-pairs** — that was measured with the
palette validator across several orderings, not assumed. So the palette is built
to a weaker but honest rule: *every pair that is still confusable leads to the
same decision.* crack/discontinuity are both reject; porosity/spatter both
acceptable. The four classes present on every frame — porosity, spatter,
workpiece, weld_seam — were validated as a set and **pass every gate all-pairs**
in both modes.

`undercut` (`#EDA100`) measures 2.11:1 against the light surface, under the 3:1
bar, which is why the class name is always printed beside its swatch and the
table view exists. Colour never carries a class alone.

### Why the status colours differ from the app

The app uses `#2ECC71 / #F1C40F / #E74C3C`. Measured against this surface,
yellow↔green is **ΔE 6.8 for protanopia** — fine on a badge carrying an icon and
a word, not fine for adjacent segments of a stacked bar where hue is the only
thing separating them.

The trio here (`#0ca30c / #fab219 / #d03b3b`) measures **11.3** and clears
contrast. Every verdict mark still ships with a glyph (`✓ ⟳ ✕`) and a label, and
a table view of every chart is one click away.

## Point cloud

`cloud.js` renders the stored depth buffer as an orbiting 3D cloud, coloured
from the photograph or by depth, croppable to the workpiece mask. Raw WebGL2 and
a hand-written 4×4 rather than three.js: there is no build step, and this is
served off a laptop where a CDN fetch is one more thing that can fail.

**Its geometry mirrors `weldz-mobile/lib/roi.dart` and has to.** The stored
`depth.u16` is the full 256×192 upload, but the masks inside `result.json` are
sized to the analysed crop (184×184) — so depth must be cut to
`geometry.depth_crop_box_source` before a mask can index it. Skip that and the
two are different grids: 33,856 entries against 49,152, which is what emptied
the app's workpiece view before it was fixed. `fx`/`fy` survive a crop
untouched; only the principal point moves, by the crop origin.

Framing uses the cloud's **lateral** extent, not its depth range. Framing off
the far distance put the camera 289 mm back for a part 115 mm across, because
the depth range is wider than the part is tall once a few bench points survive
the mask edge.

## Sample data

`weldz-server/seed_from_capture.py` clones one **real** capture across a stretch
of dates, copying the four binary files verbatim — so every seeded row has a
genuine photo, depth map and workpiece mask, and the point cloud works on all of
them. Only the detection list is resampled, and the verdict is re-derived by the
same `scoring.evaluate` the server runs against the live `ruleset.json`, so no
row carries a verdict the rule table would disagree with.

Sampling is tuned against the actual limits rather than by feel: weights are
porosity 5, overlap 15, undercut 25 with bands at 20/60, E1 trips over 3 mm and
E3 once defects pass 2% of the seam area. The first run ignored those and came
out at a 71% reject rate.

`seed_demo.py` is the older, fully synthetic version — small drawn JPEGs rather
than real frames. Every row either script writes carries `"demo": true`, and `--wipe`
clears them. Clear them before recording anything real: an inspection
archive that mixes invented rows with real ones without saying so is worse than
an empty one.

## Checking a change

The layout is absolute-positioned in places, so render before shipping. Three
overflows and a set of arrowheads buried under the next card were only ever
visible in an exported screenshot. Headless Chrome against a running server:

```
chrome --headless --disable-gpu --window-size=1420,1400 `
       --screenshot=out.png "http://localhost:8000/index.html#/rules"
```

One trap worth knowing if you write a throwaway test server: match API routes
**exactly**. A prefix match on `/rules` also swallows `/rules.js`, the module
fails to load, and the whole dashboard silently falls back to the default view.
FastAPI matches exact paths, so the real server is fine.
