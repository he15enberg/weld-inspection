// Channel parsing and the palette.
//
// The parsing matters more than it looks: native sends four loose doubles, and
// a swapped or out-of-range pair produces a Rect with negative width that draws
// as nothing rather than throwing.

import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:rfdetr_test/detection.dart';

void main() {
  group('Detection.fromMap', () {
    test('reads a normal box', () {
      final d = Detection.fromMap({
        'label': 'porosity',
        'confidence': 0.42,
        'x0': 0.1,
        'y0': 0.2,
        'x1': 0.3,
        'y1': 0.5,
      });
      expect(d.label, 'porosity');
      expect(d.confidence, closeTo(0.42, 1e-9));
      expect(d.box, const Rect.fromLTRB(0.1, 0.2, 0.3, 0.5));
    });

    test('normalises a reversed box rather than yielding negative width', () {
      final d = Detection.fromMap({
        'label': 'crack',
        'confidence': 0.3,
        'x0': 0.8,
        'y0': 0.9,
        'x1': 0.2,
        'y1': 0.4,
      });
      expect(d.box.width, greaterThan(0));
      expect(d.box.height, greaterThan(0));
      expect(d.box, const Rect.fromLTRB(0.2, 0.4, 0.8, 0.9));
    });

    test('clamps a box that runs off the frame', () {
      final d = Detection.fromMap({
        'label': 'spatter',
        'confidence': 0.9,
        'x0': -0.4,
        'y0': 0.5,
        'x1': 1.7,
        'y1': 1.2,
      });
      expect(d.box, const Rect.fromLTRB(0.0, 0.5, 1.0, 1.0));
    });

    test('survives a payload with missing fields', () {
      final d = Detection.fromMap({'label': 'undercut'});
      expect(d.confidence, 0);
      expect(d.box, Rect.zero);
    });

    test('listFrom tolerates a null or wrong-typed payload', () {
      expect(Detection.listFrom(null), isEmpty);
      expect(Detection.listFrom('nope'), isEmpty);
      expect(Detection.listFrom([1, 'two']), isEmpty);
    });

    test('listFrom parses a real channel list', () {
      final list = Detection.listFrom([
        {'label': 'weld_seam', 'confidence': 0.8, 'x0': 0.0, 'y0': 0.4, 'x1': 1.0, 'y1': 0.6},
        {'label': 'porosity', 'confidence': 0.3, 'x0': 0.4, 'y0': 0.45, 'x1': 0.44, 'y1': 0.55},
      ]);
      expect(list, hasLength(2));
      expect(list.first.label, 'weld_seam');
    });
  });

  group('palette', () {
    test('every trained class has a colour', () {
      // The union of both checkpoints: data-40's 7 and the combined set's 8.
      const all = [
        'crack', 'discontinuity', 'overlap', 'porosity',
        'spatter', 'undercut', 'weld_seam', 'workpiece',
      ];
      for (final c in all) {
        expect(kClassColors.containsKey(c), isTrue, reason: '$c has no colour');
      }
    });

    test('an unknown label still draws', () {
      expect(colorFor('something_new'), kDefaultClassColor);
    });

    test('only the large regions count as structural', () {
      expect(isStructural('workpiece'), isTrue);
      expect(isStructural('weld_seam'), isTrue);
      expect(isStructural('porosity'), isFalse);
    });
  });
}
