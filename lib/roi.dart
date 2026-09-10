// The region the server actually analysed, and the capture data cut down to it.
//
// The server turns the frame before inference (the model was trained only on
// parts lying across the frame) and crops it square. It turns its own outputs
// back before replying, so the overlay, the boxes and the masks all arrive in
// the orientation the capture was taken in -- but CROPPED. The phone still
// holds the full frame.
//
// That mismatch is not cosmetic. `buildCloud` used to index a mask as
// `v * 256 + u` against the full 256x192 depth grid, while the mask arriving
// from the server was 184x184 -- 33,856 entries against 49,152. Most points
// were dropped and the rest were placed wrong, which is why the workpiece view
// looked broken rather than empty.
//
// So: everything the app shows for a capture goes through here first, and then
// the app's data and the server's masks are in one space.

import 'dart:typed_data';

import 'capture.dart';

/// One rectangle, in the coordinates of the frame the phone holds.
class Roi {
  const Roi({
    required this.rotate,
    required this.crop,
    required this.colour,
    required this.depth,
  });

  /// Quarter turns the server applied before inference, in degrees. Recorded
  /// for the record view; the app never needs to apply it, because the server
  /// has already turned its outputs back.
  final int rotate;

  /// Square side in captured pixels. 0 means the server did not crop.
  final int crop;

  /// [x0, y0, x1, y1] in captured-image pixels.
  final List<int> colour;

  /// [x0, y0, x1, y1] in depth samples.
  final List<int> depth;

  /// Null when the server did not crop — then there is nothing to cut down and
  /// every caller should use the capture as it stands.
  static Roi? from(Object? raw) {
    if (raw is! Map) return null;
    final c = raw['crop_box_source'];
    final d = raw['depth_crop_box_source'];
    if (c is! List || d is! List || c.length != 4 || d.length != 4) return null;
    final crop = (raw['crop'] as num?)?.toInt() ?? 0;
    if (crop <= 0) return null;
    return Roi(
      rotate: (raw['rotate'] as num?)?.toInt() ?? 0,
      crop: crop,
      colour: c.map((v) => (v as num).toInt()).toList(),
      depth: d.map((v) => (v as num).toInt()).toList(),
    );
  }

  int get colourX => colour[0];
  int get colourY => colour[1];
  int get colourWidth => colour[2] - colour[0];
  int get colourHeight => colour[3] - colour[1];

  int get depthX => depth[0];
  int get depthY => depth[1];
  int get depthWidth => depth[2] - depth[0];
  int get depthHeight => depth[3] - depth[1];

  /// Fraction of the captured frame's width the crop spans, for a display-only
  /// centred crop via ClipRect + Align. The server centres the crop on both
  /// axes, which is what makes that idiom exact rather than approximate.
  double widthFactor(Capture c) => colourWidth / c.imageWidth;
  double heightFactor(Capture c) => colourHeight / c.imageHeight;

  /// True when the crop really is centred — the assumption [widthFactor] rests
  /// on. If a future server crops off-centre this goes false and callers should
  /// fall back to the uncropped frame rather than show a wrong region.
  bool isCentred(Capture c) =>
      (c.imageWidth - colour[2] - colourX).abs() <= 1 &&
      (c.imageHeight - colour[3] - colourY).abs() <= 1;
}

/// A depth map with the intrinsics that describe it — either the whole capture
/// or the analysed crop of it. One type so the depth view and both point clouds
/// cannot end up in different spaces.
class DepthGrid {
  const DepthGrid({
    required this.metres,
    required this.width,
    required this.height,
    required this.fx,
    required this.fy,
    required this.cx,
    required this.cy,
  });

  final Float32List metres;
  final int width, height;

  /// Already scaled onto THIS grid, so callers unproject with them directly.
  final double fx, fy, cx, cy;

  /// The whole capture, nothing cut away.
  factory DepthGrid.full(Capture c) {
    final sx = c.depthWidth / c.imageWidth;
    final sy = c.depthHeight / c.imageHeight;
    return DepthGrid(
      metres: c.depthMetres,
      width: c.depthWidth,
      height: c.depthHeight,
      fx: c.fx * sx,
      fy: c.fy * sy,
      cx: c.cx * sx,
      cy: c.cy * sy,
    );
  }

  /// Cut down to [roi], so it matches the masks the server sends back.
  ///
  /// fx and fy are untouched by a crop — only the principal point moves, by the
  /// crop origin. Getting that wrong tilts the whole cloud, and does it
  /// plausibly enough to look like a bad capture.
  factory DepthGrid.cropped(Capture c, Roi roi) {
    final full = DepthGrid.full(c);
    final w = roi.depthWidth, h = roi.depthHeight;
    if (w <= 0 ||
        h <= 0 ||
        roi.depth[2] > c.depthWidth ||
        roi.depth[3] > c.depthHeight) {
      return full; // nonsense rectangle: show everything rather than nothing
    }

    final out = Float32List(w * h);
    for (var v = 0; v < h; v++) {
      final src = (roi.depthY + v) * c.depthWidth + roi.depthX;
      out.setRange(v * w, v * w + w, full.metres, src);
    }
    return DepthGrid(
      metres: out,
      width: w,
      height: h,
      fx: full.fx,
      fy: full.fy,
      cx: full.cx - roi.depthX,
      cy: full.cy - roi.depthY,
    );
  }

  /// How much of the grid carries a reading at all. The depth tab uses this to
  /// tell "still decoding" apart from "genuinely no depth here" — a capture
  /// always HAS a depth buffer, so an empty view means one of those two and the
  /// difference matters to whoever is holding the phone.
  double get validFraction {
    if (metres.isEmpty) return 0;
    var n = 0;
    for (final z in metres) {
      if (z > 0.05 && z < 6.0) n++;
    }
    return n / metres.length;
  }
}
