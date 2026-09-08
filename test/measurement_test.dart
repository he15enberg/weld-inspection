// The measurement maths is the part that must be right. Everything else is UI.

import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:rfdetr_test/capture_source.dart';
import 'package:rfdetr_test/measurement.dart';

/// A flat wall at [z] metres, every pixel high-confidence.
DepthFrame flatFrame(double z, {int w = 256, int h = 192}) => DepthFrame(
      width: w,
      height: h,
      depth: Float32List(w * h)..fillRange(0, w * h, z),
      confidence: Uint8List(w * h)..fillRange(0, w * h, DepthFrame.confidenceHigh),
      fx: 2690,
      fy: 2690,
      cx: 2016,
      cy: 1512,
      imageWidth: 4032,
      imageHeight: 3024,
    );

void main() {
  group('sizeAt', () {
    test('a full-width box spans the whole field of view', () {
      final f = flatFrame(0.25);
      final s = sizeAt(f, const Rect.fromLTWH(0, 0, 1, 1), 0.25);
      // width = z * imageWidth / fx  = 0.25 * 4032 / 2690
      expect(s.widthMm, closeTo(0.25 * 4032 / 2690 * 1000, 0.01));
      expect(s.heightMm, closeTo(0.25 * 3024 / 2690 * 1000, 0.01));
    });

    test('size scales linearly with distance', () {
      final f = flatFrame(0.25);
      const box = Rect.fromLTWH(0.4, 0.4, 0.1, 0.1);
      final near = sizeAt(f, box, 0.25);
      final far = sizeAt(f, box, 0.50);
      expect(far.widthMm, closeTo(near.widthMm * 2, 1e-6));
    });

    test('a 10% box at 250 mm is a plausible weld size', () {
      final f = flatFrame(0.25);
      final s = sizeAt(f, const Rect.fromLTWH(0.4, 0.4, 0.1, 0.1), 0.25);
      // 0.1 * 0.25 * 4032 / 2690 * 1000 = 37.5 mm
      expect(s.widthMm, closeTo(37.5, 0.5));
    });

    test('mm per pixel matches the hand-computed figure', () {
      final f = flatFrame(0.25);
      // 250 mm / 2690 px = 0.0929 mm/px
      expect(mmPerPixel(f, 0.25), closeTo(0.0929, 0.001));
    });
  });

  group('sampleDepth', () {
    test('returns the plane distance and full fill', () {
      final f = flatFrame(0.3);
      final s = sampleDepth(f, const Rect.fromLTWH(0.25, 0.25, 0.5, 0.5));
      expect(s.depth, closeTo(0.3, 1e-6));
      expect(s.fill, closeTo(1.0, 0.01));
    });

    test('ignores low-confidence pixels', () {
      final f = flatFrame(0.3);
      // mark the left half as low confidence
      for (var v = 0; v < f.height; v++) {
        for (var u = 0; u < f.width ~/ 2; u++) {
          f.confidence[v * f.width + u] = DepthFrame.confidenceLow;
        }
      }
      final s = sampleDepth(f, const Rect.fromLTWH(0, 0, 1, 1));
      expect(s.depth, closeTo(0.3, 1e-6));
      expect(s.fill, closeTo(0.5, 0.02));
    });

    test('takes the median, so outliers do not drag it', () {
      final f = flatFrame(0.3);
      // a handful of wild readings, as dropouts and edge pixels produce
      for (var i = 0; i < 200; i++) {
        f.depth[i] = 4.5;
      }
      final s = sampleDepth(f, const Rect.fromLTWH(0, 0, 1, 1));
      expect(s.depth, closeTo(0.3, 1e-6));
    });

    test('reports no depth when nothing is valid', () {
      final f = flatFrame(0.3);
      f.confidence.fillRange(0, f.confidence.length, DepthFrame.confidenceLow);
      final s = sampleDepth(f, const Rect.fromLTWH(0, 0, 1, 1));
      expect(s.depth, isNull);
      expect(s.fill, 0);
    });
  });

  group('measureAll', () {
    test('sizes each detection and degrades gracefully without depth', () {
      final f = flatFrame(0.25);
      // knock out depth in the top-left quadrant
      for (var v = 0; v < f.height ~/ 2; v++) {
        for (var u = 0; u < f.width ~/ 2; u++) {
          f.confidence[v * f.width + u] = DepthFrame.confidenceLow;
        }
      }

      final out = measureAll(f, [
        (label: 'porosity', confidence: 0.7, box: const Rect.fromLTWH(0.6, 0.6, 0.05, 0.05)),
        (label: 'undercut', confidence: 0.5, box: const Rect.fromLTWH(0.05, 0.05, 0.2, 0.2)),
      ]);

      expect(out, hasLength(2));
      expect(out[0].hasSize, isTrue);
      expect(out[0].widthMm, closeTo(0.05 * 0.25 * 4032 / 2690 * 1000, 0.1));
      expect(out[1].hasSize, isFalse, reason: 'quadrant has no valid depth');
      expect(out[1].sizeLabel, 'no depth');
    });
  });

  group('unproject', () {
    test('a flat plane comes back at constant z, centred on the optical axis', () {
      final f = flatFrame(0.4);
      final pts = unproject(f, step: 4);
      expect(pts.length, greaterThan(0));

      var minZ = double.infinity, maxZ = -double.infinity;
      var sumX = 0.0, sumY = 0.0;
      final n = pts.length ~/ 3;
      for (var i = 0; i < n; i++) {
        final z = pts[i * 3 + 2];
        if (z < minZ) minZ = z;
        if (z > maxZ) maxZ = z;
        sumX += pts[i * 3];
        sumY += pts[i * 3 + 1];
      }
      expect(maxZ - minZ, closeTo(0, 1e-6));
      // principal point is the image centre, so x and y average out to ~0
      expect(sumX / n, closeTo(0, 0.01));
      expect(sumY / n, closeTo(0, 0.01));
    });

    test('plane width matches the field of view', () {
      final f = flatFrame(0.4);
      final pts = unproject(f, step: 1);
      var minX = double.infinity, maxX = -double.infinity;
      for (var i = 0; i < pts.length ~/ 3; i++) {
        final x = pts[i * 3];
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
      }
      // full-frame width at z is z * imageWidth / fx, less one pixel step
      final expected = 0.4 * 4032 / 2690;
      expect(maxX - minX, closeTo(expected, expected * 0.02));
    });

    test('skips low-confidence pixels', () {
      final f = flatFrame(0.4);
      final all = unproject(f, step: 1).length;
      f.confidence.fillRange(0, f.confidence.length ~/ 2, DepthFrame.confidenceLow);
      final half = unproject(f, step: 1).length;
      expect(half, closeTo(all / 2, all * 0.02));
    });
  });
}
