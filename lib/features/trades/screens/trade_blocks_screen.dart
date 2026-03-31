// =============================================================================
// features/trades/screens/trade_blocks_screen.dart — 20-trade block analytics
// =============================================================================
// Shows each sequential block of 20 closed trades as a card with:
//   - Block number, win/loss count, win rate, total PnL
//   - Edge-warning badge when wins < 5 in a complete block
//   - Expandable list of the individual trades in that block
//
// Also shows a rolling-window selector so the user can inspect any
// consecutive 20-trade window (not just hard blocks).
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/theme.dart';
import '../models/trade.dart';
import '../providers/trade_block_provider.dart';
import '../providers/trades_provider.dart';

class TradeBlocksScreen extends ConsumerStatefulWidget {
  const TradeBlocksScreen({super.key});

  @override
  ConsumerState<TradeBlocksScreen> createState() => _TradeBlocksScreenState();
}

class _TradeBlocksScreenState extends ConsumerState<TradeBlocksScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Block Analytics'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Blocks'),
            Tab(text: 'Rolling Window'),
          ],
          indicatorColor: AppTheme.profitColor,
          labelColor: AppTheme.profitColor,
          unselectedLabelColor: AppTheme.neutralColor,
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          _BlocksTab(),
          _RollingWindowTab(),
        ],
      ),
    );
  }
}

// ── Sequential blocks tab ──────────────────────────────────────────────────────
class _BlocksTab extends ConsumerWidget {
  const _BlocksTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocksAsync = ref.watch(blockWinRateProvider);

    return blocksAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (blocks) {
        if (blocks.isEmpty) {
          return const Center(
            child: Text(
              'No closed trades yet.\nBlocks appear after your first closed trade.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.neutralColor),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: blocks.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (_, i) => _BlockCard(block: blocks[i]),
        );
      },
    );
  }
}

class _BlockCard extends StatefulWidget {
  final TradeBlock block;
  const _BlockCard({required this.block});

  @override
  State<_BlockCard> createState() => _BlockCardState();
}

class _BlockCardState extends State<_BlockCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final b = widget.block;
    final winRatePct = (b.winRate * 100).toStringAsFixed(0);
    final pnlColor =
        b.totalPnl >= 0 ? AppTheme.profitColor : AppTheme.lossColor;
    final winRateColor = b.winRate >= 0.25 ? AppTheme.profitColor : AppTheme.lossColor;

    return Card(
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  // Block number
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: b.edgeWarning
                          ? AppTheme.lossColor.withValues(alpha: 0.15)
                          : AppTheme.cardColor,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: b.edgeWarning
                            ? AppTheme.lossColor.withValues(alpha: 0.5)
                            : AppTheme.borderColor,
                      ),
                    ),
                    child: Center(
                      child: Text(
                        '#${b.blockNumber}',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                          color: b.edgeWarning
                              ? AppTheme.lossColor
                              : Colors.white,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              '${b.wins}W / ${b.losses}L',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 15),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '$winRatePct% win rate',
                              style: TextStyle(color: winRateColor, fontSize: 13),
                            ),
                            if (b.edgeWarning) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppTheme.lossColor.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text(
                                  'EDGE WARNING',
                                  style: TextStyle(
                                    color: AppTheme.lossColor,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Text(
                              '${b.trades.length} trades',
                              style: const TextStyle(
                                  color: AppTheme.neutralColor, fontSize: 12),
                            ),
                            if (!b.isComplete)
                              const Text(
                                ' · in progress',
                                style: TextStyle(
                                    color: AppTheme.neutralColor, fontSize: 12),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '${b.totalPnl >= 0 ? '+' : ''}\$${b.totalPnl.toStringAsFixed(0)}',
                    style: TextStyle(
                        color: pnlColor,
                        fontWeight: FontWeight.w700,
                        fontSize: 15),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    color: AppTheme.neutralColor,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            const Divider(height: 1),
            ...b.trades.map((t) => _TradeRow(trade: t)),
            const SizedBox(height: 4),
          ],
        ],
      ),
    );
  }
}

class _TradeRow extends StatelessWidget {
  final Trade trade;
  const _TradeRow({required this.trade});

  @override
  Widget build(BuildContext context) {
    final pnl = trade.realizedPnl;
    final pnlColor = pnl == null
        ? AppTheme.neutralColor
        : pnl >= 0
            ? AppTheme.profitColor
            : AppTheme.lossColor;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: pnlColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Text(trade.ticker,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          const SizedBox(width: 6),
          Text(
            trade.optionType.name.toUpperCase(),
            style: TextStyle(color: pnlColor, fontSize: 11),
          ),
          const Spacer(),
          if (trade.closedAt != null)
            Text(
              DateFormat('MMM d').format(trade.closedAt!),
              style:
                  const TextStyle(color: AppTheme.neutralColor, fontSize: 12),
            ),
          const SizedBox(width: 12),
          Text(
            pnl != null
                ? '${pnl >= 0 ? '+' : ''}\$${pnl.toStringAsFixed(0)}'
                : '—',
            style: TextStyle(
                color: pnlColor,
                fontWeight: FontWeight.w600,
                fontSize: 13),
          ),
        ],
      ),
    );
  }
}

// ── Rolling window tab ─────────────────────────────────────────────────────────
class _RollingWindowTab extends ConsumerStatefulWidget {
  const _RollingWindowTab();

  @override
  ConsumerState<_RollingWindowTab> createState() => _RollingWindowTabState();
}

class _RollingWindowTabState extends ConsumerState<_RollingWindowTab> {
  int _startIndex = 0;

  @override
  Widget build(BuildContext context) {
    final closedAsync = ref.watch(closedTradesProvider);

    return closedAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (allClosed) {
        final sorted = [...allClosed]
          ..sort((a, b) => (a.closedAt ?? a.openedAt)
              .compareTo(b.closedAt ?? b.openedAt));

        if (sorted.length < 2) {
          return const Center(
            child: Text(
              'Need at least 2 closed trades.',
              style: TextStyle(color: AppTheme.neutralColor),
            ),
          );
        }

        final maxStart = sorted.length > 20 ? sorted.length - 20 : 0;
        final windowEnd =
            (_startIndex + 20) > sorted.length ? sorted.length : _startIndex + 20;
        final window = sorted.sublist(_startIndex, windowEnd);
        final windowBlock = TradeBlock(blockNumber: 0, trades: window);

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Window slider
            Row(
              children: [
                const Text('Start: ', style: TextStyle(color: AppTheme.neutralColor)),
                Expanded(
                  child: Slider(
                    value: _startIndex.toDouble(),
                    min: 0,
                    max: maxStart.toDouble(),
                    divisions: maxStart > 0 ? maxStart : 1,
                    activeColor: AppTheme.profitColor,
                    onChanged: maxStart > 0
                        ? (v) => setState(() => _startIndex = v.round())
                        : null,
                  ),
                ),
                Text(
                  'Trades ${_startIndex + 1}–$windowEnd',
                  style:
                      const TextStyle(color: AppTheme.neutralColor, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Summary card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _Stat('Wins', '${windowBlock.wins}',
                            AppTheme.profitColor),
                        _Stat('Losses', '${windowBlock.losses}',
                            AppTheme.lossColor),
                        _Stat(
                          'Win Rate',
                          '${(windowBlock.winRate * 100).toStringAsFixed(0)}%',
                          windowBlock.winRate >= 0.25
                              ? AppTheme.profitColor
                              : AppTheme.lossColor,
                        ),
                        _Stat(
                          'P&L',
                          '${windowBlock.totalPnl >= 0 ? '+' : ''}\$${windowBlock.totalPnl.toStringAsFixed(0)}',
                          windowBlock.totalPnl >= 0
                              ? AppTheme.profitColor
                              : AppTheme.lossColor,
                        ),
                      ],
                    ),
                    if (windowBlock.edgeWarning) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppTheme.lossColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: AppTheme.lossColor.withValues(alpha: 0.4)),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.warning_amber_rounded,
                                color: AppTheme.lossColor, size: 16),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Win rate below 25% — trade the next 20 cautiously. Your edge may be eroding.',
                                style: TextStyle(
                                    color: AppTheme.lossColor, fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Trade list
            ...window.map((t) => _TradeRow(trade: t)),
          ],
        );
      },
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _Stat(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value,
            style: TextStyle(
                color: color, fontWeight: FontWeight.w800, fontSize: 18)),
        const SizedBox(height: 2),
        Text(label,
            style:
                const TextStyle(color: AppTheme.neutralColor, fontSize: 11)),
      ],
    );
  }
}
