// Measure result, four views of the same capture:
//
//   RGB        the captured frame, straight from ARKit
//   Annotated  the same frame, native mask composite + boxes and mm drawn here
//   Sizes      every detection with its millimetre width and height
//   Depth      colourised LiDAR depth map
//   Cloud      full-frame RGB point cloud, orbitable
//
// The three 2-D views all share `cameraQuarterTurns`: ARKit delivers both the
// image and the depth buffer in the rear camera's native landscape orientation,
// so each needs the same rotation for a portrait screen.

import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'capture.dart';
import 'depth_map_view.dart';
import 'detection.dart';
import 'measurement.dart';
import 'overlay_painter.dart';
import 'point_cloud_view.dart';

enum MeasureTab {
  rgb('RGB'),
  annotated('Annotated'),
  sizes('Sizes'),
  depth('Depth'),
  cloud('Cloud');

  const MeasureTab(this.label);
  final String label;
}

class MeasureScreen extends StatefulWidget {
  const MeasureScreen({
    super.key,
    required this.capture,
    required this.onClose,
  });

  final Capture capture;
  final VoidCallback onClose;

  @override
  State<MeasureScreen> createState() => _MeasureScreenState();
}

class _MeasureScreenState extends State<MeasureScreen> {
  MeasureTab _tab = MeasureTab.annotated;
  bool _showStructural = true;

  @override
  Widget build(BuildContext context) {
    final capture = widget.capture;

    return Column(
      children: [
        _Header(capture: capture, tab: _tab, onClose: widget.onClose),
        _Tabs(
          active: _tab,
          available: {
            MeasureTab.rgb: capture.hasRgb,
            MeasureTab.annotated: capture.displayImage != null,
            MeasureTab.sizes: capture.measured.isNotEmpty,
            MeasureTab.depth: true,
            MeasureTab.cloud: !capture.cloud.isEmpty,
          },
          onSelect: (t) => setState(() => _tab = t),
        ),
        Expanded(
          child: Container(
            color: const Color(0xFF0C1116),
            child: _pane(capture),
          ),
        ),
      ],
    );
  }

  Widget _pane(Capture capture) {
    switch (_tab) {
      case MeasureTab.rgb:
        return capture.hasRgb
            ? _ImagePane(bytes: capture.rgb!)
            : const _Empty('No RGB frame in this capture');

      case MeasureTab.annotated:
        final image = capture.displayImage;
        if (image == null) {
          return _Empty(capture.inferenceError ?? 'No frame in this capture');
        }
        return _AnnotatedPane(
          bytes: image,
          capture: capture,
          showStructural: _showStructural,
          onToggleStructural: () =>
              setState(() => _showStructural = !_showStructural),
        );

      case MeasureTab.sizes:
        return _SizesPane(capture: capture);

      case MeasureTab.depth:
        return DepthMapView(frame: capture.frame);

      case MeasureTab.cloud:
        return Stack(
          children: [
            PointCloudView(cloud: capture.cloud),
            const Positioned(
              left: 14,
              bottom: 12,
              child: Text(
                'drag to orbit  ·  pinch to zoom  ·  double-tap to reset',
                style: TextStyle(fontSize: 11, color: Colors.white38),
              ),
            ),
          ],
        );
    }
  }
}

/// Zoomable still, rotated out of the camera's landscape frame.
class _ImagePane extends StatelessWidget {
  const _ImagePane({required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      maxScale: 8,
      child: RotatedBox(
        quarterTurns: cameraQuarterTurns,
        child: Image.memory(
          bytes,
          fit: BoxFit.contain,
          gaplessPlayback: true,
        ),
      ),
    );
  }
}

/// The capture with detections drawn over it.
///
/// The image is wrapped in an AspectRatio matching the capture's own
/// dimensions, so the CustomPaint above it is handed exactly the image's rect —
/// which is what lets the painter treat boxes as plain normalized coordinates
/// instead of reconstructing a BoxFit.contain letterbox.
class _AnnotatedPane extends StatelessWidget {
  const _AnnotatedPane({
    required this.bytes,
    required this.capture,
    required this.showStructural,
    required this.onToggleStructural,
  });

  final Uint8List bytes;
  final Capture capture;
  final bool showStructural;
  final VoidCallback onToggleStructural;

  @override
  Widget build(BuildContext context) {
    final w = capture.frame.imageWidth, h = capture.frame.imageHeight;
    final hasStructural =
        capture.measured.any((m) => isStructural(m.label));

    return Stack(
      children: [
        Positioned.fill(
          child: InteractiveViewer(
            maxScale: 8,
            child: RotatedBox(
              quarterTurns: cameraQuarterTurns,
              child: Center(
                child: AspectRatio(
                  aspectRatio: h == 0 ? 1 : w / h,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.memory(bytes,
                          fit: BoxFit.fill, gaplessPlayback: true),
                      CustomPaint(
                        painter: OverlayPainter(
                          measured: capture.measured,
                          showStructural: showStructural,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (hasStructural)
          Positioned(
            right: 12,
            bottom: 12,
            child: _Toggle(
              on: showStructural,
              label: 'workpiece / seam',
              onTap: onToggleStructural,
            ),
          ),
        if (capture.inferenceError != null)
          Positioned(
            left: 12,
            bottom: 12,
            child: _Badge(text: capture.inferenceError!),
          ),
      ],
    );
  }
}

/// Every detection with its resolved size.
class _SizesPane extends StatelessWidget {
  const _SizesPane({required this.capture});

  final Capture capture;

  @override
  Widget build(BuildContext context) {
    // defects first, then the structural regions: the defects are what a size
    // readout is for, and there are only ever one or two of the others
    final rows = [
      ...capture.measured.where((m) => !isStructural(m.label)),
      ...capture.measured.where((m) => isStructural(m.label)),
    ];

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: rows.length,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, color: Color(0xFF1B242D)),
      itemBuilder: (_, i) => _SizeRow(m: rows[i]),
    );
  }
}

class _SizeRow extends StatelessWidget {
  const _SizeRow({required this.m});

  final Measured m;

  @override
  Widget build(BuildContext context) {
    final color = colorFor(m.label);
    // depthFill is the fraction of the box that had a usable depth reading; a
    // size resting on a handful of pixels deserves to be flagged, not hidden
    final thin = m.hasSize && m.depthFill < 0.25;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Container(width: 10, height: 10,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(m.label,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  m.distanceM == null
                      ? 'no depth in this box'
                      : '${(m.distanceM! * 1000).toStringAsFixed(0)} mm away'
                          '  ·  ${(m.depthFill * 100).round()}% depth cover',
                  style: TextStyle(
                    fontSize: 11,
                    color: thin ? const Color(0xFFF1C40F) : Colors.white38,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(m.sizeLabel,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: m.hasSize ? Colors.white : Colors.white38,
                  )),
              const SizedBox(height: 2),
              Text('${(m.confidence * 100).round()}%',
                  style: const TextStyle(fontSize: 11, color: Colors.white38)),
            ],
          ),
        ],
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({required this.on, required this.label, required this.onTap});

  final bool on;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.66),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(on ? Icons.visibility : Icons.visibility_off,
                  size: 14, color: on ? Colors.white70 : Colors.white30),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                      fontSize: 11,
                      color: on ? Colors.white70 : Colors.white30)),
            ],
          ),
        ),
      );
}

class _Tabs extends StatelessWidget {
  const _Tabs({
    required this.active,
    required this.available,
    required this.onSelect,
  });

  final MeasureTab active;
  final Map<MeasureTab, bool> available;
  final ValueChanged<MeasureTab> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 42,
      color: const Color(0xFF131A22),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      child: Row(
        children: [
          for (final tab in MeasureTab.values)
            Expanded(
              child: _TabButton(
                label: tab.label,
                selected: tab == active,
                // a tab whose data is missing is disabled rather than hidden,
                // so the absence is visible instead of silent
                enabled: available[tab] ?? true,
                onTap: () => onSelect(tab),
              ),
            ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool selected, enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color fg;
    if (!enabled) {
      fg = Colors.white24;
    } else if (selected) {
      fg = const Color(0xFF061020);
    } else {
      fg = Colors.white70;
    }

    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF2F7FF0) : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: fg,
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.capture,
    required this.tab,
    required this.onClose,
  });

  final Capture capture;
  final MeasureTab tab;
  final VoidCallback onClose;

  String get _subtitle => switch (tab) {
        MeasureTab.rgb => '${capture.frame.imageWidth} x '
            '${capture.frame.imageHeight}  ·  captured frame',
        MeasureTab.annotated =>
          '${capture.detections} detections  ·  RF-DETR',
        MeasureTab.sizes => '${capture.measured.where((m) => m.hasSize).length}'
            ' of ${capture.detections} sized  ·  from LiDAR depth',
        MeasureTab.depth => '${capture.frame.width} x ${capture.frame.height}'
            '  ·  ARKit sceneDepth',
        MeasureTab.cloud => '${capture.cloud.count} points  ·  '
            '${capture.cloud.coloured ? 'RGB' : 'depth ramp'}',
      };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 6, 14, 6),
      color: const Color(0xFF131A22),
      child: Row(
        children: [
          IconButton(
            onPressed: onClose,
            icon: const Icon(Icons.arrow_back),
            tooltip: 'Back to live view',
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tab.label,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
                Text(_subtitle,
                    style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white54,
                        fontFeatures: [FontFeature.tabularFigures()])),
              ],
            ),
          ),
          if (capture.frame.synthetic) const _Badge(text: 'SIMULATED DEPTH'),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.message);
  final String message;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white38, fontSize: 13)),
        ),
      );
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFE8A13A)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text,
            style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Color(0xFFE8A13A))),
      );
}
