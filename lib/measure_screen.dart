// Result screen: the point cloud, and a size per detection.

import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'depth_source.dart';
import 'measurement.dart';
import 'point_cloud_view.dart';

const classColors = <String, Color>{
  'porosity': Color(0xFFE74C3C),
  'undercut': Color(0xFFF1C40F),
  'excess_reinforcement': Color(0xFF3498DB),
  'discontinuity': Color(0xFFE67E22),
  'crater': Color(0xFF9B59B6),
  'spatter': Color(0xFF1ABC9C),
  'weld_seam': Color(0xFF2ECC71),
  'workpiece': Color(0xFF7F8C9A),
};

Color colorFor(String label) => classColors[label] ?? const Color(0xFFBDC3C7);

class MeasureScreen extends StatelessWidget {
  const MeasureScreen({
    super.key,
    required this.frame,
    required this.points,
    required this.measured,
    required this.onClose,
  });

  final DepthFrame frame;
  final Float32List points;
  final List<Measured> measured;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final overlays = [
      for (final m in measured)
        if (m.distanceM != null)
          CloudBox(rect: m.box, z: m.distanceM!, color: colorFor(m.label)),
    ];

    return Column(
      children: [
        _Header(frame: frame, points: points.length ~/ 3, onClose: onClose),
        Expanded(
          flex: 3,
          child: Container(
            color: const Color(0xFF0C1116),
            child: Stack(
              children: [
                PointCloudView(points: points, overlays: overlays),
                const Positioned(
                  left: 12,
                  bottom: 10,
                  child: Text(
                    'drag to orbit   ·   pinch to zoom   ·   double-tap to reset',
                    style: TextStyle(fontSize: 11, color: Colors.white38),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(flex: 2, child: _Results(measured: measured)),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.frame, required this.points, required this.onClose});

  final DepthFrame frame;
  final int points;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 14, 8),
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
                Text('$points points · ${(frame.fillRate * 100).toStringAsFixed(0)}% fill',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                Text('${frame.width}x${frame.height} depth',
                    style: const TextStyle(fontSize: 11, color: Colors.white54)),
              ],
            ),
          ),
          if (frame.synthetic)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFFE8A13A)),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text('SIMULATED DEPTH',
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFFE8A13A))),
            ),
        ],
      ),
    );
  }
}

class _Results extends StatelessWidget {
  const _Results({required this.measured});

  final List<Measured> measured;

  @override
  Widget build(BuildContext context) {
    if (measured.isEmpty) {
      return const Center(
        child: Text('No detections in this frame',
            style: TextStyle(color: Colors.white38)),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: measured.length,
      separatorBuilder: (_, _) => const Divider(height: 1, color: Color(0xFF1F272E)),
      itemBuilder: (context, i) {
        final m = measured[i];
        return ListTile(
          dense: true,
          leading: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: colorFor(m.label),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          title: Text(m.sizeLabel,
              style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()])),
          subtitle: Text(
            '${m.label}  ·  conf ${m.confidence.toStringAsFixed(2)}'
            '${m.distanceM != null ? '  ·  ${m.distanceM!.toStringAsFixed(3)} m' : ''}'
            '${m.hasSize ? '  ·  depth fill ${(m.depthFill * 100).round()}%' : ''}',
            style: const TextStyle(fontSize: 11, color: Colors.white54),
          ),
          // low fill means the size rests on very few pixels -- say so
          trailing: m.hasSize && m.depthFill < 0.25
              ? const Icon(Icons.warning_amber_rounded,
                  size: 18, color: Color(0xFFE8A13A))
              : null,
        );
      },
    );
  }
}
