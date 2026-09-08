// Measure result: a 2-D colourised depth map.
//
// The 3-D RGB point cloud is commented out rather than deleted -- see the
// blocks marked POINT CLOUD below, and lib/point_cloud.dart /
// lib/point_cloud_view.dart, which are both still intact. To switch back:
// uncomment those blocks, re-add the `cloud` parameter, and restore the
// buildCloud() call in main.dart.

import 'package:flutter/material.dart';

import 'depth_map_view.dart';
import 'depth_source.dart';

// --- POINT CLOUD (disabled) -------------------------------------------------
// import 'point_cloud.dart';
// import 'point_cloud_view.dart';
// ----------------------------------------------------------------------------

class MeasureScreen extends StatelessWidget {
  const MeasureScreen({
    super.key,
    required this.frame,
    required this.onClose,
    // --- POINT CLOUD (disabled) ---
    // required this.cloud,
  });

  final DepthFrame frame;
  final VoidCallback onClose;

  // --- POINT CLOUD (disabled) ---
  // final PointCloud cloud;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _Header(frame: frame, onClose: onClose),
        Expanded(
          child: Container(
            color: const Color(0xFF0C1116),
            child: DepthMapView(frame: frame),

            // --- POINT CLOUD (disabled) ---
            // child: Stack(
            //   children: [
            //     PointCloudView(cloud: cloud),
            //     const Positioned(
            //       left: 14,
            //       bottom: 12,
            //       child: Text(
            //         'drag to orbit  ·  pinch to zoom  ·  double-tap to reset',
            //         style: TextStyle(fontSize: 11, color: Colors.white38),
            //       ),
            //     ),
            //   ],
            // ),
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.frame, required this.onClose});

  final DepthFrame frame;
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
                const Text(
                  'Depth map',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                Text(
                  '${frame.width} x ${frame.height}  ·  ARKit sceneDepth',
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
