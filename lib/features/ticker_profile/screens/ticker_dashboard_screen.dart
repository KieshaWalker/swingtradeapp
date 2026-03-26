// =============================================================================
// features/ticker_profile/screens/ticker_dashboard_screen.dart
// =============================================================================
// Tab 5 — "Tickers" — grid of every unique ticker the user has traded.
//
// Data sources:
//   Ticker list       Supabase  trades table — unique symbols, client-side
//   Live price        FMP  GET /quote?symbol=   (quoteProvider per card)
//   Company name      FMP  GET /quote?symbol=   (quote.name field)
//   Win rate / P&L    Supabase  trades table — computed locally
//                     (tickerAnalyticsProvider → TickerTradeAnalytics.compute())
//   Open count        Supabase  trades table — client-side filter
//   Search dialog     FMP  GET /search-symbol?query=  (tickerSearchProvider)
//                     — lets you browse any ticker even without trades
//
// TODO: Add Kalshi market prices alongside FMP quote on each card
//       kalshiMarketProvider(symbol) → GET /markets?ticker={symbol}
//
// Tap any card → context.push('/ticker/$symbol') → TickerProfileScreen
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme.dart';
import '../../../services/fmp/fmp_providers.dart';
import '../../trades/providers/trades_provider.dart';
import '../providers/ticker_profile_notifier.dart';
import '../providers/ticker_profile_providers.dart';

class TickerDashboardScreen extends ConsumerWidget {
  const TickerDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tradesAsync = ref.watch(tradesProvider);
    final watchedAsync = ref.watch(watchedTickersProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tickers'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Find ticker',
            onPressed: () => _showSearch(context),
          ),
        ],
      ),
      body: tradesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (trades) {
          // Trade-derived symbols (most recently traded first)
          final seen = <String>{};
          final tradeSymbols = trades
              .map((t) => t.ticker.toUpperCase())
              .where(seen.add)
              .toList();

          // Merge watched-only tickers after trade symbols
          final watched = watchedAsync.valueOrNull ?? [];
          final symbols = [
            ...tradeSymbols,
            ...watched.where((s) => !seen.contains(s)),
          ];

          if (symbols.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.candlestick_chart_outlined,
                      size: 64, color: AppTheme.neutralColor),
                  const SizedBox(height: 16),
                  const Text(
                    'No tickers yet',
                    style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Search a ticker to add it to your list.',
                    style: TextStyle(color: AppTheme.neutralColor),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: () => _showSearch(context),
                    icon: const Icon(Icons.search),
                    label: const Text('Browse a ticker'),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: symbols.length,
            itemBuilder: (_, i) => _TickerCard(symbol: symbols[i]),
          );
        },
      ),
    );
  }

  void _showSearch(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => const _TickerSearchDialog(),
    );
  }
}

// ─── Ticker card ──────────────────────────────────────────────────────────────

class _TickerCard extends ConsumerWidget {
  final String symbol;
  const _TickerCard({required this.symbol});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quoteAsync = ref.watch(quoteProvider(symbol));
    final analytics = ref.watch(tickerAnalyticsProvider(symbol));
    final tradesAsync = ref.watch(tradesProvider);

    final openCount = tradesAsync.valueOrNull
            ?.where((t) =>
                t.ticker.toUpperCase() == symbol &&
                t.status.name == 'open')
            .length ??
        0;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push('/ticker/$symbol'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header row: symbol + price ───────────────────────
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Symbol + name
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              symbol,
                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            if (openCount > 0) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppTheme.profitColor
                                      .withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                      color: AppTheme.profitColor
                                          .withValues(alpha: 0.4)),
                                ),
                                child: Text(
                                  '$openCount open',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: AppTheme.profitColor,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        quoteAsync.whenOrNull(
                              data: (q) => q != null && q.name.isNotEmpty
                                  ? Text(
                                      q.name,
                                      style: const TextStyle(
                                        color: AppTheme.neutralColor,
                                        fontSize: 12,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    )
                                  : null,
                            ) ??
                            const SizedBox.shrink(),
                      ],
                    ),
                  ),
                  // Live price
                  quoteAsync.when(
                    loading: () => const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    error: (e, _) => const Text('—',
                        style:
                            TextStyle(color: AppTheme.neutralColor)),
                    data: (q) => q == null
                        ? const Text('—',
                            style: TextStyle(
                                color: AppTheme.neutralColor))
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                '\$${q.price.toStringAsFixed(2)}',
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                '${q.isPositive ? '+' : ''}${q.changePercent.toStringAsFixed(2)}%',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: q.isPositive
                                      ? AppTheme.profitColor
                                      : AppTheme.lossColor,
                                ),
                              ),
                            ],
                          ),
                  ),
                ],
              ),

              // ── Stats row ────────────────────────────────────────
              if (analytics.totalTrades > 0) ...[
                const SizedBox(height: 12),
                const Divider(height: 1, color: Color(0xFF30363D)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _StatChip(
                      label: 'Trades',
                      value: '${analytics.totalTrades}',
                    ),
                    const SizedBox(width: 8),
                    _StatChip(
                      label: 'Win Rate',
                      value:
                          '${(analytics.winRate * 100).toStringAsFixed(0)}%',
                      valueColor: analytics.winRate >= 0.5
                          ? AppTheme.profitColor
                          : AppTheme.lossColor,
                    ),
                    const SizedBox(width: 8),
                    _StatChip(
                      label: 'P&L',
                      value:
                          '${analytics.totalRealizedPnl >= 0 ? '+' : ''}\$${analytics.totalRealizedPnl.toStringAsFixed(0)}',
                      valueColor: analytics.totalRealizedPnl >= 0
                          ? AppTheme.profitColor
                          : AppTheme.lossColor,
                    ),
                    if (analytics.playbookSummary != null) ...[
                      const SizedBox(width: 8),
                      const Icon(Icons.auto_awesome,
                          size: 14, color: AppTheme.profitColor),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _StatChip({
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1117),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
                color: AppTheme.neutralColor, fontSize: 10),
          ),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color: valueColor ?? Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Ticker search dialog ─────────────────────────────────────────────────────

class _TickerSearchDialog extends ConsumerStatefulWidget {
  const _TickerSearchDialog();

  @override
  ConsumerState<_TickerSearchDialog> createState() =>
      _TickerSearchDialogState();
}

class _TickerSearchDialogState extends ConsumerState<_TickerSearchDialog> {
  final _ctrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final resultsAsync = ref.watch(tickerSearchProvider(_query));

    return Dialog(
      backgroundColor: const Color(0xFF161B22),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _ctrl,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Search ticker or company…',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
            const SizedBox(height: 8),
            if (_query.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Type a symbol or company name',
                    style: TextStyle(color: AppTheme.neutralColor)),
              )
            else
              resultsAsync.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(),
                ),
                error: (e, _) => const Text('Search failed'),
                data: (results) => results.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('No results',
                            style:
                                TextStyle(color: AppTheme.neutralColor)),
                      )
                    : ConstrainedBox(
                        constraints:
                            const BoxConstraints(maxHeight: 320),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: results.length,
                          itemBuilder: (_, i) {
                            final r = results[i];
                            return ListTile(
                              title: Text(r.symbol,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700)),
                              subtitle: Text(r.name,
                                  style: const TextStyle(
                                      color: AppTheme.neutralColor,
                                      fontSize: 12)),
                              trailing: Text(r.exchange,
                                  style: const TextStyle(
                                      color: AppTheme.neutralColor,
                                      fontSize: 11)),
                              onTap: () {
                                ref
                                    .read(tickerProfileNotifierProvider
                                        .notifier)
                                    .addWatchedTicker(r.symbol);
                                Navigator.pop(context);
                                context.push('/ticker/${r.symbol}');
                              },
                            );
                          },
                        ),
                      ),
              ),
          ],
        ),
      ),
    );
  }
}
