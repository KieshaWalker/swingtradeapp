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
import '../models/macro_indicator.dart';
import '../models/trade.dart';
import '../providers/live_marks_provider.dart';
import '../providers/macro_indicator_provider.dart';
import '../providers/trade_block_provider.dart';
import '../providers/trades_provider.dart';

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
            onPressed: () => context.push('/trades/import'),
          ),
          IconButton(
            icon: const Icon(Icons.analytics_outlined),
            tooltip: 'Block Analytics',
            onPressed: () => context.push('/trades/blocks'),
          ),
          const _MacroScoreBadge(),
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
          const _MacroBanner(),
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
        List<Trade> trades;
        if (filter == TradeStatus.open) {
          trades = allTrades.where((t) => t.status == TradeStatus.open).toList();
        } else {
          trades = allTrades.where((t) => t.status != TradeStatus.open).toList()
            ..sort((a, b) {
              final aDate = a.closedAt;
              final bDate = b.closedAt;
              if (aDate == null && bDate == null) return 0;
              if (aDate == null) return 1;
              if (bDate == null) return -1;
              return bDate.compareTo(aDate);
            });
        }

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

        if (filter != TradeStatus.open) {
          return RefreshIndicator(
            onRefresh: () => ref.refresh(tradesProvider.future),
            child: GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 1.1,
              ),
              itemCount: trades.length,
              itemBuilder: (context, i) => _TradeGridCard(trade: trades[i]),
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

// ── Closed trade grid card ────────────────────────────────────────────────────

class _TradeGridCard extends StatelessWidget {
  final Trade trade;
  const _TradeGridCard({required this.trade});

  @override
  Widget build(BuildContext context) {
    final pnl = trade.realizedPnl;
    final pnlPct = trade.pnlPercent;
    final pnlColor = pnl == null
        ? AppTheme.neutralColor
        : pnl >= 0
            ? AppTheme.profitColor
            : AppTheme.lossColor;
    final closedLabel = trade.closedAt != null
        ? DateFormat('MMM d').format(trade.closedAt!)
        : '';

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push('/trades/${trade.id}', extra: trade),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Ticker + type badge
              Row(
                children: [
                  Expanded(
                    child: Text(
                      trade.ticker,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w800),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _Badge(
                    label: trade.optionType.name.toUpperCase(),
                    color: trade.optionType == OptionType.call
                        ? AppTheme.profitColor
                        : AppTheme.lossColor,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // Strategy + closed date
              Row(
                children: [
                  _Badge(
                    label: trade.strategy.label,
                    color: AppTheme.neutralColor,
                  ),
                  const Spacer(),
                  Text(
                    closedLabel,
                    style: const TextStyle(
                        color: AppTheme.neutralColor, fontSize: 11),
                  ),
                ],
              ),
              const Spacer(),
              // P&L
              if (pnl != null) ...[
                Text(
                  '${pnl >= 0 ? '+' : ''}\$${pnl.toStringAsFixed(0)}',
                  style: TextStyle(
                    color: pnlColor,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (pnlPct != null)
                  Text(
                    '${pnlPct >= 0 ? '+' : ''}${pnlPct.toStringAsFixed(1)}%',
                    style: TextStyle(
                        color: pnlColor.withValues(alpha: 0.75), fontSize: 12),
                  ),
              ],
              const SizedBox(height: 4),
              // Entry → exit
              Text(
                '\$${trade.entryPrice.toStringAsFixed(2)} → \$${trade.exitPrice?.toStringAsFixed(2) ?? '—'}',
                style: const TextStyle(
                    color: AppTheme.neutralColor, fontSize: 11),
                overflow: TextOverflow.ellipsis,
              ),
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
            onTap: () => context.push('/trades/blocks'),
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

// ── Macro score badge (AppBar) ────────────────────────────────────────────────

class _MacroScoreBadge extends ConsumerWidget {
  const _MacroScoreBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final indicators = ref.watch(macroIndicatorsProvider).valueOrNull;
    if (indicators == null || indicators.isEmpty) return const SizedBox.shrink();
    final score = ref.watch(macroNetScoreProvider);
    if (score == 0) return const SizedBox.shrink();
    final isPositive = score > 0;
    final color = isPositive ? AppTheme.profitColor : AppTheme.lossColor;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Center(
        child: Text(
          '${isPositive ? '▲' : '▼'} ${isPositive ? '+' : ''}$score%',
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

// ── Macro collapsible banner ──────────────────────────────────────────────────

class _MacroBanner extends ConsumerStatefulWidget {
  const _MacroBanner();

  @override
  ConsumerState<_MacroBanner> createState() => _MacroBannerState();
}

class _MacroBannerState extends ConsumerState<_MacroBanner> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final asyncIndicators = ref.watch(macroIndicatorsProvider);
    final indicators = asyncIndicators.valueOrNull ?? [];
    final score = ref.watch(macroNetScoreProvider);
    final scoreColor = score >= 0 ? AppTheme.profitColor : AppTheme.lossColor;
    // Map score to 0–1: 0 at center, ±100 at edges.
    final barValue = ((score / 100) * 0.5 + 0.5).clamp(0.0, 1.0);

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.elevatedColor,
        border: Border(
          bottom: BorderSide(color: AppTheme.borderColor.withValues(alpha: 0.4)),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Collapsed row ────────────────────────────────────────────────
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  const Text(
                    'MACRO',
                    style: TextStyle(
                      color: AppTheme.neutralColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: barValue,
                        minHeight: 5,
                        backgroundColor: AppTheme.lossColor.withValues(alpha: 0.25),
                        valueColor: AlwaysStoppedAnimation<Color>(
                          scoreColor.withValues(alpha: 0.8),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '${score >= 0 ? '+' : ''}$score%',
                    style: TextStyle(
                      color: scoreColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${indicators.length} factor${indicators.length == 1 ? '' : 's'}',
                    style: const TextStyle(
                      color: AppTheme.neutralColor,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: AppTheme.neutralColor,
                  ),
                ],
              ),
            ),
          ),

          // ── Expanded list ────────────────────────────────────────────────
          if (_expanded) ...[
            Divider(height: 1, color: AppTheme.borderColor.withValues(alpha: 0.4)),
            if (asyncIndicators.isLoading)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              ...indicators.map((ind) => _IndicatorRow(
                    indicator: ind,
                    onTap: () => _showSheet(context, indicator: ind),
                  )),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: TextButton.icon(
                  onPressed: () => _showSheet(context),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add factor'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.neutralColor,
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  void _showSheet(BuildContext context, {MacroIndicator? indicator}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.elevatedColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _IndicatorSheet(indicator: indicator),
    );
  }
}

// ── Single indicator row ──────────────────────────────────────────────────────

class _IndicatorRow extends StatelessWidget {
  final MacroIndicator indicator;
  final VoidCallback onTap;
  const _IndicatorRow({required this.indicator, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color =
        indicator.isBullish ? AppTheme.profitColor : AppTheme.lossColor;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                indicator.name,
                style: const TextStyle(fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: color.withValues(alpha: 0.35)),
              ),
              child: Text(
                '${indicator.weight >= 0 ? '+' : ''}${indicator.weight}%',
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.edit_outlined,
                size: 14, color: AppTheme.neutralColor),
          ],
        ),
      ),
    );
  }
}

// ── Add / edit sheet ──────────────────────────────────────────────────────────

class _IndicatorSheet extends ConsumerStatefulWidget {
  final MacroIndicator? indicator;
  const _IndicatorSheet({this.indicator});

  @override
  ConsumerState<_IndicatorSheet> createState() => _IndicatorSheetState();
}

class _IndicatorSheetState extends ConsumerState<_IndicatorSheet> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _pctCtrl;
  late bool _isBullish;

  @override
  void initState() {
    super.initState();
    final ind = widget.indicator;
    _nameCtrl = TextEditingController(text: ind?.name ?? '');
    _pctCtrl = TextEditingController(
      text: ind != null ? ind.weight.abs().toString() : '',
    );
    _isBullish = ind?.isBullish ?? true;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _pctCtrl.dispose();
    super.dispose();
  }

  int get _signedWeight {
    final abs = (int.tryParse(_pctCtrl.text) ?? 0).clamp(1, 100);
    return _isBullish ? abs : -abs;
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.indicator != null;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Handle
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: AppTheme.borderColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Text(
            isEdit ? 'Edit Factor' : 'Add Macro Factor',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),

          // Name field
          TextField(
            controller: _nameCtrl,
            autofocus: !isEdit,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Factor name'),
          ),
          const SizedBox(height: 16),

          // Direction toggle
          Row(
            children: [
              Expanded(
                child: _DirectionButton(
                  label: 'Bullish',
                  selected: _isBullish,
                  color: AppTheme.profitColor,
                  onTap: () => setState(() => _isBullish = true),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _DirectionButton(
                  label: 'Bearish',
                  selected: !_isBullish,
                  color: AppTheme.lossColor,
                  onTap: () => setState(() => _isBullish = false),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Percentage field
          TextField(
            controller: _pctCtrl,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'Weight',
              suffixText: '%',
              helperText: '1 – 100',
              prefixText:
                  _isBullish ? '+' : '-',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 24),

          // Save button
          FilledButton(
            onPressed: () async {
              final name = _nameCtrl.text.trim();
              final pct = int.tryParse(_pctCtrl.text);
              if (name.isEmpty || pct == null || pct < 1 || pct > 100) return;
              final notifier =
                  ref.read(macroIndicatorNotifierProvider.notifier);
              if (isEdit) {
                await notifier.edit(
                    widget.indicator!.id, name, _signedWeight);
              } else {
                await notifier.add(name, _signedWeight);
              }
              if (context.mounted) Navigator.pop(context);
            },
            style: FilledButton.styleFrom(
              backgroundColor:
                  _isBullish ? AppTheme.profitColor : AppTheme.lossColor,
              foregroundColor: Colors.black,
            ),
            child: const Text('Save'),
          ),

          // Delete button (edit mode only)
          if (isEdit) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: AppTheme.elevatedColor,
                    title: const Text('Delete factor?'),
                    content: Text(
                        '"${widget.indicator!.name}" will be removed.'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text('Delete',
                            style: TextStyle(
                                color: Theme.of(ctx).colorScheme.error)),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  await ref
                      .read(macroIndicatorNotifierProvider.notifier)
                      .delete(widget.indicator!.id);
                  if (context.mounted) Navigator.pop(context);
                }
              },
              style:
                  TextButton.styleFrom(foregroundColor: AppTheme.lossColor),
              child: const Text('Delete factor'),
            ),
          ],
        ],
      ),
    );
  }
}

class _DirectionButton extends StatelessWidget {
  final String label;
  final bool selected;
  final Color color;
  final VoidCallback onTap;
  const _DirectionButton({
    required this.label,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? color : AppTheme.borderColor,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: selected ? color : AppTheme.neutralColor,
              fontWeight:
                  selected ? FontWeight.w700 : FontWeight.w400,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}
