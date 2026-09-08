// 2-D colourised depth map.
//
// Straight visualisation of ARKit's 256x192 depth buffer: near is blue, far is
// red, pixels with no reading are left dark. No RGB, no 3-D projection.
//
// The range is taken from the 2nd-98th percentile rather than min/max, because
// a handful of stray far readings otherwise compress the whole plate into one
// colour.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'depth_source.dart';

/// Turbo-like ramp: cool near, warm far.
const _ramp = <Color>[
  Color(0xFF30123B),
  Color(0xFF4145AB),
  Color(0xFF4675ED),
  Color(0xFF39A2FC),
  Color(0xFF1BCFD4),
  Color(0xFF24ECA6),
  Color(0xFF61FC6C),
  Color(0xFFA4FC3B),
  Color(0xFFD1E834),
  Color(0xFFF3C63A),
  Color(0xFFFE9B2D),
  Color(0xFFF36315),
  Color(0xFFD93806),
  Color(0xFFB11901),
  Color(0xFF7A0403),
];

/// Colour for a normalised value in 0..1.
({int r, int g, int b}) _rampAt(double t) {
  final x = (t.clamp(0.0, 1.0)) * (_ramp.length - 1);
  final i = x.floor().clamp(0, _ramp.length - 2);
  final f = x - i;
  final a = _ramp[i], b = _ramp[i + 1];
  int mix(int lo, int hi) => (lo + (hi - lo) * f).round();
  return (
    r: mix((a.r * 255).round(), (b.r * 255).round()),
    g: mix((a.g * 255).round(), (b.g * 255).round()),
    b: mix((a.b * 255).round(), (b.b * 255).round()),
  );
}

class DepthStats {
  const DepthStats({
    required this.near,
    required this.far,
    required this.valid,
    required this.total,
  });

  final double near, far;
  final int valid, total;

  double get fill => total == 0 ? 0 : valid / total;
}

/// Colourise a depth frame into an image plus the range it was scaled over.
Future<({ui.Image image, DepthStats stats})> colouriseDepth(
  DepthFrame frame,
) async {
  final depth = frame.depth;

  final valid = <double>[];
  for (var i = 0; i < depth.length; i++) {
    final z = depth[i];
    if (z > 0 && z.isFinite) valid.add(z);
  }
  valid.sort();

  // 2nd-98th percentile, so outliers do not flatten the useful range
  final near = valid.isEmpty ? 0.0 : valid[(valid.length * 0.02).floor()];
  final far = valid.isEmpty ? 1.0 : valid[(valid.length * 0.98).floor()];
  final span = (far - near).abs() < 1e-6 ? 1.0 : far - near;

  final pixels = Uint8List(depth.length * 4);
  for (var i = 0; i < depth.length; i++) {
    final o = i * 4;
    final z = depth[i];
    if (z <= 0 || !z.isFinite) {
      // no reading: near-black, so holes are obvious rather than blended in
      pixels[o] = 16;
      pixels[o + 1] = 18;
      pixels[o + 2] = 22;
      pixels[o + 3] = 255;
      continue;
    }
    final c = _rampAt((z - near) / span);
    pixels[o] = c.r;
    pixels[o + 1] = c.g;
    pixels[o + 2] = c.b;
    pixels[o + 3] = 255;
  }

  final image = await _imageFrom(pixels, frame.width, frame.height);
  return (
    image: image,
    stats: DepthStats(
      near: near,
      far: far,
      valid: valid.length,
      total: depth.length,
    ),
  );
}

Future<ui.Image> _imageFrom(Uint8List rgba, int width, int height) {
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    width,
    height,
    ui.PixelFormat.rgba8888,
    done.complete,
  );
  return done.future;
}

class DepthMapView extends StatefulWidget {
  const DepthMapView({super.key, required this.frame});

  final DepthFrame frame;

  @override
  State<DepthMapView> createState() => _DepthMapViewState();
}

class _DepthMapViewState extends State<DepthMapView> {
  ui.Image? _image;
  DepthStats? _stats;

  /// Nearest-neighbour by default: it shows the true 256x192 resolution instead
  /// of implying detail the sensor never measured. Tap to smooth.
  bool _smooth = false;

  @override
  void initState() {
    super.initState();
    _build();
  }

  Future<void> _build() async {
    final result = await colouriseDepth(widget.frame);
    if (!mounted) {
      result.image.dispose();
      return;
    }
    setState(() {
      _image = result.image;
      _stats = result.stats;
    });
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final stats = _stats!;
    if (stats.valid == 0) {
      return const Center(
        child: Text('No depth in this frame',
            style: TextStyle(color: Colors.white38)),
      );
    }

    return GestureDetector(
      onTap: () => setState(() => _smooth = !_smooth),
      child: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              maxScale: 8,
              child: RawImage(
                image: image,
                fit: BoxFit.contain,
                filterQuality:
                    _smooth ? FilterQuality.medium : FilterQuality.none,
              ),
            ),
          ),
          Positioned(
            left: 14,
            bottom: 14,
            child: _Legend(stats: stats),
          ),
          Positioned(
            right: 14,
            bottom: 14,
            child: Text(
              _smooth ? 'smoothed · tap for raw' : 'raw pixels · tap to smooth',
              style: const TextStyle(fontSize: 10, color: Colors.white38),
            ),
          ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.stats});

  final DepthStats stats;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 150,
          height: 8,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            gradient: LinearGradient(colors: _ramp),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${(stats.near * 1000).round()} mm'
          '        ${(stats.far * 1000).round()} mm',
          style: const TextStyle(
              fontSize: 10,
              color: Colors.white54,
              fontFeatures: [FontFeature.tabularFigures()]),
        ),
        Text(
          '${(stats.fill * 100).toStringAsFixed(0)}% of pixels have depth',
          style: const TextStyle(fontSize: 10, color: Colors.white38),
        ),
      ],
    );
  }
}
