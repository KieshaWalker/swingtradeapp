// =============================================================================
// features/dashboard/screens/dashboard_screen.dart — Home overview
// =============================================================================
// Widgets defined here:
//   • DashboardScreen (ConsumerWidget) — root scaffold; watches tradesProvider
//   • _Dashboard      (StatelessWidget) — main content; computes stats from trades
//   • _StatCard       — icon + value + label card; used in 2×2 grid
//   • _PnLChart       — cumulative P&L LineChart (fl_chart); built from closed trades
//   • _OpenTradeRow   (ConsumerWidget) — single open position row with live quote
//
// Route: '/' in router.dart, tab index 0 in _AppShell
//
// Providers consumed:
//   • tradesProvider       — all user trades (Supabase 'trades' table)
//   • currentUserProvider  — email for greeting
//   • authNotifierProvider — signOut() on logout button press
//   • quoteProvider(ticker)— live FMP price shown per open trade in _OpenTradeRow
//
// Data flow:
//   tradesProvider → _Dashboard splits into _closed / _open lists
//     _closed → _totalPnl, _winRate, _avgReturn, _PnLChart
//     _open   → open trades count, _OpenTradeRow list (first 3)
//
// Navigation out:
//   _OpenTradeRow tap → context.push('/trades/${trade.id}', extra: trade)
//     → TradeDetailScreen
// =============================================================================
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme.dart';
import '../../../services/fmp/fmp_providers.dart';
import '../../auth/providers/auth_provider.dart';
import '../../trades/models/trade.dart';
import '../../trades/providers/trades_provider.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncTrades = ref.watch(tradesProvider);
    final user = ref.watch(currentUserProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () =>
                ref.read(authNotifierProvider.notifier).signOut(),
          ),
        ],
      ),
      body: asyncTrades.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (trades) => _Dashboard(trades: trades, email: user?.email ?? ''),
      ),
    );
  }
}

class _Dashboard extends StatelessWidget {
  final List<Trade> trades;
  final String email;
  const _Dashboard({required this.trades, required this.email});

  List<Trade> get _closed =>
      trades.where((t) => t.status == TradeStatus.closed).toList();

  List<Trade> get _open =>
      trades.where((t) => t.status == TradeStatus.open).toList();

  double get _totalPnl =>
      _closed.fold(0.0, (sum, t) => sum + (t.realizedPnl ?? 0));

  double get _winRate {
    if (_closed.isEmpty) return 0;
    final wins = _closed.where((t) => (t.realizedPnl ?? 0) > 0).length;
    return wins / _closed.length * 100;
  }

  double get _avgReturn {
    if (_closed.isEmpty) return 0;
    final total =
        _closed.fold(0.0, (s, t) => s + (t.pnlPercent ?? 0));
    return total / _closed.length;
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async {},
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Hey, ${email.split('@').first} 👋',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          const Text(
            'Here\'s your trading overview.',
            style: TextStyle(color: AppTheme.neutralColor),
          ),
          const SizedBox(height: 24),

          // Stat cards
          Row(
            children: [
              Expanded(
                child: _StatCard(
                  label: 'Total P&L',
                  value: '${_totalPnl >= 0 ? '+' : ''}\$${_totalPnl.toStringAsFixed(0)}',
                  color: _totalPnl >= 0 ? AppTheme.profitColor : AppTheme.lossColor,
                  icon: Icons.account_balance_wallet_outlined,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatCard(
                  label: 'Win Rate',
                  value: '${_winRate.toStringAsFixed(0)}%',
                  color: _winRate >= 50 ? AppTheme.profitColor : AppTheme.lossColor,
                  icon: Icons.emoji_events_outlined,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _StatCard(
                  label: 'Open Trades',
                  value: '${_open.length}',
                  color: AppTheme.profitColor,
                  icon: Icons.show_chart,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatCard(
                  label: 'Avg Return',
                  value: '${_avgReturn >= 0 ? '+' : ''}${_avgReturn.toStringAsFixed(1)}%',
                  color: _avgReturn >= 0 ? AppTheme.profitColor : AppTheme.lossColor,
                  icon: Icons.trending_up,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // P&L chart
          if (_closed.isNotEmpty) ...[
            const Text(
              'Cumulative P&L',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const SizedBox(height: 12),
            _PnLChart(trades: _closed),
            const SizedBox(height: 24),
          ],

          // Open trades preview
          if (_open.isNotEmpty) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Open Positions',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                ),
                TextButton(
                  onPressed: () {},
                  child: const Text('See all →'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ..._open.take(3).map((t) => _OpenTradeRow(trade: t)),
          ],

          if (trades.isEmpty) ...[
            const SizedBox(height: 60),
            const Center(
              child: Column(
                children: [
                  Icon(Icons.candlestick_chart_outlined,
                      size: 64, color: AppTheme.neutralColor),
                  SizedBox(height: 16),
                  Text(
                    'No trades yet.\nGo to Trade Log to get started.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.neutralColor),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final IconData icon;

  const _StatCard({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 8),
            Text(value,
                style: TextStyle(
                    color: color,
                    fontSize: 22,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(label,
                style: const TextStyle(
                    color: AppTheme.neutralColor, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

class _PnLChart extends StatelessWidget {
  final List<Trade> trades;
  const _PnLChart({required this.trades});

  @override
  Widget build(BuildContext context) {
    // Sort by close date and build cumulative P&L spots
    final sorted = [...trades]
      ..sort((a, b) => (a.closedAt ?? a.openedAt)
          .compareTo(b.closedAt ?? b.openedAt));

    double cumulative = 0;
    final spots = <FlSpot>[];
    for (var i = 0; i < sorted.length; i++) {
      cumulative += sorted[i].realizedPnl ?? 0;
      spots.add(FlSpot(i.toDouble(), cumulative));
    }

    final isPositive = cumulative >= 0;
    final lineColor = isPositive ? AppTheme.profitColor : AppTheme.lossColor;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 20, 20, 12),
        child: SizedBox(
          height: 180,
          child: LineChart(
            LineChartData(
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                getDrawingHorizontalLine: (_) => FlLine(
                  color: Colors.white.withValues(alpha: 0.05),
                  strokeWidth: 1,
                ),
              ),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 60,
                    getTitlesWidget: (v, _) => Text(
                      '\$${v.toStringAsFixed(0)}',
                      style: const TextStyle(
                          color: AppTheme.neutralColor, fontSize: 10),
                    ),
                  ),
                ),
                bottomTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                topTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              ),
              lineBarsData: [
                LineChartBarData(
                  spots: spots,
                  isCurved: true,
                  color: lineColor,
                  barWidth: 2.5,
                  dotData: const FlDotData(show: false),
                  belowBarData: BarAreaData(
                    show: true,
                    color: lineColor.withValues(alpha: 0.1),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// _OpenTradeRow: one row per open trade in the "Open Positions" preview.
// Fetches a live FMP quote (quoteProvider) to show current stock price & change.
// Tapping navigates to TradeDetailScreen via /trades/:id.
class _OpenTradeRow extends ConsumerWidget {
  final Trade trade;
  const _OpenTradeRow({required this.trade});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final daysLeft = trade.expiration.difference(DateTime.now()).inDays;
    final urgentColor =
        daysLeft <= 7 ? AppTheme.lossColor : AppTheme.neutralColor;
    final quoteAsync = ref.watch(quoteProvider(trade.ticker));

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        title: Text(
          '${trade.ticker} \$${trade.strike.toStringAsFixed(0)} ${trade.optionType.name.toUpperCase()}',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: quoteAsync.when(
          loading: () => Text(
            '${trade.strategy.label} · loading price…',
            style: const TextStyle(color: AppTheme.neutralColor, fontSize: 12),
          ),
          error: (e, _) => Text(
            trade.strategy.label,
            style: const TextStyle(color: AppTheme.neutralColor, fontSize: 12),
          ),
          data: (quote) {
            if (quote == null) {
              return Text(
                trade.strategy.label,
                style:
                    const TextStyle(color: AppTheme.neutralColor, fontSize: 12),
              );
            }
            final changeColor = quote.isPositive
                ? AppTheme.profitColor
                : AppTheme.lossColor;
            return RichText(
              text: TextSpan(
                style: const TextStyle(fontSize: 12),
                children: [
                  TextSpan(
                    text: '\$${quote.price.toStringAsFixed(2)} ',
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                  TextSpan(
                    text:
                        '${quote.isPositive ? '+' : ''}${quote.changePercent.toStringAsFixed(2)}%',
                    style: TextStyle(color: changeColor),
                  ),
                  const TextSpan(
                    text: '  ·  ',
                    style: TextStyle(color: AppTheme.neutralColor),
                  ),
                  TextSpan(
                    text: trade.strategy.label,
                    style: const TextStyle(color: AppTheme.neutralColor),
                  ),
                ],
              ),
            );
          },
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '$daysLeft DTE',
              style: TextStyle(
                  color: urgentColor,
                  fontWeight: FontWeight.w700,
                  fontSize: 13),
            ),
            Text(
              'Entry \$${trade.entryPrice.toStringAsFixed(2)}',
              style: const TextStyle(
                  color: AppTheme.neutralColor, fontSize: 11),
            ),
          ],
        ),
        onTap: () => context.push('/trades/${trade.id}', extra: trade),
      ),
    );
  }
}
