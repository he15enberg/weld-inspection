# weldz-dashboard

Static HTML + vanilla JS, served by the same FastAPI that runs inference. No
build step, no node, no CORS, no second process — for something that has to work
from a laptop on a tunnel during a demo, one server on one port is worth more
than a component framework.

Open `http://localhost:8000/`. If the server runs with `WELDZ_TOKEN`, open
`http://localhost:8000/?t=YOUR_TOKEN` once — it moves into sessionStorage and
out of the URL bar.

## Files

| | |
|---|---|
| `index.html` | structure; one `<script type="module">` |
| `style.css` | the phone app's tokens — Poppins, `#2F7FF0`, the dark surfaces |
| `charts.js` | inline SVG, no library |
| `depth.js` | colourises a stored `depth.u16` onto a canvas |
| `app.js` | fetch, render, routing |
| `../weldz-server/seed_demo.py` | fills the store with synthetic captures for layout work |

## Navigation

A left sidebar, three views:

| view | contents |
|---|---|
| **Overview** | verdict tiles, verdicts per day, the same three series as small multiples, reject rate, captures by hour |
| **Captures** | filterable list, newest first; a row opens the full record |
| **Quality** | defects by class, size per class, framing vs verdict, depth coverage, and the table view |

Routes are `#/overview`, `#/captures`, `#/quality`, `#/capture/<id>`. **The
leading slash is load-bearing:** a bare `#captures` matches
`<section id="captures">` and the browser anchor-scrolls, sliding the filter bar
under the sticky header.

Overview and Quality share one `/stats` call. The sidebar footer and the demo
banner describe the whole store rather than one view, so they are filled from
the boot `/stats` call too — otherwise a deep link straight to `#/captures`
opens with a sidebar full of em-dashes.

## Demo data

`python weldz-server/seed_demo.py --days 14` writes plausible captures into
`WELDZ_CAPTURES` so the charts have shape while there is nothing real recorded:
a weekday rhythm, a reject rate drifting down over the fortnight, framing
correlated with verdict, and porosity on a long tail so p50 and p95 differ.

Every row it writes carries `"demo": true`, and an amber banner names the count
on every view while any are present. Clear them with `--wipe` before recording
anything real: an inspection archive that mixes invented rows with real ones
without saying so is worse than an empty one.

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

The class swatch still appears beside each label in the defects chart, where it
does real work: matching the colour the reader saw on the overlay photograph.

## Why the status colours differ from the app

The app uses `#2ECC71 / #F1C40F / #E74C3C`. Measured with the palette validator
against this surface, yellow↔green is **ΔE 6.8 for protanopia** — fine on a badge
carrying an icon and a word, not fine for adjacent segments of a stacked bar
where hue is the only thing separating them.

The trio here (`#0ca30c / #fab219 / #d03b3b`) measures **11.3** and clears
contrast. Every verdict mark still ships with a glyph (`✓ ⟳ ✕`) and a label, so a
status colour never carries meaning alone, and a table view of every chart is
one click away.

## Known palette collision

`porosity` and `discontinuity` are **both `#E67E22`** in `overlay.py`, and so in
the app and in the swatches here. Two different classes drawn in the same colour
on the same photograph is a real problem, not a cosmetic one — visible in the
defects chart, where their swatches are identical. Fixing it means one line in
each of `overlay.py`, `theme.dart` and `charts.js`.

## Point cloud

`cloud.js` renders the stored depth buffer as an orbiting 3D cloud, coloured
from the photograph or by depth, croppable to the workpiece mask. Raw WebGL2
and a hand-written 4x4 rather than three.js: the dashboard has no build step,
and it is served off a laptop during a demo where a CDN fetch is one more thing
that can fail.

**Its geometry mirrors `weldz-mobile/lib/roi.dart` and has to.** The stored
`depth.u16` is the full 256x192 upload, but the masks inside `result.json` are
sized to the analysed crop (184x184) -- so the depth must be cut to
`geometry.depth_crop_box_source` before a mask can index it. Skip that and the
two are different grids: 33,856 entries against 49,152, which is what emptied
the app's workpiece view before it was fixed. `fx`/`fy` survive a crop
untouched; only the principal point moves, by the crop origin.

The cloud is turned a quarter turn clockwise, matching the app, because ARKit
hands over a landscape buffer and every picture beside it is displayed turned
to compensate.

Framing uses the cloud's **lateral** extent, not its depth range. Framing off
the far distance put the camera 289 mm back for a part 115 mm across; including
the z spread kept it there, because the depth range is wider than the part is
tall once a few bench points survive the mask edge.

## Demo data

`weldz-server/seed_from_capture.py` clones one **real** capture across a stretch
of dates, copying the four binary files verbatim -- so every seeded row has a
genuine photo, depth map and workpiece mask, and the point cloud works on all of
them. Only the detection list is resampled, and the verdict is re-derived by the
same `scoring.evaluate` the server runs against the live `ruleset.json`, so no
row carries a verdict the rule table would disagree with.

Sampling is tuned against the actual limits rather than by feel. The score
weights are porosity 5, overlap 15, undercut 25 with bands at 20/60, E1 trips
over 3 mm and E3 once defects pass 2% of the seam area -- the first run ignored
those and came out at a 71% reject rate.
