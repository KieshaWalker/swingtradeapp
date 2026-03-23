// =============================================================================
// features/trades/screens/trades_screen.dart — Trade log with open/closed tabs
// =============================================================================
// Widgets defined here:
//   • TradesScreen  (ConsumerStatefulWidget) — scaffold + TabBar (Open / Closed)
//                                              + FAB "New Trade" → /trades/add
//   • _TradeList    (ConsumerWidget)         — filtered ListView of _TradeCard;
//                                              pull-to-refresh via tradesProvider
//   • _TradeCard    (ConsumerWidget)         — tappable card per trade showing:
//                                              ticker, CALL/PUT badge, strategy badge,
//                                              PnL $, strike, expiration, contracts,
//                                              entry→exit price, PnL %
//   • _Badge        — colored pill label (option type or strategy)
//   • _InfoChip     — icon + text chip (strike, expiration, contracts)
//
// Route: '/trades' in router.dart, tab index 1 in _AppShell
//
// Providers consumed:
//   • tradesProvider — all trades; filtered here to open or closed list
//
// Navigation out:
//   • _TradeCard tap → context.push('/trades/${trade.id}', extra: trade)
//     → TradeDetailScreen
//   • FAB            → context.push('/trades/add') → AddTradeScreen
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../core/theme.dart';
import '../models/trade.dart';
import '../providers/trades_provider.dart';

class TradesScreen extends ConsumerStatefulWidget {
  const TradesScreen({super.key});

  @override
  ConsumerState<TradesScreen> createState() => _TradesScreenState();
}

class _TradesScreenState extends ConsumerState<TradesScreen>
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
        title: const Text('Trade Log'),
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
      body: TabBarView(
        controller: _tabController,
        children: [
          _TradeList(filter: TradeStatus.open),
          _TradeList(filter: TradeStatus.closed),
        ],
      ),
    );
  }
}

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
                const Icon(Icons.show_chart, size: 48, color: AppTheme.neutralColor),
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

class _TradeCard extends ConsumerWidget {
  final Trade trade;
  const _TradeCard({required this.trade});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pnl = trade.realizedPnl;
    final pnlColor = pnl == null
        ? AppTheme.neutralColor
        : pnl >= 0
            ? AppTheme.profitColor
            : AppTheme.lossColor;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push('/trades/${trade.id}', extra: trade),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // Ticker + type badge
                  Text(
                    trade.ticker,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
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
                  const Spacer(),
                  if (pnl != null)
                    Text(
                      '${pnl >= 0 ? '+' : ''}\$${pnl.toStringAsFixed(0)}',
                      style: TextStyle(
                        color: pnlColor,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
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
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(
                    'Entry: \$${trade.entryPrice.toStringAsFixed(2)}',
                    style: const TextStyle(color: AppTheme.neutralColor, fontSize: 13),
                  ),
                  if (trade.exitPrice != null) ...[
                    const Text(
                      ' → ',
                      style: TextStyle(color: AppTheme.neutralColor, fontSize: 13),
                    ),
                    Text(
                      'Exit: \$${trade.exitPrice!.toStringAsFixed(2)}',
                      style: const TextStyle(color: AppTheme.neutralColor, fontSize: 13),
                    ),
                  ],
                  const Spacer(),
                  if (pnl != null && trade.pnlPercent != null)
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
            ],
          ),
        ),
      ),
    );
  }
}

// _Badge: colored pill used for option type (CALL=green, PUT=red) and strategy name.
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
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
      ),
    );
  }
}

// _InfoChip: small icon + label used for strike, expiration date, contract count.
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
            style: const TextStyle(color: AppTheme.neutralColor, fontSize: 13)),
      ],
    );
  }
}
