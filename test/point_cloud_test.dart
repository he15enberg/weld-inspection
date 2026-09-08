// The cloud builder and the drawRawAtlas render path. The atlas call is the
// part that cannot be checked by reading it -- get the rects or the transform
// scale wrong and it either draws nothing or throws at paint time.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yolo_test/depth_source.dart';
import 'package:yolo_test/point_cloud.dart';
import 'package:yolo_test/point_cloud_view.dart';

void main() {
  group('buildCloud', () {
    test('keeps every valid pixel, regardless of confidence', () async {
      final frame = await FakeDepthSource().capture();
      final cloud = await buildCloud(frame);

      // the fake source marks ~18% of pixels medium confidence; none may be
      // dropped now that filtering is off
      var valid = 0;
      for (var i = 0; i < frame.depth.length; i++) {
        if (frame.depth[i] > 0) valid++;
      }
      expect(cloud.count, valid);
      expect(cloud.count, frame.width * frame.height);
    });

    test('packs three coordinates and one colour per point', () async {
      final frame = await FakeDepthSource().capture();
      final cloud = await buildCloud(frame);
      expect(cloud.xyz.length, cloud.count * 3);
      expect(cloud.argb.length, cloud.count);
    });

    test('step thins the grid', () async {
      final frame = await FakeDepthSource().capture();
      final full = await buildCloud(frame, step: 1);
      final quarter = await buildCloud(frame, step: 2);
      expect(quarter.count, closeTo(full.count / 4, full.count * 0.02));
    });

    test('falls back to a depth ramp when there is no RGB frame', () async {
      final frame = await FakeDepthSource().capture();
      final cloud = await buildCloud(frame);
      expect(frame.jpeg, isNull);
      expect(cloud.coloured, isFalse);
      // every colour must be opaque, or points render invisible
      for (var i = 0; i < cloud.argb.length; i += 97) {
        expect((cloud.argb[i] >> 24) & 0xFF, 0xFF);
      }
    });

    test('geometry is centred on the optical axis', () async {
      final frame = await FakeDepthSource().capture();
      final cloud = await buildCloud(frame);
      var sumX = 0.0, sumY = 0.0;
      for (var i = 0; i < cloud.count; i++) {
        sumX += cloud.xyz[i * 3];
        sumY += cloud.xyz[i * 3 + 1];
      }
      expect(sumX / cloud.count, closeTo(0, 0.01));
      expect(sumY / cloud.count, closeTo(0, 0.01));
    });

    test('empty cloud is well formed', () {
      final empty = PointCloud.empty;
      expect(empty.isEmpty, isTrue);
      expect(empty.xyz, isEmpty);
      expect(empty.argb, isEmpty);
    });
  });

  group('PointCloudView', () {
    testWidgets('renders a cloud without throwing', (tester) async {
      final frame = await FakeDepthSource().capture();
      final cloud = await buildCloud(frame, step: 4);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 400,
            child: PointCloudView(cloud: cloud),
          ),
        ),
      ));
      // the sprite is decoded asynchronously; settle so paint actually runs
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(PointCloudView), findsOneWidget);
    });

    testWidgets('survives orbit and zoom gestures', (tester) async {
      final frame = await FakeDepthSource().capture();
      final cloud = await buildCloud(frame, step: 4);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 400,
            child: PointCloudView(cloud: cloud),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.drag(find.byType(PointCloudView), const Offset(60, 40));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PointCloudView));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('shows a message rather than an empty canvas', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: PointCloudView(cloud: PointCloud.empty)),
      ));
      await tester.pump();
      expect(find.textContaining('No depth'), findsOneWidget);
    });
  });
}
