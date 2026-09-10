// The LiDAR depth map, colourised.
//
// 256x192 is a very small image, so it is decoded once into a ui.Image and
// drawn with FilterQuality.none. Smoothing it would invent detail that is not
// in the sensor — each pixel here is a real measurement and should look like
// one.
//
// The ramp is normalised to the frame's own near/far, not to a fixed range.
// A weld 300 mm away against a bench 900 mm away otherwise renders as two flat
// bands with no shape in either.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'capture.dart';
import 'roi.dart';
import 'point_cloud.dart' show depthColour, depthRamp;
import 'theme.dart';

class DepthView extends StatefulWidget {
  const DepthView({super.key, required this.capture, this.roi});

  final Capture capture;

  /// The analysed region. Given, the view shows only that -- so this tab and
  /// the picture tabs are the same field of view, and the depth shown is the
  /// depth the millimetres were actually taken from.
  final Roi? roi;

  @override
  State<DepthView> createState() => _DepthViewState();
}

class _DepthViewState extends State<DepthView> {
  ui.Image? _image;
  double _near = 0, _far = 0;
  double _fill = 0;

  /// Decoding is async, and `_fill` cannot distinguish "not measured yet" from
  /// "measured, and there is nothing". Without this the first build renders the
  /// no-depth message before the decode has even run -- which reads as a bug,
  /// because a capture always carries a depth buffer.
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _build();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _build() async {
    final c = widget.capture;
    final r = widget.roi;
    final grid = (r != null && r.isCentred(c))
        ? DepthGrid.cropped(c, r)
        : DepthGrid.full(c);
    final depth = grid.metres;
    final w = grid.width, h = grid.height;

    var near = double.infinity, far = -double.infinity;
    var valid = 0;
    for (final z in depth) {
      if (z > 0.05 && z < 20 && z.isFinite) {
        valid++;
        if (z < near) near = z;
        if (z > far) far = z;
      }
    }
    if (valid == 0) {
      if (mounted) {
        setState(() {
          _fill = 0;
          _done = true;
        });
      }
      return;
    }
    final span = (far - near).abs() < 1e-6 ? 1.0 : far - near;

    final rgba = Uint8List(w * h * 4);
    for (var i = 0; i < depth.length; i++) {
      final z = depth[i];
      final o = i * 4;
      if (z <= 0.05 || z >= 20 || !z.isFinite) {
        // no reading: leave it near-black rather than clamping to the ramp's
        // cold end, which would read as "very close"
        rgba[o] = 12;
        rgba[o + 1] = 14;
        rgba[o + 2] = 18;
        rgba[o + 3] = 255;
        continue;
      }
      final argb = depthColour((z - near) / span);
      rgba[o] = (argb >> 16) & 0xFF;
      rgba[o + 1] = (argb >> 8) & 0xFF;
      rgba[o + 2] = argb & 0xFF;
      rgba[o + 3] = 255;
    }

    ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, (img) {
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = img;
        _near = near;
        _far = far;
        _fill = valid / depth.length;
        _done = true;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    // Order matters: still working comes FIRST. Reporting no depth while the
    // decode is in flight is the same message for two different situations,
    // and only one of them is worth telling anyone about.
    if (!_done || (img == null && _fill > 0)) {
      return const Center(
        child: SizedBox(
            width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_fill == 0 || img == null) {
      return const Center(
        child: Text('No depth in this frame',
            style: TextStyle(color: WeldzColors.textFaint, fontSize: 13)),
      );
    }

    return Stack(
      children: [
        Positioned.fill(
          child: InteractiveViewer(
            maxScale: 12,
            child: RotatedBox(
              quarterTurns: 1,
              child: Center(
                child: AspectRatio(
                  aspectRatio: img.width / img.height,
                  child: CustomPaint(painter: _DepthPainter(img)),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 14,
          right: 14,
          bottom: 12,
          child: _Legend(near: _near, far: _far, fill: _fill),
        ),
      ],
    );
  }
}

class _DepthPainter extends CustomPainter {
  _DepthPainter(this.image);

  final ui.Image image;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, size.width, size.height),
      // none, not low: every pixel is a measurement, so do not interpolate
      // between them and imply resolution the sensor does not have
      Paint()..filterQuality = FilterQuality.none,
    );
  }

  @override
  bool shouldRepaint(_DepthPainter old) => old.image != image;
}

class _Legend extends StatelessWidget {
  const _Legend({required this.near, required this.far, required this.fill});

  final double near, far, fill;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.66),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('${(near * 1000).round()} mm', style: weldzMono(size: 11)),
                const Spacer(),
                Text('${(fill * 100).round()}% coverage',
                    style: const TextStyle(
                        fontSize: 11, color: WeldzColors.textDim)),
                const Spacer(),
                Text('${(far * 1000).round()} mm', style: weldzMono(size: 11)),
              ],
            ),
            const SizedBox(height: 6),
            Container(
              height: 6,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(3),
                gradient: LinearGradient(
                  colors: depthRamp.map(Color.new).toList(),
                ),
              ),
            ),
          ],
        ),
      );
}
