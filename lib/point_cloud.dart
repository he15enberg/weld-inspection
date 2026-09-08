// Building a coloured point cloud from a depth frame + its RGB image.
//
// Full frame, no confidence gating: every pixel with a positive depth becomes a
// point. On shiny steel most of ARKit's map is medium/low confidence, and
// filtering to high throws away almost everything -- so for visualisation we
// keep it all and let the eye judge.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'capture_source.dart';

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
  /// depth because no image was available.
  final bool coloured;

  bool get isEmpty => count == 0;

  static PointCloud get empty => PointCloud(
        xyz: Float32List(0),
        argb: Int32List(0),
        count: 0,
        coloured: false,
      );
}

/// Decode the frame's JPEG to raw RGBA so points can be tinted from it.
Future<({Uint8List bytes, int width, int height})?> _decodeRgba(
  Uint8List? jpeg,
) async {
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

/// Unproject every valid depth pixel and colour it from the RGB frame.
///
/// [step] thins the grid; 1 is the full 256x192.
Future<PointCloud> buildCloud(DepthFrame frame, {int step = 1}) async {
  final rgb = await _decodeRgba(frame.jpeg);

  // intrinsics are quoted for the captured image, so scale them onto the depth
  // grid -- getting this wrong puts every point in the wrong place
  final sx = frame.width / frame.imageWidth;
  final sy = frame.height / frame.imageHeight;
  final fx = frame.fx * sx, fy = frame.fy * sy;
  final cx = frame.cx * sx, cy = frame.cy * sy;

  // depth grid -> image grid, for sampling colour
  final imgScaleX = rgb == null ? 0.0 : rgb.width / frame.width;
  final imgScaleY = rgb == null ? 0.0 : rgb.height / frame.height;

  final xs = <double>[];
  final cols = <int>[];

  var zMin = double.infinity, zMax = -double.infinity;
  for (var i = 0; i < frame.depth.length; i++) {
    final z = frame.depth[i];
    if (_plausible(z)) {
      if (z < zMin) zMin = z;
      if (z > zMax) zMax = z;
    }
  }
  final zSpan = (zMax - zMin).abs() < 1e-6 ? 1.0 : zMax - zMin;

  for (var v = 0; v < frame.height; v += step) {
    for (var u = 0; u < frame.width; u += step) {
      final z = frame.depth[v * frame.width + u];
      if (!_plausible(z)) continue;

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
        cols.add(_depthColour((z - zMin) / zSpan));
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

/// Physically plausible range for ARKit sceneDepth, in metres. A mis-decoded
/// buffer then yields an empty cloud rather than a convincing noise field.
const _minDepth = 0.05;
const _maxDepth = 20.0;

bool _plausible(double z) => z.isFinite && z >= _minDepth && z <= _maxDepth;

/// Fallback ramp when there is no RGB frame: cool near, warm far.
int _depthColour(double t) {
  final x = t.clamp(0.0, 1.0);
  final r = (60 + 195 * x).round();
  final g = (110 + 60 * (1 - (x - 0.5).abs() * 2)).round();
  final b = (230 - 180 * x).round();
  return (0xFF << 24) | (r << 16) | (g << 8) | b;
}
