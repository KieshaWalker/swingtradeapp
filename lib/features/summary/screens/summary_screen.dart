// =============================================================================
// features/summary/screens/summary_screen.dart — Performance Summary
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/app_menu_button.dart';
import '../../trades/models/trade.dart';
import '../../trades/providers/trade_block_provider.dart';
import '../../trades/providers/trades_provider.dart';
import '../../macro/macro_score_card.dart';

class SummaryScreen extends ConsumerWidget {
  const SummaryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncTrades = ref.watch(tradesProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Performance Summary'),
        actions: const [AppMenuButton()],
      ),
      body: asyncTrades.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (trades) {
          final closed = trades
              .where((t) => t.status == TradeStatus.closed)
              .toList()
            ..sort((a, b) =>
                (a.closedAt ?? a.openedAt).compareTo(b.closedAt ?? b.openedAt));
          return _SummaryBody(closed: closed);
        },
      ),
    );
  }
}

// ── Analytics helpers ────────────────────────────────────────────────────────

class _Stats {
  final List<Trade> closed;
  _Stats(this.closed);

  List<Trade> get wins => closed.where((t) => (t.realizedPnl ?? 0) > 0).toList();
  List<Trade> get losses => closed.where((t) => (t.realizedPnl ?? 0) <= 0).toList();

  double get totalPnl => closed.fold(0.0, (s, t) => s + (t.realizedPnl ?? 0));
  double get winRate => closed.isEmpty ? 0 : wins.length / closed.length * 100;
  double get lossRate => 100 - winRate;

  double get avgWin => wins.isEmpty
      ? 0
      : wins.fold(0.0, (s, t) => s + (t.realizedPnl ?? 0)) / wins.length;
  double get avgLoss => losses.isEmpty
      ? 0
      : losses.fold(0.0, (s, t) => s + (t.realizedPnl ?? 0)) / losses.length;

  double get riskReward =>
      avgLoss == 0 ? 0 : avgWin / avgLoss.abs();

  // Group by calendar day of close
  Map<String, double> get _dailyPnl {
    final map = <String, double>{};
    for (final t in closed) {
      final key = DateFormat('yyyy-MM-dd').format(t.closedAt ?? t.openedAt);
      map[key] = (map[key] ?? 0) + (t.realizedPnl ?? 0);
    }
    return map;
  }

  double get avgWinDay {
    final winDays = _dailyPnl.values.where((v) => v > 0).toList();
    if (winDays.isEmpty) return 0;
    return winDays.fold(0.0, (s, v) => s + v) / winDays.length;
  }

  double get avgLossDay {
    final lossDays = _dailyPnl.values.where((v) => v < 0).toList();
    if (lossDays.isEmpty) return 0;
    return lossDays.fold(0.0, (s, v) => s + v) / lossDays.length;
  }

  double get startingValue =>
      closed.fold(0.0, (s, t) => s + t.costBasis);

  double get currentValue => startingValue + totalPnl;

  double get percentGained =>
      startingValue == 0 ? 0 : totalPnl / startingValue * 100;

  // By option type
  _TypeStats callStats() => _TypeStats(
      closed.where((t) => t.optionType == OptionType.call).toList());
  _TypeStats putStats() => _TypeStats(
      closed.where((t) => t.optionType == OptionType.put).toList());

  // By entry point
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
    if (w.isEmpty) return 0;
    return w.fold(0.0, (s, t) => s + (t.realizedPnl ?? 0)) / w.length;
  }
}

// ── Body ─────────────────────────────────────────────────────────────────────

class _SummaryBody extends ConsumerWidget {
  final List<Trade> closed;
  const _SummaryBody({required this.closed});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = _Stats(closed);
    final blocks = ref.watch(blockWinRateProvider);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── Overall stats ──────────────────────────────────────────────────
        _sectionHeader('Overall'),
        const SizedBox(height: 10),
        _StatGrid(children: [
          _StatTile(
            label: 'Total P&L',
            value: _fmt(s.totalPnl, dollar: true, sign: true),
            color: s.totalPnl >= 0 ? AppTheme.profitColor : AppTheme.lossColor,
          ),
          _StatTile(
            label: 'Win Rate',
            value: '${s.winRate.toStringAsFixed(1)}%',
            color: s.winRate >= 50 ? AppTheme.profitColor : AppTheme.lossColor,
          ),
          _StatTile(
            label: 'Loss Rate',
            value: '${s.lossRate.toStringAsFixed(1)}%',
            color: s.lossRate < 50 ? AppTheme.profitColor : AppTheme.lossColor,
          ),
          _StatTile(
            label: 'Risk / Reward',
            value: s.riskReward.toStringAsFixed(2),
            color: s.riskReward >= 1 ? AppTheme.profitColor : AppTheme.lossColor,
          ),
          _StatTile(
            label: 'Avg Win',
            value: _fmt(s.avgWin, dollar: true, sign: true),
            color: AppTheme.profitColor,
          ),
          _StatTile(
            label: 'Avg Loss',
            value: _fmt(s.avgLoss, dollar: true, sign: true),
            color: AppTheme.lossColor,
          ),
          _StatTile(
            label: 'Avg Win Day',
            value: _fmt(s.avgWinDay, dollar: true, sign: true),
            color: AppTheme.profitColor,
          ),
          _StatTile(
            label: 'Avg Loss Day',
            value: _fmt(s.avgLossDay, dollar: true, sign: true),
            color: AppTheme.lossColor,
          ),
          _StatTile(
            label: 'Capital Deployed',
            value: _fmt(s.startingValue, dollar: true),
            color: AppTheme.neutralColor,
          ),
          _StatTile(
            label: 'Current Value',
            value: _fmt(s.currentValue, dollar: true),
            color: s.currentValue >= s.startingValue
                ? AppTheme.profitColor
                : AppTheme.lossColor,
          ),
          _StatTile(
            label: '% Gained',
            value: '${s.percentGained >= 0 ? '+' : ''}${s.percentGained.toStringAsFixed(1)}%',
            color: s.percentGained >= 0 ? AppTheme.profitColor : AppTheme.lossColor,
          ),
          _StatTile(
            label: 'Closed Trades',
            value: '${closed.length}',
            color: AppTheme.neutralColor,
          ),
        ]),

        const SizedBox(height: 24),

        // ── Calls vs Puts ──────────────────────────────────────────────────
        _sectionHeader('By Option Type'),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _TypeCard(label: 'Calls', icon: Icons.trending_up_rounded, stats: s.callStats(), color: AppTheme.profitColor)),
          const SizedBox(width: 12),
          Expanded(child: _TypeCard(label: 'Puts', icon: Icons.trending_down_rounded, stats: s.putStats(), color: AppTheme.lossColor)),
        ]),

        const SizedBox(height: 24),

        // ── ITM / ATM / OTM ───────────────────────────────────────────────
        _sectionHeader('By Entry Point'),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _TypeCard(label: 'ITM', icon: Icons.price_check_rounded, stats: s.entryStats(EntryPointType.itm), color: const Color(0xFF60A5FA))),
          const SizedBox(width: 8),
          Expanded(child: _TypeCard(label: 'ATM', icon: Icons.adjust_rounded, stats: s.entryStats(EntryPointType.atm), color: const Color(0xFFFBBF24))),
          const SizedBox(width: 8),
          Expanded(child: _TypeCard(label: 'OTM', icon: Icons.moving_rounded, stats: s.entryStats(EntryPointType.otm), color: AppTheme.neutralColor)),
        ]),

        const SizedBox(height: 24),

        // ── 20-Trade Blocks ───────────────────────────────────────────────
        _sectionHeader('20-Trade Blocks'),
        const SizedBox(height: 10),
        blocks.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Text('$e', style: const TextStyle(color: AppTheme.lossColor)),
          data: (list) => list.isEmpty
              ? _emptyHint('No completed blocks yet')
              : SizedBox(
                  height: 160,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                    itemBuilder: (_, i) => _BlockCard(block: list[i]),
                  ),
                ),
        ),

        const SizedBox(height: 24),

        // ── Economy snapshot ──────────────────────────────────────────────
        _sectionHeader('Economy Snapshot'),
        const SizedBox(height: 10),
        const MacroScoreCard(),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => context.go('/economy'),
            icon: const Icon(Icons.bar_chart_rounded, size: 16),
            label: const Text('View Full Economy Dashboard'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.profitColor,
              side: const BorderSide(color: AppTheme.profitColor, width: 1),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),

        const SizedBox(height: 32),
      ],
    );
  }

  Widget _sectionHeader(String title) => Text(
        title,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      );

  Widget _emptyHint(String text) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppTheme.cardColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Text(text,
              style: const TextStyle(color: AppTheme.neutralColor)),
        ),
      );

  static String _fmt(double v, {bool dollar = false, bool sign = false}) {
    final prefix = sign && v > 0 ? '+' : '';
    final formatted = v.abs() >= 1000
        ? '\$${(v.abs() / 1000).toStringAsFixed(1)}k'
        : '\$${v.abs().toStringAsFixed(0)}';
    final core = dollar ? formatted : v.toStringAsFixed(1);
    if (v < 0) return '-${dollar ? formatted : v.abs().toStringAsFixed(1)}';
    return '$prefix$core';
  }
}

// ── Stat grid ─────────────────────────────────────────────────────────────────

class _StatGrid extends StatelessWidget {
  final List<_StatTile> children;
  const _StatGrid({required this.children});

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
      childAspectRatio: 1.3,
      children: children,
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _StatTile({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: const TextStyle(
              color: AppTheme.neutralColor,
              fontSize: 10,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// ── Type card (calls/puts/itm/atm/otm) ────────────────────────────────────────

class _TypeCard extends StatelessWidget {
  final String label;
  final IconData icon;
  final _TypeStats stats;
  final Color color;
  const _TypeCard({
    required this.label,
    required this.icon,
    required this.stats,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final pnlSign = stats.totalPnl >= 0 ? '+' : '';
    final pnlColor =
        stats.totalPnl >= 0 ? AppTheme.profitColor : AppTheme.lossColor;
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, color: color, size: 16),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    color: color, fontWeight: FontWeight.w700, fontSize: 13)),
          ]),
          const SizedBox(height: 8),
          Text('${stats.count} trades',
              style: const TextStyle(color: AppTheme.neutralColor, fontSize: 11)),
          const SizedBox(height: 2),
          Text('Win ${stats.winRate.toStringAsFixed(0)}%',
              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text('Avg win \$${stats.avgWin.toStringAsFixed(0)}',
              style: const TextStyle(color: AppTheme.neutralColor, fontSize: 11)),
          const SizedBox(height: 2),
          Text('$pnlSign\$${stats.totalPnl.toStringAsFixed(0)}',
              style: TextStyle(
                  color: pnlColor, fontSize: 12, fontWeight: FontWeight.w700)),
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
    final winColor = winPct >= 50 ? AppTheme.profitColor : AppTheme.lossColor;
    final avgWinTrades =
        block.trades.where((t) => (t.realizedPnl ?? 0) > 0).toList();
    final avgWin = avgWinTrades.isEmpty
        ? 0.0
        : avgWinTrades.fold(0.0, (s, t) => s + (t.realizedPnl ?? 0)) /
            avgWinTrades.length;

    return Container(
      width: 148,
      decoration: BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: block.edgeWarning
            ? Border.all(color: AppTheme.lossColor.withValues(alpha: 0.5))
            : null,
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text(
              'Block ${block.blockNumber}',
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 13),
            ),
            if (block.edgeWarning) ...[
              const SizedBox(width: 4),
              const Icon(Icons.warning_amber_rounded,
                  color: AppTheme.lossColor, size: 13),
            ],
          ]),
          const SizedBox(height: 3),
          Text(dateRange,
              style:
                  const TextStyle(color: AppTheme.neutralColor, fontSize: 10)),
          const Spacer(),
          // Win rate bar
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: block.winRate,
              backgroundColor: AppTheme.elevatedColor,
              valueColor: AlwaysStoppedAnimation<Color>(winColor),
              minHeight: 5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Win ${winPct.toStringAsFixed(0)}%  (${block.wins}/${block.trades.length})',
            style: TextStyle(
                color: winColor, fontSize: 11, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            'Avg win \$${avgWin.toStringAsFixed(0)}',
            style: const TextStyle(color: AppTheme.neutralColor, fontSize: 10),
          ),
          const SizedBox(height: 2),
          Text(
            '${block.totalPnl >= 0 ? '+' : ''}\$${block.totalPnl.toStringAsFixed(0)}',
            style: TextStyle(
                color: pnlColor, fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}
