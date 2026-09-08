// Measure result, four views of the same capture:
//
//   RGB        the captured frame, straight from ARKit
//   Annotated  the same frame with masks drawn by the model
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
import 'point_cloud_view.dart';

enum MeasureTab {
  rgb('RGB'),
  annotated('Annotated'),
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
            MeasureTab.annotated: capture.hasAnnotated,
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
        if (capture.hasAnnotated) return _ImagePane(bytes: capture.annotated!);
        return _Empty(capture.annotateError ?? 'No annotated frame');

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
          '${capture.detections} detections  ·  model overlay',
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
