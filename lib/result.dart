// Five views of one capture, plus the measurements.
//
//   RGB       the frame as shot
//   Segments  the same frame with masks and boxes, drawn server-side
//   Depth     colourised LiDAR depth
//   Cloud     full-frame point cloud
//   Part      the same cloud cropped to the workpiece mask
//
// The two image views need no coordinate maths: the overlay arrives already
// drawn. The two clouds are built on-device from depth the phone still holds,
// so nothing is round-tripped for them.
//
// Both clouds are built lazily, on first visit. Unprojecting 49k points and
// decoding the JPEG for colour is not work to do for a tab nobody opens.

import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'api.dart';
import 'roi.dart';
import 'capture.dart';
import 'depth_view.dart';
import 'point_cloud.dart';
import 'point_cloud_view.dart';
import 'theme.dart';
import 'verdict_card.dart';

enum ResultTab {
  rgb('RGB', Icons.photo_camera_outlined),
  segments('Segments', Icons.layers_outlined),
  depth('Depth', Icons.gradient_outlined),
  cloud('Cloud', Icons.blur_on),
  part('Part', Icons.center_focus_weak_outlined);

  const ResultTab(this.label, this.icon);
  final String label;
  final IconData icon;
}

class ResultView extends StatefulWidget {
  const ResultView({
    super.key,
    required this.capture,
    required this.report,
    required this.onClose,
  });

  final Capture capture;
  final Report report;
  final VoidCallback onClose;

  @override
  State<ResultView> createState() => _ResultViewState();
}

class _ResultViewState extends State<ResultView> {
  ResultTab _tab = ResultTab.segments;

  PointCloud? _full;
  PointCloud? _part;
  bool _buildingFull = false;
  bool _buildingPart = false;

  Future<void> _ensureFull() async {
    if (_full != null || _buildingFull) return;
    _buildingFull = true;
    final cloud = await buildCloud(widget.capture, roi: widget.report.roi);
    if (mounted) setState(() => _full = cloud);
    _buildingFull = false;
  }

  Future<void> _ensurePart() async {
    if (_part != null || _buildingPart) return;
    _buildingPart = true;
    final png = widget.report.cropMask;
    // No structural mask means nothing to crop to. An empty cloud says that
    // honestly, rather than silently showing the full frame under a label that
    // claims otherwise.
    final mask = png == null ? null : await decodeMask(png);
    final cloud = mask == null
        ? PointCloud.empty
        : await buildCloud(widget.capture,
            mask: mask, roi: widget.report.roi);
    if (mounted) setState(() => _part = cloud);
    _buildingPart = false;
  }

  void _select(ResultTab t) {
    setState(() => _tab = t);
    if (t == ResultTab.cloud) _ensureFull();
    if (t == ResultTab.part) _ensurePart();
  }

  @override
  Widget build(BuildContext context) {
    final defects = widget.report.detections
        .where((d) => !WeldzColors.isStructural(d.label))
        .length;

    return Column(
      children: [
        _Header(
          report: widget.report,
          defects: defects,
          onClose: widget.onClose,
        ),
        _Tabs(active: _tab, onSelect: _select),
        Expanded(
          flex: 5,
          child: ColoredBox(color: Colors.black, child: _pane()),
        ),
        _Caption(tab: _tab, report: widget.report),
        Expanded(
          flex: 4,
          child: ListView(
            padding: const EdgeInsets.only(bottom: 18),
            children: [
              // The gate stands in for the verdict rather than sitting
              // beside it: a grade from an unusable photograph looks exactly
              // like a real one, and showing both invites the number to be
              // believed anyway.
              if (widget.report.assessment.blocks)
                CaptureGate(assessment: widget.report.assessment)
              else ...[
                VerdictBanner(judgement: widget.report.judgement),
                RuleList(judgement: widget.report.judgement),
                UtilisationList(judgement: widget.report.judgement),
              ],
              AssessmentCard(assessment: widget.report.assessment),
              const SizedBox(height: 14),
              _Findings(report: widget.report),
            ],
          ),
        ),
      ],
    );
  }

  Widget _pane() {
    switch (_tab) {
      case ResultTab.rgb:
        // Cropped to the analysed square, so this tab and the Segments tab are
        // the same picture. Showing the full frame here invites reading a
        // defect into a part of the image the model never looked at.
        return _Image(bytes: widget.capture.jpeg, roi: widget.report.roi,
            capture: widget.capture);
      case ResultTab.segments:
        return _Image(bytes: widget.report.annotated);
      case ResultTab.depth:
        return DepthView(capture: widget.capture, roi: widget.report.roi);
      case ResultTab.cloud:
        return _Cloud(cloud: _full);
      case ResultTab.part:
        return _Cloud(cloud: _part);
    }
  }
}

/// ARKit hands over the frame in the camera's native landscape orientation, so
/// every 2-D view needs the same quarter turn for a portrait screen.
class _Image extends StatelessWidget {
  const _Image({required this.bytes, this.roi, this.capture});

  final Uint8List bytes;

  /// When both are given AND the crop is centred, the picture is cut down to
  /// the analysed region. The server centres its crop on both axes, which is
  /// what makes ClipRect + Align exact here rather than approximate — and
  /// [Roi.isCentred] is checked rather than assumed, because an off-centre crop
  /// would silently show the wrong part of the frame.
  final Roi? roi;
  final Capture? capture;

  @override
  Widget build(BuildContext context) {
    // quarterTurns: 1 undoes ARKit's landscape camera buffer. The server sends
    // its overlay back in that same orientation, so one rule covers both tabs.
    Widget picture = Image.memory(bytes,
        fit: BoxFit.contain, gaplessPlayback: true);

    final r = roi;
    final c = capture;
    if (r != null && c != null && r.isCentred(c)) {
      picture = ClipRect(
        child: Align(
          alignment: Alignment.center,
          widthFactor: r.widthFactor(c),
          heightFactor: r.heightFactor(c),
          child: picture,
        ),
      );
    }

    return InteractiveViewer(
      maxScale: 8,
      child: RotatedBox(quarterTurns: 1, child: picture),
    );
  }
}

class _Cloud extends StatelessWidget {
  const _Cloud({required this.cloud});

  final PointCloud? cloud;

  @override
  Widget build(BuildContext context) {
    final c = cloud;
    if (c == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
                width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(height: 12),
            Text('Unprojecting…',
                style: TextStyle(color: WeldzColors.textFaint, fontSize: 12)),
          ],
        ),
      );
    }
    return Stack(
      children: [
        Positioned.fill(child: PointCloudView(cloud: c)),
        if (!c.isEmpty)
          const Positioned(
            left: 14,
            bottom: 10,
            child: Text('drag to orbit · pinch to zoom · double-tap to reset',
                style: TextStyle(fontSize: 10, color: WeldzColors.textFaint)),
          ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.report,
    required this.defects,
    required this.onClose,
  });

  final Report report;
  final int defects;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Container(
        color: WeldzColors.bg,
        padding: const EdgeInsets.fromLTRB(4, 4, 16, 8),
        child: Row(
          children: [
            IconButton(
                onPressed: onClose, icon: const Icon(Icons.arrow_back, size: 22)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    defects == 0 ? 'No defects found' : '$defects defects',
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    '${report.detections.length} regions · '
                    '${report.serverMs} ms on the server',
                    style: const TextStyle(
                        fontSize: 11, color: WeldzColors.textDim),
                  ),
                ],
              ),
            ),
            // The rule table's verdict, not a guess from the detection count.
            // The old chip said "clean" whenever no defect class fired, which
            // is a different claim from "the rules cleared it".
            _Chip(
              text: report.judgement.verdict.label.toLowerCase(),
              color: verdictColour(report.judgement.verdict),
            ),
          ],
        ),
      );
}

class _Tabs extends StatelessWidget {
  const _Tabs({required this.active, required this.onSelect});

  final ResultTab active;
  final ValueChanged<ResultTab> onSelect;

  @override
  Widget build(BuildContext context) => Container(
        height: 44,
        decoration: const BoxDecoration(
          color: WeldzColors.bg,
          border: Border(bottom: BorderSide(color: WeldzColors.border)),
        ),
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          children: [
            for (final t in ResultTab.values)
              _TabButton(tab: t, active: t == active, onTap: () => onSelect(t)),
          ],
        ),
      );
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.tab,
    required this.active,
    required this.onTap,
  });

  final ResultTab tab;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 3),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: active
                ? WeldzColors.blue.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
                color: active ? WeldzColors.blue : Colors.transparent),
          ),
          child: Row(
            children: [
              Icon(tab.icon,
                  size: 15,
                  color: active ? WeldzColors.blue : WeldzColors.textDim),
              const SizedBox(width: 6),
              Text(
                tab.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  color: active ? WeldzColors.blue : WeldzColors.textDim,
                ),
              ),
            ],
          ),
        ),
      );
}

/// One line saying what the pane above actually is. Cheap, and it stops the
/// clouds and the depth map being indistinguishable to anyone but their author.
class _Caption extends StatelessWidget {
  const _Caption({required this.tab, required this.report});

  final ResultTab tab;
  final Report report;

  String get _text => switch (tab) {
        ResultTab.rgb => 'The frame as shot, straight from ARKit',
        ResultTab.segments => 'Masks and boxes drawn on the server',
        ResultTab.depth => 'LiDAR depth, 256x192, ramped over this frame',
        ResultTab.cloud => 'Every depth sample, coloured from the photo',
        ResultTab.part => report.cropLabel == 'none'
            ? 'No workpiece mask — nothing to crop to'
            : 'Cropped to the ${report.cropLabel.replaceAll("_", " ")} mask',
      };

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        color: WeldzColors.bg,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Text(_text,
            style: const TextStyle(fontSize: 11, color: WeldzColors.textFaint)),
      );
}

class _Findings extends StatelessWidget {
  const _Findings({required this.report});

  final Report report;

  @override
  Widget build(BuildContext context) {
    // Two headed groups rather than one ordered list. Structure comes first
    // because it is the frame of reference -- if the workpiece or the seam is
    // missing, every defect line below is suspect and the reader should see
    // that before reading any size.
    final structural = report.detections
        .where((d) => WeldzColors.isStructural(d.label))
        .toList();
    final defects = report.detections
        .where((d) => !WeldzColors.isStructural(d.label))
        .toList();

    if (structural.isEmpty && defects.isEmpty) {
      return const Center(
        child: Text('nothing detected',
            style: TextStyle(color: WeldzColors.textFaint, fontSize: 13)),
      );
    }

    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: WeldzColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _GroupHead(
            label: 'Structure',
            count: structural.length,
            // Said plainly: no structure means nothing to measure against.
            empty: structural.isEmpty
                ? 'not found — sizes below rest on nothing'
                : null,
          ),
          for (var i = 0; i < structural.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            _Row(d: structural[i]),
          ],
          _GroupHead(
            label: 'Defects',
            count: defects.length,
            empty: defects.isEmpty ? 'none found' : null,
          ),
          for (var i = 0; i < defects.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            _Row(d: defects[i]),
          ],
        ],
      ),
    );
  }
}

class _GroupHead extends StatelessWidget {
  const _GroupHead({required this.label, required this.count, this.empty});

  final String label;
  final int count;

  /// Set when the group has no rows, and says why that matters rather than
  /// leaving a bare heading with nothing under it.
  final String? empty;

  @override
  Widget build(BuildContext context) => Container(
        color: WeldzColors.surface,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Row(
          children: [
            Text(label.toUpperCase(),
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                  color: WeldzColors.textDim,
                )),
            const SizedBox(width: 8),
            if (empty == null)
              Text('$count',
                  style: const TextStyle(
                      fontSize: 10.5, color: WeldzColors.textFaint))
            else
              Expanded(
                child: Text(empty!,
                    style: const TextStyle(
                        fontSize: 10.5, color: WeldzColors.textFaint)),
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
    final colour = WeldzColors.forClass(d.label);
    // A size resting on very few depth pixels is worth flagging rather than
    // presenting with the same authority as a well-covered one.
    final thin = d.hasSize && (d.depthFill ?? 0) < 0.25;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 32,
            decoration: BoxDecoration(
              color: colour,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(d.label.replaceAll('_', ' '),
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 1),
                Text(
                  d.distanceM == null
                      ? 'no depth under this mask'
                      : '${(d.distanceM! * 1000).round()} mm away · '
                          '${((d.depthFill ?? 0) * 100).round()}% depth cover'
                          '${d.areaMm2 != null ? " · ${d.areaMm2!.round()} mm²" : ""}',
                  style: TextStyle(
                    fontSize: 11,
                    color: thin ? WeldzColors.warn : WeldzColors.textDim,
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
                style: weldzMono(
                  size: 13,
                  color: d.hasSize ? WeldzColors.text : WeldzColors.textFaint,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                d.uncertaintyMm != null
                    ? '±${d.uncertaintyMm!.toStringAsFixed(2)} · '
                        '${(d.confidence * 100).round()}%'
                    : '${(d.confidence * 100).round()}%',
                style: weldzMono(
                    size: 10,
                    weight: FontWeight.w400,
                    color: WeldzColors.textFaint),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600, color: color)),
      );
}
