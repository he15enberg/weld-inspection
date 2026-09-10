// Orbiting RGB point cloud viewer.
//
// Per-point colour rules out drawRawPoints, which takes a single Paint. This
// uses drawRawAtlas instead: one draw call, a white sprite tinted per instance,
// which is what that API exists for.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'point_cloud.dart';
import 'theme.dart';

class PointCloudView extends StatefulWidget {
  const PointCloudView({super.key, required this.cloud, this.pointSize = 3.0});

  final PointCloud cloud;
  final double pointSize;

  @override
  State<PointCloudView> createState() => _PointCloudViewState();
}

class _PointCloudViewState extends State<PointCloudView> {
  double _yaw = 0.0;
  double _pitch = 0.0;
  double _zoom = 1.0;
  double _zoomStart = 1.0;

  ui.Image? _sprite;

  @override
  void initState() {
    super.initState();
    _makeSprite();
  }

  /// A single opaque white pixel. drawRawAtlas tints it per point, so the
  /// sprite carries no colour of its own. 1x1 keeps the transform maths
  /// trivial: the RSTransform scale is then the point size in pixels.
  Future<void> _makeSprite() async {
    final pixels = Uint8List.fromList(const [255, 255, 255, 255]);
    ui.decodeImageFromPixels(pixels, 1, 1, ui.PixelFormat.rgba8888, (img) {
      if (mounted) setState(() => _sprite = img);
    });
  }

  @override
  void dispose() {
    _sprite?.dispose();
    super.dispose();
  }

  void _reset() => setState(() {
        _yaw = 0.0;
        _pitch = 0.0;
        _zoom = 1.0;
      });

  @override
  Widget build(BuildContext context) {
    if (widget.cloud.isEmpty) {
      return const Center(
        child: Text('No depth in this frame',
            style: TextStyle(color: WeldzColors.textFaint, fontSize: 13)),
      );
    }
    if (_sprite == null) {
      return const Center(
          child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2)));
    }

    return GestureDetector(
      onScaleStart: (_) => _zoomStart = _zoom,
      onScaleUpdate: (d) => setState(() {
        if (d.pointerCount > 1) {
          _zoom = (_zoomStart * d.scale).clamp(0.2, 12.0);
        } else {
          _yaw += d.focalPointDelta.dx * 0.008;
          _pitch = (_pitch + d.focalPointDelta.dy * 0.008).clamp(-1.5, 1.5);
        }
      }),
      onDoubleTap: _reset,
      child: CustomPaint(
        painter: _CloudPainter(
          cloud: widget.cloud,
          sprite: _sprite!,
          pointSize: widget.pointSize,
          yaw: _yaw,
          pitch: _pitch,
          zoom: _zoom,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _CloudPainter extends CustomPainter {
  _CloudPainter({
    required this.cloud,
    required this.sprite,
    required this.pointSize,
    required this.yaw,
    required this.pitch,
    required this.zoom,
  });

  final PointCloud cloud;
  final ui.Image sprite;
  final double pointSize;
  final double yaw, pitch, zoom;

  @override
  void paint(Canvas canvas, Size size) {
    final n = cloud.count;
    if (n == 0) return;

    final p = cloud.xyz;

    // centroid and full bounding box in one pass
    var cx = 0.0, cy = 0.0, cz = 0.0;
    var minX = double.infinity, maxX = -double.infinity;
    var minY = double.infinity, maxY = -double.infinity;
    var minZ = double.infinity, maxZ = -double.infinity;

    for (var i = 0; i < n; i++) {
      final x = p[i * 3], y = p[i * 3 + 1], z = p[i * 3 + 2];
      cx += x;
      cy += y;
      cz += z;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
      if (z < minZ) minZ = z;
      if (z > maxZ) maxZ = z;
    }
    cx /= n;
    cy /= n;
    cz /= n;

    // Frame on the LARGEST dimension of the bounding box, not the depth range.
    // Scaling by depth spread alone collapses a flat plate to a dot when the
    // background is far away, and blows it off-screen when it is not.
    final extent = math.max(
      math.max(maxX - minX, maxY - minY),
      math.max(maxZ - minZ, 1e-3),
    );
    final scale = size.shortestSide * 0.8 * zoom / extent;

    final cosY = math.cos(yaw), sinY = math.sin(yaw);
    final cosP = math.cos(pitch), sinP = math.sin(pitch);
    final originX = size.width / 2, originY = size.height / 2;

    final half = pointSize * 0.5;
    final transforms = Float32List(n * 4);
    final rects = Float32List(n * 4);
    final colors = Int32List(n);

    var kept = 0;
    for (var i = 0; i < n; i++) {
      final x = p[i * 3] - cx;
      final y = p[i * 3 + 1] - cy;
      final z = p[i * 3 + 2] - cz;

      // yaw about Y, then pitch about X
      final x1 = x * cosY + z * sinY;
      final z1 = -x * sinY + z * cosY;
      final y2 = y * cosP - z1 * sinP;
      final z2 = y * sinP + z1 * cosP;

      // weak perspective: a depth cue without a full camera model
      final d = 1.0 + z2 / extent * 0.6;
      if (d <= 0.05) continue;

      final sxp = originX + x1 * scale / d;
      final syp = originY + y2 * scale / d;
      if (sxp.isNaN || syp.isNaN) continue;

      final o = kept * 4;
      // RSTransform, no rotation: [scos, ssin, tx, ty]. With a 1x1 atlas the
      // scale IS the on-screen point size; tx/ty centre it on the projection.
      transforms[o] = pointSize;
      transforms[o + 1] = 0.0;
      transforms[o + 2] = sxp - half;
      transforms[o + 3] = syp - half;

      // source rect inside the atlas, not the destination size
      rects[o] = 0;
      rects[o + 1] = 0;
      rects[o + 2] = 1;
      rects[o + 3] = 1;

      colors[kept] = cloud.argb[i];
      kept++;
    }
    if (kept == 0) return;

    canvas.drawRawAtlas(
      sprite,
      Float32List.sublistView(transforms, 0, kept * 4),
      Float32List.sublistView(rects, 0, kept * 4),
      Int32List.sublistView(colors, 0, kept),
      BlendMode.modulate, // white sprite x colour = colour
      null,
      Paint()..filterQuality = FilterQuality.none,
    );
  }

  @override
  bool shouldRepaint(_CloudPainter old) =>
      old.yaw != yaw ||
      old.pitch != pitch ||
      old.zoom != zoom ||
      old.cloud != cloud ||
      old.sprite != sprite;
}
