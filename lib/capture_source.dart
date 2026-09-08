// One-shot capture: RGB, LiDAR depth and RF-DETR detections from a single
// ARFrame.
//
// The important difference from the YOLO app: there is no camera hand-off. That
// app had to unmount YOLOView and wait, because the plugin held the camera and
// ARKit could not open it at the same time. Here one ARSession runs the whole
// app, so RGB and depth come from the *same instant* -- which the two-stage
// flow could never actually promise.
//
// On anything but iOS this returns a synthetic frame, so the measurement maths,
// the point cloud and the result screen all run on Android and desktop with no
// Mac. Only the data source swaps; the UI is final.

import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'detection.dart';

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

    final depth = _asFloat32(map['depth']);

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

/// Coerce a channel value into a Float32List.
///
/// The native side sends float32, so the first branch is the normal path. The
/// byte fallback exists for older payloads and must respect `offsetInBytes`:
/// a Uint8List from a platform channel is a *view* into a larger buffer, so
/// reinterpreting from offset 0 reads the message header and yields garbage —
/// depths in the 1e18 range and a screen of noise.
Float32List _asFloat32(Object? raw) {
  if (raw is Float32List) return raw;
  if (raw is Float64List) return Float32List.fromList(raw);
  if (raw is Uint8List) {
    final count = raw.lengthInBytes ~/ 4;
    // Float32List.view also demands 4-byte alignment; copy when it is not met
    if (raw.offsetInBytes % 4 == 0) {
      return Float32List.view(raw.buffer, raw.offsetInBytes, count);
    }
    final out = Float32List(count);
    final bytes = ByteData.sublistView(raw);
    for (var i = 0; i < count; i++) {
      out[i] = bytes.getFloat32(i * 4, Endian.little);
    }
    return out;
  }
  throw DepthUnavailable('unexpected depth payload: ${raw.runtimeType}');
}

class DepthUnavailable implements Exception {
  DepthUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Everything one Capture press produces on the native side.
typedef RawCapture = ({
  DepthFrame frame,
  Uint8List? annotated,
  List<Detection> detections,
  String? error,
});

abstract class CaptureSource {
  Future<bool> get isSupported;
  Future<RawCapture> capture();

  /// Real ARKit + Core ML on iOS, a synthetic frame everywhere else.
  static CaptureSource create() =>
      (!kIsWeb && Platform.isIOS) ? ArKitCaptureSource() : FakeCaptureSource();
}

/// ARKit + Core ML across the `weld/capture` channel.
///
/// The native side holds one persistent ARSession. `capture` grabs the current
/// ARFrame, runs RF-DETR on its `capturedImage`, and returns depth, intrinsics,
/// the RGB frame, a mask overlay and the detection list in one payload.
class ArKitCaptureSource implements CaptureSource {
  static const _channel = MethodChannel('weld/capture');

  @override
  Future<bool> get isSupported async {
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<RawCapture> capture() async {
    try {
      final r = await _channel.invokeMethod<Map<Object?, Object?>>('capture');
      if (r == null) throw DepthUnavailable('no frame returned');
      return (
        frame: DepthFrame.fromMap(r),
        annotated: r['annotated'] as Uint8List?,
        detections: Detection.listFrom(r['detections']),
        // Inference is allowed to fail without losing the capture: depth and
        // the point cloud are still useful on their own.
        error: r['inferenceError'] as String?,
      );
    } on PlatformException catch (e) {
      throw DepthUnavailable(e.message ?? 'capture failed');
    }
  }
}

/// A plausible synthetic scene: a tilted plate with a raised bead across it.
///
/// Exists so the measurement maths, the point cloud view and the result screen
/// can be exercised without a LiDAR device.
class FakeCaptureSource implements CaptureSource {
  @override
  Future<bool> get isSupported async => true;

  @override
  Future<RawCapture> capture() async {
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

    final frame = DepthFrame(
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

    // Two detections placed on the synthetic bead, so the result screen and the
    // mm sizing have something real-shaped to render off-device.
    const detections = [
      Detection(
        label: 'weld_seam',
        confidence: 0.91,
        box: Rect.fromLTRB(0.08, 0.49, 0.94, 0.56),
      ),
      Detection(
        label: 'porosity',
        confidence: 0.44,
        box: Rect.fromLTRB(0.41, 0.505, 0.45, 0.545),
      ),
    ];

    return (
      frame: frame,
      annotated: null,
      detections: detections,
      error: null,
    );
  }
}
