// Measure result: the RGB point cloud, full frame, and nothing else.
//
// Measurement and standards logic are deliberately not wired in here yet --
// this screen exists to prove the depth capture and the 3-D view.

import 'package:flutter/material.dart';

import 'depth_source.dart';
import 'point_cloud.dart';
import 'point_cloud_view.dart';

class MeasureScreen extends StatelessWidget {
  const MeasureScreen({
    super.key,
    required this.frame,
    required this.cloud,
    required this.onClose,
  });

  final DepthFrame frame;
  final PointCloud cloud;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _Header(frame: frame, cloud: cloud, onClose: onClose),
        Expanded(
          child: Container(
            color: const Color(0xFF0C1116),
            child: Stack(
              children: [
                PointCloudView(cloud: cloud),
                const Positioned(
                  left: 14,
                  bottom: 12,
                  child: Text(
                    'drag to orbit   ·   pinch to zoom   ·   double-tap to reset',
                    style: TextStyle(fontSize: 11, color: Colors.white38),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.frame, required this.cloud, required this.onClose});

  final DepthFrame frame;
  final PointCloud cloud;
  final VoidCallback onClose;

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
                Text(
                  '${cloud.count} points',
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      fontFeatures: [FontFeature.tabularFigures()]),
                ),
                Text(
                  '${frame.width}x${frame.height} depth  ·  '
                  '${cloud.coloured ? 'RGB' : 'depth ramp'}',
                  style: const TextStyle(fontSize: 11, color: Colors.white54),
                ),
              ],
            ),
          ),
          if (frame.synthetic) const _Badge(text: 'SIMULATED DEPTH'),
        ],
      ),
    );
  }
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
