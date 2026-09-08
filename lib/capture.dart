// Everything one Measure press produces.
//
// Assembled in main.dart and handed to MeasureScreen, which just picks a view.

import 'package:flutter/foundation.dart';

import 'depth_source.dart';
import 'point_cloud.dart';

class Capture {
  const Capture({
    required this.frame,
    required this.cloud,
    this.rgb,
    this.annotated,
    this.detections = 0,
    this.annotateError,
  });

  /// LiDAR depth plus the intrinsics describing it.
  final DepthFrame frame;

  /// Full-frame coloured cloud built from [frame].
  final PointCloud cloud;

  /// The captured RGB frame as JPEG, straight from ARKit.
  final Uint8List? rgb;

  /// The same frame with masks and boxes drawn on, rendered natively by the
  /// plugin's single-image predict path (PNG).
  final Uint8List? annotated;

  final int detections;

  /// Why annotation is missing, when it is.
  final String? annotateError;

  bool get hasRgb => rgb != null && rgb!.isNotEmpty;
  bool get hasAnnotated => annotated != null && annotated!.isNotEmpty;
}
