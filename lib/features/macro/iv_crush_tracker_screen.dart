// =============================================================================
// features/macro/iv_crush_tracker_screen.dart
// =============================================================================
// IV Crush Tracker — shows historical IV drop (entry → exit) for all closed
// trades that have both impliedVolEntry and impliedVolExit recorded.
//
// Displays:
//   • Summary stats: avg IV crush, % of trades with crush, best crush
//   • Sorted list of trades by IV drop (largest first)
//   • Bar chart of IV entry vs exit per trade
// =============================================================================
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../core/theme.dart';
import '../../features/trades/models/trade.dart';
import '../../features/trades/providers/trades_provider.dart';

// ─── Model ────────────────────────────────────────────────────────────────────

class _IvCrushEntry {
  final Trade trade;
  final double ivEntry;
  final double ivExit;
  double get crush => ivEntry - ivExit; // positive = IV crushed (good for sellers)
  bool get wasCrush => crush > 0;

  _IvCrushEntry({required this.trade, required this.ivEntry, required this.ivExit});
}

// ─── Screen ───────────────────────────────────────────────────────────────────

class IvCrushTrackerScreen extends ConsumerWidget {
  const IvCrushTrackerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncTrades = ref.watch(tradesProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        title: const Text('IV Crush Tracker'),
      ),
      body: asyncTrades.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Text('Error: $e',
              style: const TextStyle(color: AppTheme.neutralColor)),
        ),
        data: (trades) {
          final entries = trades
              .where((t) =>
                  t.status == TradeStatus.closed &&
                  t.impliedVolEntry != null &&
                  t.impliedVolExit != null)
              .map((t) => _IvCrushEntry(
                    trade: t,
                    ivEntry: t.impliedVolEntry!,
                    ivExit: t.impliedVolExit!,
                  ))
              .toList()
            ..sort((a, b) => b.crush.compareTo(a.crush));

          if (entries.isEmpty) {
            return const _EmptyState();
          }
          return _IvCrushBody(entries: entries);
        },
      ),
    );
  }
}

// ─── Empty state ──────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.compress_outlined,
                size: 56, color: AppTheme.neutralColor.withValues(alpha: 0.4)),
            const SizedBox(height: 16),
            const Text(
              'No IV data yet',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              'Close trades with both "IV at Entry" and "IV at Exit" filled in to track implied volatility crush.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.neutralColor, fontSize: 13, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Body ─────────────────────────────────────────────────────────────────────

class _IvCrushBody extends StatelessWidget {
  final List<_IvCrushEntry> entries;
  const _IvCrushBody({required this.entries});

  @override
  Widget build(BuildContext context) {
    final crushes = entries.where((e) => e.wasCrush).toList();
    final avgCrush = entries.isEmpty
        ? 0.0
        : entries.fold<double>(0, (s, e) => s + e.crush) / entries.length;
    final bestCrush =
        entries.isNotEmpty ? entries.first.crush : 0.0; // sorted desc
    final crushPct =
        entries.isEmpty ? 0.0 : crushes.length / entries.length * 100;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
      children: [
        // Summary stats
        _SummaryRow(
          avgCrush: avgCrush,
          bestCrush: bestCrush,
          crushPct: crushPct,
          count: entries.length,
        ),
        const SizedBox(height: 20),

        // Bar chart (up to 20 most recent)
        if (entries.length >= 2) ...[
          const Text(
            'IV Entry vs Exit',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          _IvBarChart(entries: entries.take(20).toList()),
          const SizedBox(height: 24),
        ],

        // Trade list
        const Text(
          'Trade Detail',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        ...entries.map((e) => _IvTradeRow(entry: e)),
      ],
    );
  }
}

// ─── Summary row ──────────────────────────────────────────────────────────────

class _SummaryRow extends StatelessWidget {
  final double avgCrush;
  final double bestCrush;
  final double crushPct;
  final int count;
  const _SummaryRow(
      {required this.avgCrush,
      required this.bestCrush,
      required this.crushPct,
      required this.count});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
            child: _StatTile(
                label: 'Avg IV Crush',
                value: '${avgCrush.toStringAsFixed(1)}%',
                color: avgCrush > 0 ? AppTheme.profitColor : AppTheme.lossColor)),
        const SizedBox(width: 10),
        Expanded(
            child: _StatTile(
                label: 'Crush Rate',
                value: '${crushPct.toStringAsFixed(0)}%',
                color: crushPct >= 50
                    ? AppTheme.profitColor
                    : AppTheme.lossColor)),
        const SizedBox(width: 10),
        Expanded(
            child: _StatTile(
                label: 'Best Crush',
                value: '${bestCrush.toStringAsFixed(1)}%',
                color: AppTheme.profitColor)),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _StatTile(
      {required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1C2128),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
              style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w800, color: color)),
          const SizedBox(height: 4),
          Text(label,
              style: const TextStyle(
                  color: AppTheme.neutralColor, fontSize: 11)),
        ],
      ),
    );
  }
}

// ─── Bar chart ────────────────────────────────────────────────────────────────

class _IvBarChart extends StatelessWidget {
  final List<_IvCrushEntry> entries;
  const _IvBarChart({required this.entries});

  @override
  Widget build(BuildContext context) {
    final groups = entries.asMap().entries.map((kv) {
      final i = kv.key;
      final e = kv.value;
      return BarChartGroupData(
        x: i,
        barRods: [
          BarChartRodData(
            toY: e.ivEntry,
            color: AppTheme.neutralColor.withValues(alpha: 0.5),
            width: 6,
            borderRadius: BorderRadius.circular(2),
          ),
          BarChartRodData(
            toY: e.ivExit,
            color: e.wasCrush ? AppTheme.profitColor : AppTheme.lossColor,
            width: 6,
            borderRadius: BorderRadius.circular(2),
          ),
        ],
        barsSpace: 2,
      );
    }).toList();

    return Container(
      height: 180,
      padding: const EdgeInsets.fromLTRB(8, 12, 12, 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1C2128),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _Legend(color: AppTheme.neutralColor.withValues(alpha: 0.5), label: 'Entry IV'),
              const SizedBox(width: 14),
              _Legend(color: AppTheme.profitColor, label: 'Exit IV (crush)'),
              const SizedBox(width: 14),
              _Legend(color: AppTheme.lossColor, label: 'Exit IV (expansion)'),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: BarChart(
              BarChartData(
                barGroups: groups,
                borderData: FlBorderData(show: false),
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (_) => FlLine(
                    color: Colors.white.withValues(alpha: 0.05),
                    strokeWidth: 1,
                  ),
                ),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 22,
                      getTitlesWidget: (v, _) {
                        final idx = v.round();
                        if (idx < 0 || idx >= entries.length) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            entries[idx].trade.ticker,
                            style: const TextStyle(
                                color: AppTheme.neutralColor, fontSize: 8),
                          ),
                        );
                      },
                    ),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 32,
                      getTitlesWidget: (v, meta) {
                        if (v != meta.min && v != meta.max) {
                          return const SizedBox.shrink();
                        }
                        return Text(
                          '${v.toStringAsFixed(0)}%',
                          style: const TextStyle(
                              color: AppTheme.neutralColor, fontSize: 9),
                        );
                      },
                    ),
                  ),
                ),
                barTouchData: BarTouchData(
                  touchTooltipData: BarTouchTooltipData(
                    getTooltipColor: (_) => const Color(0xFF30363D),
                    getTooltipItem: (group, _, rod, rodIndex) {
                      final e = entries[group.x];
                      final label =
                          rodIndex == 0 ? 'Entry IV' : 'Exit IV';
                      return BarTooltipItem(
                        '${e.trade.ticker}\n$label: ${rod.toY.toStringAsFixed(1)}%',
                        const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w600),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  final Color color;
  final String label;
  const _Legend({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 4),
        Text(label,
            style:
                const TextStyle(color: AppTheme.neutralColor, fontSize: 9)),
      ],
    );
  }
}

// ─── Trade row ────────────────────────────────────────────────────────────────

class _IvTradeRow extends StatelessWidget {
  final _IvCrushEntry entry;
  const _IvTradeRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final t = entry.trade;
    final crush = entry.crush;
    final crushColor =
        entry.wasCrush ? AppTheme.profitColor : AppTheme.lossColor;
    final closedStr = t.closedAt != null
        ? DateFormat('MMM d, yy').format(t.closedAt!)
        : '—';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1C2128),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Row(
        children: [
          // Ticker + strategy
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${t.ticker}  ·  ${t.strategy.label}',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(
                  'Closed $closedStr',
                  style: const TextStyle(
                      color: AppTheme.neutralColor, fontSize: 11),
                ),
              ],
            ),
          ),

          // IV entry → exit
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${entry.ivEntry.toStringAsFixed(1)}% → ${entry.ivExit.toStringAsFixed(1)}%',
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
              const SizedBox(height: 3),
              Text(
                '${crush >= 0 ? '−' : '+'}${crush.abs().toStringAsFixed(1)}% IV ${entry.wasCrush ? 'crush' : 'expansion'}',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: crushColor),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
