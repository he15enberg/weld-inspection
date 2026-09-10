// History — the server's capture index, on the phone.
//
// The list comes from SQLite on the server, not from local storage: captures
// are written server-side, so this device's history and any other device's are
// the same list, and a reinstall does not lose it.
//
// Rows are summaries, not reports. The list endpoint answers from one query
// and never opens a stored record; the full record is fetched only when a row
// is tapped. That is the difference between a screen that opens instantly and
// one that reads a hundred JSON files first.

import 'package:flutter/material.dart';

import 'api.dart';
import 'history_detail.dart';
import 'settings.dart';
import 'theme.dart';
import 'verdict_card.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, this.refresh});

  /// Bumped by the shell when this tab is opened.
  ///
  /// IndexedStack keeps every page alive, so without a nudge this screen would
  /// never learn that the server address was changed on the Settings tab, and
  /// would keep failing against a host nobody is running any more.
  final ValueNotifier<int>? refresh;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  static const _pageSize = 30;

  final _scroll = ScrollController();

  Settings _settings = const Settings(url: '', token: '');
  final List<CaptureSummary> _rows = [];
  Verdict? _filter;
  int _total = 0;
  bool _loading = false;
  bool _more = true;
  String? _error;
  bool _loadedOnce = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    widget.refresh?.addListener(_onShown);
    _boot();
  }

  @override
  void dispose() {
    widget.refresh?.removeListener(_onShown);
    _scroll.dispose();
    super.dispose();
  }

  void _onShown() {
    // Ignore the nudge while a fetch is already in flight, so tapping the tab
    // twice does not start two.
    if (!_loading) reload();
  }

  Future<void> _boot() async {
    _settings = await Settings.load();
    if (!mounted) return;
    await _refresh();
  }

  /// Re-read settings on every visit: the server address can be changed on the
  /// settings tab while this screen sits alive inside the IndexedStack, and a
  /// list pointing at the old host would fail for no visible reason.
  Future<void> reload() async {
    _settings = await Settings.load();
    if (!mounted) return;
    await _refresh();
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loading || !_more) return;
    if (_scroll.position.pixels >
        _scroll.position.maxScrollExtent - 400) {
      _fetch();
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _rows.clear();
      _more = true;
      _error = null;
    });
    await _fetch();
  }

  Future<void> _fetch() async {
    if (_loading || !_more) return;
    setState(() => _loading = true);

    if (!_settings.isSet) {
      setState(() {
        _loading = false;
        _loadedOnce = true;
        _error = 'No server set. Add one on the Settings tab.';
      });
      return;
    }

    try {
      final page = await Api(_settings.url, token: _settings.token).captures(
        limit: _pageSize,
        offset: _rows.length,
        verdict: _filter,
      );
      if (!mounted) return;
      setState(() {
        _rows.addAll(page.captures);
        _total = page.total;
        // Stop on a short page as well as on the count: a capture recorded
        // while paging would otherwise shift the offset and repeat a row
        // forever.
        _more = page.captures.length == _pageSize && _rows.length < page.total;
        _loading = false;
        _loadedOnce = true;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadedOnce = true;
        _error = '$e';
      });
    }
  }

  void _setFilter(Verdict? v) {
    if (_filter == v) return;
    setState(() => _filter = v);
    _refresh();
  }

  Future<void> _open(CaptureSummary s) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HistoryDetail(summary: s, settings: _settings),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageTitle(
              title: 'History',
              subtitle: _total > 0
                  ? '$_total inspection${_total == 1 ? '' : 's'} on the server'
                  : 'Inspections recorded on the server',
            ),
            _Filters(active: _filter, onSelect: _setFilter),
            Expanded(child: _body()),
          ],
        ),
      );

  Widget _body() {
    if (!_loadedOnce && _loading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child:
              CircularProgressIndicator(strokeWidth: 2, color: WeldzColors.blue),
        ),
      );
    }
    if (_rows.isEmpty) {
      return RefreshIndicator(
        onRefresh: reload,
        color: WeldzColors.blue,
        backgroundColor: WeldzColors.surface,
        child: ListView(
          children: [
            SizedBox(height: MediaQuery.of(context).size.height * 0.22),
            _Empty(error: _error, filtered: _filter != null),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: reload,
      color: WeldzColors.blue,
      backgroundColor: WeldzColors.surface,
      child: ListView.separated(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        itemCount: _rows.length + ((_more || _error != null) ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (_, i) {
          if (i >= _rows.length) {
            // A paging failure lands here rather than wiping the rows already
            // on screen -- losing twenty good rows to one bad request would be
            // a poor trade.
            if (_error != null) {
              return _InlineError(message: _error!, onRetry: _fetch);
            }
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: WeldzColors.blue),
                ),
              ),
            );
          }
          final r = _rows[i];
          return _Row(summary: r, onTap: () => _open(r));
        },
      ),
    );
  }
}

class _Filters extends StatelessWidget {
  const _Filters({required this.active, required this.onSelect});

  final Verdict? active;
  final ValueChanged<Verdict?> onSelect;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 44,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            _Pill(
              label: 'All',
              active: active == null,
              onTap: () => onSelect(null),
            ),
            for (final v in Verdict.values)
              _Pill(
                label: v.label,
                colour: verdictColour(v),
                active: active == v,
                onTap: () => onSelect(v),
              ),
          ],
        ),
      );
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.active,
    required this.onTap,
    this.colour,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;
  final Color? colour;

  @override
  Widget build(BuildContext context) {
    final c = colour ?? WeldzColors.blue;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: active ? c.withValues(alpha: 0.16) : WeldzColors.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: active
                  ? c.withValues(alpha: 0.55)
                  : WeldzColors.border,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              color: active ? c : WeldzColors.textDim,
            ),
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.summary, required this.onTap});

  final CaptureSummary summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colour = verdictColour(summary.verdict);
    final worst = summary.worst;

    return GestureDetector(
      onTap: onTap,
      child: Container(
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
              child: Icon(verdictIcon(summary.verdict), size: 21, color: colour),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        summary.verdict.label.toUpperCase(),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: colour,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          when(summary.capturedAt),
                          style: const TextStyle(
                              fontSize: 11, color: WeldzColors.textFaint),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    summary.headline.isNotEmpty
                        ? summary.headline
                        : '${summary.defects} defect'
                            '${summary.defects == 1 ? '' : 's'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, height: 1.3),
                  ),
                  if (worst != null) ...[
                    const SizedBox(height: 3),
                    Text('worst $worst',
                        style: const TextStyle(
                            fontSize: 11, color: WeldzColors.textDim)),
                  ],
                ],
              ),
            ),
            const Icon(Icons.chevron_right,
                size: 20, color: WeldzColors.textFaint),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.error, required this.filtered});

  final String? error;
  final bool filtered;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 34),
        child: Column(
          children: [
            Icon(error != null ? Icons.cloud_off : Icons.inbox_outlined,
                size: 26, color: WeldzColors.textFaint),
            const SizedBox(height: 12),
            Text(
              error ??
                  (filtered
                      ? 'No captures with that verdict.'
                      : 'No captures yet. Take one on the Capture tab.'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 12, height: 1.45, color: WeldzColors.textDim),
            ),
            const SizedBox(height: 10),
            const Text(
              'Pull down to refresh.',
              style: TextStyle(fontSize: 11, color: WeldzColors.textFaint),
            ),
          ],
        ),
      );
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Column(
          children: [
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 11.5, color: WeldzColors.textDim)),
            const SizedBox(height: 10),
            OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      );
}
