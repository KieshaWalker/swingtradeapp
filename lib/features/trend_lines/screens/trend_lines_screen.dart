// =============================================================================
// features/trend_lines/screens/trend_lines_screen.dart
// =============================================================================
// Named, persisted trend lines for one ticker. No chart yet — this is the
// list-management layer (add / rename / delete / view accuracy); rendering
// saved lines on a candlestick chart is a deliberately separate, later step.
//
// A line can be added two ways, both writing the identical trend_lines row:
//   Fit      slide the fit's own tolerance knobs, see candidate support and
//            resistance lines from services/channel_fit.suggest_trendlines,
//            save any of them under a name.
//   Manual   type two (date, price) anchors directly. No chart-tap yet either
//            — that also waits for the chart.
//
// ACCURACY IS FETCHED, NEVER STORED. Each row's holding/broken status comes
// from POST /trend-lines/accuracy, recomputed against whatever equity_bars
// exist right now. A manual line's status is always null — it carries no
// assumed side, so no verdict is fabricated for it.
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme.dart';
import '../../../core/widgets/app_menu_button.dart';
import '../../../services/python_api/python_api_client.dart';
import '../../ticker_profile/providers/ticker_profile_providers.dart';
import '../models/trend_line.dart';
import '../providers/equity_bars_provider.dart';
import '../providers/trend_lines_provider.dart';
import '../widgets/candlestick_chart.dart';

class TrendLinesScreen extends ConsumerStatefulWidget {
  const TrendLinesScreen({super.key});

  @override
  ConsumerState<TrendLinesScreen> createState() => _TrendLinesScreenState();
}

class _TrendLinesScreenState extends ConsumerState<TrendLinesScreen> {
  String? _ticker;

  @override
  Widget build(BuildContext context) {
    final watchedAsync = ref.watch(watchedTickersProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Trend Lines'),
        actions: const [AppMenuButton()],
      ),
      body: watchedAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Text('$e', style: const TextStyle(color: AppTheme.neutralColor)),
        ),
        data: (tickers) {
          if (tickers.isEmpty) {
            return const _Message(
              icon: Icons.visibility_off_rounded,
              title: 'No watched tickers',
              detail: 'Add a ticker to your watchlist first.',
            );
          }
          _ticker ??= tickers.first;
          return Column(
            children: [
              _TickerPicker(
                tickers: tickers,
                selected: _ticker!,
                onChanged: (t) => setState(() => _ticker = t),
              ),
              _ChartSection(ticker: _ticker!),
              const Divider(height: 1, color: AppTheme.borderColor),
              Expanded(child: _LinesList(ticker: _ticker!)),
            ],
          );
        },
      ),
      floatingActionButton: _ticker == null
          ? null
          : FloatingActionButton.extended(
              backgroundColor: AppTheme.profitColor,
              foregroundColor: Colors.black,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add line'),
              onPressed: () => showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                backgroundColor: AppTheme.elevatedColor,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                ),
                builder: (_) => _AddLineSheet(ticker: _ticker!),
              ),
            ),
    );
  }
}

class _TickerPicker extends StatelessWidget {
  final List<String> tickers;
  final String selected;
  final ValueChanged<String> onChanged;
  const _TickerPicker({
    required this.tickers,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: DropdownButtonFormField<String>(
          initialValue: selected,
          dropdownColor: AppTheme.elevatedColor,
          decoration: const InputDecoration(labelText: 'Ticker'),
          items: [
            for (final t in tickers) DropdownMenuItem(value: t, child: Text(t)),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      );
}

class _ChartSection extends ConsumerWidget {
  final String ticker;
  const _ChartSection({required this.ticker});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final barsAsync = ref.watch(equityBarsProvider(ticker));
    final linesAsync = ref.watch(trendLinesProvider(ticker));

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: barsAsync.when(
        loading: () => const SizedBox(
          height: 320,
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (e, _) => SizedBox(
          height: 80,
          child: Center(
            child: Text('$e',
                style: const TextStyle(color: AppTheme.neutralColor)),
          ),
        ),
        // Lines are allowed to still be loading/erroring independently — the
        // chart renders candles-only rather than waiting on both providers,
        // since price history is available immediately and lines are not the
        // reason someone opened this screen for the first time.
        data: (bars) {
          final lines = linesAsync.valueOrNull ?? const <TrendLineRecord>[];
          // Watching trendLineAccuracyProvider(l) here for the SAME
          // TrendLineRecord instances _LinesList watches below shares one
          // cache entry per line (Riverpod's family key is the object itself,
          // and both widgets read it from the same trendLinesProvider result)
          // — this does not double the number of /trend-lines/accuracy calls.
          final accuracyByLineId = <String, TrendLineAccuracy>{};
          for (final line in lines) {
            final acc = ref.watch(trendLineAccuracyProvider(line)).valueOrNull;
            if (acc != null) accuracyByLineId[line.id] = acc;
          }
          return CandlestickChart(
            bars: bars,
            lines: lines,
            accuracyByLineId: accuracyByLineId,
          );
        },
      ),
    );
  }
}

class _LinesList extends ConsumerWidget {
  final String ticker;
  const _LinesList({required this.ticker});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final linesAsync = ref.watch(trendLinesProvider(ticker));
    return linesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Text('$e', style: const TextStyle(color: AppTheme.neutralColor)),
      ),
      data: (lines) {
        if (lines.isEmpty) {
          return const _Message(
            icon: Icons.timeline_rounded,
            title: 'No trend lines yet',
            detail: 'Fit one from recent price action or add your own two points.',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: lines.length,
          separatorBuilder: (_, _) =>
              const Divider(height: 1, color: Color(0x22FFFFFF)),
          itemBuilder: (_, i) => _LineTile(line: lines[i]),
        );
      },
    );
  }
}

class _LineTile extends ConsumerWidget {
  final TrendLineRecord line;
  const _LineTile({required this.line});

  static String _fmtDate(DateTime d) =>
      '${d.month}/${d.day}/${d.year.toString().substring(2)}';

  Color _kindColor() => switch (line.kind) {
        TrendLineKind.resistance => AppTheme.lossColor,
        TrendLineKind.support => AppTheme.profitColor,
        TrendLineKind.manual => AppTheme.neutralColor,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accAsync = ref.watch(trendLineAccuracyProvider(line));

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 4,
            height: 40,
            margin: const EdgeInsets.only(top: 2, right: 12),
            decoration: BoxDecoration(
              color: _kindColor(),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(line.name,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 14)),
                    ),
                    Text(line.kind.label,
                        style: TextStyle(
                            color: _kindColor(),
                            fontSize: 11,
                            fontWeight: FontWeight.w700)),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '${_fmtDate(line.anchor1Date)} @ ${line.anchor1Price.toStringAsFixed(2)}'
                  '  →  ${_fmtDate(line.anchor2Date)} @ ${line.anchor2Price.toStringAsFixed(2)}'
                  '  ·  ${line.source == TrendLineSource.fitted ? "fitted" : "manual"}',
                  style: const TextStyle(
                      color: AppTheme.neutralColor, fontSize: 11),
                ),
                const SizedBox(height: 4),
                accAsync.when(
                  loading: () => const Text('checking…',
                      style: TextStyle(
                          color: AppTheme.neutralColor, fontSize: 11)),
                  error: (_, _) => const Text('accuracy unavailable',
                      style: TextStyle(
                          color: AppTheme.neutralColor, fontSize: 11)),
                  data: (acc) => _AccuracyBadge(acc: acc),
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded,
                size: 18, color: AppTheme.neutralColor),
            color: AppTheme.elevatedColor,
            onSelected: (v) async {
              if (v == 'rename') {
                await _showRenameDialog(context, ref);
              } else if (v == 'delete') {
                await ref
                    .read(trendLinesNotifierProvider.notifier)
                    .delete(line.id, line.ticker);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('Rename')),
              PopupMenuItem(
                value: 'delete',
                child: Text('Delete', style: TextStyle(color: AppTheme.lossColor)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _showRenameDialog(BuildContext context, WidgetRef ref) async {
    final ctrl = TextEditingController(text: line.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.elevatedColor,
        title: const Text('Rename line'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty && newName != line.name) {
      await ref
          .read(trendLinesNotifierProvider.notifier)
          .rename(line.id, line.ticker, newName);
    }
  }
}

class _AccuracyBadge extends StatelessWidget {
  final TrendLineAccuracy acc;
  const _AccuracyBadge({required this.acc});

  @override
  Widget build(BuildContext context) {
    if (acc.status == null) {
      return Text(
        '${acc.touches} touches over ${acc.barsChecked} bars — no verdict (manual line)',
        style: const TextStyle(color: AppTheme.neutralColor, fontSize: 11),
      );
    }
    final holding = acc.status == 'holding';
    final color = holding ? AppTheme.profitColor : AppTheme.lossColor;
    final label = holding
        ? 'Holding — ${acc.touches} touches, ${acc.barsChecked} bars'
        : 'Broken'
            '${acc.firstViolationDate != null ? " on ${_LineTile._fmtDate(acc.firstViolationDate!)}" : ""}';
    return Row(
      children: [
        Icon(holding ? Icons.check_circle_rounded : Icons.cancel_rounded,
            size: 13, color: color),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(
                color: color, fontSize: 11, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

// ── Add sheet ────────────────────────────────────────────────────────────────

class _AddLineSheet extends StatefulWidget {
  final String ticker;
  const _AddLineSheet({required this.ticker});

  @override
  State<_AddLineSheet> createState() => _AddLineSheetState();
}

class _AddLineSheetState extends State<_AddLineSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      expand: false,
      builder: (_, scroll) => Column(
        children: [
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: AppTheme.borderColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          TabBar(
            controller: _tab,
            labelColor: AppTheme.profitColor,
            unselectedLabelColor: AppTheme.neutralColor,
            indicatorColor: AppTheme.profitColor,
            tabs: const [Tab(text: 'FIT'), Tab(text: 'MANUAL')],
          ),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [
                _FitTab(ticker: widget.ticker, scroll: scroll),
                _ManualTab(ticker: widget.ticker, scroll: scroll),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FitTab extends ConsumerStatefulWidget {
  final String ticker;
  final ScrollController scroll;
  const _FitTab({required this.ticker, required this.scroll});

  @override
  ConsumerState<_FitTab> createState() => _FitTabState();
}

class _FitTabState extends ConsumerState<_FitTab> {
  double _touchAtr = 0.55;
  double _breakAtr = 1.10;
  int _minTouches = 3;
  double _minSpanFrac = 0.35;

  bool _loading = false;
  String? _error;
  List<TrendLineCandidate> _resistance = [];
  List<TrendLineCandidate> _support = [];

  Future<void> _runFit() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final json = await PythonApiClient.trendLineSuggest(
        ticker: widget.ticker,
        touchAtr: _touchAtr,
        breakAtr: _breakAtr,
        minTouches: _minTouches,
        minSpanFrac: _minSpanFrac,
      );
      setState(() {
        _resistance = (json['resistance'] as List)
            .map((c) => TrendLineCandidate.fromJson(c as Map<String, dynamic>))
            .toList();
        _support = (json['support'] as List)
            .map((c) => TrendLineCandidate.fromJson(c as Map<String, dynamic>))
            .toList();
      });
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: widget.scroll,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      children: [
        const Text(
          'Adjust tolerance, then fit. Nothing is saved until you pick a '
          'candidate below and name it.',
          style: TextStyle(color: AppTheme.neutralColor, fontSize: 11),
        ),
        const SizedBox(height: 12),
        // Each hint is framed as "lower does X, higher does Y" so you can
        // tune toward whatever you're actually after — more candidates to
        // choose from, or fewer but more rigorously confirmed ones — without
        // needing to know what ATR or "span" mean under the hood.
        _slider('Touch tolerance (× ATR)', _touchAtr, 0.1, 2.0,
            (v) => setState(() => _touchAtr = v),
            hint: 'How close price must come to the line to count as '
                "confirming it. Lower → stricter, cleaner-looking lines. "
                'Higher → more forgiving, so more candidates pass.'),
        _slider('Break tolerance (× ATR)', _breakAtr, 0.2, 3.0,
            (v) => setState(() => _breakAtr = v),
            hint: 'How far price must pierce the line before it counts as '
                'broken. Lower → a single wick kills the line. Higher → '
                'lets a brief poke-through slide without rejecting it.'),
        _slider('Min span (% of window)', _minSpanFrac, 0.1, 0.9,
            (v) => setState(() => _minSpanFrac = v), isPct: true,
            hint: 'How much of the chart the line must stretch across. '
                'Higher → only long-running, well-established lines. '
                'Lower → also surfaces short-lived, recent ones.'),
        Row(
          children: [
            const Text('Min touches',
                style: TextStyle(color: AppTheme.neutralColor, fontSize: 12)),
            Expanded(
              child: Slider(
                value: _minTouches.toDouble(),
                min: 2,
                max: 10,
                divisions: 8,
                activeColor: AppTheme.profitColor,
                label: '$_minTouches',
                onChanged: (v) => setState(() => _minTouches = v.round()),
              ),
            ),
            SizedBox(
                width: 24,
                child: Text('$_minTouches',
                    style: const TextStyle(color: Colors.white, fontSize: 12))),
          ],
        ),
        const Padding(
          padding: EdgeInsets.only(bottom: 4),
          child: Text(
            'Minimum number of times price must have bounced off the line '
            'to trust it. Higher → fewer, better-evidenced lines. Lower → '
            'more candidates, some barely tested.',
            style: TextStyle(
                color: AppTheme.neutralColor,
                fontSize: 10,
                fontStyle: FontStyle.italic),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _loading ? null : _runFit,
          child: _loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Fit'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: const TextStyle(color: AppTheme.lossColor, fontSize: 12)),
        ],
        if (_resistance.isNotEmpty) ...[
          const SizedBox(height: 16),
          _CandidateSection(
            title: 'RESISTANCE',
            color: AppTheme.lossColor,
            candidates: _resistance,
            ticker: widget.ticker,
            kind: TrendLineKind.resistance,
          ),
        ],
        if (_support.isNotEmpty) ...[
          const SizedBox(height: 16),
          _CandidateSection(
            title: 'SUPPORT',
            color: AppTheme.profitColor,
            candidates: _support,
            ticker: widget.ticker,
            kind: TrendLineKind.support,
          ),
        ],
        if (!_loading && _error == null && _resistance.isEmpty &&
            _support.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text(
              'Press Fit to search. No line is a valid, common outcome — '
              'not every chart has one at these settings.',
              style: TextStyle(color: AppTheme.neutralColor, fontSize: 11),
            ),
          ),
      ],
    );
  }

  Widget _slider(String label, double value, double min, double max,
      ValueChanged<double> onChanged, {bool isPct = false, String? hint}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sliderRow(label, value, min, max, onChanged, isPct: isPct),
          if (hint != null)
            // Full width, not indented under the slider track — on a narrow
            // sheet, matching the track's left inset (150dp for the label)
            // would leave too little room and force the hint into 3-4 wrapped
            // lines. Vertical order already reads as "this hint belongs to
            // the slider above it" without needing the indent to match too.
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                hint,
                style: const TextStyle(
                    color: AppTheme.neutralColor,
                    fontSize: 10,
                    fontStyle: FontStyle.italic),
              ),
            ),
        ],
      ),
    );
  }

  Widget _sliderRow(String label, double value, double min, double max,
      ValueChanged<double> onChanged, {bool isPct = false}) {
    return Row(
      children: [
        SizedBox(
          width: 150,
          child: Text(label,
              style: const TextStyle(color: AppTheme.neutralColor, fontSize: 12)),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            activeColor: AppTheme.profitColor,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            isPct ? '${(value * 100).round()}%' : value.toStringAsFixed(2),
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

class _CandidateSection extends ConsumerWidget {
  final String title;
  final Color color;
  final List<TrendLineCandidate> candidates;
  final String ticker;
  final TrendLineKind kind;
  const _CandidateSection({
    required this.title,
    required this.color,
    required this.candidates,
    required this.ticker,
    required this.kind,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.0)),
        const SizedBox(height: 6),
        for (final c in candidates)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.cardColor,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${c.anchor1Price.toStringAsFixed(2)} → ${c.anchor2Price.toStringAsFixed(2)}'
                      '  ·  ${c.touches} touches, ${c.spanBars}d span',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _save(context, ref, c),
                    child: const Text('Save'),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _save(
      BuildContext context, WidgetRef ref, TrendLineCandidate c) async {
    final name = await _promptName(context, '$title line');
    if (name == null || name.isEmpty) return;
    await ref.read(trendLinesNotifierProvider.notifier).add(
          ticker: ticker,
          name: name,
          kind: kind,
          source: TrendLineSource.fitted,
          anchor1Date: c.anchor1Date,
          anchor1Price: c.anchor1Price,
          anchor2Date: c.anchor2Date,
          anchor2Price: c.anchor2Price,
        );
    if (context.mounted) Navigator.pop(context);
  }
}

Future<String?> _promptName(BuildContext context, String suggested) {
  final ctrl = TextEditingController(text: suggested);
  return showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: AppTheme.elevatedColor,
      title: const Text('Name this line'),
      content: TextField(controller: ctrl, autofocus: true),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        TextButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: const Text('Save')),
      ],
    ),
  );
}

class _ManualTab extends ConsumerStatefulWidget {
  final String ticker;
  final ScrollController scroll;
  const _ManualTab({required this.ticker, required this.scroll});

  @override
  ConsumerState<_ManualTab> createState() => _ManualTabState();
}

class _ManualTabState extends ConsumerState<_ManualTab> {
  final _nameCtrl = TextEditingController();
  final _p1Ctrl = TextEditingController();
  final _p2Ctrl = TextEditingController();
  DateTime? _d1;
  DateTime? _d2;
  TrendLineKind _kind = TrendLineKind.manual;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _p1Ctrl.dispose();
    _p2Ctrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate(bool first) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: (first ? _d1 : _d2) ?? now,
      firstDate: DateTime(now.year - 3),
      lastDate: now,
    );
    if (picked != null) {
      setState(() => first ? _d1 = picked : _d2 = picked);
    }
  }

  Future<void> _save() async {
    setState(() => _error = null);
    final name = _nameCtrl.text.trim();
    final p1 = double.tryParse(_p1Ctrl.text);
    final p2 = double.tryParse(_p2Ctrl.text);
    if (name.isEmpty || _d1 == null || _d2 == null || p1 == null || p2 == null) {
      setState(() => _error = 'Fill in a name, both dates and both prices.');
      return;
    }
    if (!_d2!.isAfter(_d1!)) {
      setState(() => _error = 'Second date must be after the first.');
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(trendLinesNotifierProvider.notifier).add(
            ticker: widget.ticker,
            name: name,
            kind: _kind,
            source: TrendLineSource.manual,
            anchor1Date: _d1!,
            anchor1Price: p1,
            anchor2Date: _d2!,
            anchor2Price: p2,
          );
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: widget.scroll,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      children: [
        TextField(
          controller: _nameCtrl,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<TrendLineKind>(
          initialValue: _kind,
          dropdownColor: AppTheme.elevatedColor,
          decoration: const InputDecoration(labelText: 'Kind'),
          items: TrendLineKind.values
              .map((k) => DropdownMenuItem(value: k, child: Text(k.label)))
              .toList(),
          onChanged: (v) => setState(() => _kind = v ?? _kind),
        ),
        const SizedBox(height: 16),
        _anchorRow('Anchor 1', _d1, _p1Ctrl, () => _pickDate(true)),
        const SizedBox(height: 12),
        _anchorRow('Anchor 2', _d2, _p2Ctrl, () => _pickDate(false)),
        const SizedBox(height: 20),
        if (_error != null) ...[
          Text(_error!, style: const TextStyle(color: AppTheme.lossColor, fontSize: 12)),
          const SizedBox(height: 8),
        ],
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }

  Widget _anchorRow(String label, DateTime? date, TextEditingController priceCtrl,
      VoidCallback onPickDate) {
    return Row(
      children: [
        SizedBox(
          width: 70,
          child: Text(label,
              style: const TextStyle(color: AppTheme.neutralColor, fontSize: 12)),
        ),
        Expanded(
          child: OutlinedButton(
            onPressed: onPickDate,
            child: Text(date == null
                ? 'Pick date'
                : '${date.year}-${date.month.toString().padLeft(2, '0')}-'
                    '${date.day.toString().padLeft(2, '0')}'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: priceCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Price'),
          ),
        ),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;
  const _Message({required this.icon, required this.title, required this.detail});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 40, color: AppTheme.neutralColor),
              const SizedBox(height: 12),
              Text(title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 15)),
              const SizedBox(height: 6),
              Text(detail,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: AppTheme.neutralColor, fontSize: 12)),
            ],
          ),
        ),
      );
}
