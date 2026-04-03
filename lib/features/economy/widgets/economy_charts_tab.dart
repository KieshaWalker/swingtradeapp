// =============================================================================
// features/economy/widgets/economy_charts_tab.dart — historical chart views
// =============================================================================
// Displays day-by-day / monthly line charts for every Economy Pulse metric,
// reading from Supabase snapshot tables populated by various government APIs:
//
// Data Sources:
// - Market quotes (SPY, QQQ, VIXY, $DXY, commodities): Schwab API → economy_quote_snapshots
// - Treasury yields: Treasury API → economy_treasury_snapshots
// - Economic indicators (FMP): Financial Modeling Prep API → economy_indicator_snapshots
// - BLS data: Bureau of Labor Statistics API → economy_indicator_snapshots
// - BEA data: Bureau of Economic Analysis API → economy_indicator_snapshots
// - EIA data: Energy Information Administration API → economy_indicator_snapshots
// - Census data: US Census Bureau API → economy_indicator_snapshots
//
// Tap any chart card to expand it full-screen with interactive touch tooltips.
// =============================================================================
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/theme.dart';
import '../../../services/economy/economy_snapshot_models.dart';
import '../../../services/economy/economy_storage_providers.dart';
import '../../../services/fmp/fmp_models.dart';
import '../../../services/fmp/fmp_providers.dart';
import '../../../services/economy/economy_storage_service.dart';

// ─── Palette ──────────────────────────────────────────────────────────────────

const _blue = Color(0xFF58A6FF);
const _green = Color(0xFF56D364);
const _yellow = Color(0xFFE3B341);
const _purple = Color(0xFFBC8CFF);
const _red = Color(0xFFFF7B72);
const _teal = Color(0xFF39D353);
const _orange = Color(0xFFF78166);

// ─── Root tab widget ──────────────────────────────────────────────────────────

class EconomyChartsTab extends ConsumerWidget {
  const EconomyChartsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Fetch latest economy data from APIs and save to database
    // This ensures charts have fresh data even if economy pulse screen hasn't been visited
    ref.watch(economyPulseProvider);

    // Save economy pulse data to database when fetched
    final storage = ref.read(economyStorageServiceProvider);
    ref.listen<AsyncValue<EconomyPulseData>>(economyPulseProvider, (_, next) {
      next.whenData((data) {
        storage.saveEconomyPulse(data);
        // Invalidate quote history providers to refresh charts with new data
        ref.invalidate(economyQuoteHistoryProvider(r'$DXY'));
        ref.invalidate(economyQuoteHistoryProvider('/GC'));
        ref.invalidate(economyQuoteHistoryProvider('/SI'));
        ref.invalidate(economyQuoteHistoryProvider('/CL'));
        ref.invalidate(economyQuoteHistoryProvider('/NG'));
        ref.invalidate(economyQuoteHistoryProvider('SPY'));
        ref.invalidate(economyQuoteHistoryProvider('QQQ'));
        ref.invalidate(economyQuoteHistoryProvider('VIXY'));
      });
    });

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
      children: [
        _DataNote(),
        SizedBox(height: 20),

        // Market Snapshot - Live quotes from Schwab API (stored in economy_quote_snapshots)
        _SectionHeader('Market Snapshot'),
        SizedBox(height: 8),
        _QuoteChart(symbol: 'SPY', title: 'S&P 500', color: _blue),
        SizedBox(height: 8),
        _QuoteChart(symbol: 'QQQ', title: 'Nasdaq 100', color: _purple),
        SizedBox(height: 8),
        _QuoteChart(symbol: 'VIXY', title: 'VIX', color: _red),
        SizedBox(height: 8),
        _QuoteChart(symbol: r'$DXY', title: 'Dollar Index', color: _yellow),
        SizedBox(height: 24),

        // Interest Rates - Treasury yields from Treasury API (stored in economy_treasury_snapshots)
        _SectionHeader('Interest Rates'),
        SizedBox(height: 8),
        _TreasuryChart(),
        SizedBox(height: 8),
        // Economic indicators from FMP API (stored in economy_indicator_snapshots)
        _IndicatorChart(
          identifier: 'federalFunds',
          title: 'Fed Funds Rate',
          sublabel: 'Target Rate',
          color: _teal,
          formatY: _fmtPct,
        ),
        SizedBox(height: 8),
        _IndicatorChart(
          identifier: '30YearFixedRateMortgageAverage',
          title: 'Mortgage 30Y',
          sublabel: 'Fixed Rate Avg',
          color: _blue,
          formatY: _fmtPct,
        ),
        SizedBox(height: 24),

        // Commodities - Futures quotes from Schwab API (stored in economy_quote_snapshots)
        _SectionHeader('Commodities'),
        SizedBox(height: 8),
        _QuoteChart(symbol: '/GC', title: 'Gold', color: _yellow),
        SizedBox(height: 8),
        _QuoteChart(symbol: '/SI', title: 'Silver', color: Color(0xFFADB5BD)),
        SizedBox(height: 8),
        _QuoteChart(symbol: '/CL', title: 'WTI Crude', color: _orange),
        SizedBox(height: 8),
        _QuoteChart(symbol: '/NG', title: 'Natural Gas', color: _green),
        SizedBox(height: 24),

        // Labor Market - Economic indicators from FMP API (stored in economy_indicator_snapshots)
        _SectionHeader('Labor Market'),
        SizedBox(height: 8),
        _IndicatorChart(
          identifier: 'unemploymentRate',
          title: 'Unemployment Rate',
          sublabel: 'Monthly',
          color: _red,
          formatY: _fmtPct,
        ),
        SizedBox(height: 8),
        _IndicatorChart(
          identifier: 'totalNonfarmPayrolls',
          title: 'Non-Farm Payrolls',
          sublabel: 'Jobs Added',
          color: _green,
          formatY: _fmtJobsK,
        ),
        SizedBox(height: 8),
        _IndicatorChart(
          identifier: 'initialJoblessClaims',
          title: 'Initial Claims',
          sublabel: 'Weekly Jobless',
          color: _orange,
          formatY: _fmtJobsK,
        ),
        SizedBox(height: 8),
        _IndicatorChart(
          identifier: 'consumerSentiment',
          title: 'Consumer Sentiment',
          sublabel: 'Univ. of Michigan',
          color: _blue,
          formatY: _fmtNum,
        ),
        SizedBox(height: 24),

        // Economy - Economic indicators from FMP API (stored in economy_indicator_snapshots)
        _SectionHeader('Economy'),
        SizedBox(height: 8),
        _IndicatorChart(
          identifier: 'CPI',
          title: 'CPI',
          sublabel: 'Inflation Rate',
          color: _red,
          formatY: _fmtPct,
        ),
        SizedBox(height: 8),
        _IndicatorChart(
          identifier: 'realGDP',
          title: 'Real GDP',
          sublabel: 'Billions USD',
          color: _teal,
          formatY: _fmtGdpShort,
        ),
        SizedBox(height: 8),
        _IndicatorChart(
          identifier: 'retailSales',
          title: 'Retail Sales',
          sublabel: 'Monthly',
          color: _purple,
          formatY: _fmtRetailShort,
        ),
        SizedBox(height: 8),
        _IndicatorChart(
          identifier: 'smoothedUSRecessionProbabilities',
          title: 'Recession Probability',
          sublabel: 'Smoothed Model',
          color: _orange,
          formatY: _fmtPct,
        ),
        SizedBox(height: 24),

        // Housing - Economic indicators from FMP API (stored in economy_indicator_snapshots)
        _SectionHeader('Housing'),
        SizedBox(height: 8),
        _IndicatorChart(
          identifier: 'newPrivatelyOwnedHousingUnitsStartedTotalUnits',
          title: 'Housing Starts',
          sublabel: 'New Units (K)',
          color: _yellow,
          formatY: _fmtHousingShort,
        ),
        const SizedBox(height: 24),

        // BLS Employment - Data from Bureau of Labor Statistics API (stored in economy_indicator_snapshots)
        const _SectionHeader('BLS — Employment'),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.blsUnemploymentU3,
          title: 'Unemployment Rate U-3',
          sublabel: 'CPS Monthly',
          color: _red,
          formatY: _fmtPct,
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.blsUnemploymentU6,
          title: 'Unemployment Rate U-6',
          sublabel: 'Underemployment',
          color: _orange,
          formatY: _fmtPct,
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.blsNfp,
          title: 'Nonfarm Payrolls',
          sublabel: 'CES Thousands',
          color: _green,
          formatY: _fmtJobsK,
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.blsLfpr,
          title: 'Labor Force Participation',
          sublabel: 'CPS %',
          color: _blue,
          formatY: _fmtPct,
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.blsAvgHourlyEarnings,
          title: 'Avg Hourly Earnings',
          sublabel: 'All Private (\$)',
          color: _purple,
          formatY: (v) => '\$${v.toStringAsFixed(2)}',
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.blsAvgWeeklyHours,
          title: 'Avg Weekly Hours',
          sublabel: 'All Private',
          color: _teal,
          formatY: (v) => '${v.toStringAsFixed(1)} hrs',
        ),
        const SizedBox(height: 24),

        // BLS CPI - Data from Bureau of Labor Statistics API (stored in economy_indicator_snapshots)
        const _SectionHeader('BLS — Consumer Price Index'),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.blsCpiAll,
          title: 'CPI All Items (SA)',
          sublabel: 'Index 1982-84=100',
          color: _red,
          formatY: _fmtNum,
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.blsCpiCore,
          title: 'Core CPI',
          sublabel: 'Less Food & Energy',
          color: _orange,
          formatY: _fmtNum,
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.blsCpiShelter,
          title: 'CPI Shelter',
          sublabel: 'Housing Component',
          color: _yellow,
          formatY: _fmtNum,
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.blsCpiFood,
          title: 'CPI Food',
          sublabel: 'Food at Home & Away',
          color: _green,
          formatY: _fmtNum,
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.blsCpiEnergy,
          title: 'CPI Energy',
          sublabel: 'Energy Component',
          color: _teal,
          formatY: _fmtNum,
        ),
        const SizedBox(height: 24),

        // BLS PPI - Data from Bureau of Labor Statistics API (stored in economy_indicator_snapshots)
        const _SectionHeader('BLS — Producer Price Index'),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.blsPpiFinal,
          title: 'PPI Final Demand',
          sublabel: 'Index Nov 2009=100',
          color: _teal,
          formatY: _fmtNum,
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.blsPpiCore,
          title: 'Core PPI',
          sublabel: 'Less Food & Energy',
          color: _blue,
          formatY: _fmtNum,
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.blsPpiGoods,
          title: 'PPI Goods',
          sublabel: 'Final Demand Goods',
          color: _yellow,
          formatY: _fmtNum,
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.blsPpiServices,
          title: 'PPI Services',
          sublabel: 'Final Demand Services',
          color: _purple,
          formatY: _fmtNum,
        ),
        const SizedBox(height: 24),

        // BLS JOLTS - Data from Bureau of Labor Statistics API (stored in economy_indicator_snapshots)
        const _SectionHeader('BLS — JOLTS'),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.blsJobOpenings,
          title: 'Job Openings',
          sublabel: 'Total Thousands',
          color: _green,
          formatY: _fmtJobsK,
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.blsQuitsRate,
          title: 'Quits Rate',
          sublabel: '% of Employment',
          color: _purple,
          formatY: _fmtPct,
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.blsJobOpeningsRate,
          title: 'Job Openings Rate',
          sublabel: '% of Employment',
          color: _teal,
          formatY: _fmtPct,
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.blsHires,
          title: 'Hires',
          sublabel: 'Total (Thousands)',
          color: _green,
          formatY: _fmtJobsK,
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.blsQuits,
          title: 'Quits',
          sublabel: 'Total (Thousands)',
          color: _blue,
          formatY: _fmtJobsK,
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.blsLayoffs,
          title: 'Layoffs & Discharges',
          sublabel: 'Total (Thousands)',
          color: _red,
          formatY: _fmtJobsK,
        ),
        const SizedBox(height: 24),

        // BEA - Data from Bureau of Economic Analysis API (stored in economy_indicator_snapshots)
        const _SectionHeader('BEA — National Accounts'),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.beaGdpPct,
          title: 'GDP % Change Q/Q',
          sublabel: 'SAAR (T10101)',
          color: _teal,
          formatY: _fmtPct,
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.beaRealGdp,
          title: 'Real GDP',
          sublabel: 'Chained 2017 \$ Billions',
          color: _green,
          formatY: _fmtGdpShort,
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.beaCorePce,
          title: 'Core PCE Price Index',
          sublabel: 'Less Food & Energy (T20804)',
          color: _red,
          formatY: _fmtNum,
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.beaPersonalIncome,
          title: 'Personal Income',
          sublabel: 'Billions SAAR (T20100)',
          color: _blue,
          formatY: _fmtGdpShort,
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.beaCorporateProfits,
          title: 'Corporate Profits After Tax',
          sublabel: 'Billions \$ (T10901)',
          color: _purple,
          formatY: _fmtGdpShort,
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.beaPce,
          title: 'PCE % Change',
          sublabel: 'Personal Consumption Q/Q (T10101)',
          color: _blue,
          formatY: _fmtPct,
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.beaNetExports,
          title: 'Net Exports % Change',
          sublabel: 'Goods & Services Q/Q (T10101)',
          color: _orange,
          formatY: _fmtPct,
        ),
        const SizedBox(height: 24),

        // EIA - Data from Energy Information Administration API (stored in economy_indicator_snapshots)
        const _SectionHeader('EIA — Energy'),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.eiaGasolinePrice,
          title: 'Retail Gasoline Price',
          sublabel: 'US Avg \$/gal (Weekly)',
          color: _orange,
          formatY: (v) => '\$${v.toStringAsFixed(3)}',
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.eiaCrudeStocks,
          title: 'Crude Oil Stocks',
          sublabel: 'Commercial Thousand Bbl (Weekly)',
          color: _yellow,
          formatY: (v) => '${(v / 1000).toStringAsFixed(0)}M',
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.eiaNatGasStorage,
          title: 'Natural Gas Storage',
          sublabel: 'Working Gas Bcf (Weekly)',
          color: _blue,
          formatY: (v) => '${v.toStringAsFixed(0)} Bcf',
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.eiaRefineryUtil,
          title: 'Refinery Utilization',
          sublabel: '% of Operable Capacity',
          color: _teal,
          formatY: _fmtPct,
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.eiaCrudeProd,
          title: 'Crude Oil Production',
          sublabel: 'US Weekly (Mb/d)',
          color: _yellow,
          formatY: (v) => '${v.toStringAsFixed(0)} Mb/d',
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.eiaSpr,
          title: 'Strategic Petroleum Reserve',
          sublabel: 'Thousand Barrels',
          color: _red,
          formatY: (v) => '${(v / 1000).toStringAsFixed(1)}M bbl',
        ),
        const SizedBox(height: 24),

        // Census - Data from US Census Bureau API (stored in economy_indicator_snapshots)
        const _SectionHeader('Census — Trade & Construction'),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.censusRetailTotal,
          title: 'Total Retail Sales',
          sublabel: 'SA \$M (MARTS)',
          color: _green,
          formatY: _fmtRetailShort,
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.censusRetailVehicles,
          title: 'Motor Vehicle Sales',
          sublabel: 'SA \$M (MARTS 441)',
          color: _blue,
          formatY: _fmtRetailShort,
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.censusRetailNonStore,
          title: 'Non-Store / E-Commerce',
          sublabel: 'SA \$M (MARTS 454)',
          color: _purple,
          formatY: _fmtRetailShort,
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.censusConstruction,
          title: 'Construction Spending',
          sublabel: 'Value Put in Place \$M',
          color: _yellow,
          formatY: _fmtRetailShort,
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.censusMfgOrders,
          title: 'Manufacturers\' New Orders',
          sublabel: 'Total SA \$M (M3)',
          color: _orange,
          formatY: _fmtRetailShort,
        ),
        const SizedBox(height: 8),
        _IndicatorChart(
          identifier: EconIds.censusWholesale,
          title: 'Wholesale Sales',
          sublabel: 'Monthly SA \$M',
          color: _purple,
          formatY: _fmtRetailShort,
        ),
      ],
    );
  }
}

// ─── Section header ───────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Text(
      title.toUpperCase(),
      style: const TextStyle(
        color: AppTheme.neutralColor,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
      ),
    );
  }
}

// ─── Data note ────────────────────────────────────────────────────────────────

class _DataNote extends StatelessWidget {
  const _DataNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: const Row(
        children: [
          Icon(Icons.info_outline, size: 14, color: AppTheme.neutralColor),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Economic indicators populate immediately from FMP history. '
              'Market & commodity charts build one point per day you visit. '
              'Tap any chart to expand.',
              style: TextStyle(color: AppTheme.neutralColor, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Quote (daily) chart card ─────────────────────────────────────────────────

class _QuoteChart extends ConsumerWidget {
  final String symbol;
  final String title;
  final DateTime date;
  final double price;
  final Color color;

  const _QuoteChart({
    required this.symbol,
    required this.title,
    required this.date,
    required this.price,
    required this.color,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(economyQuoteHistoryProvider(symbol));
    return async.when(
      loading: () => _chartSkeleton(title, symbol,),
      error: (_, _) => _chartSkeleton(title, symbol),
      data: (history) {
        if (history.isEmpty) return _chartEmpty(title, symbol);
        final dates = history.map((h) => h.date).toList();
        final spots = history
            .asMap()
            .entries
            .map((e) => FlSpot(e.key.toDouble(), e.value.price))
            .toList();
        return _LineChartCard(
          title: title,
          sublabel: symbol,
          dates: dates,
          series: [_Series(symbol, spots, color)],
          formatY: (v) => v >= 1000
              ? '\$${(v / 1000).toStringAsFixed(1)}K'
              : '\$${v.toStringAsFixed(2)}',
        );
      },
    );
  }
}

// ─── Economic indicator (monthly) chart card ──────────────────────────────────

class _IndicatorChart extends ConsumerWidget {
  final String identifier;
  final String title;
  final String sublabel;
  final Color color;
  final String Function(double) formatY;

  const _IndicatorChart({
    required this.identifier,
    required this.title,
    required this.sublabel,
    required this.color,
    required this.formatY,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(economyIndicatorHistoryProvider(identifier));
    return async.when(
      loading: () => _chartSkeleton(title, sublabel),
      error: (_, _) => _chartSkeleton(title, sublabel),
      data: (history) {
        if (history.isEmpty) return _chartEmpty(title, sublabel);
        final dates = history.map((p) => p.date).toList();
        final spots = history
            .asMap()
            .entries
            .map((e) => FlSpot(e.key.toDouble(), e.value.value))
            .toList();
        return _LineChartCard(
          title: title,
          sublabel: sublabel,
          dates: dates,
          series: [_Series(identifier, spots, color)],
          formatY: formatY,
        );
      },
    );
  }
}

// ─── Treasury multi-line chart card ───────────────────────────────────────────

class _TreasuryChart extends ConsumerWidget {
  const _TreasuryChart();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(economyTreasuryHistoryProvider);
    return async.when(
      loading: () => _chartSkeleton('Treasury Yields', '2Y · 5Y · 10Y · 30Y'),
      error: (_, _) => _chartSkeleton('Treasury Yields', '2Y · 5Y · 10Y · 30Y'),
      data: (history) {
        if (history.isEmpty) {
          return _chartEmpty('Treasury Yields', '2Y · 5Y · 10Y · 30Y');
        }
        final dates = history.map((h) => h.date).toList();
        List<FlSpot> toSpots(double? Function(TreasurySnapshot) pick) => history
            .asMap()
            .entries
            .map((e) => FlSpot(e.key.toDouble(), pick(e.value) ?? 0))
            .toList();
        return _LineChartCard(
          title: 'Treasury Yields',
          sublabel: '2Y · 5Y · 10Y · 30Y',
          dates: dates,
          series: [
            _Series('2Y', toSpots((h) => h.year2), _blue),
            _Series('5Y', toSpots((h) => h.year5), _green),
            _Series('10Y', toSpots((h) => h.year10), _yellow),
            _Series('30Y', toSpots((h) => h.year30), _purple),
          ],
          formatY: _fmtPct,
          showLegend: true,
        );
      },
    );
  }
}

// ─── Data model for a single series ──────────────────────────────────────────

class _Series {
  final String label;
  final List<FlSpot> spots;
  final Color color;
  const _Series(this.label, this.spots, this.color);
}

// ─── Pick n evenly-spaced indices from a list of length total ─────────────────
// Uses integer arithmetic only — no floating-point label misalignment.

List<int> _evenIndices(int total, int count) {
  if (total <= 0) return [];
  if (total <= count) return List.generate(total, (i) => i);
  if (count == 1) return [0];
  return List.generate(count, (i) => ((i * (total - 1)) / (count - 1)).round());
}

// ─── Compact chart card (shown in the list) ───────────────────────────────────

class _LineChartCard extends StatelessWidget {
  final String title;
  final String sublabel;
  final List<DateTime> dates;
  final List<_Series> series;
  final String Function(double) formatY;
  final bool showLegend;

  const _LineChartCard({
    required this.title,
    required this.sublabel,
    required this.dates,
    required this.series,
    required this.formatY,
    this.showLegend = false,
  });

  void _expand(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => _FullScreenChartPage(
          title: title,
          sublabel: sublabel,
          dates: dates,
          series: series,
          formatY: formatY,
          showLegend: showLegend,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final n = dates.length;
    final labelSet = _evenIndices(n, 4).toSet();

    final bars = _buildBars(compact: true);

    return GestureDetector(
      onTap: () => _expand(context),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1C2128),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF30363D)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          sublabel,
                          style: const TextStyle(
                            color: AppTheme.neutralColor,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '$n pts',
                    style: const TextStyle(
                      color: AppTheme.neutralColor,
                      fontSize: 10,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.open_in_full,
                    size: 13,
                    color: AppTheme.neutralColor,
                  ),
                ],
              ),

              if (showLegend) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 12,
                  children: series
                      .map(
                        (s) => Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(width: 12, height: 2, color: s.color),
                            const SizedBox(width: 4),
                            Text(
                              s.label,
                              style: const TextStyle(
                                color: AppTheme.neutralColor,
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                      )
                      .toList(),
                ),
              ],

              const SizedBox(height: 12),

              SizedBox(
                height: 140,
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
                    lineTouchData: const LineTouchData(enabled: false),
                    titlesData: FlTitlesData(
                      topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 48,
                          getTitlesWidget: (v, meta) {
                            if (v != meta.min && v != meta.max) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Text(
                                formatY(v),
                                style: const TextStyle(
                                  color: AppTheme.neutralColor,
                                  fontSize: 9,
                                ),
                                textAlign: TextAlign.right,
                              ),
                            );
                          },
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 22,
                          // interval: 1 so we control exactly which to show
                          interval: 1,
                          getTitlesWidget: (v, _) {
                            final idx = v.round();
                            if (!labelSet.contains(idx)) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                _fmtAxisDate(dates[idx]),
                                style: const TextStyle(
                                  color: AppTheme.neutralColor,
                                  fontSize: 9,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    lineBarsData: bars,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<LineChartBarData> _buildBars({required bool compact}) {
    final n = dates.length;
    return series
        .map(
          (s) => LineChartBarData(
            spots: s.spots,
            isCurved: n > 3,
            color: s.color,
            barWidth: compact ? 2 : 2.5,
            dotData: FlDotData(show: n <= 2),
            belowBarData: series.length == 1
                ? BarAreaData(
                    show: true,
                    color: s.color.withValues(alpha: 0.08),
                  )
                : BarAreaData(show: false),
          ),
        )
        .toList();
  }
}

// ─── Full-screen expanded chart page ─────────────────────────────────────────

class _FullScreenChartPage extends StatelessWidget {
  final String title;
  final String sublabel;
  final List<DateTime> dates;
  final List<_Series> series;
  final String Function(double) formatY;
  final bool showLegend;

  const _FullScreenChartPage({
    required this.title,
    required this.sublabel,
    required this.dates,
    required this.series,
    required this.formatY,
    this.showLegend = false,
  });

  @override
  Widget build(BuildContext context) {
    final n = dates.length;
    // Show up to 6 labels in full-screen
    final labelSet = _evenIndices(n, 6).toSet();

    final bars = series
        .map(
          (s) => LineChartBarData(
            spots: s.spots,
            isCurved: n > 3,
            color: s.color,
            barWidth: 2.5,
            dotData: FlDotData(show: n <= 10),
            belowBarData: series.length == 1
                ? BarAreaData(
                    show: true,
                    color: s.color.withValues(alpha: 0.10),
                  )
                : BarAreaData(show: false),
          ),
        )
        .toList();

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 16)),
            Text(
              sublabel,
              style: const TextStyle(
                color: AppTheme.neutralColor,
                fontSize: 11,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Text(
              '$n pts',
              style: const TextStyle(
                color: AppTheme.neutralColor,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Legend
              if (showLegend) ...[
                Wrap(
                  spacing: 16,
                  children: series
                      .map(
                        (s) => Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(width: 16, height: 2, color: s.color),
                            const SizedBox(width: 6),
                            Text(
                              s.label,
                              style: const TextStyle(
                                color: AppTheme.neutralColor,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 16),
              ],

              // Chart fills remaining height
              Expanded(
                child: LineChart(
                  LineChartData(
                    gridData: FlGridData(
                      show: true,
                      drawVerticalLine: true,
                      getDrawingHorizontalLine: (_) => FlLine(
                        color: Colors.white.withValues(alpha: 0.06),
                        strokeWidth: 1,
                      ),
                      getDrawingVerticalLine: (_) => FlLine(
                        color: Colors.white.withValues(alpha: 0.04),
                        strokeWidth: 1,
                      ),
                    ),
                    borderData: FlBorderData(show: false),
                    lineTouchData: LineTouchData(
                      enabled: true,
                      touchTooltipData: LineTouchTooltipData(
                        getTooltipColor: (_) => const Color(0xFF30363D),
                        getTooltipItems: (touchedSpots) => touchedSpots.map((
                          s,
                        ) {
                          final idx = s.x.round();
                          final dateStr = (idx >= 0 && idx < dates.length)
                              ? DateFormat('MMM d, yyyy').format(dates[idx])
                              : '';
                          final seriesLabel =
                              series.length > 1 && s.barIndex < series.length
                              ? '${series[s.barIndex].label}: '
                              : '';
                          return LineTooltipItem(
                            '$dateStr\n$seriesLabel${formatY(s.y)}',
                            TextStyle(
                              color: series[s.barIndex % series.length].color,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                    titlesData: FlTitlesData(
                      topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 56,
                          getTitlesWidget: (v, meta) {
                            if (v != meta.min && v != meta.max) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Text(
                                formatY(v),
                                style: const TextStyle(
                                  color: AppTheme.neutralColor,
                                  fontSize: 10,
                                ),
                                textAlign: TextAlign.right,
                              ),
                            );
                          },
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 28,
                          interval: 1,
                          getTitlesWidget: (v, _) {
                            final idx = v.round();
                            if (!labelSet.contains(idx)) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                _fmtAxisDate(dates[idx]),
                                style: const TextStyle(
                                  color: AppTheme.neutralColor,
                                  fontSize: 10,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    lineBarsData: bars,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Skeleton / empty states ──────────────────────────────────────────────────

Widget _chartSkeleton(String title, String sub) => _ChartFrame(
  title: title,
  sublabel: sub,
  child: const Center(
    child: SizedBox(
      width: 20,
      height: 20,
      child: CircularProgressIndicator(strokeWidth: 2),
    ),
  ),
);

Widget _chartEmpty(String title, String sub) => _ChartFrame(
  title: title,
  sublabel: sub,
  child: const Center(
    child: Text(
      'No data yet — visit the Snapshot tab to start building history.',
      textAlign: TextAlign.center,
      style: TextStyle(color: AppTheme.neutralColor, fontSize: 11),
    ),
  ),
);

class _ChartFrame extends StatelessWidget {
  final String title;
  final String sublabel;
  final Widget child;

  const _ChartFrame({
    required this.title,
    required this.sublabel,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1C2128),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            Text(
              sublabel,
              style: const TextStyle(
                color: AppTheme.neutralColor,
                fontSize: 10,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(height: 100, child: child),
          ],
        ),
      ),
    );
  }
}

// ─── Date label formatter ─────────────────────────────────────────────────────

String _fmtAxisDate(DateTime d) => DateFormat("MMM ''yy").format(d);

// ─── Y-axis formatters ────────────────────────────────────────────────────────

String _fmtPct(double v) => '${v.toStringAsFixed(1)}%';
String _fmtNum(double v) => v.toStringAsFixed(0);

String _fmtJobsK(double v) {
  final k = v / 1000;
  return k.abs() >= 1000
      ? '${(k / 1000).toStringAsFixed(1)}M'
      : '${k.toStringAsFixed(0)}K';
}

String _fmtGdpShort(double v) {
  if (v >= 1000) return '\$${(v / 1000).toStringAsFixed(1)}T';
  return '\$${v.toStringAsFixed(0)}B';
}

String _fmtRetailShort(double v) {
  if (v.abs() >= 1000) return '\$${(v / 1000).toStringAsFixed(1)}B';
  return '\$${v.toStringAsFixed(0)}M';
}

String _fmtHousingShort(double v) => '${v.toStringAsFixed(0)}K';
