// RF-DETR weld inspection: aim, capture, measure.
//
// One ARSession runs the whole app. Pressing Capture takes a single ARFrame and
// gets everything from it at once -- the RGB image, RF-DETR's masks and boxes,
// the LiDAR depth map and a full-frame point cloud -- so every view in the
// result screen describes the same instant.
//
// This is what the YOLO app could not do. There, the inference plugin owned the
// camera and ARKit could not open it simultaneously, so Measure had to unmount
// the live view, wait for the camera to free, then start ARKit: the RGB and the
// depth came from different moments. Nothing here needs that dance, because
// nothing competes for the camera -- inference runs on a frame ARKit already
// handed us.

import 'package:flutter/material.dart';

import 'ar_preview.dart';
import 'capture.dart';
import 'capture_source.dart';
import 'measure_screen.dart';
import 'measurement.dart';
import 'point_cloud.dart';

void main() => runApp(const WeldApp());

class WeldApp extends StatelessWidget {
  const WeldApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Weld Inspect',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: const HomePage(),
      );
}

enum _Mode { live, capturing, result }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _source = CaptureSource.create();

  _Mode _mode = _Mode.live;
  String _status = '';
  Capture? _capture;

  Future<void> _capturePressed() async {
    setState(() {
      _mode = _Mode.capturing;
      _status = 'Capturing frame…';
    });

    try {
      // One channel round trip: ARKit grabs the frame and Core ML runs on it
      // natively, so nothing large crosses back except the images.
      final raw = await _source.capture();

      if (!mounted) return;
      setState(() => _status = 'Building point cloud…');
      final cloud = await buildCloud(raw.frame);

      // Sizes are resolved here rather than natively: the maths is the tested
      // Dart in measurement.dart, and it only needs the depth frame and a
      // normalized box.
      final measured = measureAll(
        raw.frame,
        raw.detections
            .map((d) => (label: d.label, confidence: d.confidence, box: d.box))
            .toList(),
      );

      if (!mounted) return;
      setState(() {
        _capture = Capture(
          frame: raw.frame,
          cloud: cloud,
          measured: measured,
          rgb: raw.frame.jpeg,
          annotated: raw.annotated,
          inferenceError: raw.error,
        );
        _mode = _Mode.result;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _mode = _Mode.live);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Capture failed: $e')),
      );
    }
  }

  void _backToLive() => setState(() {
        _mode = _Mode.live;
        _capture = null;
      });

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: const Color(0xFF0C1116),
        body: SafeArea(child: _body()),
        floatingActionButton: _mode == _Mode.live
            ? FloatingActionButton.extended(
                onPressed: _capturePressed,
                backgroundColor: const Color(0xFF2F7FF0),
                icon: const Icon(Icons.center_focus_strong),
                label: const Text('Capture'),
              )
            : null,
      );

  Widget _body() {
    switch (_mode) {
      case _Mode.capturing:
        return _Busy(status: _status);

      case _Mode.result:
        return MeasureScreen(capture: _capture!, onClose: _backToLive);

      case _Mode.live:
        return Stack(
          children: const [
            Positioned.fill(child: ArPreview()),
            Positioned(
              left: 12,
              top: 12,
              child: _Pill(text: 'aim at the weld, then Capture'),
            ),
          ],
        );
    }
  }
}

class _Busy extends StatelessWidget {
  const _Busy({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 18),
            Text(status, style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 8),
            const Text(
              'RF-DETR at 1272 takes a moment',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ],
        ),
      );
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.62),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(text, style: const TextStyle(fontSize: 13)),
      );
}
