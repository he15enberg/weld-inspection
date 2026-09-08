// Boxes, labels and millimetre sizes drawn over the captured image.
//
// The masks are composited natively (they are cheap to draw there and
// expensive to ship across a channel); only the vector layer is drawn here, so
// the mm figures — which are computed in Dart from the depth frame — can sit
// next to the box they belong to.
//
// Boxes are normalized, so this painter needs no knowledge of the capture
// resolution: it multiplies by whatever rect the image was laid out into.

import 'package:flutter/material.dart';

import 'detection.dart';
import 'measurement.dart';

class OverlayPainter extends CustomPainter {
  OverlayPainter({required this.measured, this.showStructural = true});

  final List<Measured> measured;

  /// Workpiece and weld_seam cover most of the frame; hiding them declutters
  /// the view when you only care about defects.
  final bool showStructural;

  @override
  void paint(Canvas canvas, Size size) {
    // structural first, so defect boxes and their labels land on top
    final ordered = [
      ...measured.where((m) => isStructural(m.label)),
      ...measured.where((m) => !isStructural(m.label)),
    ];

    for (final m in ordered) {
      final structural = isStructural(m.label);
      if (structural && !showStructural) continue;

      final color = colorFor(m.label);
      final r = Rect.fromLTRB(
        m.box.left * size.width,
        m.box.top * size.height,
        m.box.right * size.width,
        m.box.bottom * size.height,
      );

      canvas.drawRect(
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = structural ? 1.4 : 2.2
          ..color = structural ? color.withValues(alpha: 0.75) : color,
      );

      // Structural regions are labelled by the summary list, not on the image —
      // a full-frame workpiece box with a caption just covers the weld.
      if (!structural) _label(canvas, size, r, m, color);
    }
  }

  void _label(Canvas canvas, Size size, Rect r, Measured m, Color color) {
    final text = m.hasSize
        ? '${m.label} ${(m.confidence * 100).round()}%  ${m.sizeLabel}'
        : '${m.label} ${(m.confidence * 100).round()}%';

    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          height: 1.1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    const padX = 4.0, padY = 2.0;
    final w = tp.width + padX * 2, h = tp.height + padY * 2;

    // Prefer above the box; flip inside when there is no room at the top, and
    // pull back from the right edge so the caption is never clipped.
    var left = r.left;
    if (left + w > size.width) left = size.width - w;
    if (left < 0) left = 0;
    var top = r.top - h - 1;
    if (top < 0) top = r.top + 1;

    final bg = Rect.fromLTWH(left, top, w, h);
    canvas.drawRRect(
      RRect.fromRectAndRadius(bg, const Radius.circular(3)),
      Paint()..color = color.withValues(alpha: 0.92),
    );
    tp.paint(canvas, Offset(left + padX, top + padY));
  }

  @override
  bool shouldRepaint(OverlayPainter old) =>
      old.measured != measured || old.showStructural != showStructural;
}
