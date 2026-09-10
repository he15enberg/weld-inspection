// History — laid out, not wired.
//
// The rows below are fixtures. Nothing is persisted yet: the server writes each
// capture to disk, so the real version of this screen is a GET against it
// rather than local storage, and that endpoint does not exist.
//
// It is here now so the shape of the screen is settled and the nav bar has
// somewhere to go. The banner says so plainly rather than letting invented
// numbers pass for measurements.

import 'package:flutter/material.dart';

import 'theme.dart';

class _Fixture {
  const _Fixture(this.when, this.defects, this.worst, this.size, this.verdict);
  final String when;
  final int defects;
  final String worst;
  final String size;
  final String verdict;
}

const _fixtures = [
  _Fixture('Today 04:12', 3, 'porosity', '4.2 mm', 'review'),
  _Fixture('Today 03:58', 0, '—', '—', 'clean'),
  _Fixture('Yesterday 18:20', 1, 'undercut', '0.7 mm', 'review'),
  _Fixture('Yesterday 17:44', 5, 'porosity', '6.1 mm', 'review'),
  _Fixture('8 Sep 11:02', 0, '—', '—', 'clean'),
];

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const PageTitle(
              title: 'History',
              subtitle: 'Past inspections on this device',
            ),
            const _Notice(),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
                itemCount: _fixtures.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (_, i) => _Card(f: _fixtures[i]),
              ),
            ),
          ],
        ),
      );
}

class _Notice extends StatelessWidget {
  const _Notice();

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        decoration: BoxDecoration(
          color: WeldzColors.warn.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: WeldzColors.warn.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            const Icon(Icons.info_outline, size: 16, color: WeldzColors.warn),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Placeholder rows. Captures are stored on the server, so this '
                'list needs an endpoint that does not exist yet.',
                style: TextStyle(
                    fontSize: 11,
                    height: 1.35,
                    color: WeldzColors.warn.withValues(alpha: 0.95)),
              ),
            ),
          ],
        ),
      );
}

class _Card extends StatelessWidget {
  const _Card({required this.f});

  final _Fixture f;

  @override
  Widget build(BuildContext context) {
    final clean = f.verdict == 'clean';
    final colour = clean ? WeldzColors.good : WeldzColors.warn;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: WeldzColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: WeldzColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: colour.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(clean ? Icons.check_rounded : Icons.warning_amber_rounded,
                size: 21, color: colour),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  clean ? 'No defects' : '${f.defects} defects',
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  clean ? f.when : '${f.when} · worst ${f.worst} ${f.size}',
                  style: const TextStyle(
                      fontSize: 11, color: WeldzColors.textDim),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right,
              size: 20, color: WeldzColors.textFaint),
        ],
      ),
    );
  }
}
