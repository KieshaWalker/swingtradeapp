// =============================================================================
// features/greek_grid/screens/greek_grid_screen.dart
// =============================================================================
// Route: /ticker/:symbol/greek-grid
//
// Layout:
//   AppBar  — ticker name, purge button, menu
//   GreekSwitcherBar  — Δ Γ V Θ IV Va Ch Vo selector
//   DateScrubber      — slider over obs_dates, newest default
//   GreekGridHeatmap  — 5 × 5 colour grid; tap → detail sheet
//   Empty/loading states
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../../core/theme.dart';
import '../../../../core/widgets/app_menu_button.dart';
import '../models/greek_grid_models.dart';
import '../providers/greek_grid_providers.dart';
import '../services/greek_interpreter.dart';
import '../widgets/greek_grid_heatmap.dart';
import '../../../../services/python_api/python_api_client.dart';
import '../widgets/greek_cell_detail_sheet.dart';
import '../widgets/greek_interpretation_panel.dart';

class GreekGridScreen extends ConsumerStatefulWidget {
  final String symbol;
  const GreekGridScreen({super.key, required this.symbol});

  @override
  ConsumerState<GreekGridScreen> createState() => _GreekGridScreenState();
}

class _GreekGridScreenState extends ConsumerState<GreekGridScreen> {
  GreekSelector     _selected     = GreekSelector.delta;
  int               _dateIndex    = 0;
  bool              _indexInit    = false;
  InterpretationResult? _interpretation;
  String?           _lastInterpKey;

  @override
  Widget build(BuildContext context) {
    final obsDates = ref.watch(greekGridObsDatesProvider(widget.symbol));
    final gridAsync = ref.watch(greekGridProvider(widget.symbol));

    // Default to newest date on first load
    if (!_indexInit && obsDates.isNotEmpty) {
      _dateIndex = obsDates.length - 1;
      _indexInit = true;
    }

    final selectedDate = obsDates.isNotEmpty ? obsDates[_dateIndex] : null;
    final snapshot     = selectedDate != null
        ? ref.watch(greekGridSnapshotProvider((widget.symbol, selectedDate)))
        : null;

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.symbol} Greek Grid',
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.cleaning_services_rounded, size: 20),
            tooltip: 'Purge expired grid rows',
            onPressed: _purgeExpired,
          ),
          const AppMenuButton(),
        ],
      ),
      body: gridAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error:   (e, _) => Center(
          child: Text('Error: $e',
              style: const TextStyle(color: Colors.white54))),
        data: (_) {
          if (obsDates.isEmpty) {
            return _EmptyState(symbol: widget.symbol);
          }

          final allPoints = gridAsync.valueOrNull ?? [];
          final interpKey = '${widget.symbol}_${selectedDate}_${allPoints.length}';
          if (interpKey != _lastInterpKey) {
            _lastInterpKey = interpKey;
            _interpretation = null;
            WidgetsBinding.instance.addPostFrameCallback((_) => _fetchInterpretation(allPoints));
          }

          return Column(
            children: [
              const SizedBox(height: 8),
              _GreekSwitcherBar(
                selected:  _selected,
                onChanged: (g) => setState(() => _selected = g),
              ),
              const SizedBox(height: 4),
              Text(
                _selected.label,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: _interpretation != null
                    ? GreekInterpretationPanel(result: _interpretation!)
                    : const SizedBox(height: 48, child: Center(child: CircularProgressIndicator(strokeWidth: 1.5))),
              ),
              const SizedBox(height: 4),
              // ── Date scrubber ──────────────────────────────────────────────
              _DateScrubber(
                dates:     obsDates,
                index:     _dateIndex,
                onChanged: (i) => setState(() => _dateIndex = i),
              ),
              const SizedBox(height: 8),
              // ── Heatmap ────────────────────────────────────────────────────
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: GreekGridHeatmap(
                    snapshot: snapshot,
                    selected: _selected,
                    onCellTap: _showDetail,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _fetchInterpretation(List<dynamic> allPoints) async {
    try {
      final cells = allPoints
          .map((p) => (p as GreekGridPoint).toJson())
          .toList();
      final raw = await PythonApiClient.greekGridInterpretGrid(gridCells: cells);
      if (!mounted) return;
      setState(() => _interpretation = InterpretationResult.fromJson(raw));
    } catch (_) {
      // leave _interpretation null — panel stays hidden
    }
  }

  void _showDetail(StrikeBand band, ExpiryBucket bucket) {
    showModalBottomSheet(
      context:           context,
      isScrollControlled: true,
      backgroundColor:   Colors.transparent,
      builder: (_) => GreekCellDetailSheet(
        ticker: widget.symbol,
        band:   band,
        bucket: bucket,
      ),
    );
  }

  Future<void> _purgeExpired() async {
    final count = await ref
        .read(greekGridProvider(widget.symbol).notifier)
        .purgeExpired();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(count > 0
          ? 'Purged $count expired grid row${count == 1 ? '' : 's'}.'
          : 'No expired rows to purge.'),
      backgroundColor: AppTheme.cardColor,
    ));
  }
}

// ── Greek switcher bar ────────────────────────────────────────────────────────

class _GreekSwitcherBar extends StatelessWidget {
  final GreekSelector selected;
  final ValueChanged<GreekSelector> onChanged;
  const _GreekSwitcherBar({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: GreekSelector.values.map((g) {
          final active = g == selected;
          return GestureDetector(
            onTap: () => onChanged(g),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: active ? AppTheme.profitColor : AppTheme.cardColor,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                g.shortLabel,
                style: TextStyle(
                  color:      active ? Colors.black : Colors.white70,
                  fontSize:   13,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ── Date scrubber ─────────────────────────────────────────────────────────────

class _DateScrubber extends StatelessWidget {
  final List<DateTime> dates;
  final int            index;
  final ValueChanged<int> onChanged;
  const _DateScrubber(
      {required this.dates, required this.index, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('MMM d, y');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          Text(
            fmt.format(dates[index]),
            style: const TextStyle(
                color: Colors.white70, fontSize: 12,
                fontWeight: FontWeight.w600),
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor:   AppTheme.profitColor,
              inactiveTrackColor: AppTheme.cardColor,
              thumbColor:         AppTheme.profitColor,
              overlayColor:       AppTheme.profitColor.withValues(alpha: 0.15),
              trackHeight:        2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            ),
            child: Slider(
              min:       0,
              max:       (dates.length - 1).toDouble(),
              divisions: dates.length > 1 ? dates.length - 1 : 1,
              value:     index.toDouble(),
              onChanged: (v) => onChanged(v.round()),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(fmt.format(dates.first),
                  style: const TextStyle(color: Colors.white38, fontSize: 9)),
              Text(fmt.format(dates.last),
                  style: const TextStyle(color: Colors.white38, fontSize: 9)),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final String symbol;
  const _EmptyState({required this.symbol});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.grid_off_rounded,
                size: 48, color: Colors.white24),
            const SizedBox(height: 16),
            Text(
              'No Greek Grid data for $symbol yet.',
              style: const TextStyle(
                  color: Colors.white70, fontSize: 14,
                  fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Open the options chain screen for this ticker.\n'
              'Data will be collected automatically each time you load the chain.',
              style: TextStyle(color: Colors.white38, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
