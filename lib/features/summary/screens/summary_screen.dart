// =============================================================================
// features/summary/screens/summary_screen.dart — Home Dashboard
// =============================================================================
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/app_menu_button.dart';
import '../../../services/fmp/fmp_providers.dart';
import '../../auth/providers/auth_provider.dart';
import '../../trades/models/trade.dart';
import '../../trades/providers/trade_block_provider.dart';
import '../../trades/providers/trades_provider.dart';
import '../../macro/macro_score_card.dart';
import '../../macro/fred_sync_widget.dart';

// ── Format helper ─────────────────────────────────────────────────────────────

String _fmt(double v, {bool dollar = false, bool sign = false}) {
  final neg = v < 0;
  final abs = v.abs();
  final core = dollar
      ? (abs >= 1000
          ? '\$${(abs / 1000).toStringAsFixed(1)}k'
          : '\$${abs.toStringAsFixed(0)}')
      : abs.toStringAsFixed(1);
  final prefix = neg ? '-' : (sign ? '+' : '');
  return '$prefix$core';
}

// ── Root screen ───────────────────────────────────────────────────────────────

class SummaryScreen extends ConsumerWidget {
  const SummaryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncTrades = ref.watch(tradesProvider);
    final user = ref.watch(currentUserProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Home'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout_rounded, size: 20),
            color: Colors.white70,
            tooltip: 'Sign out',
            onPressed: () => ref.read(authNotifierProvider.notifier).signOut(),
          ),
          const AppMenuButton(),
        ],
      ),
      body: FredSyncWidget(
        child: asyncTrades.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Error: $e')),
          data: (trades) {
            final closed = trades
                .where((t) => t.status == TradeStatus.closed)
                .toList()
              ..sort((a, b) =>
                  (a.closedAt ?? a.openedAt)
                      .compareTo(b.closedAt ?? b.openedAt));
            final open = trades
                .where((t) => t.status == TradeStatus.open)
                .toList();
            return Column(
              children: [
                _EdgeWarningCard(),
                Expanded(
                  child: _Body(
                    closed: closed,
                    open: open,
                    greeting: user?.email?.split('@').first ?? 'Trader',
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ── Edge erosion banner ───────────────────────────────────────────────────────

class _EdgeWarningCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(edgeErodingProvider)) return const SizedBox.shrink();
    return GestureDetector(
      onTap: () => context.push('/trades/blocks'),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppTheme.lossColor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.lossColor.withValues(alpha: 0.35)),
        ),
        child: const Row(
          children: [
            Icon(Icons.warning_amber_rounded,
                color: AppTheme.lossColor, size: 18),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Edge Erosion Warning — last block < 5 wins. Trade cautiously.',
                style: TextStyle(
                    color: AppTheme.lossColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w500),
              ),
            ),
            Icon(Icons.chevron_right, color: AppTheme.lossColor, size: 16),
          ],
        ),
      ),
    );
  }
}

// ── Analytics models ──────────────────────────────────────────────────────────

class _Stats {
  final List<Trade> closed;
  _Stats(this.closed);

  List<Trade> get wins =>
      closed.where((t) => (t.realizedPnl ?? 0) > 0).toList();
  List<Trade> get losses =>
      closed.where((t) => (t.realizedPnl ?? 0) <= 0).toList();

  double get totalPnl =>
      closed.fold(0.0, (s, t) => s + (t.realizedPnl ?? 0));
  double get winRate =>
      closed.isEmpty ? 0 : wins.length / closed.length * 100;

  double get avgWin => wins.isEmpty
      ? 0
      : wins.fold(0.0, (s, t) => s + (t.realizedPnl ?? 0)) / wins.length;
  double get avgLoss => losses.isEmpty
      ? 0
      : losses.fold(0.0, (s, t) => s + (t.realizedPnl ?? 0)) / losses.length;

  double get riskReward => avgLoss == 0 ? 0 : avgWin / avgLoss.abs();

  Map<String, double> get _dailyPnl {
    final map = <String, double>{};
    for (final t in closed) {
      final key =
          DateFormat('yyyy-MM-dd').format(t.closedAt ?? t.openedAt);
      map[key] = (map[key] ?? 0) + (t.realizedPnl ?? 0);
    }
    return map;
  }

  double get avgWinDay {
    final wd = _dailyPnl.values.where((v) => v > 0).toList();
    return wd.isEmpty ? 0 : wd.fold(0.0, (s, v) => s + v) / wd.length;
  }

  double get avgLossDay {
    final ld = _dailyPnl.values.where((v) => v < 0).toList();
    return ld.isEmpty ? 0 : ld.fold(0.0, (s, v) => s + v) / ld.length;
  }

  double get capitalDeployed =>
      closed.fold(0.0, (s, t) => s + t.costBasis);
  double get currentValue => capitalDeployed + totalPnl;
  double get percentGained =>
      capitalDeployed == 0 ? 0 : totalPnl / capitalDeployed * 100;

  /// Positive = win streak length, negative = loss streak length.
  int get currentStreak {
    if (closed.isEmpty) return 0;
    final recent = [...closed]
      ..sort((a, b) =>
          (b.closedAt ?? b.openedAt).compareTo(a.closedAt ?? a.openedAt));
    final isWin = (recent.first.realizedPnl ?? 0) > 0;
    var count = 0;
    for (final t in recent) {
      if (((t.realizedPnl ?? 0) > 0) == isWin) {
        count++;
      } else {
        break;
      }
    }
    return isWin ? count : -count;
  }

  _TypeStats callStats() => _TypeStats(
      closed.where((t) => t.optionType == OptionType.call).toList());
  _TypeStats putStats() => _TypeStats(
      closed.where((t) => t.optionType == OptionType.put).toList());
  _TypeStats entryStats(EntryPointType type) => _TypeStats(
      closed.where((t) => t.entryPointType == type).toList());
}

class _TypeStats {
  final List<Trade> trades;
  _TypeStats(this.trades);

  int get count => trades.length;
  int get wins => trades.where((t) => (t.realizedPnl ?? 0) > 0).length;
  double get winRate => count == 0 ? 0 : wins / count * 100;
  double get totalPnl =>
      trades.fold(0.0, (s, t) => s + (t.realizedPnl ?? 0));
  double get avgWin {
    final w = trades.where((t) => (t.realizedPnl ?? 0) > 0).toList();
    return w.isEmpty
        ? 0
        : w.fold(0.0, (s, t) => s + (t.realizedPnl ?? 0)) / w.length;
  }
}

// ── Main body ─────────────────────────────────────────────────────────────────

class _Body extends ConsumerWidget {
  final List<Trade> closed;
  final List<Trade> open;
  final String greeting;
  const _Body(
      {required this.closed, required this.open, required this.greeting});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = _Stats(closed);
    final blocksAsync = ref.watch(blockWinRateProvider);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
      children: [
        // Greeting
        Text('Hey, $greeting 👋',
            style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: Colors.white)),
        const SizedBox(height: 2),
        const Text('Your trading overview.',
            style: TextStyle(color: AppTheme.neutralColor, fontSize: 13)),
        const SizedBox(height: 16),

        // Hero P&L card
        _HeroCard(stats: s),
        const SizedBox(height: 20),

        // Cumulative P&L chart
        if (closed.isNotEmpty) ...[
          _sectionHeader('Cumulative P&L', Icons.show_chart_rounded),
          const SizedBox(height: 10),
          _PnlChart(trades: closed),
          const SizedBox(height: 22),
        ],

        // Open positions
        if (open.isNotEmpty) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _sectionHeader('Open Positions', Icons.bolt_rounded),
              TextButton(
                onPressed: () => context.go('/trades'),
                style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                child: const Text('See all →',
                    style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...open.take(3).map((t) => _OpenTradeRow(trade: t)),
          const SizedBox(height: 14),
        ],

        // Performance stats + breakdowns
        if (closed.isNotEmpty) ...[
          _sectionHeader('Performance', Icons.analytics_outlined),
          const SizedBox(height: 10),
          _PerformanceGrid(stats: s),
          const SizedBox(height: 22),

          _sectionHeader('By Option Type', Icons.compare_arrows_rounded),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
                child: _TypeCard(
                    label: 'Calls',
                    icon: Icons.trending_up_rounded,
                    stats: s.callStats(),
                    color: AppTheme.profitColor)),
            const SizedBox(width: 10),
            Expanded(
                child: _TypeCard(
                    label: 'Puts',
                    icon: Icons.trending_down_rounded,
                    stats: s.putStats(),
                    color: AppTheme.lossColor)),
          ]),
          const SizedBox(height: 22),

          _sectionHeader('By Strike Entry', Icons.adjust_rounded),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
                child: _TypeCard(
                    label: 'ITM',
                    icon: Icons.price_check_rounded,
                    stats: s.entryStats(EntryPointType.itm),
                    color: const Color(0xFF60A5FA))),
            const SizedBox(width: 8),
            Expanded(
                child: _TypeCard(
                    label: 'ATM',
                    icon: Icons.adjust_rounded,
                    stats: s.entryStats(EntryPointType.atm),
                    color: const Color(0xFFFBBF24))),
            const SizedBox(width: 8),
            Expanded(
                child: _TypeCard(
                    label: 'OTM',
                    icon: Icons.moving_rounded,
                    stats: s.entryStats(EntryPointType.otm),
                    color: AppTheme.neutralColor)),
          ]),
          const SizedBox(height: 22),

          _sectionHeader('20-Trade Blocks', Icons.grid_view_rounded),
          const SizedBox(height: 10),
          blocksAsync.when(
            loading: () => const Center(
                child: CircularProgressIndicator(strokeWidth: 2)),
            error: (e, _) =>
                Text('$e', style: const TextStyle(color: AppTheme.lossColor)),
            data: (list) => list.isEmpty
                ? _emptyCard('No completed blocks yet')
                : SizedBox(
                    height: 172,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: list.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(width: 10),
                      itemBuilder: (_, i) => _BlockCard(block: list[i]),
                    ),
                  ),
          ),
          const SizedBox(height: 22),
        ],

        // Macro regime
        _sectionHeader('Market Regime', Icons.public_rounded),
        const SizedBox(height: 10),
        const MacroScoreCard(),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => context.go('/economy'),
            icon: const Icon(Icons.bar_chart_rounded, size: 16),
            label: const Text('Full Economy Dashboard'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.profitColor,
              side: const BorderSide(color: AppTheme.profitColor),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),

        if (closed.isEmpty && open.isEmpty) ...[
          const SizedBox(height: 48),
          const Center(
            child: Column(
              children: [
                Icon(Icons.candlestick_chart_outlined,
                    size: 56, color: AppTheme.neutralColor),
                SizedBox(height: 14),
                Text(
                  'No trades yet.\nGo to Trade Log to get started.',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(color: AppTheme.neutralColor, height: 1.5),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  static Widget _sectionHeader(String title, IconData icon) => Row(
        children: [
          Icon(icon, size: 14, color: AppTheme.profitColor),
          const SizedBox(width: 6),
          Text(title,
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Colors.white)),
        ],
      );

  static Widget _emptyCard(String text) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppTheme.cardColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
            child: Text(text,
                style: const TextStyle(color: AppTheme.neutralColor))),
      );
}

// ── Hero P&L card ─────────────────────────────────────────────────────────────

class _HeroCard extends StatelessWidget {
  final _Stats stats;
  const _HeroCard({required this.stats});

  @override
  Widget build(BuildContext context) {
    final pnl = stats.totalPnl;
    final pnlColor =
        pnl >= 0 ? AppTheme.profitColor : AppTheme.lossColor;
    final streak = stats.currentStreak;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(16),
        border:
            Border.all(color: pnlColor.withValues(alpha: 0.4), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Total P&L',
                        style: TextStyle(
                            color: AppTheme.neutralColor, fontSize: 12)),
                    const SizedBox(height: 4),
                    Text(
                      _fmt(pnl, dollar: true, sign: true),
                      style: TextStyle(
                        color: pnlColor,
                        fontSize: 34,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -1,
                      ),
                    ),
                  ],
                ),
              ),
              if (streak != 0) _StreakBadge(streak: streak),
            ],
          ),
          const SizedBox(height: 14),
          IntrinsicHeight(
            child: Row(
              children: [
                Expanded(
                    child: _MiniKpi(
                        label: 'Win Rate',
                        value:
                            '${stats.winRate.toStringAsFixed(1)}%',
                        color: stats.winRate >= 50
                            ? AppTheme.profitColor
                            : AppTheme.lossColor)),
                _vDiv(),
                Expanded(
                    child: _MiniKpi(
                        label: 'Trades',
                        value: '${stats.closed.length}',
                        color: Colors.white)),
                _vDiv(),
                Expanded(
                    child: _MiniKpi(
                        label: '% Return',
                        value:
                            '${stats.percentGained >= 0 ? '+' : ''}${stats.percentGained.toStringAsFixed(1)}%',
                        color: stats.percentGained >= 0
                            ? AppTheme.profitColor
                            : AppTheme.lossColor)),
                _vDiv(),
                Expanded(
                    child: _MiniKpi(
                        label: 'R:R',
                        value: stats.riskReward.toStringAsFixed(2),
                        color: stats.riskReward >= 1
                            ? AppTheme.profitColor
                            : AppTheme.lossColor)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _vDiv() => Container(
        width: 1,
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        color: AppTheme.borderColor.withValues(alpha: 0.35),
      );
}

class _MiniKpi extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _MiniKpi(
      {required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(value,
              style: TextStyle(
                  color: color,
                  fontSize: 14,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(
                  color: AppTheme.neutralColor, fontSize: 10)),
        ],
      );
}

class _StreakBadge extends StatelessWidget {
  final int streak;
  const _StreakBadge({required this.streak});

  @override
  Widget build(BuildContext context) {
    final isWin = streak > 0;
    final color = isWin ? AppTheme.profitColor : AppTheme.lossColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        '${streak.abs()}${isWin ? 'W' : 'L'} streak',
        style: TextStyle(
            color: color, fontSize: 11, fontWeight: FontWeight.w700),
      ),
    );
  }
}

// ── Cumulative P&L chart ──────────────────────────────────────────────────────

class _PnlChart extends StatelessWidget {
  final List<Trade> trades;
  const _PnlChart({required this.trades});

  @override
  Widget build(BuildContext context) {
    final sorted = [...trades]
      ..sort((a, b) =>
          (a.closedAt ?? a.openedAt).compareTo(b.closedAt ?? b.openedAt));

    double cumulative = 0;
    final spots = <FlSpot>[];
    for (var i = 0; i < sorted.length; i++) {
      cumulative += sorted[i].realizedPnl ?? 0;
      spots.add(FlSpot(i.toDouble(), cumulative));
    }

    final lineColor =
        cumulative >= 0 ? AppTheme.profitColor : AppTheme.lossColor;

    return Container(
      height: 180,
      decoration: BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.fromLTRB(6, 14, 14, 8),
      child: LineChart(
        LineChartData(
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) => FlLine(
              color: Colors.white.withValues(alpha: 0.05),
              strokeWidth: 1,
            ),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 58,
                getTitlesWidget: (v, _) => Text(
                  v.abs() >= 1000
                      ? '\$${(v / 1000).toStringAsFixed(0)}k'
                      : '\$${v.toStringAsFixed(0)}',
                  style: const TextStyle(
                      color: AppTheme.neutralColor, fontSize: 9),
                ),
              ),
            ),
            bottomTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false)),
            topTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false)),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              color: lineColor,
              barWidth: 2.5,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: lineColor.withValues(alpha: 0.08),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Open trade row ────────────────────────────────────────────────────────────

class _OpenTradeRow extends ConsumerWidget {
  final Trade trade;
  const _OpenTradeRow({required this.trade});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final daysLeft = trade.expiration.difference(DateTime.now()).inDays;
    final urgentColor =
        daysLeft <= 7 ? AppTheme.lossColor : AppTheme.neutralColor;
    final quoteAsync = ref.watch(quoteProvider(trade.ticker));

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        title: Text(
          '${trade.ticker}  \$${trade.strike.toStringAsFixed(0)} ${trade.optionType.name.toUpperCase()}',
          style:
              const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
        ),
        subtitle: quoteAsync.when(
          loading: () => Text('${trade.strategy.label} · loading…',
              style: const TextStyle(
                  color: AppTheme.neutralColor, fontSize: 11)),
          error: (_, __) => Text(trade.strategy.label,
              style: const TextStyle(
                  color: AppTheme.neutralColor, fontSize: 11)),
          data: (quote) {
            if (quote == null) {
              return Text(trade.strategy.label,
                  style: const TextStyle(
                      color: AppTheme.neutralColor, fontSize: 11));
            }
            final chgColor = quote.isPositive
                ? AppTheme.profitColor
                : AppTheme.lossColor;
            return RichText(
              text: TextSpan(
                style: const TextStyle(fontSize: 11),
                children: [
                  TextSpan(
                    text: '\$${quote.price.toStringAsFixed(2)} ',
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600),
                  ),
                  TextSpan(
                    text:
                        '${quote.isPositive ? '+' : ''}${quote.changePercent.toStringAsFixed(2)}%',
                    style: TextStyle(color: chgColor),
                  ),
                  const TextSpan(
                      text: '  ·  ',
                      style:
                          TextStyle(color: AppTheme.neutralColor)),
                  TextSpan(
                      text: trade.strategy.label,
                      style: const TextStyle(
                          color: AppTheme.neutralColor)),
                ],
              ),
            );
          },
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('$daysLeft DTE',
                style: TextStyle(
                    color: urgentColor,
                    fontWeight: FontWeight.w700,
                    fontSize: 12)),
            Text('Entry \$${trade.entryPrice.toStringAsFixed(2)}',
                style: const TextStyle(
                    color: AppTheme.neutralColor, fontSize: 10)),
          ],
        ),
        onTap: () => context.push('/trades/${trade.id}', extra: trade),
        onLongPress: () => context.push('/ticker/${trade.ticker}'),
      ),
    );
  }
}

// ── Performance stats grid ────────────────────────────────────────────────────

class _PerformanceGrid extends StatelessWidget {
  final _Stats stats;
  const _PerformanceGrid({required this.stats});

  @override
  Widget build(BuildContext context) {
    final s = stats;
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 10,
      mainAxisSpacing: 10,
      childAspectRatio: 2.6,
      children: [
        _StatTile(
            icon: Icons.arrow_upward_rounded,
            label: 'Avg Win',
            value: _fmt(s.avgWin, dollar: true, sign: true),
            color: AppTheme.profitColor),
        _StatTile(
            icon: Icons.arrow_downward_rounded,
            label: 'Avg Loss',
            value: _fmt(s.avgLoss, dollar: true),
            color: AppTheme.lossColor),
        _StatTile(
            icon: Icons.wb_sunny_rounded,
            label: 'Avg Win Day',
            value: _fmt(s.avgWinDay, dollar: true, sign: true),
            color: AppTheme.profitColor),
        _StatTile(
            icon: Icons.nights_stay_rounded,
            label: 'Avg Loss Day',
            value: _fmt(s.avgLossDay, dollar: true),
            color: AppTheme.lossColor),
        _StatTile(
            icon: Icons.account_balance_rounded,
            label: 'Capital Deployed',
            value: _fmt(s.capitalDeployed, dollar: true),
            color: AppTheme.neutralColor),
        _StatTile(
            icon: Icons.savings_rounded,
            label: 'Current Value',
            value: _fmt(s.currentValue, dollar: true),
            color: s.currentValue >= s.capitalDeployed
                ? AppTheme.profitColor
                : AppTheme.lossColor),
        _StatTile(
            icon: Icons.check_circle_outline_rounded,
            label: 'Winners',
            value: '${s.wins.length}',
            color: AppTheme.profitColor),
        _StatTile(
            icon: Icons.cancel_outlined,
            label: 'Losers',
            value: '${s.losses.length}',
            color: AppTheme.lossColor),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  const _StatTile(
      {required this.icon,
      required this.label,
      required this.value,
      required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(10),
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color.withValues(alpha: 0.8), size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(value,
                    style: TextStyle(
                        color: color,
                        fontSize: 14,
                        fontWeight: FontWeight.w800),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 1),
                Text(label,
                    style: const TextStyle(
                        color: AppTheme.neutralColor, fontSize: 10),
                    maxLines: 1),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Option type / entry point card ────────────────────────────────────────────

class _TypeCard extends StatelessWidget {
  final String label;
  final IconData icon;
  final _TypeStats stats;
  final Color color;
  const _TypeCard(
      {required this.label,
      required this.icon,
      required this.stats,
      required this.color});

  @override
  Widget build(BuildContext context) {
    final pnlColor =
        stats.totalPnl >= 0 ? AppTheme.profitColor : AppTheme.lossColor;
    final wrColor =
        stats.winRate >= 50 ? AppTheme.profitColor : AppTheme.lossColor;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, color: color, size: 14),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w700,
                    fontSize: 13)),
            const Spacer(),
            Text('${stats.count}',
                style: const TextStyle(
                    color: AppTheme.neutralColor, fontSize: 11)),
          ]),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: stats.winRate / 100,
              backgroundColor: AppTheme.elevatedColor,
              valueColor: AlwaysStoppedAnimation(wrColor),
              minHeight: 4,
            ),
          ),
          const SizedBox(height: 5),
          Text('${stats.winRate.toStringAsFixed(0)}% win',
              style: TextStyle(
                  color: wrColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text('Avg \$${stats.avgWin.toStringAsFixed(0)}',
              style: const TextStyle(
                  color: AppTheme.neutralColor, fontSize: 11)),
          const SizedBox(height: 2),
          Text(
              '${stats.totalPnl >= 0 ? '+' : ''}\$${stats.totalPnl.toStringAsFixed(0)}',
              style: TextStyle(
                  color: pnlColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

// ── 20-trade block card ───────────────────────────────────────────────────────

class _BlockCard extends StatelessWidget {
  final TradeBlock block;
  const _BlockCard({required this.block});

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('MMM d');
    final first = block.trades.first.closedAt ?? block.trades.first.openedAt;
    final last = block.trades.last.closedAt ?? block.trades.last.openedAt;
    final dateRange = '${fmt.format(first)} – ${fmt.format(last)}';
    final winPct = block.winRate * 100;
    final pnlColor =
        block.totalPnl >= 0 ? AppTheme.profitColor : AppTheme.lossColor;
    final winColor =
        winPct >= 50 ? AppTheme.profitColor : AppTheme.lossColor;
    final winTrades =
        block.trades.where((t) => (t.realizedPnl ?? 0) > 0).toList();
    final avgWin = winTrades.isEmpty
        ? 0.0
        : winTrades.fold(0.0, (s, t) => s + (t.realizedPnl ?? 0)) /
            winTrades.length;

    return Container(
      width: 156,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: block.edgeWarning
            ? Border.all(
                color: AppTheme.lossColor.withValues(alpha: 0.5))
            : Border.all(
                color: AppTheme.borderColor.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text('Block ${block.blockNumber}',
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 13)),
            if (block.edgeWarning) ...[
              const SizedBox(width: 4),
              const Icon(Icons.warning_amber_rounded,
                  color: AppTheme.lossColor, size: 12),
            ],
          ]),
          const SizedBox(height: 2),
          Text(dateRange,
              style: const TextStyle(
                  color: AppTheme.neutralColor, fontSize: 10)),
          const Spacer(),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: block.winRate,
              backgroundColor: AppTheme.elevatedColor,
              valueColor: AlwaysStoppedAnimation(winColor),
              minHeight: 5,
            ),
          ),
          const SizedBox(height: 5),
          Text(
              '${winPct.toStringAsFixed(0)}%  (${block.wins}/${block.trades.length})',
              style: TextStyle(
                  color: winColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text('Avg win \$${avgWin.toStringAsFixed(0)}',
              style: const TextStyle(
                  color: AppTheme.neutralColor, fontSize: 10)),
          const SizedBox(height: 2),
          Text(
              '${block.totalPnl >= 0 ? '+' : ''}\$${block.totalPnl.toStringAsFixed(0)}',
              style: TextStyle(
                  color: pnlColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}
