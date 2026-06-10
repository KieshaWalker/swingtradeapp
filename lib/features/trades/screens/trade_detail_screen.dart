// =============================================================================
// features/trades/screens/trade_detail_screen.dart — Full trade view
// =============================================================================
// Widgets defined here:
//   • TradeDetailScreen  (ConsumerWidget) — receives Trade via GoRouter extra;
//                          scrollable detail view with header, quote, details,
//                          Greeks, notes, SEC filings sections
//   • _LiveQuoteCard     (ConsumerWidget) — live price card with open/high/
//                          low/prev-close stats; powered by quoteProvider(symbol)
//   • _QuoteStat         — label + value column used inside _LiveQuoteCard
//   • _StatusBadge       — OPEN/CLOSED/EXPIRED pill; color from AppTheme
//   • _DetailRow         — label ↔ value row used in the details grid card
//   • _GreekBox          — Delta / IV Rank box; shown only if values were entered
//   • _SecFilingsSection — SEC EDGAR link card for the trade's ticker
//
// Route: '/trades/:id' (child of /trades in router.dart)
//        — reached by tapping a _TradeCard or _OpenTradeRow
//
// Providers consumed:
//   • quoteProvider(trade.ticker)              — live stock price (_LiveQuoteCard)
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
import '../../../services/schwab/schwab_providers.dart';
import '../../../services/iv/iv_providers.dart';
import '../../../features/strategy_tracker/providers/strategy_tracker_provider.dart';
import '../models/trade.dart';
import '../providers/trades_provider.dart';
import '../services/live_greeks_service.dart';

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

    final partialCloses =
        ref.watch(partialClosesProvider(trade.id)).valueOrNull ?? [];
    final closedContracts =
        partialCloses.fold<int>(0, (s, c) => s + c.contractsClosed);
    final remainingContracts = trade.contracts - closedContracts;

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
              onPressed: () => _showCloseDialog(context, remainingContracts),
              icon: const Icon(Icons.check_circle_outline),
              label: const Text('Close'),
              style: TextButton.styleFrom(foregroundColor: AppTheme.profitColor),
            ),
          if (trade.status != TradeStatus.open)
            TextButton.icon(
              onPressed: () =>
                  context.push('/trades/${trade.id}/journal', extra: trade),
              icon: const Icon(Icons.book_outlined),
              label: const Text('Journal'),
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

          // Live stock quote from Schwab
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
                  _DetailRow(
                    'Contracts',
                    closedContracts > 0
                        ? '${trade.contracts} total · $remainingContracts remaining'
                        : '${trade.contracts}',
                  ),
                  _DetailRow('Entry Premium',
                      '\$${trade.entryPrice.toStringAsFixed(4)} / share'),
                  _DetailRow('Cost Basis',
                      '\$${trade.costBasis.toStringAsFixed(2)}'),
                  if (trade.exitPrice != null)
                    _DetailRow('Exit Premium',
                        '\$${trade.exitPrice!.toStringAsFixed(4)} / share'),
                  if (trade.stopLoss != null)
                    _DetailRow('Stop Loss', '\$${trade.stopLoss!.toStringAsFixed(2)}'),
                  if (trade.takeProfit != null)
                    _DetailRow('Take Profit', '\$${trade.takeProfit!.toStringAsFixed(2)}'),
                  if (trade.maxLoss != null)
                    _DetailRow('Max Loss', '\$${trade.maxLoss!.toStringAsFixed(2)}'),
                  if (trade.entryPointType != null)
                    _DetailRow('Entry Point', trade.entryPointType!.label),
                  if (trade.timeOfEntry != null)
                    _DetailRow('Time of Entry', trade.timeOfEntry!),
                  if (trade.timeOfExit != null)
                    _DetailRow('Time of Exit', trade.timeOfExit!),
                  _DetailRow(
                    'IV at Entry',
                    trade.impliedVolEntry != null
                        ? '${trade.impliedVolEntry!.toStringAsFixed(1)}%'
                        : '—',
                  ),
                  if (trade.impliedVolExit != null)
                    _DetailRow('IV at Exit', '${trade.impliedVolExit!.toStringAsFixed(1)}%'),
                  if (trade.priceRangeHigh != null && trade.priceRangeLow != null)
                    _DetailRow('Price Range',
                        '\$${trade.priceRangeLow!.toStringAsFixed(2)} – \$${trade.priceRangeHigh!.toStringAsFixed(2)}'),
                  if (trade.intradaySupport != null)
                    _DetailRow('Intraday Support', '\$${trade.intradaySupport!.toStringAsFixed(2)}'),
                  if (trade.intradayResistance != null)
                    _DetailRow('Intraday Resistance', '\$${trade.intradayResistance!.toStringAsFixed(2)}'),
                  if (trade.dailyBreakoutLevel != null)
                    _DetailRow('Daily Breakout', '\$${trade.dailyBreakoutLevel!.toStringAsFixed(2)}'),
                  if (trade.dailyBreakdownLevel != null)
                    _DetailRow('Daily Breakdown', '\$${trade.dailyBreakdownLevel!.toStringAsFixed(2)}'),
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

          // Partial close history — shown whenever any legs have been closed
          if (partialCloses.isNotEmpty) ...[
            _PartialClosesCard(
              trade: trade,
              partialCloses: partialCloses,
              remainingContracts: remainingContracts,
            ),
            const SizedBox(height: 12),
          ],

          // Live Greeks card (recomputed from current spot + IV)
          if (trade.status == TradeStatus.open)
            _LiveGreeksCard(trade: trade),
          if (trade.status == TradeStatus.open) const SizedBox(height: 12),

          // Static entry Greeks
          if (trade.ivRank != null || trade.delta != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Entry Greeks',
                        style: TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 15)),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        if (trade.delta != null)
                          _GreekBox(
                              label: 'Delta',
                              value: trade.delta!.toStringAsFixed(3)),
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

          // Strategy tag
          _StrategyTagCard(tradeId: trade.id),
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

  void _showCloseDialog(BuildContext context, int remainingContracts) {
    showDialog(
      context: context,
      builder: (_) => _CloseTradeDialog(
        trade: trade,
        remainingContracts: remainingContracts,
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
// Live Greeks card — recomputes BS Greeks from current spot + IV.
// Only shown for open trades. Falls back gracefully when data is loading.
// ----------------------------------------------------------------
class _LiveGreeksCard extends ConsumerStatefulWidget {
  final Trade trade;
  const _LiveGreeksCard({required this.trade});

  @override
  ConsumerState<_LiveGreeksCard> createState() => _LiveGreeksCardState();
}

class _LiveGreeksCardState extends ConsumerState<_LiveGreeksCard> {
  LiveGreeks? _greeks;
  double?     _lastSpot;
  double?     _lastIv;

  void _maybeFetch(double spot, double iv, double dividendYield) {
    if (spot == _lastSpot && iv == _lastIv) return;
    _lastSpot = spot;
    _lastIv   = iv;
    fetchLiveGreeks(
      trade:         widget.trade,
      spot:          spot,
      currentIv:     iv,
      dividendYield: dividendYield,
    ).then((g) { if (mounted && g != null) setState(() => _greeks = g); });
  }

  @override
  Widget build(BuildContext context) {
    final quoteAsync = ref.watch(quoteProvider(widget.trade.ticker));
    final ivAsync    = ref.watch(ivAnalysisProvider(widget.trade.ticker));

    final spot          = quoteAsync.valueOrNull?.price;
    final iv            = ivAsync.valueOrNull?.currentIv;
    final dividendYield = quoteAsync.valueOrNull?.dividendYield ?? 0.0;

    if (spot == null || iv == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 12),
              Text(
                spot == null ? 'Loading live quote…' : 'Loading IV data…',
                style: const TextStyle(
                    color: AppTheme.neutralColor, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    _maybeFetch(spot, iv, dividendYield);

    final g = _greeks;
    if (g == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Row(children: [
            SizedBox(width: 14, height: 14,
                child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 12),
            Text('Computing Greeks…',
                style: TextStyle(color: AppTheme.neutralColor, fontSize: 13)),
          ]),
        ),
      );
    }

    final deltaColor = g.delta >= 0 ? AppTheme.profitColor : AppTheme.lossColor;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.bolt, size: 14, color: AppTheme.profitColor),
                const SizedBox(width: 6),
                const Text('Live Greeks',
                    style: TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15)),
                const Spacer(),
                Text(
                  'IV ${(g.impliedVol * 100).toStringAsFixed(1)}%  '
                  '· ${g.dteRemaining.toStringAsFixed(1)} DTE',
                  style: const TextStyle(
                      color: AppTheme.neutralColor, fontSize: 11),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // Primary Greeks row
            Row(
              children: [
                _GreekBox(
                    label: 'Δ Delta',
                    value: g.delta.toStringAsFixed(3),
                    valueColor: deltaColor),
                _GreekBox(
                    label: 'Γ Gamma',
                    value: g.gamma.toStringAsFixed(4)),
                _GreekBox(
                    label: 'θ Theta',
                    value: g.theta.toStringAsFixed(3)),
                _GreekBox(
                    label: 'ν Vega',
                    value: g.vega.toStringAsFixed(3)),
              ],
            ),
            const SizedBox(height: 10),
            // Second-order Greeks row
            Row(
              children: [
                _GreekBox(
                    label: 'Vanna',
                    value: g.vanna.toStringAsFixed(4)),
                _GreekBox(
                    label: 'Charm',
                    value: g.charm.toStringAsFixed(5)),
                _GreekBox(
                    label: 'Volga',
                    value: g.volga.toStringAsFixed(4)),
                const Expanded(child: SizedBox()),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------
// Live quote card powered by Schwab
// Watches quoteProvider(symbol) → SchwabService.getQuote()
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

// _GreekBox: dark inset box showing a single Greek value.
class _GreekBox extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  const _GreekBox({required this.label, required this.value, this.valueColor});

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
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: valueColor)),
          ],
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------
// SEC filings mini-feed for this ticker
class _SecFilingsSection extends StatelessWidget {
  final String ticker;
  const _SecFilingsSection({required this.ticker});

  @override
  Widget build(BuildContext context) {
    final uri = Uri.parse(
      'https://www.sec.gov/cgi-bin/browse-edgar'
      '?action=getcompany&CIK=$ticker&type=&dateb=&owner=include&count=40',
    );
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(Icons.article_outlined,
                  size: 16, color: AppTheme.neutralColor),
              const SizedBox(width: 6),
              Text(
                'SEC Filings — $ticker',
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 15),
              ),
              const Spacer(),
              const Text('View on EDGAR',
                  style: TextStyle(
                      color: AppTheme.neutralColor, fontSize: 12)),
              const SizedBox(width: 4),
              const Icon(Icons.open_in_new,
                  size: 14, color: AppTheme.neutralColor),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// _CloseTradeDialog — handles both full and partial closes.
// Shows a contracts field (prefilled with remaining) when trade has >1 contract.
// Calls addPartialClose which auto-closes the trade when all contracts are filled.
// =============================================================================

class _CloseTradeDialog extends ConsumerStatefulWidget {
  final Trade trade;
  final int remainingContracts;
  const _CloseTradeDialog({required this.trade, required this.remainingContracts});

  @override
  ConsumerState<_CloseTradeDialog> createState() => _CloseTradeDialogState();
}

class _CloseTradeDialogState extends ConsumerState<_CloseTradeDialog> {
  late final TextEditingController _contractsCtrl;
  final TextEditingController _exitCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _contractsCtrl =
        TextEditingController(text: widget.remainingContracts.toString());
  }

  @override
  void dispose() {
    _contractsCtrl.dispose();
    _exitCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isMulti = widget.trade.contracts > 1;
    return AlertDialog(
      backgroundColor: AppTheme.elevatedColor,
      title: Text(widget.remainingContracts == widget.trade.contracts
          ? 'Close Trade'
          : 'Close Position (${widget.remainingContracts} remaining)'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isMulti) ...[
            TextField(
              controller: _contractsCtrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Contracts to close',
                helperText: 'Max ${widget.remainingContracts}',
              ),
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _exitCtrl,
            autofocus: !isMulti,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Exit Premium (per share)',
              prefixText: '\$',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () async {
            final price = double.tryParse(_exitCtrl.text);
            if (price == null) return;
            final contracts = isMulti
                ? (int.tryParse(_contractsCtrl.text) ??
                        widget.remainingContracts)
                    .clamp(1, widget.remainingContracts)
                : widget.remainingContracts;
            await ref.read(tradesNotifierProvider.notifier).addPartialClose(
                  trade: widget.trade,
                  contractsClosed: contracts,
                  exitPrice: price,
                );
            if (context.mounted) {
              Navigator.pop(context);
              if (contracts >= widget.remainingContracts) context.pop();
            }
          },
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}

// =============================================================================
// _PartialClosesCard — close history with per-leg P&L and running totals.
// =============================================================================

class _PartialClosesCard extends StatelessWidget {
  final Trade trade;
  final List<PartialClose> partialCloses;
  final int remainingContracts;

  const _PartialClosesCard({
    required this.trade,
    required this.partialCloses,
    required this.remainingContracts,
  });

  @override
  Widget build(BuildContext context) {
    final totalPnl = partialCloses.fold<double>(0, (s, c) => s + c.pnl);
    final totalClosed =
        partialCloses.fold<int>(0, (s, c) => s + c.contractsClosed);
    final pnlColor =
        totalPnl >= 0 ? AppTheme.profitColor : AppTheme.lossColor;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'Partial Closes',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
                const Spacer(),
                Text(
                  '$totalClosed of ${trade.contracts} contracts',
                  style: const TextStyle(
                      color: AppTheme.neutralColor, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...partialCloses.map((c) => _PartialCloseRow(c, trade.entryPrice)),
            const Divider(height: 20),
            Row(
              children: [
                Text(
                  remainingContracts > 0
                      ? '$remainingContracts contracts remaining'
                      : 'Fully closed',
                  style: TextStyle(
                    fontSize: 12,
                    color: remainingContracts > 0
                        ? AppTheme.neutralColor
                        : AppTheme.profitColor,
                  ),
                ),
                const Spacer(),
                Text(
                  '${totalPnl >= 0 ? '+' : ''}\$${totalPnl.toStringAsFixed(2)} realized',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: pnlColor,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PartialCloseRow extends StatelessWidget {
  final PartialClose close;
  final double entryPrice;
  const _PartialCloseRow(this.close, this.entryPrice);

  @override
  Widget build(BuildContext context) {
    final pnlColor =
        close.pnl >= 0 ? AppTheme.profitColor : AppTheme.lossColor;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Text(
            DateFormat('MMM d').format(close.closedAt),
            style: const TextStyle(
                color: AppTheme.neutralColor, fontSize: 12),
          ),
          const SizedBox(width: 10),
          Text(
            '${close.contractsClosed} contract${close.contractsClosed > 1 ? 's' : ''}',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(width: 6),
          Text(
            '@ \$${close.exitPrice.toStringAsFixed(4)}',
            style: const TextStyle(
                color: AppTheme.neutralColor, fontSize: 12),
          ),
          const Spacer(),
          Text(
            '${close.pnl >= 0 ? '+' : ''}\$${close.pnl.toStringAsFixed(2)}',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color: pnlColor,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// _StrategyTagCard
// =============================================================================
// Shows the strategy currently tagged to this trade. Watches tradesProvider
// live so the tag updates instantly after edit without re-navigating.
// "Edit" opens a picker that lists all strategies + a "Remove tag" option.
// =============================================================================
class _StrategyTagCard extends ConsumerWidget {
  final String tradeId;
  const _StrategyTagCard({required this.tradeId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Get live strategy_setup_id for this trade
    final tradesValue      = ref.watch(tradesProvider);
    final currentSetupId   = tradesValue.valueOrNull
        ?.where((t) => t.id == tradeId)
        .firstOrNull
        ?.strategySetupId;

    // Get strategy name if tagged
    final setupsValue   = ref.watch(strategyTrackerProvider);
    final linkedSetup   = currentSetupId == null
        ? null
        : setupsValue.valueOrNull
            ?.where((s) => s.id == currentSetupId)
            .firstOrNull;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            const Icon(Icons.track_changes_rounded,
                size: 18, color: AppTheme.neutralColor),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Strategy',
                    style: TextStyle(
                      color:    AppTheme.neutralColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    linkedSetup?.name ?? 'No strategy tagged',
                    style: TextStyle(
                      color:      linkedSetup != null
                          ? Colors.white
                          : AppTheme.neutralColor,
                      fontSize:   14,
                      fontWeight: linkedSetup != null
                          ? FontWeight.w700
                          : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: () => _showPicker(context, ref, currentSetupId),
              child: Text(
                currentSetupId == null ? 'Tag' : 'Edit',
                style: const TextStyle(
                  color:      AppTheme.profitColor,
                  fontWeight: FontWeight.w700,
                  fontSize:   13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showPicker(
    BuildContext context,
    WidgetRef ref,
    String? currentSetupId,
  ) {
    final setups =
        ref.read(strategyTrackerProvider).valueOrNull ?? [];

    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.elevatedColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 8),
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: AppTheme.borderColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'TAG TO STRATEGY',
                  style: TextStyle(
                    color:         AppTheme.neutralColor,
                    fontSize:      11,
                    fontWeight:    FontWeight.w700,
                    letterSpacing: 1.0,
                  ),
                ),
              ),
            ),
            if (currentSetupId != null)
              ListTile(
                leading: const Icon(Icons.link_off,
                    color: AppTheme.lossColor, size: 20),
                title: const Text(
                  'Remove tag',
                  style: TextStyle(color: AppTheme.lossColor),
                ),
                onTap: () async {
                  Navigator.pop(context);
                  await ref
                      .read(tradesNotifierProvider.notifier)
                      .tagStrategy(tradeId, null);
                },
              ),
            if (setups.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text(
                  'No strategies yet. Create one in Strategy Tracker.',
                  style: TextStyle(color: AppTheme.neutralColor),
                  textAlign: TextAlign.center,
                ),
              )
            else
              for (final setup in setups)
                ListTile(
                  leading: Icon(
                    setup.id == currentSetupId
                        ? Icons.check_circle
                        : Icons.track_changes_rounded,
                    color: setup.id == currentSetupId
                        ? AppTheme.profitColor
                        : AppTheme.neutralColor,
                    size: 20,
                  ),
                  title: Text(
                    setup.name,
                    style: TextStyle(
                      color: setup.id == currentSetupId
                          ? AppTheme.profitColor
                          : Colors.white,
                      fontWeight: setup.id == currentSetupId
                          ? FontWeight.w700
                          : FontWeight.w400,
                    ),
                  ),
                  subtitle: setup.totalScored > 0
                      ? Text(
                          '${(setup.winRate * 100).toStringAsFixed(0)}% WR · '
                          '${setup.totalScored} trades',
                          style: const TextStyle(
                            color:    AppTheme.neutralColor,
                            fontSize: 11,
                          ),
                        )
                      : null,
                  onTap: () async {
                    Navigator.pop(context);
                    await ref
                        .read(tradesNotifierProvider.notifier)
                        .tagStrategy(tradeId, setup.id);
                  },
                ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
