// =============================================================================
// features/trades/screens/trades_screen.dart — Trade log with open/closed tabs
// =============================================================================
// Widgets defined here:
//   • TradesScreen  (ConsumerStatefulWidget) — scaffold + TabBar (Open / Closed)
//                                              + FAB "New Trade" → /trades/add
//                                              + refresh button → refreshAllMarks
//   • _TradeList    (ConsumerWidget)         — filtered ListView of _TradeCard;
//                                              pull-to-refresh via tradesProvider
//   • _TradeCard    (ConsumerWidget)         — tappable card per trade showing:
//                                              ticker, CALL/PUT badge, strategy badge,
//                                              duration flag (amber after 5 days),
//                                              DTE warning (red when < 7 days),
//                                              live unrealized P&L (open trades),
//                                              TP/SL proximity bar (when levels set),
//                                              entry→exit price, realized PnL
//   • _TpSlBar      — LinearProgressIndicator from SL → TP with current mark tick
//   • _Badge        — colored pill label (option type or strategy)
//   • _InfoChip     — icon + text chip (strike, expiration, contracts)
//
// Providers consumed:
//   • tradesProvider      — all trades
//   • liveMarksProvider   — session-only Map<tradeId, currentMark>
//   • refreshAllMarks()   — bulk mark fetcher (called on refresh button)
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/app_menu_button.dart';
import '../models/trade.dart';
import '../providers/live_marks_provider.dart';
import '../providers/trade_block_provider.dart';
import '../providers/trades_provider.dart';
import 'csv_import_screen.dart';
import 'trade_blocks_screen.dart';

class TradesScreen extends ConsumerStatefulWidget {
  const TradesScreen({super.key});

  @override
  ConsumerState<TradesScreen> createState() => _TradesScreenState();
}

class _TradesScreenState extends ConsumerState<TradesScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  bool _refreshing = false;

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

  Future<void> _refreshMarks() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    final tradesAsync = ref.read(tradesProvider);
    final open = tradesAsync.valueOrNull
            ?.where((t) => t.status == TradeStatus.open)
            .toList() ??
        [];
    await refreshAllMarks(open, ref);
    if (mounted) setState(() => _refreshing = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trade Log'),
        actions: [
          // Live mark refresh
          _refreshing
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : IconButton(
                  icon: const Icon(Icons.sync_rounded),
                  tooltip: 'Refresh live marks',
                  onPressed: _refreshMarks,
                ),
          IconButton(
            icon: const Icon(Icons.upload_file_outlined),
            tooltip: 'Import CSV',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CsvImportScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.analytics_outlined),
            tooltip: 'Block Analytics',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const TradeBlocksScreen()),
            ),
          ),
          const AppMenuButton(),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Open'),
            Tab(text: 'Closed'),
          ],
          indicatorColor: AppTheme.profitColor,
          labelColor: AppTheme.profitColor,
          unselectedLabelColor: AppTheme.neutralColor,
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/trades/add'),
        icon: const Icon(Icons.add),
        label: const Text('New Trade'),
        backgroundColor: AppTheme.profitColor,
        foregroundColor: Colors.black,
      ),
      body: Column(
        children: [
          _EdgeWarningBanner(),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _TradeList(filter: TradeStatus.open),
                _TradeList(filter: TradeStatus.closed),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Trade list ────────────────────────────────────────────────────────────────

class _TradeList extends ConsumerWidget {
  final TradeStatus filter;
  const _TradeList({required this.filter});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncTrades = ref.watch(tradesProvider);

    return asyncTrades.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (allTrades) {
        final trades = filter == TradeStatus.open
            ? allTrades.where((t) => t.status == TradeStatus.open).toList()
            : allTrades.where((t) => t.status != TradeStatus.open).toList();

        if (trades.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.show_chart,
                    size: 48, color: AppTheme.neutralColor),
                const SizedBox(height: 12),
                Text(
                  filter == TradeStatus.open
                      ? 'No open trades.\nHit + to log one.'
                      : 'No closed trades yet.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppTheme.neutralColor),
                ),
              ],
            ),
          );
        }

        return RefreshIndicator(
          onRefresh: () => ref.refresh(tradesProvider.future),
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: trades.length,
            separatorBuilder: (context, _) => const SizedBox(height: 10),
            itemBuilder: (context, i) => _TradeCard(trade: trades[i]),
          ),
        );
      },
    );
  }
}

// ── Trade card ────────────────────────────────────────────────────────────────

class _TradeCard extends ConsumerWidget {
  final Trade trade;
  const _TradeCard({required this.trade});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOpen = trade.status == TradeStatus.open;

    // Live mark from session overlay.
    final marks = ref.watch(liveMarksProvider);
    final currentMark = marks.markFor(trade.id);

    // Duration metrics.
    final daysHeld = DateTime.now().difference(trade.openedAt).inDays;
    final dteRemaining = trade.expiration.difference(DateTime.now()).inDays;
    final isDurationWarning = isOpen && daysHeld >= 5;
    final isDteWarning = isOpen && dteRemaining < 7 && dteRemaining >= 0;

    // P&L display.
    final realizedPnl = trade.realizedPnl;
    final unrealizedPnl =
        (isOpen && currentMark != null) ? trade.unrealizedPnl(currentMark) : null;
    final displayPnl = realizedPnl ?? unrealizedPnl;
    final pnlColor = displayPnl == null
        ? AppTheme.neutralColor
        : displayPnl >= 0
            ? AppTheme.profitColor
            : AppTheme.lossColor;

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isDurationWarning
            ? const BorderSide(color: Colors.amber, width: 1.5)
            : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push('/trades/${trade.id}', extra: trade),
        onLongPress: () => context.push('/ticker/${trade.ticker}'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Row 1: Ticker · badges · duration chip · P&L ─────────────
              Row(
                children: [
                  Text(
                    trade.ticker,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(width: 8),
                  _Badge(
                    label: trade.optionType.name.toUpperCase(),
                    color: trade.optionType == OptionType.call
                        ? AppTheme.profitColor
                        : AppTheme.lossColor,
                  ),
                  const SizedBox(width: 6),
                  _Badge(
                    label: trade.strategy.label,
                    color: AppTheme.neutralColor,
                  ),
                  if (isDurationWarning) ...[
                    const SizedBox(width: 6),
                    _Badge(
                      label: 'Day $daysHeld',
                      color: Colors.amber,
                    ),
                  ],
                  const Spacer(),
                  if (displayPnl != null) ...[
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '${displayPnl >= 0 ? '+' : ''}\$${displayPnl.toStringAsFixed(0)}',
                          style: TextStyle(
                            color: pnlColor,
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                        if (unrealizedPnl != null)
                          Text(
                            'live',
                            style: TextStyle(
                                color: pnlColor.withValues(alpha: 0.6),
                                fontSize: 10),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),

              // ── Row 2: Strike · Expiry · Contracts · DTE warning ─────────
              Row(
                children: [
                  _InfoChip(
                    icon: Icons.attach_money,
                    label: '\$${trade.strike.toStringAsFixed(0)} strike',
                  ),
                  const SizedBox(width: 8),
                  _InfoChip(
                    icon: Icons.calendar_today,
                    label: DateFormat('MMM d').format(trade.expiration),
                  ),
                  const SizedBox(width: 8),
                  _InfoChip(
                    icon: Icons.confirmation_number_outlined,
                    label: '${trade.contracts}x',
                  ),
                  if (isDteWarning) ...[
                    const SizedBox(width: 8),
                    _Badge(
                      label: 'DTE: $dteRemaining',
                      color: AppTheme.lossColor,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),

              // ── Row 3: Entry / exit price · realized % ───────────────────
              Row(
                children: [
                  Text(
                    'Entry: \$${trade.entryPrice.toStringAsFixed(2)}',
                    style: const TextStyle(
                        color: AppTheme.neutralColor, fontSize: 13),
                  ),
                  if (trade.exitPrice != null) ...[
                    const Text(' → ',
                        style: TextStyle(
                            color: AppTheme.neutralColor, fontSize: 13)),
                    Text(
                      'Exit: \$${trade.exitPrice!.toStringAsFixed(2)}',
                      style: const TextStyle(
                          color: AppTheme.neutralColor, fontSize: 13),
                    ),
                  ],
                  if (currentMark != null && isOpen) ...[
                    const Text(' · ',
                        style: TextStyle(
                            color: AppTheme.neutralColor, fontSize: 13)),
                    Text(
                      'Mark: \$${currentMark.toStringAsFixed(2)}',
                      style: const TextStyle(
                          color: AppTheme.neutralColor, fontSize: 13),
                    ),
                  ],
                  const Spacer(),
                  if (realizedPnl != null && trade.pnlPercent != null)
                    Text(
                      '${trade.pnlPercent! >= 0 ? '+' : ''}${trade.pnlPercent!.toStringAsFixed(1)}%',
                      style: TextStyle(
                        color: pnlColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),

              // ── TP/SL proximity bar ──────────────────────────────────────
              if (isOpen &&
                  currentMark != null &&
                  trade.stopLoss != null &&
                  trade.takeProfit != null) ...[
                const SizedBox(height: 10),
                _TpSlBar(
                  currentMark: currentMark,
                  stopLoss: trade.stopLoss!,
                  takeProfit: trade.takeProfit!,
                  entryPrice: trade.entryPrice,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ── TP/SL proximity bar ───────────────────────────────────────────────────────

class _TpSlBar extends StatelessWidget {
  final double currentMark;
  final double stopLoss;
  final double takeProfit;
  final double entryPrice;

  const _TpSlBar({
    required this.currentMark,
    required this.stopLoss,
    required this.takeProfit,
    required this.entryPrice,
  });

  @override
  Widget build(BuildContext context) {
    final range = takeProfit - stopLoss;
    final progress =
        range <= 0 ? 0.5 : ((currentMark - stopLoss) / range).clamp(0.0, 1.0);
    final entryPct =
        range <= 0 ? 0.5 : ((entryPrice - stopLoss) / range).clamp(0.0, 1.0);

    final barColor = progress >= entryPct
        ? AppTheme.profitColor
        : AppTheme.lossColor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Labels
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'SL \$${stopLoss.toStringAsFixed(2)}',
              style: const TextStyle(
                  color: AppTheme.lossColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w600),
            ),
            Text(
              'TP \$${takeProfit.toStringAsFixed(2)}',
              style: const TextStyle(
                  color: AppTheme.profitColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // Bar with entry tick overlay
        Stack(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                backgroundColor: AppTheme.lossColor.withValues(alpha: 0.2),
                valueColor: AlwaysStoppedAnimation<Color>(barColor),
              ),
            ),
            // Entry price tick mark
            Positioned(
              left: entryPct *
                  (MediaQuery.sizeOf(context).width - 64), // approx bar width
              top: 0,
              bottom: 0,
              child: Container(
                width: 2,
                color: Colors.white54,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Center(
          child: Text(
            'Mark \$${currentMark.toStringAsFixed(2)}  '
            '(${(progress * 100).toStringAsFixed(0)}% to TP)',
            style: TextStyle(
                color: barColor, fontSize: 10),
          ),
        ),
      ],
    );
  }
}

// ── Edge warning banner ───────────────────────────────────────────────────────

class _EdgeWarningBanner extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final eroding = ref.watch(edgeErodingProvider);
    if (!eroding) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: AppTheme.lossColor.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded,
              color: AppTheme.lossColor, size: 18),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Edge warning: last 20-trade block had fewer than 5 wins. Trade cautiously.',
              style: TextStyle(color: AppTheme.lossColor, fontSize: 13),
            ),
          ),
          GestureDetector(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const TradeBlocksScreen()),
            ),
            child: const Text(
              'View →',
              style: TextStyle(
                  color: AppTheme.lossColor,
                  fontWeight: FontWeight.w700,
                  fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Shared primitives ─────────────────────────────────────────────────────────

class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  const _Badge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style:
            TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _InfoChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: AppTheme.neutralColor),
        const SizedBox(width: 4),
        Text(label,
            style:
                const TextStyle(color: AppTheme.neutralColor, fontSize: 13)),
      ],
    );
  }
}
