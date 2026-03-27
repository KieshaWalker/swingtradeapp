// =============================================================================
// features/economy/screens/economy_pulse_screen.dart — Economy Pulse tab
// =============================================================================
// Two-tab screen:
//   Snapshot — real-time macroeconomic dashboard sourced from FMP
//   Charts   — day-by-day / monthly historical charts from Supabase
//
// Each time the Snapshot data loads the latest values are upserted into the
// three Supabase economy snapshot tables so charts accumulate over time.
//
// Provider: economyPulseProvider (fmp_providers.dart)
// Model:    EconomyPulseData     (fmp_models.dart)
// Storage:  EconomyStorageService via economyStorageServiceProvider
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/app_menu_button.dart';
import '../../../services/economy/economy_storage_providers.dart';
import '../../../services/fmp/fmp_models.dart';
import '../../../services/fmp/fmp_providers.dart';
import '../widgets/economy_charts_tab.dart';

class EconomyPulseScreen extends ConsumerWidget {
  const EconomyPulseScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pulseAsync = ref.watch(economyPulseProvider);

    // Persist data to Supabase each time a fresh fetch succeeds
    ref.listen<AsyncValue<EconomyPulseData>>(economyPulseProvider, (_, next) {
      next.whenData((data) {
        ref.read(economyStorageServiceProvider).saveEconomyPulse(data);
      });
    });

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Economy Pulse'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
              onPressed: () => ref.invalidate(economyPulseProvider),
            ),
            const AppMenuButton(),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Snapshot'),
              Tab(text: 'Charts'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            pulseAsync.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.wifi_off_outlined,
                        size: 48, color: AppTheme.neutralColor),
                    const SizedBox(height: 12),
                    const Text('Could not load economic data'),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: () => ref.invalidate(economyPulseProvider),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
              data: (data) => _PulseBody(data: data),
            ),
            const EconomyChartsTab(),
          ],
        ),
      ),
    );
  }
}

// ─── Body ─────────────────────────────────────────────────────────────────────

class _PulseBody extends StatelessWidget {
  final EconomyPulseData data;
  const _PulseBody({required this.data});

  @override
  Widget build(BuildContext context) {
    final fetchTime =
        '${data.fetchedAt.hour.toString().padLeft(2, '0')}:${data.fetchedAt.minute.toString().padLeft(2, '0')}';

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        // Timestamp
        Text(
          'Updated $fetchTime',
          style: const TextStyle(color: AppTheme.neutralColor, fontSize: 11),
        ),
        const SizedBox(height: 16),

        // ── Market Snapshot ────────────────────────────────────────────────
        _SectionHeader('Market Snapshot'),
        _TileGrid(children: [
          _QuoteTile(label: 'S&P 500', sublabel: 'SPY', quote: data.sp500),
          _QuoteTile(label: 'Nasdaq 100', sublabel: 'QQQ', quote: data.nasdaq),
          _QuoteTile(label: 'VIX', sublabel: 'Fear Index', quote: data.vix,
              invertColor: true),
          _QuoteTile(label: 'Dollar Index', sublabel: 'UUP', quote: data.dxy),
        ]),
        const SizedBox(height: 20),

        // ── Interest Rates ────────────────────────────────────────────────
        _SectionHeader('Interest Rates'),
        _TileGrid(children: [
          _EconTile(
            label: 'Fed Funds',
            sublabel: 'Target Rate',
            point: data.fedFunds,
            format: _fmtPct,
          ),
          _EconTile(
            label: 'Mortgage 30Y',
            sublabel: 'Fixed Rate Avg',
            point: data.mortgageRate,
            format: _fmtPct,
          ),
          _YieldTile(
            label: '2Y Treasury',
            value: data.treasury?.year2,
            date: data.treasury?.date,
          ),
          _YieldTile(
            label: '10Y Treasury',
            value: data.treasury?.year10,
            date: data.treasury?.date,
          ),
          _YieldTile(
            label: '5Y Treasury',
            value: data.treasury?.year5,
            date: data.treasury?.date,
          ),
          _YieldTile(
            label: '30Y Treasury',
            value: data.treasury?.year30,
            date: data.treasury?.date,
          ),
        ]),
        const SizedBox(height: 20),

        // ── Commodities ───────────────────────────────────────────────────
        _SectionHeader('Commodities'),
        _TileGrid(children: [
          _QuoteTile(label: 'Gold', sublabel: 'GC=F', quote: data.gold,
              pricePrefix: '\$'),
          _QuoteTile(label: 'Silver', sublabel: 'SI=F', quote: data.silver,
              pricePrefix: '\$'),
          _QuoteTile(label: 'WTI Crude', sublabel: 'CL=F', quote: data.wtiCrude,
              pricePrefix: '\$'),
          _QuoteTile(label: 'Natural Gas', sublabel: 'NG=F', quote: data.natGas,
              pricePrefix: '\$'),
        ]),
        const SizedBox(height: 20),

        // ── Labor Market ──────────────────────────────────────────────────
        _SectionHeader('Labor Market'),
        _TileGrid(children: [
          _EconTile(
            label: 'Unemployment',
            sublabel: 'Rate',
            point: data.unemployment,
            format: _fmtPct,
            warnHigh: true,
          ),
          _EconTile(
            label: 'Non-Farm Payrolls',
            sublabel: 'Jobs Added',
            point: data.nfp,
            format: _fmtJobsK,
            showSign: true,
          ),
          _EconTile(
            label: 'Initial Claims',
            sublabel: 'Weekly Jobless',
            point: data.initialClaims,
            format: _fmtJobsK,
            warnHigh: true,
          ),
          _EconTile(
            label: 'Consumer Sentiment',
            sublabel: 'Univ. of Michigan',
            point: data.consumerSentiment,
            format: _fmtNum,
          ),
        ]),
        const SizedBox(height: 20),

        // ── Economy ───────────────────────────────────────────────────────
        _SectionHeader('Economy'),
        _TileGrid(children: [
          _EconTile(
            label: 'CPI',
            sublabel: 'Inflation Rate',
            point: data.cpi,
            format: _fmtPct,
            warnHigh: true,
          ),
          _EconTile(
            label: 'Real GDP',
            sublabel: 'Billions USD',
            point: data.gdp,
            format: _fmtGdp,
          ),
          _EconTile(
            label: 'Retail Sales',
            sublabel: 'Monthly (M)',
            point: data.retailSales,
            format: _fmtRetail,
          ),
          _EconTile(
            label: 'Recession Prob.',
            sublabel: 'Smoothed Model',
            point: data.recessionProb,
            format: _fmtPct,
            warnHigh: true,
          ),
        ]),
        const SizedBox(height: 20),

        // ── Housing ───────────────────────────────────────────────────────
        _SectionHeader('Housing'),
        _TileGrid(children: [
          _EconTile(
            label: 'Housing Starts',
            sublabel: 'New Units (K)',
            point: data.housingStarts,
            format: _fmtHousing,
          ),
        ]),
      ],
    );
  }
}

// ─── Formatters ───────────────────────────────────────────────────────────────

String _fmtPct(double v) => '${v.toStringAsFixed(2)}%';
String _fmtNum(double v) => v.toStringAsFixed(1);
String _fmtJobsK(double v) {
  final k = v / 1000;
  return k >= 1000
      ? '${(k / 1000).toStringAsFixed(1)}M'
      : '${k.toStringAsFixed(0)}K';
}

String _fmtGdp(double v) {
  // FMP returns real GDP in billions
  if (v >= 1000) return '\$${(v / 1000).toStringAsFixed(1)}T';
  return '\$${v.toStringAsFixed(0)}B';
}

String _fmtRetail(double v) {
  if (v.abs() >= 1000) return '\$${(v / 1000).toStringAsFixed(1)}B';
  return '\$${v.toStringAsFixed(0)}M';
}

String _fmtHousing(double v) {
  // FMP returns housing starts in thousands of units
  return '${v.toStringAsFixed(0)}K';
}

String _fmtDate(DateTime d) {
  const months = [
    '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${months[d.month]} ${d.year}';
}

// ─── Layout widgets ───────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          color: AppTheme.neutralColor,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _TileGrid extends StatelessWidget {
  final List<Widget> children;
  const _TileGrid({required this.children});

  @override
  Widget build(BuildContext context) {
    // Pair children into rows of 2
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += 2) {
      final hasSecond = i + 1 < children.length;
      rows.add(Row(
        children: [
          Expanded(child: children[i]),
          const SizedBox(width: 8),
          Expanded(child: hasSecond ? children[i + 1] : const SizedBox()),
        ],
      ));
      if (i + 2 < children.length) rows.add(const SizedBox(height: 8));
    }
    return Column(children: rows);
  }
}

// ─── Tile types ───────────────────────────────────────────────────────────────

// Base tile container
class _Tile extends StatelessWidget {
  final Widget child;
  const _Tile({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: child,
    );
  }
}

// Live asset quote tile (price + change%)
class _QuoteTile extends StatelessWidget {
  final String label;
  final String sublabel;
  final StockQuote? quote;
  final bool invertColor; // VIX: high = bad (red)
  final String pricePrefix;

  const _QuoteTile({
    required this.label,
    required this.sublabel,
    required this.quote,
    this.invertColor = false,
    this.pricePrefix = '',
  });

  @override
  Widget build(BuildContext context) {
    if (quote == null) return _Tile(child: _PlaceholderContent(label, sublabel));

    final positive = invertColor ? !quote!.isPositive : quote!.isPositive;
    final changeColor =
        positive ? AppTheme.profitColor : AppTheme.lossColor;
    final sign = quote!.changePercent >= 0 ? '+' : '';

    return _Tile(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TileLabel(label, sublabel),
          const SizedBox(height: 6),
          Text(
            '$pricePrefix${_fmtPrice(quote!.price)}',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '$sign${quote!.changePercent.toStringAsFixed(2)}%',
            style: TextStyle(
              color: changeColor,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  static String _fmtPrice(double p) {
    if (p >= 1000) return p.toStringAsFixed(0);
    if (p >= 100) return p.toStringAsFixed(2);
    return p.toStringAsFixed(2);
  }
}

// Economic indicator tile (lagging data + report date)
class _EconTile extends StatelessWidget {
  final String label;
  final String sublabel;
  final EconomicIndicatorPoint? point;
  final String Function(double) format;
  final bool warnHigh; // high value = yellow/red warning (unemployment, CPI)
  final bool showSign;

  const _EconTile({
    required this.label,
    required this.sublabel,
    required this.point,
    required this.format,
    this.warnHigh = false,
    this.showSign = false,
  });

  @override
  Widget build(BuildContext context) {
    if (point == null) return _Tile(child: _PlaceholderContent(label, sublabel));

    Color valueColor = Colors.white;
    if (warnHigh) {
      // No threshold — show neutral. Could add thresholds later.
      valueColor = Colors.white;
    }

    final raw = format(point!.value);
    final display = showSign && point!.value >= 0 ? '+$raw' : raw;

    return _Tile(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TileLabel(label, sublabel),
          const SizedBox(height: 6),
          Text(
            display,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
              color: valueColor,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _fmtDate(point!.date),
            style: const TextStyle(
              color: AppTheme.neutralColor,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

// Treasury yield tile (single maturity value)
class _YieldTile extends StatelessWidget {
  final String label;
  final double? value;
  final DateTime? date;

  const _YieldTile({
    required this.label,
    required this.value,
    required this.date,
  });

  @override
  Widget build(BuildContext context) {
    if (value == null) {
      return _Tile(child: _PlaceholderContent(label, 'Treasury'));
    }

    return _Tile(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TileLabel(label, 'Treasury'),
          const SizedBox(height: 6),
          Text(
            '${value!.toStringAsFixed(2)}%',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            date != null ? _fmtDate(date!) : '—',
            style: const TextStyle(
              color: AppTheme.neutralColor,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

// Shared label row used inside every tile
class _TileLabel extends StatelessWidget {
  final String title;
  final String sub;
  const _TileLabel(this.title, this.sub);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          sub,
          style: const TextStyle(
            color: AppTheme.neutralColor,
            fontSize: 10,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _PlaceholderContent extends StatelessWidget {
  final String label;
  final String sub;
  const _PlaceholderContent(this.label, this.sub);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TileLabel(label, sub),
        const SizedBox(height: 6),
        const Text('—',
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppTheme.neutralColor)),
        const SizedBox(height: 2),
        const Text('No data',
            style:
                TextStyle(color: AppTheme.neutralColor, fontSize: 11)),
      ],
    );
  }
}
