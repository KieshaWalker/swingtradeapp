// =============================================================================
// features/ticker_profile/screens/ticker_profile_screen.dart
// =============================================================================
// Full-screen per-ticker profile. Pushed from:
//   • TradeDetailScreen   — AppBar action icon (stock chart icon)
//   • TradesScreen        — _TradeCard long-press
//   • DashboardScreen     — _OpenTradeRow long-press
//   • TickerDashboardScreen — tap any ticker card
//
// Route: /ticker/:symbol  (child of /ticker, no shell — back → TickerDashboard)
//
// Data sources per tab:
//   ── Overview ────────────────────────────────────────────────────────────
//   AppBar price      FMP  GET /quote?symbol=          (quoteProvider)
//   Next earnings     FMP  GET /earnings-calendar      (tickerNextEarningsProvider)
//   Notes             Supabase  ticker_profile_notes   (tickerNotesProvider)
//   Insider buys      Supabase  ticker_insider_buys    (tickerInsiderBuysProvider)
//                     (raw Form 4 discovery → SEC /live-query-api formType:4)
//   Earnings history  Supabase  ticker_earnings_reactions (tickerEarningsReactionsProvider)
//                     (EPS estimates pre-filled from FMP /earnings-calendar)
//
//   ── My Edge ─────────────────────────────────────────────────────────────
//   All analytics     Supabase  trades table — computed locally, no API calls
//                     (tickerAnalyticsProvider → TickerTradeAnalytics.compute())
//   TODO: IV Rank history from Kalshi or broker feed for IVR bucketing
//
//   ── Levels ──────────────────────────────────────────────────────────────
//   S/R levels        Supabase  ticker_support_resistance (tickerSRLevelsProvider)
//
//   ── Timeline ────────────────────────────────────────────────────────────
//   Merged feed from all 6 sources (tickerTimelineProvider):
//     Supabase  trades / notes / insider buys / earnings reactions / S/R levels
//     SEC EDGAR secfilingdata.com  POST /live-query-api  (secFilingsForTickerProvider)
//   TODO: Kalshi market events — add kalshiMarketProvider(symbol) here
//
// FAB per tab:
//   Overview  → add note sheet (saves to Supabase)
//   Levels    → add S/R level sheet (saves to Supabase)
// =============================================================================
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme.dart';
import '../../../services/fmp/fmp_models.dart';
import '../../../services/fmp/fmp_providers.dart' show tickerNextEarningsProvider;
import '../../../services/schwab/schwab_providers.dart';
import '../../trades/models/trade.dart';
import '../models/ticker_profile_models.dart';
import '../providers/ticker_profile_notifier.dart';
import '../providers/ticker_profile_providers.dart';
import '../widgets/add_earnings_reaction_sheet.dart';
import '../widgets/paste_form4_sheet.dart';
import '../widgets/add_sr_level_sheet.dart';
import '../widgets/add_ticker_note_sheet.dart';

class TickerProfileScreen extends ConsumerStatefulWidget {
  final String symbol;
  const TickerProfileScreen({super.key, required this.symbol});

  @override
  ConsumerState<TickerProfileScreen> createState() =>
      _TickerProfileScreenState();
}

class _TickerProfileScreenState extends ConsumerState<TickerProfileScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 5, vsync: this);
    _tabs.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  String get _sym => widget.symbol.toUpperCase();

  void _showSheet(Widget sheet) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.elevatedColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => sheet,
    );
  }

  Widget? _fab() {
    switch (_tabs.index) {
      case 0:
        return FloatingActionButton(
          heroTag: 'note_fab',
          onPressed: () =>
              _showSheet(AddTickerNoteSheet(symbol: _sym)),
          child: const Icon(Icons.note_add_outlined),
        );
      case 2:
        return FloatingActionButton(
          heroTag: 'sr_fab',
          onPressed: () =>
              _showSheet(AddSRLevelSheet(symbol: _sym)),
          child: const Icon(Icons.add),
        );
      case 4:
        return FloatingActionButton(
          heroTag: 'insider_fab',
          onPressed: () => _showSheet(PasteForm4Sheet(symbol: _sym)),
          child: const Icon(Icons.upload_file_outlined),
        );
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final quote = ref.watch(quoteProvider(_sym));

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_sym),
            quote.whenOrNull(
                  data: (q) => q != null
                      ? Text(
                          '\$${q.price.toStringAsFixed(2)}  ${q.isPositive ? '+' : ''}${q.changePercent.toStringAsFixed(2)}%',
                          style: TextStyle(
                            fontSize: 13,
                            color: q.isPositive
                                ? AppTheme.profitColor
                                : AppTheme.lossColor,
                          ),
                        )
                      : null,
                ) ??
                const SizedBox.shrink(),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.candlestick_chart_rounded),
            tooltip: 'Options Chain',
            onPressed: () => context.push('/ticker/$_sym/chains'),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Overview'),
            Tab(text: 'My Edge'),
            Tab(text: 'Levels'),
            Tab(text: 'Timeline'),
            Tab(text: 'Insiders'),
          ],
        ),
      ),
      floatingActionButton: _fab(),
      body: TabBarView(
        controller: _tabs,
        children: [
          _OverviewTab(
            symbol: _sym,
            onAddInsider: () => _showSheet(PasteForm4Sheet(symbol: _sym)),
            onAddEarnings: () => _showSheet(AddEarningsReactionSheet(symbol: _sym)),
            onSeeAllInsiders: () => _tabs.animateTo(4),
          ),
          _MyEdgeTab(symbol: _sym),
          _LevelsTab(symbol: _sym),
          _TimelineTab(symbol: _sym),
          _InsidersTab(symbol: _sym),
        ],
      ),
    );
  }
}

// ─── Overview Tab ─────────────────────────────────────────────────────────────

class _OverviewTab extends ConsumerWidget {
  final String symbol;
  final VoidCallback onAddInsider;
  final VoidCallback onAddEarnings;
  final VoidCallback onSeeAllInsiders;

  const _OverviewTab({
    required this.symbol,
    required this.onAddInsider,
    required this.onAddEarnings,
    required this.onSeeAllInsiders,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nextEarnings = ref.watch(tickerNextEarningsProvider(symbol));
    final insiders = ref.watch(tickerInsiderBuysProvider(symbol));
    final earningsHistory = ref.watch(tickerEarningsReactionsProvider(symbol));
    final notes = ref.watch(tickerNotesProvider(symbol));

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Next earnings card
        _SectionHeader('Next Earnings'),
        nextEarnings.when(
          loading: () => const _LoadingCard(),
          error: (e, _) => const _ErrorCard('Could not load earnings date'),
          data: (e) => e == null
              ? _EmptyCard('No upcoming earnings in the next 6 months')
              : _EarningsDateCard(e),
        ),
        const SizedBox(height: 20),

        // Insider transactions
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _SectionHeader('Insider Transactions'),
            TextButton.icon(
              onPressed: onAddInsider,
              icon: const Icon(Icons.upload_file_outlined, size: 16),
              label: const Text('Import Form 4'),
            ),
          ],
        ),
        insiders.when(
          loading: () => const _LoadingCard(),
          error: (e, _) =>
              const _ErrorCard('Could not load insider transactions'),
          data: (list) => list.isEmpty
              ? _EmptyCard('No insider transactions logged yet')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ...list
                        .take(3)
                        .map((b) => _InsiderBuyCard(symbol: symbol, buy: b)),
                    TextButton(
                      onPressed: onSeeAllInsiders,
                      child: Text(
                        'See all ${list.length} transaction${list.length == 1 ? '' : 's'} →',
                      ),
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 20),

        // Earnings history
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _SectionHeader('Earnings History'),
            TextButton.icon(
              onPressed: onAddEarnings,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Log Reaction'),
            ),
          ],
        ),
        earningsHistory.when(
          loading: () => const _LoadingCard(),
          error: (e, _) =>const _ErrorCard('Could not load earnings history'),
          data: (list) => list.isEmpty
              ? _EmptyCard('No earnings reactions logged yet')
              : Column(
                  children: list
                      .map((e) => _EarningsReactionCard(symbol: symbol, reaction: e))
                      .toList(),
                ),
        ),
        const SizedBox(height: 20),

        // Notes
        _SectionHeader('Notes'),
        notes.when(
          loading: () => const _LoadingCard(),
          error: (e, _) =>const _ErrorCard('Could not load notes'),
          data: (list) => list.isEmpty
              ? _EmptyCard('No notes yet — tap + to add one')
              : Column(
                  children: list.map((n) => _NoteCard(symbol: symbol, note: n)).toList(),
                ),
        ),
        const SizedBox(height: 80),
      ],
    );
  }
}

// ─── My Edge Tab ──────────────────────────────────────────────────────────────

class _MyEdgeTab extends ConsumerWidget {
  final String symbol;
  const _MyEdgeTab({required this.symbol});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final analytics = ref.watch(tickerAnalyticsProvider(symbol));

    if (!analytics.hasEnoughData) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.bar_chart_outlined,
                  size: 56, color: AppTheme.neutralColor),
              const SizedBox(height: 16),
              Text(
                'Need at least 5 closed trades to generate your edge analysis.',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: AppTheme.neutralColor),
                textAlign: TextAlign.center,
              ),
              if (analytics.totalTrades > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '${analytics.totalTrades} closed trade${analytics.totalTrades == 1 ? '' : 's'} so far',
                    style: const TextStyle(color: AppTheme.neutralColor),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Playbook summary
        if (analytics.playbookSummary != null)
          Container(
            padding: const EdgeInsets.all(16),
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: AppTheme.profitColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: AppTheme.profitColor.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.emoji_events_outlined,
                    color: AppTheme.profitColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    analytics.playbookSummary!,
                    style: const TextStyle(
                      color: AppTheme.profitColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),

        // Top stats
        _EdgeStatsRow(analytics: analytics),
        const SizedBox(height: 20),

        // Monthly P&L chart
        if (analytics.monthlyPnl.isNotEmpty) ...[
          _SectionHeader('Monthly P&L'),
          SizedBox(
            height: 160,
            child: _MonthlyPnlChart(monthlyPnl: analytics.monthlyPnl),
          ),
          const SizedBox(height: 20),
        ],

        // Strategy breakdown
        _SectionHeader('By Strategy'),
        ...(analytics.strategyBreakdown.entries.toList()
              ..sort((a, b) => b.value.count.compareTo(a.value.count)))
            .map((e) => _StrategyRow(strategy: e.key, stats: e.value)),

        const SizedBox(height: 20),

        // Best conditions
        if (analytics.bestDteRange != null ||
            analytics.bestIvRankRange != null) ...[
          _SectionHeader('Best Conditions'),
          if (analytics.bestDteRange != null)
            _ConditionChip(
              label: 'Best DTE',
              value: analytics.bestDteRange!.$2 >= 9999
                  ? '${analytics.bestDteRange!.$1}+ days'
                  : '${analytics.bestDteRange!.$1}–${analytics.bestDteRange!.$2} days',
            ),
          if (analytics.bestIvRankRange != null)
            _ConditionChip(
              label: 'Best IV Rank',
              value:
                  '${analytics.bestIvRankRange!.$1.toStringAsFixed(0)}–${analytics.bestIvRankRange!.$2.toStringAsFixed(0)}',
            ),
        ],
        const SizedBox(height: 80),
      ],
    );
  }
}

// ─── Levels Tab ───────────────────────────────────────────────────────────────

class _LevelsTab extends ConsumerWidget {
  final String symbol;
  const _LevelsTab({required this.symbol});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final levelsAsync = ref.watch(tickerSRLevelsProvider(symbol));

    return levelsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>const Center(child: Text('Could not load levels')),
      data: (all) {
        final active = all.where((l) => l.isActive).toList();
        final invalidated = all.where((l) => !l.isActive).toList();

        if (all.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.horizontal_rule,
                    size: 56, color: AppTheme.neutralColor),
                const SizedBox(height: 16),
                Text('No S/R levels yet — tap + to add one',
                    style: TextStyle(color: AppTheme.neutralColor)),
              ],
            ),
          );
        }

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (active.isNotEmpty) ...[
              _SectionHeader('Active'),
              ...active.map((l) => _SRLevelCard(symbol: symbol, level: l)),
              const SizedBox(height: 16),
            ],
            if (invalidated.isNotEmpty) ...[
              _SectionHeader('Invalidated'),
              ...invalidated
                  .map((l) => _SRLevelCard(symbol: symbol, level: l)),
            ],
            const SizedBox(height: 80),
          ],
        );
      },
    );
  }
}

// ─── Timeline Tab ─────────────────────────────────────────────────────────────

class _TimelineTab extends ConsumerWidget {
  final String symbol;
  const _TimelineTab({required this.symbol});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timeline = ref.watch(tickerTimelineProvider(symbol));

    return timeline.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (events) {
        if (events.isEmpty) {
          return Center(
            child: Text(
              'No events yet — add trades, notes, or levels to start building your timeline.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.neutralColor),
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: events.length,
          itemBuilder: (_, i) => _TimelineEventTile(event: events[i]),
        );
      },
    );
  }
}

// ─── Shared small widgets ─────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: AppTheme.neutralColor,
            fontSize: 12,
            letterSpacing: 1,
          ),
        ),
      );
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard();
  @override
  Widget build(BuildContext context) => const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
}

class _ErrorCard extends StatelessWidget {
  final String message;
  const _ErrorCard(this.message);
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(message,
              style: const TextStyle(color: AppTheme.lossColor)),
        ),
      );
}

class _EmptyCard extends StatelessWidget {
  final String message;
  const _EmptyCard(this.message);
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(message,
              style: const TextStyle(color: AppTheme.neutralColor)),
        ),
      );
}

// ─── Earnings date card ───────────────────────────────────────────────────────

class _EarningsDateCard extends StatelessWidget {
  final FmpEarningsDate earnings;
  const _EarningsDateCard(this.earnings);

  @override
  Widget build(BuildContext context) {
    final d = earnings.date;
    final label =
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.event, color: AppTheme.profitColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  if (earnings.timeLabel.isNotEmpty)
                    Text(earnings.timeLabel,
                        style: const TextStyle(
                            color: AppTheme.neutralColor, fontSize: 12)),
                  if (earnings.epsEstimated != null)
                    Text(
                        'EPS est. ${earnings.epsEstimated!.toStringAsFixed(2)}',
                        style: const TextStyle(
                            color: AppTheme.neutralColor, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Insider activity chart ───────────────────────────────────────────────────

class _InsiderActivityChart extends StatelessWidget {
  final List<TickerInsiderBuy> transactions;
  const _InsiderActivityChart({required this.transactions});

  @override
  Widget build(BuildContext context) {
    // Aggregate shares by month, split buy vs sell
    final buyByMonth = <int, double>{};
    final sellByMonth = <int, double>{};

    for (final t in transactions) {
      final date = t.transactionDate ?? t.filedAt;
      final key = date.year * 100 + date.month;
      final isBuy = t.transactionType == InsiderTransactionType.purchase ||
          t.transactionType == InsiderTransactionType.exercise;
      final isSell = t.transactionType == InsiderTransactionType.sale ||
          t.transactionType == InsiderTransactionType.taxWithholding;
      if (isBuy) buyByMonth[key] = (buyByMonth[key] ?? 0) + t.shares;
      if (isSell) sellByMonth[key] = (sellByMonth[key] ?? 0) + t.shares;
    }

    final allMonths = {
      ...buyByMonth.keys,
      ...sellByMonth.keys,
    }.toList()..sort();
    if (allMonths.isEmpty) return const SizedBox.shrink();

    // Build grouped bars — always two rods per group (buy left, sell right)
    final bars = allMonths.asMap().entries.map((e) {
      final i = e.key;
      final month = e.value;
      final buys = buyByMonth[month] ?? 0.0;
      final sells = sellByMonth[month] ?? 0.0;
      return BarChartGroupData(
        x: i,
        barsSpace: 3,
        barRods: [
          BarChartRodData(
            toY: buys,
            color: AppTheme.profitColor
                .withAlpha(buys > 0 ? 220 : 0),
            width: 9,
            borderRadius: BorderRadius.circular(3),
          ),
          BarChartRodData(
            toY: sells,
            color:
                AppTheme.lossColor.withAlpha(sells > 0 ? 220 : 0),
            width: 9,
            borderRadius: BorderRadius.circular(3),
          ),
        ],
      );
    }).toList();

    String fmtShares(double v) {
      if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
      if (v >= 1000) return '${(v / 1000).toStringAsFixed(0)}k';
      return v.toStringAsFixed(0);
    }

    const monthLabels = [
      '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Legend
        Row(
          children: [
            _LegendDot(color: AppTheme.profitColor, label: 'Buy / Exercise'),
            const SizedBox(width: 16),
            _LegendDot(color: AppTheme.lossColor, label: 'Sell / Withholding'),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 140,
          child: BarChart(
            BarChartData(
              barGroups: bars,
              gridData: const FlGridData(show: false),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                leftTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false)),
                topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false)),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    getTitlesWidget: (v, _) {
                      final idx = v.toInt();
                      if (idx < 0 || idx >= allMonths.length) {
                        return const SizedBox.shrink();
                      }
                      // Skip alternate labels when many months
                      if (allMonths.length > 6 && idx % 2 != 0) {
                        return const SizedBox.shrink();
                      }
                      final key   = allMonths[idx];
                      final year  = key ~/ 100;
                      final month = key % 100;
                      final label = (month == 1 || idx == 0)
                          ? "${monthLabels[month]} '${year % 100}"
                          : monthLabels[month];
                      return Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          label,
                          style: const TextStyle(
                              color: AppTheme.neutralColor,
                              fontSize: 9),
                        ),
                      );
                    },
                  ),
                ),
              ),
              barTouchData: BarTouchData(
                touchTooltipData: BarTouchTooltipData(
                  getTooltipColor: (_) => AppTheme.elevatedColor,
                  getTooltipItem: (group, _, rod, rodIdx) {
                    if (rod.toY == 0) return null;
                    final label = rodIdx == 0 ? 'Buy' : 'Sell';
                    return BarTooltipItem(
                      '$label\n${fmtShares(rod.toY)} sh',
                      TextStyle(
                        color: rodIdx == 0
                            ? AppTheme.profitColor
                            : AppTheme.lossColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label,
            style: const TextStyle(
                color: AppTheme.neutralColor, fontSize: 11)),
      ],
    );
  }
}

// ─── Insider buy card ─────────────────────────────────────────────────────────

class _InsiderBuyCard extends ConsumerWidget {
  final String symbol;
  final TickerInsiderBuy buy;
  const _InsiderBuyCard({required this.symbol, required this.buy});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isBuy = buy.transactionType == InsiderTransactionType.purchase ||
        buy.transactionType == InsiderTransactionType.exercise;
    final isSell = buy.transactionType == InsiderTransactionType.sale ||
        buy.transactionType == InsiderTransactionType.taxWithholding;
    final iconColor = isBuy
        ? AppTheme.profitColor
        : isSell
            ? AppTheme.lossColor
            : AppTheme.neutralColor;
    final icon = isBuy
        ? Icons.trending_up
        : isSell
            ? Icons.trending_down
            : Icons.swap_horiz;
    final val = buy.totalValue != null
        ? ' · \$${(buy.totalValue! / 1000).toStringAsFixed(0)}k'
        : '';
    final dateStr =
        '${buy.filedAt.year}-${buy.filedAt.month.toString().padLeft(2, '0')}-${buy.filedAt.day.toString().padLeft(2, '0')}';
    return Card(
      child: ListTile(
        leading: Icon(icon, color: iconColor),
        title: Text(buy.insiderName),
        subtitle: Text(
            '${buy.transactionType.label} · ${buy.shares} sh$val · $dateStr'),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline,
              size: 18, color: AppTheme.neutralColor),
          onPressed: () async {
            await ref
                .read(tickerProfileNotifierProvider.notifier)
                .deleteInsiderBuy(buy.id, symbol);
          },
        ),
      ),
    );
  }
}

// ─── Insiders Tab ─────────────────────────────────────────────────────────────

class _InsidersTab extends ConsumerWidget {
  final String symbol;
  const _InsidersTab({required this.symbol});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final insiders = ref.watch(tickerInsiderBuysProvider(symbol));

    return insiders.when(
      loading: () =>
          const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          const Center(child: Text('Could not load insider transactions')),
      data: (list) {
        if (list.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.person_search_outlined,
                    size: 56, color: AppTheme.neutralColor),
                const SizedBox(height: 16),
                const Text('No insider transactions yet',
                    style: TextStyle(color: AppTheme.neutralColor)),
                const SizedBox(height: 4),
                const Text('Import a Form 4 to get started',
                    style: TextStyle(
                        color: AppTheme.neutralColor, fontSize: 12)),
              ],
            ),
          );
        }

        // ── Summary stats ──
        double totalBuyValue = 0;
        double totalSellValue = 0;
        int totalBuyShares = 0;
        int totalSellShares = 0;
        final uniqueInsiders = <String>{};

        for (final t in list) {
          uniqueInsiders.add(t.insiderName);
          final val = t.totalValue ?? 0;
          final shares = t.shares;
          final isBuy =
              t.transactionType == InsiderTransactionType.purchase ||
                  t.transactionType == InsiderTransactionType.exercise;
          final isSell =
              t.transactionType == InsiderTransactionType.sale ||
                  t.transactionType ==
                      InsiderTransactionType.taxWithholding;
          if (isBuy) {
            totalBuyValue += val;
            totalBuyShares += shares;
          }
          if (isSell) {
            totalSellValue += val;
            totalSellShares += shares;
          }
        }

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
          children: [
            // Summary stat tiles
            _InsiderSummaryRow(
              totalBuyValue: totalBuyValue,
              totalSellValue: totalSellValue,
              totalBuyShares: totalBuyShares,
              totalSellShares: totalSellShares,
              uniqueInsiderCount: uniqueInsiders.length,
            ),
            const SizedBox(height: 20),

            // Activity chart
            _InsiderActivityChart(transactions: list),
            const SizedBox(height: 20),

            // Transactions header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'All Transactions (${list.length})',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: AppTheme.neutralColor,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Full transaction list
            ...list.map(
                (t) => _InsiderTransactionCard(symbol: symbol, tx: t)),
          ],
        );
      },
    );
  }
}

// ─── Insider summary row ──────────────────────────────────────────────────────

class _InsiderSummaryRow extends StatelessWidget {
  final double totalBuyValue;
  final double totalSellValue;
  final int totalBuyShares;
  final int totalSellShares;
  final int uniqueInsiderCount;

  const _InsiderSummaryRow({
    required this.totalBuyValue,
    required this.totalSellValue,
    required this.totalBuyShares,
    required this.totalSellShares,
    required this.uniqueInsiderCount,
  });

  static String _fmtVal(double v) {
    if (v == 0) return '—';
    if (v >= 1e9) return '\$${(v / 1e9).toStringAsFixed(1)}B';
    if (v >= 1e6) return '\$${(v / 1e6).toStringAsFixed(1)}M';
    if (v >= 1e3) return '\$${(v / 1e3).toStringAsFixed(0)}K';
    return '\$${v.toStringAsFixed(0)}';
  }

  static String _fmtShares(int v) {
    if (v == 0) return '—';
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M sh';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(0)}K sh';
    return '$v sh';
  }

  @override
  Widget build(BuildContext context) {
    final isBullish = totalBuyValue > totalSellValue;
    final hasBoth = totalBuyValue > 0 && totalSellValue > 0;
    final sentimentColor = hasBoth
        ? (isBullish ? AppTheme.profitColor : AppTheme.lossColor)
        : totalBuyValue > 0
            ? AppTheme.profitColor
            : totalSellValue > 0
                ? AppTheme.lossColor
                : AppTheme.neutralColor;
    final sentimentLabel = hasBoth
        ? (isBullish ? 'Net Bullish' : 'Net Bearish')
        : totalBuyValue > 0
            ? 'Bullish'
            : totalSellValue > 0
                ? 'Bearish'
                : 'Neutral';
    final sentimentIcon = (totalBuyValue >= totalSellValue)
        ? Icons.trending_up
        : Icons.trending_down;

    return Row(
      children: [
        // Sentiment
        Expanded(
          child: _InsiderStatTile(
            label: 'Sentiment',
            value: sentimentLabel,
            valueColor: sentimentColor,
            icon: sentimentIcon,
            iconColor: sentimentColor,
          ),
        ),
        const SizedBox(width: 8),
        // Bought
        Expanded(
          child: _InsiderStatTile(
            label: 'Bought',
            value: _fmtVal(totalBuyValue),
            sub: _fmtShares(totalBuyShares),
            valueColor: totalBuyValue > 0
                ? AppTheme.profitColor
                : AppTheme.neutralColor,
          ),
        ),
        const SizedBox(width: 8),
        // Sold
        Expanded(
          child: _InsiderStatTile(
            label: 'Sold',
            value: _fmtVal(totalSellValue),
            sub: _fmtShares(totalSellShares),
            valueColor: totalSellValue > 0
                ? AppTheme.lossColor
                : AppTheme.neutralColor,
          ),
        ),
        const SizedBox(width: 8),
        // Insiders
        Expanded(
          child: _InsiderStatTile(
            label: 'Insiders',
            value: '$uniqueInsiderCount',
            valueColor: AppTheme.neutralColor,
            icon: Icons.person_outline,
            iconColor: AppTheme.neutralColor,
          ),
        ),
      ],
    );
  }
}

class _InsiderStatTile extends StatelessWidget {
  final String label;
  final String value;
  final String? sub;
  final Color valueColor;
  final IconData? icon;
  final Color? iconColor;

  const _InsiderStatTile({
    required this.label,
    required this.value,
    this.sub,
    required this.valueColor,
    this.icon,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: AppTheme.neutralColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 4),
          if (icon != null)
            Row(
              children: [
                Icon(icon, size: 13, color: iconColor),
                const SizedBox(width: 3),
                Flexible(
                  child: Text(value,
                      style: TextStyle(
                          color: valueColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w700),
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            )
          else
            Text(value,
                style: TextStyle(
                    color: valueColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
          if (sub != null)
            Text(sub!,
                style: const TextStyle(
                    color: AppTheme.neutralColor, fontSize: 10)),
        ],
      ),
    );
  }
}

// ─── Insider transaction card (full detail) ───────────────────────────────────

class _InsiderTransactionCard extends ConsumerWidget {
  final String symbol;
  final TickerInsiderBuy tx;
  const _InsiderTransactionCard(
      {required this.symbol, required this.tx});

  static String _fmtDate(DateTime d) =>
      '${_monthAbbr[d.month]} ${d.day}, ${d.year}';
  static const _monthAbbr = [
    '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String _fmtShares(int v) => v
      .toString()
      .replaceAllMapped(
          RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');

  static String _fmtVal(double v) {
    if (v >= 1e9) return '\$${(v / 1e9).toStringAsFixed(2)}B';
    if (v >= 1e6) return '\$${(v / 1e6).toStringAsFixed(2)}M';
    if (v >= 1e3) return '\$${(v / 1e3).toStringAsFixed(0)}K';
    return '\$${v.toStringAsFixed(0)}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isBuy = tx.transactionType == InsiderTransactionType.purchase ||
        tx.transactionType == InsiderTransactionType.exercise;
    final isSell = tx.transactionType == InsiderTransactionType.sale ||
        tx.transactionType == InsiderTransactionType.taxWithholding;
    final typeColor = isBuy
        ? AppTheme.profitColor
        : isSell
            ? AppTheme.lossColor
            : AppTheme.neutralColor;

    final txDate = tx.transactionDate;
    final showTxDate =
        txDate != null && _fmtDate(txDate) != _fmtDate(tx.filedAt);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Type indicator bar
            Container(
              width: 3,
              height: 56,
              margin: const EdgeInsets.only(right: 12),
              decoration: BoxDecoration(
                color: typeColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Main content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Name + type badge
                  Row(
                    children: [
                      Expanded(
                        child: Text(tx.insiderName,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14)),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: typeColor.withAlpha(30),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                              color: typeColor.withAlpha(80)),
                        ),
                        child: Text(
                          tx.transactionType.label,
                          style: TextStyle(
                              color: typeColor,
                              fontSize: 10,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  if (tx.insiderTitle != null) ...[
                    const SizedBox(height: 2),
                    Text(tx.insiderTitle!,
                        style: const TextStyle(
                            color: AppTheme.neutralColor,
                            fontSize: 11)),
                  ],
                  const SizedBox(height: 8),
                  // Shares · price · value
                  Wrap(
                    spacing: 12,
                    children: [
                      _Detail('${_fmtShares(tx.shares)} sh'),
                      if (tx.pricePerShare != null)
                        _Detail(
                            '@ \$${tx.pricePerShare!.toStringAsFixed(2)}'),
                      if (tx.totalValue != null)
                        Text(
                          _fmtVal(tx.totalValue!),
                          style: TextStyle(
                              color: typeColor,
                              fontSize: 12,
                              fontWeight: FontWeight.w700),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // Dates
                  Wrap(
                    spacing: 8,
                    children: [
                      if (showTxDate)
                        _Detail('Tx ${_fmtDate(txDate)}'),
                      _Detail('Filed ${_fmtDate(tx.filedAt)}'),
                    ],
                  ),
                ],
              ),
            ),
            // Delete
            IconButton(
              icon: const Icon(Icons.delete_outline,
                  size: 16, color: AppTheme.neutralColor),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: () => ref
                  .read(tickerProfileNotifierProvider.notifier)
                  .deleteInsiderBuy(tx.id, symbol),
            ),
          ],
        ),
      ),
    );
  }
}

class _Detail extends StatelessWidget {
  final String text;
  const _Detail(this.text);

  @override
  Widget build(BuildContext context) => Text(text,
      style:
          const TextStyle(color: AppTheme.neutralColor, fontSize: 12));
}

// ─── Earnings reaction card ───────────────────────────────────────────────────

class _EarningsReactionCard extends ConsumerWidget {
  final String symbol;
  final TickerEarningsReaction reaction;
  const _EarningsReactionCard(
      {required this.symbol, required this.reaction});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dir = reaction.direction ?? '';
    final dirColor = dir == 'up'
        ? AppTheme.profitColor
        : dir == 'down'
            ? AppTheme.lossColor
            : AppTheme.neutralColor;
    final movePctStr = reaction.movePct != null
        ? '${reaction.movePct! >= 0 ? '+' : ''}${reaction.movePct!.toStringAsFixed(1)}%'
        : '';

    return Card(
      child: ListTile(
        leading: Icon(
          dir == 'up'
              ? Icons.arrow_upward
              : dir == 'down'
                  ? Icons.arrow_downward
                  : Icons.remove,
          color: dirColor,
        ),
        title: Text(reaction.fiscalPeriod ??
            '${reaction.earningsDate.year}-${reaction.earningsDate.month.toString().padLeft(2, '0')}-${reaction.earningsDate.day.toString().padLeft(2, '0')}'),
        subtitle: Text([
          if (movePctStr.isNotEmpty) movePctStr,
          if (reaction.beat) 'Beat',
          if (reaction.epsActual != null)
            'EPS ${reaction.epsActual!.toStringAsFixed(2)}',
        ].join(' · ')),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.edit_outlined,
                  size: 18, color: AppTheme.neutralColor),
              onPressed: () => showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                backgroundColor: AppTheme.elevatedColor,
                shape: const RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.vertical(top: Radius.circular(16)),
                ),
                builder: (_) => AddEarningsReactionSheet(
                    symbol: symbol, existing: reaction),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline,
                  size: 18, color: AppTheme.neutralColor),
              onPressed: () async {
                await ref
                    .read(tickerProfileNotifierProvider.notifier)
                    .deleteEarningsReaction(reaction.id, symbol);
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Note card ────────────────────────────────────────────────────────────────

class _NoteCard extends ConsumerWidget {
  final String symbol;
  final TickerProfileNote note;
  const _NoteCard({required this.symbol, required this.note});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${note.createdAt.year}-${note.createdAt.month.toString().padLeft(2, '0')}-${note.createdAt.day.toString().padLeft(2, '0')}',
                    style: const TextStyle(
                        color: AppTheme.neutralColor, fontSize: 12),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline,
                      size: 18, color: AppTheme.neutralColor),
                  onPressed: () async {
                    await ref
                        .read(tickerProfileNotifierProvider.notifier)
                        .deleteNote(note.id, symbol);
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            Text(note.body),
            if (note.tags.isNotEmpty)
              Wrap(
                spacing: 4,
                children: note.tags
                    .map((t) => Chip(
                          label: Text(t),
                          visualDensity: VisualDensity.compact,
                        ))
                    .toList(),
              ),
          ],
        ),
      ),
    );
  }
}

// ─── S/R level card ───────────────────────────────────────────────────────────

class _SRLevelCard extends ConsumerWidget {
  final String symbol;
  final SupportResistanceLevel level;
  const _SRLevelCard({required this.symbol, required this.level});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isSupport = level.levelType == SRLevelType.support;
    return Card(
      child: ListTile(
        leading: Icon(
          isSupport ? Icons.arrow_upward : Icons.arrow_downward,
          color:
              isSupport ? AppTheme.profitColor : AppTheme.lossColor,
        ),
        title: Text('\$${level.price.toStringAsFixed(2)}'
            '${level.label != null ? '  ·  ${level.label}' : ''}'),
        subtitle: Text([
          level.levelType.name,
          if (level.timeframe != null) level.timeframe!.label,
          if (!level.isActive) 'Invalidated',
        ].join(' · ')),
        trailing: level.isActive
            ? IconButton(
                icon: const Icon(Icons.check_circle_outline,
                    size: 18, color: AppTheme.neutralColor),
                tooltip: 'Invalidate level',
                onPressed: () async {
                  await ref
                      .read(tickerProfileNotifierProvider.notifier)
                      .invalidateSRLevel(level.id, symbol, null);
                },
              )
            : null,
      ),
    );
  }
}

// ─── Timeline event tile ──────────────────────────────────────────────────────

class _TimelineEventTile extends StatelessWidget {
  final TickerTimelineEvent event;
  const _TimelineEventTile({required this.event});

  Color _dotColor() => switch (event.type) {
        TimelineEventType.tradeClosed => event.trade?.isProfitable == true
            ? AppTheme.profitColor
            : AppTheme.lossColor,
        TimelineEventType.tradeOpened => AppTheme.neutralColor,
        TimelineEventType.note => const Color(0xFF7EC8E3),       // sky-blue
        TimelineEventType.secFiling => const Color(0xFFFFD166),   // golden-yellow
        TimelineEventType.earningsReaction =>
          event.earningsReaction?.direction == 'up'
              ? AppTheme.profitColor
              : AppTheme.lossColor,
        TimelineEventType.insiderBuy => AppTheme.profitColor,
        TimelineEventType.srLevelAdded => const Color(0xFFBBABFF), // bright lavender
        TimelineEventType.srLevelInvalidated => AppTheme.neutralColor,
      };

  IconData _icon() => switch (event.type) {
        TimelineEventType.tradeOpened => Icons.open_in_new,
        TimelineEventType.tradeClosed => Icons.check_circle_outline,
        TimelineEventType.note => Icons.note_outlined,
        TimelineEventType.secFiling => Icons.description_outlined,
        TimelineEventType.earningsReaction => Icons.bar_chart,
        TimelineEventType.insiderBuy => Icons.trending_up,
        TimelineEventType.srLevelAdded => Icons.horizontal_rule,
        TimelineEventType.srLevelInvalidated => Icons.remove_circle_outline,
      };

  @override
  Widget build(BuildContext context) {
    final d = event.timestamp;
    final dateStr =
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: _dotColor().withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(_icon(), size: 16, color: _dotColor()),
              ),
              Container(
                  width: 2, height: 32, color: AppTheme.borderColor),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(dateStr,
                    style: const TextStyle(
                        color: AppTheme.neutralColor, fontSize: 11)),
                const SizedBox(height: 2),
                Text(event.summary),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── My Edge sub-widgets ──────────────────────────────────────────────────────

class _EdgeStatsRow extends StatelessWidget {
  final TickerTradeAnalytics analytics;
  const _EdgeStatsRow({required this.analytics});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _StatTile(
            label: 'Win Rate',
            value:
                '${(analytics.winRate * 100).toStringAsFixed(0)}%',
            color: analytics.winRate >= 0.5
                ? AppTheme.profitColor
                : AppTheme.lossColor,
          ),
        ),
        Expanded(
          child: _StatTile(
            label: 'Avg Return',
            value:
                '${analytics.avgReturn >= 0 ? '+' : ''}${analytics.avgReturn.toStringAsFixed(1)}%',
            color: analytics.avgReturn >= 0
                ? AppTheme.profitColor
                : AppTheme.lossColor,
          ),
        ),
        Expanded(
          child: _StatTile(
            label: 'Total P&L',
            value:
                '${analytics.totalRealizedPnl >= 0 ? '+' : ''}\$${analytics.totalRealizedPnl.toStringAsFixed(0)}',
            color: analytics.totalRealizedPnl >= 0
                ? AppTheme.profitColor
                : AppTheme.lossColor,
          ),
        ),
        Expanded(
          child: _StatTile(
            label: 'Trades',
            value: '${analytics.totalTrades}',
            color: Colors.white,
          ),
        ),
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
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          child: Column(
            children: [
              Text(value,
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: color,
                      fontSize: 16)),
              const SizedBox(height: 4),
              Text(label,
                  style: const TextStyle(
                      color: AppTheme.neutralColor, fontSize: 11)),
            ],
          ),
        ),
      );
}

class _StrategyRow extends StatelessWidget {
  final TradeStrategy strategy;
  final StrategyStats stats;
  const _StrategyRow({required this.strategy, required this.stats});

  @override
  Widget build(BuildContext context) {
    final wrPct = (stats.winRate * 100).toStringAsFixed(0);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Expanded(child: Text(strategy.label)),
            Text('$wrPct%  ',
                style: TextStyle(
                  color: stats.winRate >= 0.5
                      ? AppTheme.profitColor
                      : AppTheme.lossColor,
                  fontWeight: FontWeight.w600,
                )),
            Text('${stats.count} trades',
                style: const TextStyle(
                    color: AppTheme.neutralColor, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _ConditionChip extends StatelessWidget {
  final String label;
  final String value;
  const _ConditionChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Text('$label  ',
                  style: const TextStyle(color: AppTheme.neutralColor)),
              Text(value,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppTheme.profitColor)),
            ],
          ),
        ),
      );
}

class _MonthlyPnlChart extends StatelessWidget {
  final Map<int, double> monthlyPnl;
  const _MonthlyPnlChart({required this.monthlyPnl});

  @override
  Widget build(BuildContext context) {
    final entries = monthlyPnl.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    final bars = entries.asMap().entries.map((e) {
      final pnl = e.value.value;
      return BarChartGroupData(
        x: e.key,
        barRods: [
          BarChartRodData(
            toY: pnl,
            color:
                pnl >= 0 ? AppTheme.profitColor : AppTheme.lossColor,
            width: 14,
            borderRadius: BorderRadius.circular(4),
          ),
        ],
      );
    }).toList();

    return BarChart(
      BarChartData(
        barGroups: bars,
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          leftTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (v, _) {
                final idx = v.toInt();
                if (idx < 0 || idx >= entries.length) {
                  return const SizedBox.shrink();
                }
                // Skip labels when many months to avoid crowding
                if (entries.length > 6 && idx % 2 != 0) {
                  return const SizedBox.shrink();
                }
                final key = entries[idx].key;
                final year  = key ~/ 100;
                final month = key % 100;
                const abbr = [
                  '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
                ];
                // Show year on January or first bar
                final label = (month == 1 || idx == 0)
                    ? "${abbr[month]} '${year % 100}"
                    : abbr[month];
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(label,
                      style: const TextStyle(
                          color: AppTheme.neutralColor, fontSize: 9)),
                );
              },
            ),
          ),
        ),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (group, _, rod, idx) => BarTooltipItem(
              '${rod.toY >= 0 ? '+' : ''}\$${rod.toY.toStringAsFixed(0)}',
              TextStyle(
                  color: rod.toY >= 0
                      ? AppTheme.profitColor
                      : AppTheme.lossColor),
            ),
          ),
        ),
      ),
    );
  }
}
