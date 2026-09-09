// One ARKit frame: RGB, depth, and the intrinsics that describe them.
//
// Everything here comes from a single ARFrame, so the photo and the depth map
// are the same instant. Nothing is interpreted on the phone -- the bytes go
// straight to the server.

import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

class Capture {
  const Capture({
    required this.jpeg,
    required this.depth,
    required this.confidence,
    required this.depthWidth,
    required this.depthHeight,
    required this.imageWidth,
    required this.imageHeight,
    required this.fx,
    required this.fy,
    required this.cx,
    required this.cy,
  });

  /// The captured frame, JPEG.
  final Uint8List jpeg;

  /// uint16 little-endian millimetres, row-major. Zero means no reading.
  final Uint8List depth;

  /// ARKit confidence levels, one byte per depth sample.
  final Uint8List confidence;

  final int depthWidth, depthHeight;

  /// The size the intrinsics are quoted for -- NOT the depth grid size.
  final int imageWidth, imageHeight;
  final double fx, fy, cx, cy;

  factory Capture.fromChannel(Map<Object?, Object?> m) {
    double d(String k) => (m[k] as num).toDouble();
    int i(String k) => (m[k] as num).toInt();
    final jpeg = m['jpeg'] as Uint8List?;
    if (jpeg == null || jpeg.isEmpty) {
      throw const CaptureFailed('the camera frame could not be encoded');
    }
    return Capture(
      jpeg: jpeg,
      depth: m['depth'] as Uint8List,
      confidence: m['confidence'] as Uint8List,
      depthWidth: i('depthWidth'),
      depthHeight: i('depthHeight'),
      imageWidth: i('imageWidth'),
      imageHeight: i('imageHeight'),
      fx: d('fx'),
      fy: d('fy'),
      cx: d('cx'),
      cy: d('cy'),
    );
  }

  /// Roughly what will go over the wire, for the progress line.
  int get bytes => jpeg.length + depth.length + confidence.length;
}

class CaptureFailed implements Exception {
  const CaptureFailed(this.message);
  final String message;
  @override
  String toString() => message;
}

class CaptureSource {
  static const _channel = MethodChannel('weldz/capture');

  Future<bool> get isSupported async {
    if (kIsWeb || !Platform.isIOS) return false;
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<Capture> grab() async {
    try {
      final r = await _channel.invokeMethod<Map<Object?, Object?>>('capture');
      if (r == null) throw const CaptureFailed('no frame returned');
      return Capture.fromChannel(r);
    } on PlatformException catch (e) {
      throw CaptureFailed(e.message ?? 'capture failed');
    }
  }
}
