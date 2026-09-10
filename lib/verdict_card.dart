// The verdict, the rules behind it, and the VLM's read of it.
//
// Two things are deliberately separated here, because conflating them is how an
// inspection app becomes untrustworthy:
//
//   The VERDICT comes from the server's rule table. It is deterministic, the
//   same for the same detections, and it is what a person acts on.
//
//   The ASSESSMENT is a vision model explaining that verdict in plain language.
//   It is labelled advisory and it cannot move the verdict.
//
// The one exception is the missed-rejectable warning: if the VLM says it can
// see a crack the detector did not, that is shown prominently — and still does
// not change the verdict. A person decides. Keeping the verdict reproducible
// matters more than catching every miss automatically.

import 'package:flutter/material.dart';

import 'api.dart';
import 'theme.dart';

Color verdictColour(Verdict v) => switch (v) {
      Verdict.approve => WeldzColors.good,
      Verdict.rework => WeldzColors.warn,
      Verdict.reject => WeldzColors.bad,
    };

IconData verdictIcon(Verdict v) => switch (v) {
      Verdict.approve => Icons.check_circle_rounded,
      Verdict.rework => Icons.build_circle_rounded,
      Verdict.reject => Icons.cancel_rounded,
    };

/// The headline answer, always present because the rules always produce one.
class VerdictBanner extends StatelessWidget {
  const VerdictBanner({super.key, required this.judgement});

  final Judgement judgement;

  @override
  Widget build(BuildContext context) {
    final colour = verdictColour(judgement.verdict);
    final fired =
        judgement.checks.where((c) => c.fired || c.unmeasured).toList();

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colour.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(verdictIcon(judgement.verdict), size: 22, color: colour),
              const SizedBox(width: 10),
              Text(
                judgement.verdict.label.toUpperCase(),
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: colour,
                ),
              ),
              const Spacer(),
              Text('${judgement.checks.length} rules',
                  style: const TextStyle(
                      fontSize: 10, color: WeldzColors.textFaint)),
            ],
          ),
          if (judgement.headline.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(judgement.headline,
                style: const TextStyle(fontSize: 12.5, height: 1.35)),
          ],
          // Only the rules that fired. The clear ones sit in the collapsed list
          // below so the banner stays a headline rather than a report.
          for (final c in fired) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c.id,
                    style: weldzMono(
                        size: 10,
                        weight: FontWeight.w600,
                        color: WeldzColors.textFaint)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    c.reason == null
                        ? '${c.title} - ${c.detail}'
                        : '${c.title} - ${c.detail}\n${c.reason}',
                    style: const TextStyle(
                        fontSize: 11, height: 1.35, color: WeldzColors.textDim),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// What was checked and cleared, collapsed.
///
/// An APPROVE showing nothing reads as "nobody looked"; three green rows on
/// every capture would bury the findings. Collapsed with a count is the
/// compromise.
class RuleList extends StatefulWidget {
  const RuleList({super.key, required this.judgement});

  final Judgement judgement;

  @override
  State<RuleList> createState() => _RuleListState();
}

class _RuleListState extends State<RuleList> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final clear = widget.judgement.checks
        .where((c) => !c.fired && !c.unmeasured)
        .toList();
    if (clear.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 9, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => setState(() => _open = !_open),
            child: Row(
              children: [
                Icon(_open ? Icons.expand_less : Icons.expand_more,
                    size: 16, color: WeldzColors.textDim),
                const SizedBox(width: 6),
                Text('${clear.length} rules clear',
                    style: const TextStyle(
                        fontSize: 11, color: WeldzColors.textDim)),
                if (widget.judgement.noted.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '· ${widget.judgement.noted.join(", ")} noted',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 10, color: WeldzColors.textFaint),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (_open)
            for (final c in clear)
              Padding(
                padding: const EdgeInsets.only(left: 22, top: 6),
                child: Row(
                  children: [
                    const Icon(Icons.check, size: 12, color: WeldzColors.good),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('${c.title} - ${c.detail}',
                          style: const TextStyle(
                              fontSize: 11, color: WeldzColors.textDim)),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

class AssessmentCard extends StatelessWidget {
  const AssessmentCard({super.key, required this.assessment});

  final Assessment assessment;

  @override
  Widget build(BuildContext context) {
    // Nothing to say and no reason to take up space.
    if (assessment.isDisabled) return const SizedBox.shrink();

    if (!assessment.isReady) {
      return _shell(
        child: Text(
          assessment.error ?? 'No assessment for this capture.',
          style: const TextStyle(fontSize: 11.5, color: WeldzColors.textFaint),
        ),
      );
    }

    return _shell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (assessment.missedRejectable.isNotEmpty) ...[
            _MissedWarning(labels: assessment.missedRejectable),
            const SizedBox(height: 11),
          ],
          Text(assessment.summary,
              style: const TextStyle(fontSize: 12.5, height: 1.45)),
          if (assessment.concerns.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final c in assessment.concerns) _Chip(text: c),
              ],
            ),
          ],
          // Framing is the biggest single lever on result quality, so a poor
          // image gets its own line rather than being one chip among several.
          if (assessment.poorImage) ...[
            const SizedBox(height: 10),
            const Row(
              children: [
                Icon(Icons.center_focus_weak, size: 14, color: WeldzColors.warn),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Image quality is poor. Try again closer, with the part '
                    'filling the frame.',
                    style: TextStyle(
                        fontSize: 11, height: 1.3, color: WeldzColors.warn),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _shell({required Widget child}) => Container(
        margin: const EdgeInsets.fromLTRB(14, 10, 14, 0),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: WeldzColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: WeldzColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.auto_awesome_outlined,
                    size: 14, color: WeldzColors.blue),
                const SizedBox(width: 8),
                const Text('ASSESSMENT',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.1,
                      color: WeldzColors.blue,
                    )),
                const Spacer(),
                // Says outright that this is not the verdict.
                const Text('advisory',
                    style: TextStyle(
                        fontSize: 9.5,
                        fontStyle: FontStyle.italic,
                        color: WeldzColors.textFaint)),
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      );
}

class _MissedWarning extends StatelessWidget {
  const _MissedWarning({required this.labels});

  final List<String> labels;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: WeldzColors.bad.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: WeldzColors.bad.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            const Icon(Icons.priority_high_rounded,
                size: 15, color: WeldzColors.bad),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                'Possible ${labels.join(", ")} the detector did not report. '
                'Check by eye — the verdict above does not include this.',
                style: const TextStyle(
                    fontSize: 11, height: 1.3, color: WeldzColors.bad),
              ),
            ),
          ],
        ),
      );
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: WeldzColors.surfaceHigh,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: WeldzColors.border),
        ),
        child: Text(text,
            style:
                const TextStyle(fontSize: 10.5, color: WeldzColors.textDim)),
      );
}
