// =============================================================================
// features/strategy_tracker/screens/strategy_detail_screen.dart
// =============================================================================
// Full detail view for one strategy setup.
//
// Receives [setupId] as a path param — watches strategyTrackerProvider live so
// stats auto-refresh when trades are tagged or closed.
//
// Sections:
//   Header      — name, status badge (AppBar), edit button, win-rate hero
//   Stats grid  — Win Rate · Profit Factor · Expectancy · Total P&L
//   Secondary   — Total trades (open/closed/scored), max consecutive losses
//   Target Area — selected price targets (ATH, 200 SMA, Prior High…) blue chips
//   Criteria    — full checklist of every defined entry condition
//   Notes       — strategy description, if set
//   Chart       — rolling 10-trade WR (green) + cumulative WR (gray dashed)
//                 Horizontal reference at 50%; shows "die and come back" shape
//   Trades      — all linked trades newest-first, with outcome badge
// =============================================================================
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../core/theme.dart';
import '../../trades/models/trade.dart';
import '../models/strategy_models.dart';
import '../providers/strategy_tracker_provider.dart';
import '../widgets/add_strategy_sheet.dart';

// ── Screen shell ──────────────────────────────────────────────────────────────

class StrategyDetailScreen extends ConsumerWidget {
  final String setupId;
  const StrategyDetailScreen({super.key, required this.setupId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final setupsAsync = ref.watch(strategyTrackerProvider);

    return setupsAsync.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: Center(
          child: Text('$e',
              style: const TextStyle(color: AppTheme.lossColor)),
        ),
      ),
      data: (setups) {
        final setup = setups.where((s) => s.id == setupId).firstOrNull;
        if (setup == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Strategy not found')),
          );
        }
        return _DetailView(setup: setup);
      },
    );
  }
}

// ── Full detail view ──────────────────────────────────────────────────────────

class _DetailView extends StatelessWidget {
  final StrategySetup setup;
  const _DetailView({required this.setup});

  @override
  Widget build(BuildContext context) {
    final wr      = setup.winRate;
    final wrColor = wr >= 0.60
        ? AppTheme.profitColor
        : wr >= 0.40
            ? const Color(0xFFFBBF24)
            : AppTheme.lossColor;

    return Scaffold(
      appBar: AppBar(
        title: Text(setup.name),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 4),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color:        setup.status.color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
              border:       Border.all(
                  color: setup.status.color.withValues(alpha: 0.5)),
            ),
            child: Text(
              setup.status.label,
              style: TextStyle(
                color:         setup.status.color,
                fontWeight:    FontWeight.w800,
                fontSize:      12,
                letterSpacing: 0.5,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.edit_rounded, size: 20),
            tooltip: 'Edit strategy',
            onPressed: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              backgroundColor: Colors.transparent,
              builder: (_) => AddStrategySheet(initialSetup: setup),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 40),
        children: [
          // ── Win-rate hero card ───────────────────────────────────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          setup.totalScored == 0
                              ? '—'
                              : '${(wr * 100).toStringAsFixed(1)}%',
                          style: TextStyle(
                            fontSize:   40,
                            fontWeight: FontWeight.w900,
                            color:      setup.totalScored == 0
                                ? AppTheme.neutralColor
                                : wrColor,
                          ),
                        ),
                        const Text(
                          'Win Rate',
                          style: TextStyle(
                            color:    AppTheme.neutralColor,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '${setup.wins}W  ${setup.losses}L  ${setup.breakevens}B',
                        style: const TextStyle(
                          fontSize:   15,
                          fontWeight: FontWeight.w700,
                          color:      Colors.white,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${setup.linkedTrades.length} total · '
                        '${setup.openTrades.length} open',
                        style: const TextStyle(
                          color:    AppTheme.neutralColor,
                          fontSize: 12,
                        ),
                      ),
                      if (setup.createdAt.isAfter(DateTime(2000))) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Since ${DateFormat('MMM yyyy').format(setup.createdAt)}',
                          style: const TextStyle(
                            color:    AppTheme.neutralColor,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),

          // ── Stats grid ───────────────────────────────────────────────────────
          Row(
            children: [
              _StatCard(
                label: 'Profit Factor',
                value: setup.totalScored == 0
                    ? '—'
                    : setup.profitFactor >= 999
                        ? '∞'
                        : setup.profitFactor.toStringAsFixed(2),
                color: setup.profitFactor >= 1.5
                    ? AppTheme.profitColor
                    : null,
              ),
              const SizedBox(width: 8),
              _StatCard(
                label: 'Expectancy',
                value: setup.totalScored == 0
                    ? '—'
                    : '${setup.expectancy >= 0 ? '+' : ''}'
                        '\$${setup.expectancy.toStringAsFixed(0)}',
                color: setup.expectancy >= 0
                    ? AppTheme.profitColor
                    : AppTheme.lossColor,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _StatCard(
                label: 'Total P&L',
                value: setup.totalScored == 0
                    ? '—'
                    : '${setup.totalPnl >= 0 ? '+' : ''}'
                        '\$${setup.totalPnl.abs() >= 1000 ? '${(setup.totalPnl / 1000).toStringAsFixed(1)}k' : setup.totalPnl.toStringAsFixed(0)}',
                color: setup.totalPnl >= 0
                    ? AppTheme.profitColor
                    : AppTheme.lossColor,
              ),
              const SizedBox(width: 8),
              _StatCard(
                label: 'Max Consec. Losses',
                value: setup.totalScored == 0
                    ? '—'
                    : '${setup.maxConsecutiveLosses}',
                color: setup.maxConsecutiveLosses >= 5
                    ? AppTheme.lossColor
                    : null,
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ── Target areas ──────────────────────────────────────────────────────
          if (setup.hasTargets) ...[
            _SectionLabel('Target Area'),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                child: Wrap(
                  spacing:    8,
                  runSpacing: 8,
                  children: [
                    for (final area in setup.targetAreas)
                      _TargetBadge(area),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],

          // ── Entry criteria ────────────────────────────────────────────────────
          if (setup.hasCriteria) ...[
            _SectionLabel('Entry Criteria'),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final lbl in setup.allCriteriaLabels)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.only(top: 1),
                              child: Icon(
                                Icons.check_circle_outline,
                                size:  15,
                                color: AppTheme.profitColor,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                lbl,
                                style: const TextStyle(
                                  color:    Colors.white,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],

          if (setup.description != null &&
              setup.description!.isNotEmpty) ...[
            _SectionLabel('Notes'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(
                  setup.description!,
                  style: const TextStyle(
                    color:    AppTheme.neutralColor,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],

          // ── Win-rate trend chart ──────────────────────────────────────────────
          _SectionLabel('Win Rate Trend'),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 16, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _LegendDot(AppTheme.profitColor),
                      const SizedBox(width: 4),
                      const Text(
                        'Rolling 10-trade',
                        style: TextStyle(
                            color: AppTheme.neutralColor, fontSize: 11),
                      ),
                      const SizedBox(width: 12),
                      _LegendDash(AppTheme.neutralColor),
                      const SizedBox(width: 4),
                      const Text(
                        'Cumulative',
                        style: TextStyle(
                            color: AppTheme.neutralColor, fontSize: 11),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _WinRateChart(scoredTrades: setup.scoredTrades),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ── Trade history ─────────────────────────────────────────────────────
          _SectionLabel(
              'Trade History (${setup.linkedTrades.length})'),
          if (setup.linkedTrades.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Center(
                  child: Column(
                    children: [
                      const Icon(Icons.link_off,
                          size: 36, color: AppTheme.neutralColor),
                      const SizedBox(height: 8),
                      const Text(
                        'No trades tagged yet',
                        style: TextStyle(color: AppTheme.neutralColor),
                      ),
                      const SizedBox(height: 4),
                      TextButton(
                        onPressed: () => context.push('/trades/add'),
                        child: const Text('Log a trade'),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            // Newest first
            for (final trade
                in setup.linkedTrades.reversed.toList())
              _TradeRow(trade: trade),
        ],
      ),
    );
  }
}

// ── Target area badge ─────────────────────────────────────────────────────────

class _TargetBadge extends StatelessWidget {
  final TargetArea area;
  const _TargetBadge(this.area);

  static const _color = Color(0xFF60A5FA);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color:        _color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(7),
          border:       Border.all(color: _color.withValues(alpha: 0.35)),
        ),
        child: Text(
          area.label,
          style: const TextStyle(
            color:      _color,
            fontSize:   12,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}

// ── Stat card ─────────────────────────────────────────────────────────────────

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  const _StatCard({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) => Expanded(
        child: Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    fontSize:   20,
                    fontWeight: FontWeight.w800,
                    color:      color ?? Colors.white,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: const TextStyle(
                      color: AppTheme.neutralColor, fontSize: 11),
                ),
              ],
            ),
          ),
        ),
      );
}

// ── Win-rate chart ────────────────────────────────────────────────────────────
// scoredTrades arrive oldest-first from StrategySetup.scoredTrades.
// Rolling line: 10-trade window; shows hot/cold streaks and "die & come back".
// Cumulative line: overall trend stabilising over time.

class _WinRateChart extends StatelessWidget {
  final List<Trade> scoredTrades;
  const _WinRateChart({required this.scoredTrades});

  @override
  Widget build(BuildContext context) {
    if (scoredTrades.length < 2) {
      return const SizedBox(
        height: 100,
        child: Center(
          child: Text(
            'Log 2+ closed trades to see the trend',
            style: TextStyle(color: AppTheme.neutralColor, fontSize: 12),
          ),
        ),
      );
    }

    final rolling    = <FlSpot>[];
    final cumulative = <FlSpot>[];
    int wins = 0;

    for (int i = 0; i < scoredTrades.length; i++) {
      if (scoredTrades[i].realizedPnl! > 0) wins++;
      cumulative.add(FlSpot(i.toDouble(), wins / (i + 1) * 100));

      final start  = i < 9 ? 0 : i - 9;
      final window = scoredTrades.sublist(start, i + 1);
      final wWins  = window.where((t) => t.realizedPnl! > 0).length;
      rolling.add(FlSpot(i.toDouble(), wWins / window.length * 100));
    }

    return SizedBox(
      height: 180,
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: 100,
          minX: 0,
          maxX: (scoredTrades.length - 1).toDouble(),
          clipData: const FlClipData.all(),
          gridData: FlGridData(
            show: true,
            horizontalInterval: 25,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) => FlLine(
              color:       AppTheme.borderColor.withValues(alpha: 0.3),
              strokeWidth: 0.5,
            ),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles:   true,
                interval:     50,
                reservedSize: 32,
                getTitlesWidget: (v, _) => Text(
                  '${v.toInt()}%',
                  style: const TextStyle(
                      color: AppTheme.neutralColor, fontSize: 10),
                ),
              ),
            ),
            rightTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false)),
            topTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false)),
            bottomTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false)),
          ),
          extraLinesData: ExtraLinesData(
            horizontalLines: [
              HorizontalLine(
                y:           50,
                color:       Colors.white24,
                strokeWidth: 1,
                dashArray:   [4, 4],
                label: HorizontalLineLabel(
                  show:      true,
                  alignment: Alignment.topRight,
                  style: const TextStyle(
                      color: Colors.white38, fontSize: 9),
                  labelResolver: (_) => '50%',
                ),
              ),
            ],
          ),
          lineBarsData: [
            // Rolling 10-trade win rate — the "hot/cold" signal
            LineChartBarData(
              spots:          rolling,
              isCurved:       true,
              curveSmoothness: 0.25,
              color:          AppTheme.profitColor,
              barWidth:       2.5,
              dotData:        const FlDotData(show: false),
              belowBarData:   BarAreaData(
                show:  true,
                color: AppTheme.profitColor.withValues(alpha: 0.07),
              ),
            ),
            // Cumulative win rate — stabilises over time
            LineChartBarData(
              spots:          cumulative,
              isCurved:       true,
              curveSmoothness: 0.25,
              color:          AppTheme.neutralColor,
              barWidth:       1.5,
              dashArray:      [5, 4],
              dotData:        const FlDotData(show: false),
            ),
          ],
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipItems: (spots) => spots.map((s) {
                final isRolling = s.barIndex == 0;
                return LineTooltipItem(
                  '${s.y.toStringAsFixed(0)}%',
                  TextStyle(
                    color:      isRolling
                        ? AppTheme.profitColor
                        : AppTheme.neutralColor,
                    fontSize:   12,
                    fontWeight: FontWeight.w700,
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Trade row ─────────────────────────────────────────────────────────────────

class _TradeRow extends StatelessWidget {
  final Trade trade;
  const _TradeRow({required this.trade});

  @override
  Widget build(BuildContext context) {
    final pnl      = trade.realizedPnl;
    final isOpen   = trade.status == TradeStatus.open;
    final pnlColor = pnl == null
        ? AppTheme.neutralColor
        : pnl > 0
            ? AppTheme.profitColor
            : pnl < 0
                ? AppTheme.lossColor
                : AppTheme.neutralColor;

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push(
          '/trades/${trade.id}',
          extra: trade,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Row(
            children: [
              // Outcome dot
              Container(
                width:  10,
                height: 10,
                margin: const EdgeInsets.only(right: 10),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isOpen
                      ? AppTheme.neutralColor.withValues(alpha: 0.4)
                      : pnlColor.withValues(alpha: 0.85),
                ),
              ),
              // Ticker + strategy
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      trade.ticker,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize:   14,
                        color:      Colors.white,
                      ),
                    ),
                    Text(
                      '${trade.optionType.name.toUpperCase()} · '
                      '${trade.strategy.label} · '
                      '${DateFormat('MMM d, yy').format(trade.openedAt)}',
                      style: const TextStyle(
                        color:    AppTheme.neutralColor,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              // P&L or OPEN badge
              if (isOpen)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color:        AppTheme.neutralColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Text(
                    'OPEN',
                    style: TextStyle(
                      color:    AppTheme.neutralColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                )
              else if (pnl != null)
                Text(
                  '${pnl >= 0 ? '+' : ''}\$${pnl.toStringAsFixed(0)}',
                  style: TextStyle(
                    color:      pnlColor,
                    fontWeight: FontWeight.w700,
                    fontSize:   14,
                  ),
                )
              else
                const Text(
                  'No exit',
                  style: TextStyle(
                      color: AppTheme.neutralColor, fontSize: 11),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            color:         AppTheme.neutralColor,
            fontSize:      11,
            fontWeight:    FontWeight.w700,
            letterSpacing: 1.0,
          ),
        ),
      );
}

class _LegendDot extends StatelessWidget {
  final Color color;
  const _LegendDot(this.color);

  @override
  Widget build(BuildContext context) => Container(
        width:  10,
        height: 2.5,
        color:  color,
      );
}

class _LegendDash extends StatelessWidget {
  final Color color;
  const _LegendDash(this.color);

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Container(width: 5, height: 1.5, color: color),
          const SizedBox(width: 2),
          Container(width: 5, height: 1.5, color: color),
        ],
      );
}
