// Live weld segmentation, and a Measure action that returns a point cloud plus
// a height and width for every detection.
//
// The one structural constraint: YOLOView owns the camera, and ARKit also wants
// to own it. They cannot run at the same time. So pressing Measure UNMOUNTS
// YOLOView -- which disposes it and frees the camera -- and only then runs the
// depth capture. That is what `_Mode` exists to sequence.

import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import 'depth_source.dart';
import 'measure_screen.dart';
import 'measurement.dart';

/// Both trained models ship in assets; switch by changing [activeModel].
///
///   v1 - 8 classes, the earlier 12-image model
///        porosity, weld_seam, discontinuity, workpiece, undercut,
///        excess_reinforcement, crater, spatter
///   v2 - 7 classes, trained on the 36-image data-40 set  <- current
///        crack, overlap, porosity, spatter, undercut, weld_seam, workpiece
///
/// Class names differ between them, so measure_screen.dart's classColors must
/// match whichever is active or detections fall back to grey.
enum WeldModel {
  v1('weld_v1_8cls'),
  v2('weld_v2_7cls');

  const WeldModel(this.base);
  final String base;

  /// TFLite on Android, CoreML on iOS.
  ///
  /// The iOS path MUST keep the `.zip` suffix. The plugin's resolver only
  /// unpacks an archive when the path ends in `.mlpackage.zip`; give it a bare
  /// `.mlpackage` and it passes the string straight through, then fails with
  /// "Model does not exist at ... -- file:///".
  String get path => (!kIsWeb && Platform.isIOS)
      ? 'assets/models/$base.mlpackage.zip'
      : 'assets/models/$base.tflite';
}

const activeModel = WeldModel.v2;
final modelPath = activeModel.path;

enum _Mode { live, capturing, result }

void main() => runApp(const WeldApp());

class WeldApp extends StatelessWidget {
  const WeldApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Weld Measure',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _depth = DepthSource.create();

  _Mode _mode = _Mode.live;
  String _status = '';

  // newest live detections, kept so Measure has something to size
  List<YOLOResult> _live = const [];

  DepthFrame? _frame;
  Float32List _points = Float32List(0);
  List<Measured> _measured = const [];

  void _onResult(List<YOLOResult> results) {
    if (!mounted || _mode != _Mode.live) return;
    setState(() => _live = results);
  }

  Future<void> _measure() async {
    final detections = [
      for (final r in _live)
        (label: r.className, confidence: r.confidence, box: r.normalizedBox),
    ];

    // unmount YOLOView first: ARKit cannot open the camera while it is held
    setState(() {
      _mode = _Mode.capturing;
      _status = 'Releasing camera…';
    });
    await Future<void>.delayed(const Duration(milliseconds: 250));

    try {
      setState(() => _status = 'Capturing depth…');
      final frame = await _depth.capture();

      setState(() => _status = 'Measuring…');
      final points = unproject(frame, step: 2);
      final measured = measureAll(frame, detections);

      if (!mounted) return;
      setState(() {
        _frame = frame;
        _points = points;
        _measured = measured;
        _mode = _Mode.result;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _mode = _Mode.live);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Depth capture failed: $e')),
      );
    }
  }

  void _backToLive() => setState(() {
        _mode = _Mode.live;
        _points = Float32List(0);
        _measured = const [];
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0C1116),
      body: SafeArea(child: _body()),
      floatingActionButton: _mode == _Mode.live
          ? FloatingActionButton.extended(
              onPressed: _live.isEmpty ? null : _measure,
              backgroundColor:
                  _live.isEmpty ? Colors.grey.shade800 : const Color(0xFF2F7FF0),
              icon: const Icon(Icons.straighten),
              label: const Text('Measure'),
            )
          : null,
    );
  }

  Widget _body() {
    switch (_mode) {
      case _Mode.capturing:
        return _Busy(status: _status);

      case _Mode.result:
        return MeasureScreen(
          frame: _frame!,
          points: _points,
          measured: _measured,
          onClose: _backToLive,
        );

      case _Mode.live:
        return Stack(
          children: [
            YOLOView(
              modelPath: modelPath,
              task: YOLOTask.segment,
              onResult: _onResult,
            ),
            Positioned(
              left: 12,
              top: 12,
              child: _Pill(
                text: _live.isEmpty
                    ? 'no detections'
                    : '${_live.length} detections',
              ),
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
