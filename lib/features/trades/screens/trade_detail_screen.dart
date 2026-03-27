// =============================================================================
// features/trades/screens/trade_detail_screen.dart — Full trade view
// =============================================================================
// Widgets defined here:
//   • TradeDetailScreen  (ConsumerWidget) — receives Trade via GoRouter extra;
//                          scrollable detail view with header, quote, details,
//                          Greeks, notes, SEC filings sections
//   • _LiveQuoteCard     (ConsumerWidget) — live FMP price card with open/high/
//                          low/prev-close stats; powered by quoteProvider(symbol)
//   • _QuoteStat         — label + value column used inside _LiveQuoteCard
//   • _StatusBadge       — OPEN/CLOSED/EXPIRED pill; color from AppTheme
//   • _DetailRow         — label ↔ value row used in the details grid card
//   • _GreekBox          — Delta / IV Rank box; shown only if values were entered
//   • _SecFilingsSection (ConsumerWidget) — recent SEC filings for the trade's
//                          ticker; powered by secFilingsForTickerProvider(ticker)
//   • _SecFilingRow      — tappable row per filing; opens EDGAR link via url_launcher
//
// Route: '/trades/:id' (child of /trades in router.dart)
//        — reached by tapping a _TradeCard or _OpenTradeRow
//
// Providers consumed:
//   • quoteProvider(trade.ticker)              — live stock price (_LiveQuoteCard)
//   • secFilingsForTickerProvider(trade.ticker)— SEC filings feed (_SecFilingsSection)
//   • tradesNotifierProvider                   — close / delete mutations
//
// AppBar actions:
//   Close trade → _showCloseDialog → tradesNotifierProvider.closeTrade()
//   Delete trade → _confirmDelete  → tradesNotifierProvider.deleteTrade()
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/theme.dart';
import '../../../services/fmp/fmp_providers.dart';
import '../../../services/sec/sec_models.dart';
import '../../../services/sec/sec_providers.dart';
import '../models/trade.dart';
import '../providers/trades_provider.dart';

class TradeDetailScreen extends ConsumerWidget {
  final Trade trade;
  const TradeDetailScreen({super.key, required this.trade});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pnl = trade.realizedPnl;
    final pnlColor = pnl == null
        ? AppTheme.neutralColor
        : pnl >= 0
            ? AppTheme.profitColor
            : AppTheme.lossColor;

    return Scaffold(
      appBar: AppBar(
        title: Text('${trade.ticker} ${trade.strategy.label}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.candlestick_chart_outlined),
            tooltip: 'Ticker Profile',
            onPressed: () => context.push('/ticker/${trade.ticker}'),
          ),
          if (trade.status == TradeStatus.open)
            TextButton.icon(
              onPressed: () => _showCloseDialog(context, ref),
              icon: const Icon(Icons.check_circle_outline),
              label: const Text('Close'),
              style: TextButton.styleFrom(foregroundColor: AppTheme.profitColor),
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            color: AppTheme.lossColor,
            onPressed: () => _confirmDelete(context, ref),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Header card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        trade.ticker,
                        style: const TextStyle(
                            fontSize: 28, fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(width: 10),
                      _StatusBadge(trade.status),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${trade.optionType.name.toUpperCase()} · ${trade.strategy.label}',
                    style: const TextStyle(color: AppTheme.neutralColor),
                  ),
                  if (pnl != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      '${pnl >= 0 ? '+' : ''}\$${pnl.toStringAsFixed(2)}',
                      style: TextStyle(
                        color: pnlColor,
                        fontSize: 32,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      '${trade.pnlPercent! >= 0 ? '+' : ''}${trade.pnlPercent!.toStringAsFixed(1)}% return',
                      style: TextStyle(color: pnlColor, fontSize: 15),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Live stock quote from FMP
          _LiveQuoteCard(symbol: trade.ticker),
          const SizedBox(height: 12),

          // Details grid
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _DetailRow('Strike', '\$${trade.strike.toStringAsFixed(2)}'),
                  _DetailRow('Expiration',
                      DateFormat('MMM d, yyyy').format(trade.expiration)),
                  _DetailRow('DTE at Entry',
                      trade.dteAtEntry != null ? '${trade.dteAtEntry} days' : '—'),
                  _DetailRow('Contracts', '${trade.contracts}'),
                  _DetailRow('Entry Premium',
                      '\$${trade.entryPrice.toStringAsFixed(4)} / share'),
                  _DetailRow('Cost Basis',
                      '\$${trade.costBasis.toStringAsFixed(2)}'),
                  if (trade.exitPrice != null)
                    _DetailRow('Exit Premium',
                        '\$${trade.exitPrice!.toStringAsFixed(4)} / share'),
                  _DetailRow('Opened',
                      DateFormat('MMM d, yyyy h:mm a').format(trade.openedAt)),
                  if (trade.closedAt != null)
                    _DetailRow('Closed',
                        DateFormat('MMM d, yyyy h:mm a').format(trade.closedAt!)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Greeks card
          if (trade.ivRank != null || trade.delta != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Greeks & IV',
                      style: TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 15),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        if (trade.delta != null)
                          _GreekBox(
                              label: 'Delta',
                              value: trade.delta!.toStringAsFixed(2)),
                        if (trade.ivRank != null)
                          _GreekBox(
                              label: 'IV Rank',
                              value: '${trade.ivRank!.toStringAsFixed(0)}%'),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),

          // Notes
          if (trade.notes != null && trade.notes!.isNotEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Setup Notes',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                    ),
                    const SizedBox(height: 8),
                    Text(trade.notes!,
                        style: const TextStyle(color: AppTheme.neutralColor)),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),

          // SEC filings for this ticker
          _SecFilingsSection(ticker: trade.ticker),
        ],
      ),
    );
  }

  void _showCloseDialog(BuildContext context, WidgetRef ref) {
    final exitCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.elevatedColor,
        title: const Text('Close Trade'),
        content: TextField(
          controller: exitCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Exit Premium (per share)',
            prefixText: '\$',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final price = double.tryParse(exitCtrl.text);
              if (price == null) return;
              await ref.read(tradesNotifierProvider.notifier).closeTrade(
                    tradeId: trade.id,
                    exitPrice: price,
                  );
              if (context.mounted) {
                Navigator.pop(context);
                context.pop();
              }
            },
            child: const Text('Close Trade'),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.elevatedColor,
        title: const Text('Delete Trade?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.lossColor),
            onPressed: () async {
              await ref
                  .read(tradesNotifierProvider.notifier)
                  .deleteTrade(trade.id);
              if (context.mounted) {
                Navigator.pop(context);
                context.pop();
              }
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------
// Live quote card powered by FMP
// Watches quoteProvider(symbol) → FmpService.getQuote()
// Shows: price, change $/%,  open / high / low / prev close
// ----------------------------------------------------------------
class _LiveQuoteCard extends ConsumerWidget {
  final String symbol;
  const _LiveQuoteCard({required this.symbol});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quoteAsync = ref.watch(quoteProvider(symbol));

    return quoteAsync.when(
      loading: () => const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Row(
            children: [
              SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 12),
              Text('Loading live quote…',
                  style: TextStyle(color: AppTheme.neutralColor)),
            ],
          ),
        ),
      ),
      error: (e, _) => const SizedBox.shrink(),
      data: (quote) {
        if (quote == null) return const SizedBox.shrink();
        final changeColor =
            quote.isPositive ? AppTheme.profitColor : AppTheme.lossColor;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.bolt, size: 14, color: AppTheme.profitColor),
                    const SizedBox(width: 4),
                    const Text(
                      'Live Quote',
                      style: TextStyle(
                          color: AppTheme.neutralColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w600),
                    ),
                    const Spacer(),
                    Text(
                      quote.name,
                      style: const TextStyle(
                          color: AppTheme.neutralColor, fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '\$${quote.price.toStringAsFixed(2)}',
                      style: const TextStyle(
                          fontSize: 28, fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(width: 10),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '${quote.isPositive ? '+' : ''}\$${quote.change.toStringAsFixed(2)} '
                        '(${quote.isPositive ? '+' : ''}${quote.changePercent.toStringAsFixed(2)}%)',
                        style: TextStyle(
                            color: changeColor, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _QuoteStat('Open', '\$${quote.open.toStringAsFixed(2)}'),
                    _QuoteStat('High', '\$${quote.dayHigh.toStringAsFixed(2)}'),
                    _QuoteStat('Low', '\$${quote.dayLow.toStringAsFixed(2)}'),
                    _QuoteStat('Prev Close',
                        '\$${quote.previousClose.toStringAsFixed(2)}'),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// _QuoteStat: label + value column used in _LiveQuoteCard OHLC row.
class _QuoteStat extends StatelessWidget {
  final String label;
  final String value;
  const _QuoteStat(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style:
                  const TextStyle(color: AppTheme.neutralColor, fontSize: 10)),
          Text(value,
              style:
                  const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        ],
      ),
    );
  }
}

// _StatusBadge: OPEN (green) / CLOSED (gray) / EXPIRED (red) pill.
class _StatusBadge extends StatelessWidget {
  final TradeStatus status;
  const _StatusBadge(this.status);

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      TradeStatus.open => ('OPEN', AppTheme.profitColor),
      TradeStatus.closed => ('CLOSED', AppTheme.neutralColor),
      TradeStatus.expired => ('EXPIRED', AppTheme.lossColor),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
            color: color, fontSize: 12, fontWeight: FontWeight.w800),
      ),
    );
  }
}

// _DetailRow: label on left, value on right — used in the details grid card.
class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  const _DetailRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: AppTheme.neutralColor)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// _GreekBox: dark inset box showing a single Greek value (Delta or IV Rank).
class _GreekBox extends StatelessWidget {
  final String label;
  final String value;
  const _GreekBox({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.cardColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(color: AppTheme.neutralColor, fontSize: 12)),
            const SizedBox(height: 4),
            Text(value,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          ],
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------
// SEC filings mini-feed for this ticker
// Watches secFilingsForTickerProvider(ticker) → SecService.getFilingsForTicker()
// Renders up to 5 _SecFilingRow items with EDGAR link launching.
// ----------------------------------------------------------------
class _SecFilingsSection extends ConsumerWidget {
  final String ticker;
  const _SecFilingsSection({required this.ticker});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filingsAsync = ref.watch(secFilingsForTickerProvider(ticker));

    return filingsAsync.when(
      loading: () => const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Row(
            children: [
              SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 12),
              Text('Loading SEC filings…',
                  style: TextStyle(color: AppTheme.neutralColor)),
            ],
          ),
        ),
      ),
      error: (e, _) => const SizedBox.shrink(),
      data: (filings) {
        if (filings.isEmpty) return const SizedBox.shrink();
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.article_outlined,
                        size: 16, color: AppTheme.neutralColor),
                    const SizedBox(width: 6),
                    Text(
                      'SEC Filings — $ticker',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 15),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ...filings.take(5).map((f) => _SecFilingRow(filing: f)),
              ],
            ),
          ),
        );
      },
    );
  }
}

// _SecFilingRow: tappable row showing form-type badge, label, and date.
// Color-coded by SecFiling.category: earnings=blue, event=yellow,
// insider=green, holder=purple. Tap opens EDGAR HTML link.
class _SecFilingRow extends StatelessWidget {
  final SecFiling filing;
  const _SecFilingRow({required this.filing});

  Color get _typeColor => switch (filing.category) {
        'earnings' => const Color(0xFF7EC8E3), // sky-blue
        'event'    => const Color(0xFFFFD166), // golden-yellow
        'insider'  => AppTheme.profitColor,    // teal-green
        'holder'   => const Color(0xFFBBABFF), // bright lavender
        _ => AppTheme.neutralColor,
      };

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () async {
        final uri = Uri.parse(filing.linkToHtml);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: _typeColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                filing.formType,
                style: TextStyle(
                    color: _typeColor,
                    fontSize: 10,
                    fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                filing.formLabel,
                style: const TextStyle(fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              DateFormat('MMM d, yy').format(filing.filedAt),
              style: const TextStyle(
                  color: AppTheme.neutralColor, fontSize: 11),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right,
                size: 16, color: AppTheme.neutralColor),
          ],
        ),
      ),
    );
  }
}
