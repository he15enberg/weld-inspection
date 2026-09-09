// The server's answer: the annotated frame and the millimetre figures.
//
// The overlay is drawn server-side, so this widget does no coordinate maths at
// all -- it shows an image and a list. That is the whole point of returning a
// JPEG rather than polygons.

import 'package:flutter/material.dart';

import 'api.dart';

const _classColors = <String, Color>{
  'crack': Color(0xFFE74C3C),
  'discontinuity': Color(0xFFE67E22),
  'overlap': Color(0xFF9B59B6),
  'porosity': Color(0xFFE67E22),
  'spatter': Color(0xFF1ABC9C),
  'undercut': Color(0xFFF1C40F),
  'weld_seam': Color(0xFF2ECC71),
  'workpiece': Color(0xFFFFFF00),
};

Color _colorFor(String label) => _classColors[label] ?? const Color(0xFFC8C8C8);

/// Large regions; listed after the defects, which are what a size readout is for.
const _structural = {'workpiece', 'weld_seam'};

class ResultView extends StatelessWidget {
  const ResultView({super.key, required this.report, required this.onClose});

  final Report report;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final rows = [
      ...report.detections.where((d) => !_structural.contains(d.label)),
      ...report.detections.where((d) => _structural.contains(d.label)),
    ];

    return Column(
      children: [
        _Header(report: report, onClose: onClose),
        Expanded(
          flex: 3,
          child: ColoredBox(
            color: const Color(0xFF0C1116),
            child: InteractiveViewer(
              maxScale: 8,
              // ARKit hands over the frame in the camera's native landscape
              // orientation, so it needs a quarter turn for a portrait screen.
              child: RotatedBox(
                quarterTurns: 1,
                child: Image.memory(report.annotated, fit: BoxFit.contain),
              ),
            ),
          ),
        ),
        Expanded(
          flex: 2,
          child: rows.isEmpty
              ? const Center(
                  child: Text('nothing detected',
                      style: TextStyle(color: Colors.white38)))
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: rows.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, color: Color(0xFF1B242D)),
                  itemBuilder: (_, i) => _Row(d: rows[i]),
                ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.report, required this.onClose});

  final Report report;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Container(
        color: const Color(0xFF131A22),
        padding: const EdgeInsets.fromLTRB(4, 6, 14, 6),
        child: Row(
          children: [
            IconButton(
                onPressed: onClose,
                icon: const Icon(Icons.arrow_back, size: 20)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${report.detections.length} detections',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                  Text('server ${report.serverMs} ms',
                      style: const TextStyle(
                          fontSize: 11, color: Colors.white38)),
                ],
              ),
            ),
          ],
        ),
      );
}

class _Row extends StatelessWidget {
  const _Row({required this.d});

  final Detection d;

  @override
  Widget build(BuildContext context) {
    // A size resting on very few depth pixels is worth flagging rather than
    // presenting with the same confidence as a well-covered one.
    final thin = d.hasSize && (d.depthFill ?? 0) < 0.25;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
                color: _colorFor(d.label), shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(d.label,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  d.distanceM == null
                      ? 'no depth in this mask'
                      : '${(d.distanceM! * 1000).toStringAsFixed(0)} mm away'
                          '  ·  ${((d.depthFill ?? 0) * 100).round()}% depth cover',
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
              Text(
                d.sizeLabel,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: d.hasSize ? Colors.white : Colors.white38,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                d.uncertaintyMm != null
                    ? '±${d.uncertaintyMm!.toStringAsFixed(2)} mm  ·  '
                        '${(d.confidence * 100).round()}%'
                    : '${(d.confidence * 100).round()}%',
                style: const TextStyle(fontSize: 11, color: Colors.white38),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
