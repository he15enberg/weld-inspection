// Everything one Capture press produces.
//
// Assembled in main.dart and handed to MeasureScreen, which just picks a view.

import 'package:flutter/foundation.dart';

import 'capture_source.dart';
import 'measurement.dart';
import 'point_cloud.dart';

class Capture {
  const Capture({
    required this.frame,
    required this.cloud,
    required this.measured,
    this.rgb,
    this.annotated,
    this.inferenceError,
  });

  /// LiDAR depth plus the intrinsics describing it.
  final DepthFrame frame;

  /// Full-frame coloured cloud built from [frame].
  final PointCloud cloud;

  /// Detections with their millimetre sizes resolved against [frame].
  final List<Measured> measured;

  /// The captured RGB frame as JPEG, straight from ARKit.
  final Uint8List? rgb;

  /// The same frame with RF-DETR's masks composited on, rendered natively
  /// (PNG). Boxes and labels are drawn over this in Dart, not baked in, so the
  /// millimetre figures computed here can appear alongside them.
  final Uint8List? annotated;

  /// Why detections are missing or incomplete, when they are. Inference is
  /// allowed to fail without losing the capture — depth and the point cloud
  /// stand on their own.
  final String? inferenceError;

  int get detections => measured.length;

  bool get hasRgb => rgb != null && rgb!.isNotEmpty;
  bool get hasAnnotated => annotated != null && annotated!.isNotEmpty;

  /// The image to draw detections over: the mask composite when native
  /// produced one, otherwise the plain frame.
  Uint8List? get displayImage => hasAnnotated ? annotated : rgb;
}
