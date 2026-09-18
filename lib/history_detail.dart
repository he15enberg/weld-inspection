// One stored capture, reopened.
//
// This screen is deliberately thin. It fetches the record and the three stored
// files, rebuilds the Capture the phone originally held, and hands both to
// ResultView -- the same widget the live path uses. So a record from last week
// has the same five tabs, the same verdict card and the same point clouds as a
// capture taken two seconds ago, because it IS the same code.
//
// The alternative was a second, smaller result screen. That drifts: the live
// view gains a field, the history view does not, and the two quietly start
// telling different stories about the same weld.
//
// The reduced view below is the fallback, not the design. It appears only when
// the pixels cannot be rebuilt -- a file missing from the archive, or a record
// written before the intrinsics were stored -- and it says which tabs are gone
// and why rather than silently showing fewer.

import 'package:flutter/material.dart';

import 'api.dart';
import 'capture.dart';
import 'result.dart';
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

class _HistoryDetailState extends State<HistoryDetail> {
  StoredCapture? _stored;
  String? _error;
  bool _loading = true;

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
    try {
      final stored = await Api(widget.settings.url, token: widget.settings.token)
          .capture(widget.summary.id);
      if (!mounted) return;
      setState(() {
        _stored = stored;
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

  void _close() => Navigator.of(context).maybePop();

  @override
  Widget build(BuildContext context) {
    final stored = _stored;
    final capture = stored?.capture;

    return Scaffold(
      backgroundColor: WeldzColors.bg,
      // ResultView brings its own header with a close control, so the app bar
      // only appears on the paths that do not have one.
      appBar: (stored != null && capture != null)
          ? null
          : AppBar(
              backgroundColor: WeldzColors.bg,
              elevation: 0,
              title: Text(
                when(widget.summary.capturedAt),
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
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
        top: capture == null,
        child: _body(stored, capture),
      ),
    );
  }

  Widget _body(StoredCapture? stored, Capture? capture) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child:
              CircularProgressIndicator(strokeWidth: 2, color: WeldzColors.blue),
        ),
      );
    }
    if (_error != null) {
      return _Failed(message: _error!, onRetry: _load);
    }
    if (stored == null) {
      return _Failed(message: 'Nothing came back.', onRetry: _load);
    }

    // The whole point: the live result screen, on a stored capture.
    if (capture != null) {
      return ResultView(
        capture: capture,
        report: stored.report,
        onClose: _close,
      );
    }
    return _Reduced(report: stored.report, summary: widget.summary);
  }
}

/// Shown when the pixels could not be rebuilt. Everything that does not need
/// depth is still here.
class _Reduced extends StatelessWidget {
  const _Reduced({required this.report, required this.summary});

  final Report report;
  final CaptureSummary summary;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.only(bottom: 26),
        children: [
          if (report.annotated.isNotEmpty)
            Container(
              height: 300,
              width: double.infinity,
              color: Colors.black,
              child: InteractiveViewer(
                maxScale: 6,
                child: Image.memory(report.annotated, fit: BoxFit.contain),
              ),
            ),
          Container(
            margin: const EdgeInsets.fromLTRB(14, 12, 14, 0),
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: WeldzColors.warn.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
              border:
                  Border.all(color: WeldzColors.warn.withValues(alpha: 0.35)),
            ),
            child: const Row(
              children: [
                Icon(Icons.layers_clear_outlined,
                    size: 16, color: WeldzColors.warn),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'The depth map for this capture is not on the server, so '
                    'the depth and point-cloud tabs are unavailable. The '
                    'verdict and every measurement are unaffected.',
                    style: TextStyle(
                        fontSize: 11, height: 1.35, color: WeldzColors.warn),
                  ),
                ),
              ],
            ),
          ),
          if (report.assessment.blocks)
            CaptureGate(assessment: report.assessment)
          else ...[
            VerdictBanner(judgement: report.judgement),
            RuleList(judgement: report.judgement),
            UtilisationList(judgement: report.judgement),
          ],
          AssessmentCard(assessment: report.assessment),
          _Provenance(summary: summary, judgement: report.judgement),
        ],
      );
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
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
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
