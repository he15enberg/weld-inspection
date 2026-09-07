// Turning detections into millimetres.
//
// Height and width are lateral quantities, so depth contributes exactly one
// number per detection: the distance z. Everything works in normalized box
// coordinates, which means the preview, the depth map and the captured image
// never have to be reconciled pixel-for-pixel -- they share a field of view,
// so a normalized box maps into all three directly.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'depth_source.dart';

/// A detection with its real-world size resolved.
class Measured {
  Measured({
    required this.label,
    required this.confidence,
    required this.box,
    required this.widthMm,
    required this.heightMm,
    required this.distanceM,
    required this.depthFill,
  });

  final String label;
  final double confidence;
  final Rect box; // normalized, 0..1
  final double? widthMm;
  final double? heightMm;
  final double? distanceM;

  /// Fraction of the box that had usable depth. Low values mean the size rests
  /// on very few pixels.
  final double depthFill;

  bool get hasSize => widthMm != null && heightMm != null;

  String get sizeLabel => hasSize
      ? '${widthMm!.toStringAsFixed(1)} x ${heightMm!.toStringAsFixed(1)} mm'
      : 'no depth';
}

/// Median of the valid depths inside a normalized rect, plus the fill fraction.
///
/// Median rather than mean: the mean is dragged around by pixels that straddle
/// the object boundary and by dropouts.
({double? depth, double fill}) sampleDepth(DepthFrame frame, Rect box) {
  final x0 = (box.left * frame.width).floor().clamp(0, frame.width - 1);
  final x1 = (box.right * frame.width).ceil().clamp(1, frame.width);
  final y0 = (box.top * frame.height).floor().clamp(0, frame.height - 1);
  final y1 = (box.bottom * frame.height).ceil().clamp(1, frame.height);

  final total = math.max((x1 - x0) * (y1 - y0), 1);
  final values = <double>[];

  for (var y = y0; y < y1; y++) {
    final row = y * frame.width;
    for (var x = x0; x < x1; x++) {
      final i = row + x;
      final d = frame.depth[i];
      // low-confidence pixels are largely interpolation between the sparse
      // laser spots rather than measurement
      if (d > 0 && d.isFinite && frame.confidence[i] >= DepthFrame.confidenceHigh) {
        values.add(d);
      }
    }
  }

  if (values.isEmpty) return (depth: null, fill: 0);
  values.sort();
  return (depth: values[values.length ~/ 2], fill: values.length / total);
}

/// Size in millimetres of a normalized box at distance [z] metres.
///
///   width  = normalizedWidth  * z * (imageWidth  / fx)
///   height = normalizedHeight * z * (imageHeight / fy)
///
/// which is resolution independent: (imageWidth / fx) is just the tangent of
/// the horizontal half-FOV, doubled.
({double widthMm, double heightMm}) sizeAt(
  DepthFrame frame,
  Rect box,
  double z,
) {
  final w = box.width * z * (frame.imageWidth / frame.fx) * 1000;
  final h = box.height * z * (frame.imageHeight / frame.fy) * 1000;
  return (widthMm: w, heightMm: h);
}

/// Millimetres per pixel of the captured image at distance [z]. Useful as a
/// sanity readout.
double mmPerPixel(DepthFrame frame, double z) => z / frame.fx * 1000;

/// Resolve sizes for every detection.
List<Measured> measureAll(
  DepthFrame frame,
  List<({String label, double confidence, Rect box})> detections,
) {
  return detections.map((d) {
    final sample = sampleDepth(frame, d.box);
    final z = sample.depth;
    if (z == null) {
      return Measured(
        label: d.label,
        confidence: d.confidence,
        box: d.box,
        widthMm: null,
        heightMm: null,
        distanceM: null,
        depthFill: 0,
      );
    }
    final size = sizeAt(frame, d.box, z);
    return Measured(
      label: d.label,
      confidence: d.confidence,
      box: d.box,
      widthMm: size.widthMm,
      heightMm: size.heightMm,
      distanceM: z,
      depthFill: sample.fill,
    );
  }).toList();
}

/// Unproject the depth map into 3-D points in camera space (metres, +Z away).
///
/// Returns packed x,y,z triples. High-confidence pixels only, and [step] lets
/// the cloud be thinned for rendering.
Float32List unproject(DepthFrame frame, {int step = 1}) {
  // intrinsics are quoted for the captured image, so scale them to the depth
  // grid -- getting this wrong puts every point in the wrong place
  final sx = frame.width / frame.imageWidth;
  final sy = frame.height / frame.imageHeight;
  final fx = frame.fx * sx, fy = frame.fy * sy;
  final cx = frame.cx * sx, cy = frame.cy * sy;

  final out = <double>[];
  for (var v = 0; v < frame.height; v += step) {
    for (var u = 0; u < frame.width; u += step) {
      final i = v * frame.width + u;
      final z = frame.depth[i];
      if (z <= 0 || !z.isFinite) continue;
      if (frame.confidence[i] < DepthFrame.confidenceHigh) continue;
      out.add((u - cx) / fx * z);
      out.add((v - cy) / fy * z);
      out.add(z);
    }
  }
  return Float32List.fromList(out);
}
