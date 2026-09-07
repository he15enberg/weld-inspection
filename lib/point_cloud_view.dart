// A small orbiting point cloud viewer.
//
// A few thousand points do not need a 3-D engine. This rotates and projects by
// hand and draws with canvas.drawRawPoints, which keeps it dependency-free and
// short. Points are coloured in depth bands -- drawRawPoints takes one Paint,
// so per-point colour means one call per band.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show PointMode;

import 'package:flutter/material.dart';

const _bandColors = [
  Color(0xFF3B4CC0),
  Color(0xFF6788EE),
  Color(0xFF9ABBFF),
  Color(0xFFC9D7F0),
  Color(0xFFF2CBB7),
  Color(0xFFEE8468),
  Color(0xFFB40426),
];

class PointCloudView extends StatefulWidget {
  const PointCloudView({super.key, required this.points, this.overlays = const []});

  /// Packed x,y,z triples in metres, camera space.
  final Float32List points;

  /// Boxes to draw into the cloud, in normalized image coords at a distance.
  final List<CloudBox> overlays;

  @override
  State<PointCloudView> createState() => _PointCloudViewState();
}

/// A detection box placed in the cloud at its measured distance.
class CloudBox {
  const CloudBox({required this.rect, required this.z, required this.color});
  final Rect rect; // normalized 0..1
  final double z; // metres
  final Color color;
}

class _PointCloudViewState extends State<PointCloudView> {
  double _yaw = 0.35;
  double _pitch = -0.25;
  double _zoom = 1.0;
  double _zoomStart = 1.0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onScaleStart: (_) => _zoomStart = _zoom,
      onScaleUpdate: (d) {
        setState(() {
          if (d.pointerCount > 1) {
            _zoom = (_zoomStart * d.scale).clamp(0.3, 6.0);
          } else {
            _yaw += d.focalPointDelta.dx * 0.008;
            _pitch = (_pitch + d.focalPointDelta.dy * 0.008).clamp(-1.4, 1.4);
          }
        });
      },
      onDoubleTap: () => setState(() {
        _yaw = 0.35;
        _pitch = -0.25;
        _zoom = 1.0;
      }),
      child: CustomPaint(
        painter: _CloudPainter(
          points: widget.points,
          overlays: widget.overlays,
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
    required this.points,
    required this.overlays,
    required this.yaw,
    required this.pitch,
    required this.zoom,
  });

  final Float32List points;
  final List<CloudBox> overlays;
  final double yaw, pitch, zoom;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 3) return;

    // centre the cloud on its own centroid so rotation feels natural
    var cx = 0.0, cy = 0.0, cz = 0.0;
    var zMin = double.infinity, zMax = -double.infinity;
    final n = points.length ~/ 3;
    for (var i = 0; i < n; i++) {
      cx += points[i * 3];
      cy += points[i * 3 + 1];
      final z = points[i * 3 + 2];
      cz += z;
      if (z < zMin) zMin = z;
      if (z > zMax) zMax = z;
    }
    cx /= n;
    cy /= n;
    cz /= n;

    final cosY = math.cos(yaw), sinY = math.sin(yaw);
    final cosP = math.cos(pitch), sinP = math.sin(pitch);

    // scale so the cloud fills the viewport at zoom 1
    final spread = math.max(zMax - zMin, 0.02);
    final scale = size.shortestSide * 0.9 * zoom / (spread * 6);
    final originX = size.width / 2, originY = size.height / 2;

    // one bucket per colour band, since drawRawPoints takes a single Paint
    final buckets = List.generate(_bandColors.length, (_) => <double>[]);

    for (var i = 0; i < n; i++) {
      final p = _project(
        points[i * 3] - cx,
        points[i * 3 + 1] - cy,
        points[i * 3 + 2] - cz,
        cosY, sinY, cosP, sinP, scale, originX, originY,
      );
      if (p == null) continue;

      final t = ((points[i * 3 + 2] - zMin) / spread).clamp(0.0, 0.999);
      final band = (t * _bandColors.length).floor();
      buckets[band]..add(p.dx)..add(p.dy);
    }

    final paint = Paint()..strokeWidth = 2.2..strokeCap = StrokeCap.round;
    for (var b = 0; b < buckets.length; b++) {
      if (buckets[b].isEmpty) continue;
      paint.color = _bandColors[b];
      canvas.drawRawPoints(
        PointMode.points,
        Float32List.fromList(buckets[b]),
        paint,
      );
    }

    _paintOverlays(canvas, cx, cy, cz, cosY, sinY, cosP, sinP, scale, originX, originY);
  }

  /// Detection boxes, placed in the cloud at their measured distance.
  void _paintOverlays(
    Canvas canvas,
    double cx, double cy, double cz,
    double cosY, double sinY, double cosP, double sinP,
    double scale, double originX, double originY,
  ) {
    for (final box in overlays) {
      // normalized image coords -> camera space at distance z, using the same
      // half-FOV relation the measurement maths uses
      final corners = <Offset?>[];
      for (final c in [
        Offset(box.rect.left, box.rect.top),
        Offset(box.rect.right, box.rect.top),
        Offset(box.rect.right, box.rect.bottom),
        Offset(box.rect.left, box.rect.bottom),
      ]) {
        final x = (c.dx - 0.5) * box.z * 1.5;
        final y = (c.dy - 0.5) * box.z * 1.5 * 0.75;
        corners.add(_project(x - cx, y - cy, box.z - cz,
            cosY, sinY, cosP, sinP, scale, originX, originY));
      }
      if (corners.any((c) => c == null)) continue;

      final path = Path()..moveTo(corners[0]!.dx, corners[0]!.dy);
      for (var i = 1; i < corners.length; i++) {
        path.lineTo(corners[i]!.dx, corners[i]!.dy);
      }
      path.close();
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = box.color,
      );
    }
  }

  Offset? _project(
    double x, double y, double z,
    double cosY, double sinY, double cosP, double sinP,
    double scale, double originX, double originY,
  ) {
    // yaw about Y, then pitch about X
    final x1 = x * cosY + z * sinY;
    final z1 = -x * sinY + z * cosY;
    final y2 = y * cosP - z1 * sinP;
    final z2 = y * sinP + z1 * cosP;

    // weak perspective: enough depth cue without a full camera model
    final d = 1.0 + z2 * 1.2;
    if (d <= 0.05) return null;
    return Offset(originX + x1 * scale / d, originY + y2 * scale / d);
  }

  @override
  bool shouldRepaint(_CloudPainter old) =>
      old.yaw != yaw ||
      old.pitch != pitch ||
      old.zoom != zoom ||
      old.points != points ||
      old.overlays != overlays;
}
