// One stored capture, reopened.
//
// Reuses VerdictBanner / RuleList / UtilisationList / AssessmentCard rather
// than restating them, so a capture reads the same whether it is two seconds
// old or two weeks. A history screen that summarises differently from the
// result screen quietly becomes a second opinion.
//
// What it does NOT do is rebuild the point cloud. The stored depth map is the
// full frame as the phone sent it, while the masks in the record are in the
// analysed region's smaller grid; lining those up again means re-applying the
// crop from `geometry`, and a cloud that is subtly misaligned is worse than no
// cloud. The photograph, the overlay, the verdict and every measurement are
// all here -- which is what reviewing a decision actually needs.

import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'api.dart';
import 'settings.dart';
import 'theme.dart';
import 'verdict_card.dart';

class HistoryDetail extends StatefulWidget {
  const HistoryDetail({
    super.key,
    required this.summary,
    required this.settings,
  });

  final CaptureSummary summary;
  final Settings settings;

  @override
  State<HistoryDetail> createState() => _HistoryDetailState();
}

enum _Pane { overlay, photo }

class _HistoryDetailState extends State<HistoryDetail> {
  Report? _report;
  Uint8ListHolder? _photo;
  String? _error;
  bool _loading = true;
  _Pane _pane = _Pane.overlay;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final api = Api(widget.settings.url, token: widget.settings.token);
    try {
      final report = await api.capture(widget.summary.id);
      if (!mounted) return;
      setState(() {
        _report = report;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// Fetched only when the photo pane is opened. It is the largest file in the
  /// record and most visits never look at it.
  Future<void> _ensurePhoto() async {
    if (_photo != null) return;
    try {
      final bytes = await Api(widget.settings.url, token: widget.settings.token)
          .file(widget.summary.id, 'color.jpg');
      if (!mounted) return;
      setState(() => _photo = Uint8ListHolder(bytes));
    } catch (_) {
      if (!mounted) return;
      setState(() => _photo = Uint8ListHolder(null));
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _report;
    return Scaffold(
      backgroundColor: WeldzColors.bg,
      appBar: AppBar(
        backgroundColor: WeldzColors.bg,
        elevation: 0,
        title: Text(
          when(widget.summary.capturedAt),
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh, size: 19),
            tooltip: 'Reload',
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: _loading
            ? const Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: WeldzColors.blue),
                ),
              )
            : _error != null
                ? _Failed(message: _error!, onRetry: _load)
                : ListView(
                    padding: const EdgeInsets.only(bottom: 26),
                    children: [
                      _Viewer(
                        pane: _pane,
                        report: r!,
                        photo: _photo,
                        onSelect: (p) {
                          setState(() => _pane = p);
                          if (p == _Pane.photo) _ensurePhoto();
                        },
                      ),
                      if (r.assessment.blocks)
                        CaptureGate(assessment: r.assessment)
                      else ...[
                        VerdictBanner(judgement: r.judgement),
                        RuleList(judgement: r.judgement),
                        UtilisationList(judgement: r.judgement),
                      ],
                      AssessmentCard(assessment: r.assessment),
                      const SizedBox(height: 12),
                      _Detections(report: r),
                      _Provenance(
                          summary: widget.summary, judgement: r.judgement),
                    ],
                  ),
      ),
    );
  }
}

/// A tiny box so "not fetched yet" and "fetched and failed" are different
/// states. A bare nullable byte list cannot tell them apart, and the screen
/// would retry the download on every rebuild.
class Uint8ListHolder {
  const Uint8ListHolder(this.bytes);
  final Uint8List? bytes;
  bool get ok => bytes != null;
}

class _Viewer extends StatelessWidget {
  const _Viewer({
    required this.pane,
    required this.report,
    required this.photo,
    required this.onSelect,
  });

  final _Pane pane;
  final Report report;
  final Uint8ListHolder? photo;
  final ValueChanged<_Pane> onSelect;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Container(
            height: 300,
            color: Colors.black,
            width: double.infinity,
            child: _body(),
          ),
          Container(
            height: 42,
            decoration: const BoxDecoration(
              color: WeldzColors.bg,
              border:
                  Border(bottom: BorderSide(color: WeldzColors.border)),
            ),
            child: Row(
              children: [
                _Tab(
                  label: 'Result',
                  active: pane == _Pane.overlay,
                  onTap: () => onSelect(_Pane.overlay),
                ),
                _Tab(
                  label: 'Photo',
                  active: pane == _Pane.photo,
                  onTap: () => onSelect(_Pane.photo),
                ),
              ],
            ),
          ),
        ],
      );

  Widget _body() {
    if (pane == _Pane.overlay) {
      if (report.annotated.isEmpty) {
        return const _Missing(text: 'The overlay image is not on the server.');
      }
      return InteractiveViewer(
        maxScale: 6,
        child: Image.memory(report.annotated, fit: BoxFit.contain),
      );
    }
    final p = photo;
    if (p == null) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: WeldzColors.blue),
        ),
      );
    }
    if (!p.ok) {
      return const _Missing(text: 'The photograph is not on the server.');
    }
    return InteractiveViewer(
      maxScale: 6,
      child: Image.memory(p.bytes!, fit: BoxFit.contain),
    );
  }
}

class _Missing extends StatelessWidget {
  const _Missing({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 30),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: WeldzColors.textFaint),
          ),
        ),
      );
}

class _Tab extends StatelessWidget {
  const _Tab({required this.label, required this.active, required this.onTap});

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Expanded(
        child: InkWell(
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: active ? WeldzColors.blue : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                color: active ? WeldzColors.text : WeldzColors.textDim,
              ),
            ),
          ),
        ),
      );
}

/// Structural regions last: they are found on every frame and are not what
/// anyone opened the record to read.
class _Detections extends StatelessWidget {
  const _Detections({required this.report});

  final Report report;

  @override
  Widget build(BuildContext context) {
    final rows = [
      ...report.detections
          .where((d) => !WeldzColors.isStructural(d.label)),
      ...report.detections.where((d) => WeldzColors.isStructural(d.label)),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 0),
      decoration: BoxDecoration(
        color: WeldzColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: WeldzColors.border),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            child: Row(
              children: [
                const Text('DETECTIONS',
                    style: TextStyle(
                        fontSize: 10.5,
                        letterSpacing: 0.8,
                        fontWeight: FontWeight.w600,
                        color: WeldzColors.textDim)),
                const Spacer(),
                Text('${rows.length}',
                    style: const TextStyle(
                        fontSize: 10.5, color: WeldzColors.textFaint)),
              ],
            ),
          ),
          for (final d in rows) _DetectionRow(d: d),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

class _DetectionRow extends StatelessWidget {
  const _DetectionRow({required this.d});

  final Detection d;

  @override
  Widget build(BuildContext context) {
    final colour = WeldzColors.forClass(d.label);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      child: Row(
        children: [
          Container(width: 4, height: 26, color: colour),
          const SizedBox(width: 11),
          Expanded(
            child: Text(d.label.replaceAll('_', ' '),
                style: const TextStyle(fontSize: 12.5)),
          ),
          Text(
            d.hasSize
                ? '${d.widthMm!.toStringAsFixed(1)} x '
                    '${d.heightMm!.toStringAsFixed(1)} mm'
                : 'not sized',
            style: TextStyle(
              fontSize: 11,
              color: d.hasSize ? WeldzColors.textDim : WeldzColors.textFaint,
            ),
          ),
          const SizedBox(width: 10),
          Text('${(d.confidence * 100).round()}%',
              style: const TextStyle(
                  fontSize: 11, color: WeldzColors.textFaint)),
        ],
      ),
    );
  }
}

/// Which rule set judged this, and on what. A verdict without it cannot be
/// compared against one from a different week -- the limits may have moved.
class _Provenance extends StatelessWidget {
  const _Provenance({required this.summary, required this.judgement});

  final CaptureSummary summary;
  final Judgement judgement;

  @override
  Widget build(BuildContext context) {
    final bits = <String>[
      summary.id,
      if (summary.device != null) summary.device!,
      if (judgement.rulesetVersion != null)
        'rule set v${judgement.rulesetVersion}',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
      child: Text(
        bits.join('  ·  '),
        style: const TextStyle(
            fontSize: 10, height: 1.5, color: WeldzColors.textFaint),
      ),
    );
  }
}

class _Failed extends StatelessWidget {
  const _Failed({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 26, color: WeldzColors.textFaint),
              const SizedBox(height: 12),
              Text(message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 12, height: 1.4, color: WeldzColors.textDim)),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ),
        ),
      );
}

/// Shared by the list and the detail, so one capture is never dated two ways.
String when(DateTime? at) {
  if (at == null) return 'Unknown time';
  final local = at.toLocal();
  final now = DateTime.now();
  final sameDay = local.year == now.year &&
      local.month == now.month &&
      local.day == now.day;
  final yesterday = now.subtract(const Duration(days: 1));
  final wasYesterday = local.year == yesterday.year &&
      local.month == yesterday.month &&
      local.day == yesterday.day;

  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  if (sameDay) return 'Today $hh:$mm';
  if (wasYesterday) return 'Yesterday $hh:$mm';

  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  return '${local.day} ${months[local.month - 1]} $hh:$mm';
}
