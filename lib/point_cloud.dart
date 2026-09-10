// Building a coloured point cloud from the capture's depth map and JPEG.
//
// Full frame by default, no confidence gating: every pixel with a plausible
// depth becomes a point. On shiny steel most of ARKit's map is medium or low
// confidence, and filtering to high throws away almost everything — so for
// looking at, we keep it all and let the eye judge. (Measurement is stricter;
// that happens server-side and does gate on confidence.)
//
// Pass a mask to crop, which is how the workpiece-only view is built.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'capture.dart';

class PointCloud {
  const PointCloud({
    required this.xyz,
    required this.argb,
    required this.count,
    required this.coloured,
  });

  /// Packed x,y,z triples in metres, camera space (+Z away from the camera).
  final Float32List xyz;

  /// One ARGB per point, same order as [xyz].
  final Int32List argb;

  final int count;

  /// True when colour came from the RGB frame, false when it was derived from
  /// depth because the JPEG could not be decoded.
  final bool coloured;

  bool get isEmpty => count == 0;

  static PointCloud get empty => PointCloud(
        xyz: Float32List(0),
        argb: Int32List(0),
        count: 0,
        coloured: false,
      );
}

/// Physically plausible range for ARKit sceneDepth, in metres. A mis-decoded
/// buffer then yields an empty cloud rather than a convincing noise field.
const _minDepth = 0.05;
const _maxDepth = 20.0;

bool _plausible(double z) => z.isFinite && z >= _minDepth && z <= _maxDepth;

/// Decode a mask PNG from the server into one byte per depth sample.
///
/// The server already downsampled it to the depth grid, so this needs no
/// resampling — just the red channel of the decoded RGBA.
Future<Uint8List?> decodeMask(Uint8List png) async {
  try {
    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final w = image.width, h = image.height;
    image.dispose();
    codec.dispose();
    if (data == null) return null;

    final rgba = data.buffer.asUint8List();
    final out = Uint8List(w * h);
    for (var i = 0; i < out.length; i++) {
      out[i] = rgba[i * 4];
    }
    return out;
  } catch (_) {
    return null;
  }
}

Future<({Uint8List bytes, int width, int height})?> _decodeRgba(
    Uint8List? jpeg) async {
  if (jpeg == null || jpeg.isEmpty) return null;
  try {
    final codec = await ui.instantiateImageCodec(jpeg);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final width = image.width, height = image.height;
    image.dispose();
    codec.dispose();
    if (data == null) return null;
    return (bytes: data.buffer.asUint8List(), width: width, height: height);
  } catch (_) {
    return null;
  }
}

/// Unproject every plausible depth pixel and colour it from the RGB frame.
///
/// [mask] is one byte per depth sample; non-zero keeps the point. [step] thins
/// the grid — 1 is the full 256x192.
Future<PointCloud> buildCloud(
  Capture c, {
  Uint8List? mask,
  int step = 1,
}) async {
  final rgb = await _decodeRgba(c.jpeg);
  final depth = c.depthMetres;
  final dw = c.depthWidth, dh = c.depthHeight;

  // Intrinsics are quoted for the CAPTURED IMAGE, so scale them onto the depth
  // grid. Getting this wrong puts every point in the wrong place — and it does
  // so plausibly, which is why it is worth stating.
  final sx = dw / c.imageWidth;
  final sy = dh / c.imageHeight;
  final fx = c.fx * sx, fy = c.fy * sy;
  final cx = c.cx * sx, cy = c.cy * sy;

  // depth grid -> image grid, for sampling colour
  final imgScaleX = rgb == null ? 0.0 : rgb.width / dw;
  final imgScaleY = rgb == null ? 0.0 : rgb.height / dh;

  var zMin = double.infinity, zMax = -double.infinity;
  for (var i = 0; i < depth.length; i++) {
    final z = depth[i];
    if (_plausible(z)) {
      if (z < zMin) zMin = z;
      if (z > zMax) zMax = z;
    }
  }
  final zSpan = (zMax - zMin).abs() < 1e-6 ? 1.0 : zMax - zMin;

  final xs = <double>[];
  final cols = <int>[];

  for (var v = 0; v < dh; v += step) {
    for (var u = 0; u < dw; u += step) {
      final i = v * dw + u;
      final z = depth[i];
      if (!_plausible(z)) continue;
      if (mask != null && (i >= mask.length || mask[i] == 0)) continue;

      xs.add((u - cx) / fx * z);
      xs.add((v - cy) / fy * z);
      xs.add(z);

      if (rgb != null) {
        final ix = (u * imgScaleX).round().clamp(0, rgb.width - 1);
        final iy = (v * imgScaleY).round().clamp(0, rgb.height - 1);
        final o = (iy * rgb.width + ix) * 4;
        cols.add((0xFF << 24) |
            (rgb.bytes[o] << 16) |
            (rgb.bytes[o + 1] << 8) |
            rgb.bytes[o + 2]);
      } else {
        cols.add(depthColour((z - zMin) / zSpan));
      }
    }
  }

  return PointCloud(
    xyz: Float32List.fromList(xs),
    argb: Int32List.fromList(cols),
    count: cols.length,
    coloured: rgb != null,
  );
}

/// Turbo-ish ramp, shared with the depth view so the two agree.
const depthRamp = <int>[
  0xFF30123B, 0xFF4145AB, 0xFF4675ED, 0xFF39A2FC, 0xFF1BCFD4,
  0xFF24ECA6, 0xFF61FC6C, 0xFFA4FC3B, 0xFFD1E834, 0xFFF3C63A,
  0xFFFE9B2D, 0xFFF36315, 0xFFD93806, 0xFFB11901, 0xFF7A0403,
];

int depthColour(double t) {
  final x = t.clamp(0.0, 1.0) * (depthRamp.length - 1);
  final i = x.floor().clamp(0, depthRamp.length - 2);
  final f = x - i;
  final a = depthRamp[i], b = depthRamp[i + 1];

  int lerp(int shift) {
    final av = (a >> shift) & 0xFF, bv = (b >> shift) & 0xFF;
    return (av + (bv - av) * f).round();
  }

  return (0xFF << 24) | (lerp(16) << 16) | (lerp(8) << 8) | lerp(0);
}
