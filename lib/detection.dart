// One RF-DETR detection, and the palette used to draw it.
//
// Boxes arrive normalized 0..1. That is deliberate and it is what lets
// measurement.dart work unchanged: a normalized box maps into the captured
// image, the depth grid and the preview alike, so none of them ever has to be
// reconciled pixel-for-pixel.

import 'dart:ui' show Color, Rect;

class Detection {
  const Detection({
    required this.label,
    required this.confidence,
    required this.box,
  });

  final String label;
  final double confidence;

  /// Normalized 0..1, relative to the captured image.
  final Rect box;

  /// Parse one entry of the `detections` list from the platform channel.
  ///
  /// Native sends normalized xyxy as four doubles. Clamping happens here rather
  /// than in Swift so a box running slightly off the frame edge is still
  /// drawable, and the ordering is normalised so `Rect.width` can never come
  /// out negative.
  factory Detection.fromMap(Map<Object?, Object?> m) {
    double d(String k) => ((m[k] as num?) ?? 0).toDouble().clamp(0.0, 1.0);
    final x0 = d('x0'), y0 = d('y0'), x1 = d('x1'), y1 = d('y1');
    return Detection(
      label: m['label'] as String? ?? '?',
      confidence: ((m['confidence'] as num?) ?? 0).toDouble(),
      box: Rect.fromLTRB(
        x0 < x1 ? x0 : x1,
        y0 < y1 ? y0 : y1,
        x0 < x1 ? x1 : x0,
        y0 < y1 ? y1 : y0,
      ),
    );
  }

  static List<Detection> listFrom(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map(Detection.fromMap)
        .toList();
  }

  @override
  String toString() => '$label ${(confidence * 100).toStringAsFixed(0)}%';
}

// ---------------------------------------------------------------------------
// palette
// ---------------------------------------------------------------------------

/// Same colours as train/overlay.py, so a phone screenshot and a desktop
/// prediction of the same weld are directly comparable.
///
/// Note overlay.py stores BGR for OpenCV; these are the RGB equivalents.
const Map<String, Color> kClassColors = {
  'crack': Color(0xFFE74C3C),
  'discontinuity': Color(0xFFE67E22),
  'overlap': Color(0xFF9B59B6),
  'porosity': Color(0xFFE67E22),
  'spatter': Color(0xFF1ABC9C),
  'undercut': Color(0xFFF1C40F),
  'weld_seam': Color(0xFF2ECC71),
  'workpiece': Color(0xFFFFFF00),
};

const Color kDefaultClassColor = Color(0xFFC8C8C8);

/// Large regions. Drawn as a thin outline only, so the defects sitting inside
/// them stay readable — the same split overlay.py makes.
const Set<String> kStructuralClasses = {'workpiece', 'weld_seam'};

Color colorFor(String label) => kClassColors[label] ?? kDefaultClassColor;

bool isStructural(String label) => kStructuralClasses.contains(label);
