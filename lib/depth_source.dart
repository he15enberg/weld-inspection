// One-shot depth capture.
//
// On iOS this crosses a MethodChannel into ARKit. Everywhere else it returns a
// synthetic frame, so the whole Dart side runs and is testable on Android and
// desktop with no Mac -- the UI is final, only the data source swaps.

import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A single depth frame plus the camera intrinsics that describe it.
class DepthFrame {
  DepthFrame({
    required this.width,
    required this.height,
    required this.depth,
    required this.confidence,
    required this.fx,
    required this.fy,
    required this.cx,
    required this.cy,
    required this.imageWidth,
    required this.imageHeight,
    this.jpeg,
    this.synthetic = false,
  });

  /// ARKit confidence levels.
  static const int confidenceLow = 0;
  static const int confidenceMedium = 1;
  static const int confidenceHigh = 2;

  /// Depth map size (ARKit sceneDepth is 256x192).
  final int width;
  final int height;

  /// Metres, row-major, length width*height. Zero means no reading.
  final Float32List depth;

  /// Per-pixel confidence, same layout as [depth].
  final Uint8List confidence;

  /// Intrinsics, quoted for the CAPTURED IMAGE resolution, not the depth grid.
  final double fx, fy, cx, cy;
  final int imageWidth, imageHeight;

  /// The RGB frame the depth belongs to, for running inference on.
  final Uint8List? jpeg;

  /// True when this came from the fake source rather than real hardware.
  final bool synthetic;

  int get validCount {
    var n = 0;
    for (var i = 0; i < depth.length; i++) {
      if (depth[i] > 0 && confidence[i] >= confidenceHigh) n++;
    }
    return n;
  }

  double get fillRate => depth.isEmpty ? 0 : validCount / depth.length;

  factory DepthFrame.fromMap(Map<Object?, Object?> map) {
    double d(String k) => (map[k] as num).toDouble();
    int i(String k) => (map[k] as num).toInt();

    final raw = map['depth'];
    final depth = raw is Float32List
        ? raw
        : Float32List.view((raw as Uint8List).buffer, 0, (raw).lengthInBytes ~/ 4);

    return DepthFrame(
      width: i('width'),
      height: i('height'),
      depth: depth,
      confidence: map['confidence'] as Uint8List,
      fx: d('fx'),
      fy: d('fy'),
      cx: d('cx'),
      cy: d('cy'),
      imageWidth: i('imageWidth'),
      imageHeight: i('imageHeight'),
      jpeg: map['jpeg'] as Uint8List?,
    );
  }
}

class DepthUnavailable implements Exception {
  DepthUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract class DepthSource {
  Future<bool> get isSupported;
  Future<DepthFrame> capture();

  /// Real LiDAR on iOS, a synthetic frame everywhere else.
  static DepthSource create() =>
      (!kIsWeb && Platform.isIOS) ? ArKitDepthSource() : FakeDepthSource();
}

/// ARKit sceneDepth, one frame at a time.
///
/// The native side starts an ARSession on demand and tears it down after the
/// grab, because YOLOView holds the camera the rest of the time and the two
/// cannot own it simultaneously.
class ArKitDepthSource implements DepthSource {
  static const _channel = MethodChannel('weld/depth');

  @override
  Future<bool> get isSupported async {
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<DepthFrame> capture() async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>('capture');
      if (result == null) throw DepthUnavailable('no depth frame returned');
      return DepthFrame.fromMap(result);
    } on PlatformException catch (e) {
      throw DepthUnavailable(e.message ?? 'depth capture failed');
    }
  }
}

/// A plausible synthetic scene: a tilted plate with a raised bead across it.
///
/// Exists so the measurement maths, the point cloud view and the result screen
/// can be exercised without a LiDAR device.
class FakeDepthSource implements DepthSource {
  @override
  Future<bool> get isSupported async => true;

  @override
  Future<DepthFrame> capture() async {
    await Future<void>.delayed(const Duration(milliseconds: 600));

    const w = 256, h = 192;
    final depth = Float32List(w * h);
    final conf = Uint8List(w * h);
    final rng = math.Random(7);

    for (var v = 0; v < h; v++) {
      for (var u = 0; u < w; u++) {
        final i = v * w + u;
        // plate at ~300 mm, gently tilted
        var z = 0.30 + (u - w / 2) * 0.00012 + (v - h / 2) * 0.00008;
        // a bead running horizontally across the middle, ~4 mm proud
        final bead = math.exp(-math.pow((v - h * 0.52) / 9.0, 2).toDouble());
        z -= 0.004 * bead;
        z += rng.nextDouble() * 0.0008 - 0.0004;

        depth[i] = z;
        // mimic the sparse-return pattern: a fraction of pixels are not trusted
        conf[i] = rng.nextDouble() < 0.82
            ? DepthFrame.confidenceHigh
            : DepthFrame.confidenceMedium;
      }
    }

    return DepthFrame(
      width: w,
      height: h,
      depth: depth,
      confidence: conf,
      // iPhone Pro main camera, roughly
      fx: 2690,
      fy: 2690,
      cx: 2016,
      cy: 1512,
      imageWidth: 4032,
      imageHeight: 3024,
      synthetic: true,
    );
  }
}
