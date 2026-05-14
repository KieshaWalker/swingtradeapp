// =============================================================================
// features/ticker_profile/screens/ticker_dashboard_screen.dart
// =============================================================================
// Tab 5 — "Tickers" — grid of every unique ticker the user has traded.
//
// Data sources:
//   Ticker list       Supabase  trades table — unique symbols, client-side
//   Live price        Schwab  GET /marketdata/v1/quotes  (quoteProvider per card)
//   Company name      Schwab  GET /marketdata/v1/quotes  (quote.name field)
//   Win rate / P&L    Supabase  trades table — computed locally
//                     (tickerAnalyticsProvider → TickerTradeAnalytics.compute())
//   Open count        Supabase  trades table — client-side filter
//   Search dialog     Schwab  GET /marketdata/v1/instruments  (tickerSearchProvider)
//                     — lets you browse any ticker even without trades
//
// Tap any card → context.push('/ticker/$symbol') → TickerProfileScreen
// =============================================================================
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/app_menu_button.dart';
import '../../../services/schwab/schwab_providers.dart';
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
            icon: const Icon(Icons.search_rounded),
            tooltip: 'Find ticker',
            onPressed: () => _showSearch(context),
          ),
          const AppMenuButton(),
        ],
      ),
      body: tradesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (trades) {
          // Deduplicate traded symbols preserving insertion order.
          final seen = <String>{};
          final tradeSymbols = trades
              .map((t) => t.ticker.toUpperCase())
              .where((s) => seen.add(s))
              .toList();

          // Bug fix: use seen.add() so watched duplicates are also deduplicated.
          final watchedSymbols = watchedAsync.valueOrNull ?? [];
          final symbols = [
            ...tradeSymbols,
            ...watchedSymbols.map((s) => s.toUpperCase()).where(seen.add),
          ];

          if (symbols.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.candlestick_chart_outlined,
                    size: 52,
                    color: AppTheme.neutralColor.withValues(alpha: 0.4),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'No tickers yet',
                    style: TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Search a ticker to add it to your watchlist.',
                    style: TextStyle(
                        color: AppTheme.neutralColor, fontSize: 13),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: () => _showSearch(context),
                    icon: const Icon(Icons.search_rounded, size: 18),
                    label: const Text('Browse a ticker'),
                  ),
                ],
              ),
            );
          }

          // Responsive column count: 2 on phones, 3 on medium, 4 on wide.
          return LayoutBuilder(
            builder: (context, constraints) {
              final crossAxisCount = constraints.maxWidth < 480
                  ? 2
                  : constraints.maxWidth < 800
                      ? 3
                      : 4;
              return GridView.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  // Fixed pixel height guarantees stats row always has room.
                  mainAxisExtent: 118,
                ),
                padding: const EdgeInsets.all(12),
                itemCount: symbols.length,
                itemBuilder: (_, i) => _TickerCard(symbol: symbols[i]),
              );
            },
          );
        },
      ),
    );
  }

  void _showSearch(BuildContext context) {
    showDialog(context: context, builder: (_) => const _TickerSearchDialog());
  }
}

// ─── Ticker card ──────────────────────────────────────────────────────────────

class _TickerCard extends ConsumerWidget {
  final String symbol;
  const _TickerCard({required this.symbol});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quoteAsync = ref.watch(quoteProvider(symbol));
    final analytics  = ref.watch(tickerAnalyticsProvider(symbol));
    final tradesAsync = ref.watch(tradesProvider);

    final openCount =
        tradesAsync.valueOrNull
            ?.where((t) =>
                t.ticker.toUpperCase() == symbol &&
                t.status.name == 'open')
            .length ??
        0;

    return Card(
      clipBehavior: Clip.hardEdge,
      child: InkWell(
        onTap: () => context.push('/ticker/$symbol'),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header row: symbol + live price ─────────────────────────
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Left: symbol + open badge + company name
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              symbol,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.3,
                              ),
                            ),
                            if (openCount > 0) ...[
                              const SizedBox(width: 5),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(
                                  color: AppTheme.profitColor
                                      .withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                    color: AppTheme.profitColor
                                        .withValues(alpha: 0.4),
                                  ),
                                ),
                                child: Text(
                                  '$openCount open',
                                  style: const TextStyle(
                                    fontSize: 9,
                                    color: AppTheme.profitColor,
                                    fontWeight: FontWeight.w700,
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
                                        fontSize: 10,
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
                  // Right: price + change%
                  quoteAsync.when(
                    loading: () => const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    ),
                    error: (_, _) => const Text(
                      '—',
                      style: TextStyle(
                          color: AppTheme.neutralColor, fontSize: 12),
                    ),
                    data: (q) {
                      if (q == null) {
                        return const Text(
                          '—',
                          style: TextStyle(
                              color: AppTheme.neutralColor, fontSize: 12),
                        );
                      }
                      final chg = q.changePercent;
                      // Bug fix: flat (0%) should be neutral, not green.
                      final pctColor = chg > 0
                          ? AppTheme.profitColor
                          : chg < 0
                              ? AppTheme.lossColor
                              : AppTheme.neutralColor;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '\$${q.price.toStringAsFixed(2)}',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            '${chg >= 0 ? '+' : ''}${chg.toStringAsFixed(2)}%',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: pctColor,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),

              // ── Stats row — pushed to card bottom via Spacer ─────────────
              if (analytics.totalTrades > 0) ...[
                const Spacer(),
                Divider(height: 1, color: AppTheme.borderColor),
                const SizedBox(height: 6),
                Row(
                  children: [
                    _StatPill(
                      label: 'TRADES',
                      value: '${analytics.totalTrades}',
                    ),
                    const SizedBox(width: 10),
                    _StatPill(
                      label: 'WIN',
                      value:
                          '${(analytics.winRate * 100).toStringAsFixed(0)}%',
                      valueColor: analytics.winRate >= 0.5
                          ? AppTheme.profitColor
                          : AppTheme.lossColor,
                    ),
                    const SizedBox(width: 10),
                    // Flexible prevents long P&L values from overflowing.
                    Flexible(
                      child: _StatPill(
                        label: 'P&L',
                        value:
                            '${analytics.totalRealizedPnl >= 0 ? '+' : ''}\$${analytics.totalRealizedPnl.toStringAsFixed(0)}',
                        valueColor: analytics.totalRealizedPnl >= 0
                            ? AppTheme.profitColor
                            : AppTheme.lossColor,
                      ),
                    ),
                    if (analytics.playbookSummary != null) ...[
                      const SizedBox(width: 4),
                      Tooltip(
                        message: 'Has playbook analysis',
                        child: const Icon(
                          Icons.auto_awesome,
                          size: 12,
                          color: AppTheme.profitColor,
                        ),
                      ),
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

// ─── Stat label + value column (no box — card boundary is sufficient) ─────────

class _StatPill extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _StatPill(
      {required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: AppTheme.neutralColor,
            fontSize: 9,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 12,
            color: valueColor ?? Colors.white,
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ],
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
  Timer? _debounce;

  @override
  void dispose() {
    _ctrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  // Debounce to 350 ms so the Schwab instruments API isn't hit on every keystroke.
  void _onQueryChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _query = v.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    final resultsAsync = ref.watch(tickerSearchProvider(_query));

    return Dialog(
      backgroundColor: AppTheme.elevatedColor,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _ctrl,
              autofocus: true,
              style: const TextStyle(fontSize: 15),
              decoration: const InputDecoration(
                hintText: 'Search ticker or company…',
                prefixIcon: Icon(Icons.search_rounded, size: 20),
                isDense: true,
              ),
              onChanged: _onQueryChanged,
            ),
            const SizedBox(height: 8),
            if (_query.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'Type a symbol or company name',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: AppTheme.neutralColor, fontSize: 13),
                ),
              )
            else
              resultsAsync.when(
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (_, _) => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    'Search failed',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.neutralColor),
                  ),
                ),
                data: (results) => results.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Text(
                          'No results',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: AppTheme.neutralColor, fontSize: 13),
                        ),
                      )
                    : ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 300),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: results.length,
                          itemBuilder: (_, i) {
                            final r = results[i];
                            return ListTile(
                              dense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 8),
                              title: Text(
                                r.symbol,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                ),
                              ),
                              subtitle: Text(
                                r.name,
                                style: const TextStyle(
                                  color: AppTheme.neutralColor,
                                  fontSize: 12,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Text(
                                r.exchange,
                                style: const TextStyle(
                                  color: AppTheme.neutralColor,
                                  fontSize: 11,
                                ),
                              ),
                              onTap: () {
                                ref
                                    .read(
                                      tickerProfileNotifierProvider.notifier,
                                    )
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
