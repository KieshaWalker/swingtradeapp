// =============================================================================
// features/economy/widgets/fred_tab.dart
// =============================================================================
// FRED tab for Economy Pulse — displays the 7 FRED series with their latest
// value, date, and a sparkline of recent history from Supabase.
//
// Sections:
//   Market Stress    — VIX, HY OAS, IG OAS
//   Rates & Curve    — Fed Funds (DFF), 10Y−2Y Spread (T10Y2Y)
//   Commodities      — Gold, Silver
// =============================================================================
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/theme.dart';
import '../../../services/fred/fred_models.dart';
import '../../../services/fred/fred_providers.dart';

class FredTab extends ConsumerWidget {
  const FredTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(fredVixProvider);
        ref.invalidate(fredGoldProvider);
        ref.invalidate(fredSilverProvider);
        ref.invalidate(fredHyOasProvider);
        ref.invalidate(fredIgOasProvider);
        ref.invalidate(fredSpreadProvider);
        ref.invalidate(fredFedFundsProvider);
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          // ── Market Stress ─────────────────────────────────────────────────
          const _SectionHeader('Market Stress'),
          _FredSeriesTile(
            provider: fredVixProvider,
            label: 'VIX',
            sublabel: 'CBOE Volatility Index · VIXCLS',
            suffix: '',
            decimals: 2,
            invertColor: true,
            accentColor: const Color(0xFFFF7B72),
          ),
          const SizedBox(height: 8),
          _FredSeriesTile(
            provider: fredHyOasProvider,
            label: 'HY Credit OAS',
            sublabel: 'ICE BofA High Yield · BAMLH0A0HYM2',
            suffix: ' bps',
            decimals: 0,
            invertColor: true,
            accentColor: const Color(0xFFF0883E),
          ),
          const SizedBox(height: 8),
          _FredSeriesTile(
            provider: fredIgOasProvider,
            label: 'IG Credit OAS',
            sublabel: 'ICE BofA Invest. Grade · BAMLC0A0CM',
            suffix: ' bps',
            decimals: 0,
            invertColor: true,
            accentColor: const Color(0xFFD29922),
          ),
          const SizedBox(height: 20),

          // ── Rates & Curve ─────────────────────────────────────────────────
          const _SectionHeader('Rates & Curve'),
          _FredSeriesTile(
            provider: fredFedFundsProvider,
            label: 'Fed Funds Rate',
            sublabel: 'Effective Rate · DFF',
            suffix: '%',
            decimals: 2,
            invertColor: false,
            accentColor: const Color(0xFF58A6FF),
          ),
          const SizedBox(height: 8),
          _FredSeriesTile(
            provider: fredSpreadProvider,
            label: '10Y − 2Y Spread',
            sublabel: 'Treasury Yield Curve · T10Y2Y',
            suffix: '%',
            decimals: 2,
            invertColor: false,
            accentColor: const Color(0xFF3FB950),
            showZeroLine: true,
          ),
          const SizedBox(height: 20),

          // ── Commodities ───────────────────────────────────────────────────
          const _SectionHeader('Commodities'),
          _FredSeriesTile(
            provider: fredGoldProvider,
            label: 'Gold',
            sublabel: 'USD/Troy Oz · London AM · GOLDAMGBD228NLBM',
            prefix: '\$',
            suffix: '',
            decimals: 2,
            invertColor: false,
            accentColor: const Color(0xFFD29922),
          ),
          const SizedBox(height: 8),
          _FredSeriesTile(
            provider: fredSilverProvider,
            label: 'Silver',
            sublabel: 'USD/Troy Oz · SLVPRUSD',
            prefix: '\$',
            suffix: '',
            decimals: 2,
            invertColor: false,
            accentColor: const Color(0xFF8B949E),
          ),
          const SizedBox(height: 24),

          // ── FRED attribution ──────────────────────────────────────────────
          const Center(
            child: Text(
              'Source: FRED — Federal Reserve Bank of St. Louis',
              style: TextStyle(color: AppTheme.neutralColor, fontSize: 10),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Section header ───────────────────────────────────────────────────────────

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

// ─── Series tile ──────────────────────────────────────────────────────────────

class _FredSeriesTile extends ConsumerWidget {
  final ProviderListenable<AsyncValue<FredSeries>> provider;
  final String label;
  final String sublabel;
  final String prefix;
  final String suffix;
  final int decimals;
  final bool invertColor;   // true = high value is bad (red)
  final Color accentColor;
  final bool showZeroLine;  // for yield curve spread

  const _FredSeriesTile({
    required this.provider,
    required this.label,
    required this.sublabel,
    required this.suffix,
    required this.decimals,
    required this.invertColor,
    required this.accentColor,
    this.prefix = '',
    this.showZeroLine = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(provider);
    return async.when(
      loading: () => _shell(
        label: label,
        sublabel: sublabel,
        accentColor: accentColor,
        child: const SizedBox(
          height: 60,
          child: Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      ),
      error: (_, _) => _shell(
        label: label,
        sublabel: sublabel,
        accentColor: accentColor,
        child: const SizedBox(
          height: 60,
          child: Center(
            child: Text('Failed to load',
                style: TextStyle(color: AppTheme.neutralColor, fontSize: 11)),
          ),
        ),
      ),
      data: (series) {
        if (series.observations.isEmpty) {
          return _shell(
            label: label,
            sublabel: sublabel,
            accentColor: accentColor,
            child: const SizedBox(
              height: 60,
              child: Center(
                child: Text('No data',
                    style: TextStyle(
                        color: AppTheme.neutralColor, fontSize: 11)),
              ),
            ),
          );
        }

        // Observations are newest-first from FRED service
        final obs = series.observations;
        final latest = obs.first;
        final prevDay = obs.length > 1 ? obs[1] : null;
        final change = prevDay != null ? latest.value - prevDay.value : 0.0;
        final changePositive = invertColor ? change < 0 : change >= 0;
        final changeColor =
            changePositive ? AppTheme.profitColor : AppTheme.lossColor;

        // Sparkline — last 90 obs, reversed so left = older
        final sparkObs = obs.take(90).toList().reversed.toList();
        final spots = sparkObs
            .asMap()
            .entries
            .map((e) => FlSpot(e.key.toDouble(), e.value.value))
            .toList();

        final dateStr =
            DateFormat('MMM d, yyyy').format(latest.date);

        return _shell(
          label: label,
          sublabel: sublabel,
          accentColor: accentColor,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Value block
              SizedBox(
                width: 110,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '$prefix${latest.value.toStringAsFixed(decimals)}$suffix',
                      style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      prevDay != null
                          ? '${change >= 0 ? '+' : ''}${change.toStringAsFixed(decimals)}$suffix'
                          : '',
                      style: TextStyle(
                          color: changeColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      dateStr,
                      style: const TextStyle(
                          color: AppTheme.neutralColor, fontSize: 10),
                    ),
                  ],
                ),
              ),
              // Sparkline
              Expanded(
                child: SizedBox(
                  height: 60,
                  child: spots.length < 2
                      ? const SizedBox.shrink()
                      : LineChart(
                          _buildSparkline(spots, accentColor,
                              showZeroLine: showZeroLine),
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _shell({
    required String label,
    required String sublabel,
    required Color accentColor,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1C2128),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 3,
                height: 14,
                decoration: BoxDecoration(
                  color: accentColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600)),
                    Text(sublabel,
                        style: const TextStyle(
                            color: AppTheme.neutralColor, fontSize: 9)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

// ─── Sparkline builder ────────────────────────────────────────────────────────

LineChartData _buildSparkline(
  List<FlSpot> spots,
  Color color, {
  bool showZeroLine = false,
}) {
  final minY = spots.map((s) => s.y).reduce((a, b) => a < b ? a : b);
  final maxY = spots.map((s) => s.y).reduce((a, b) => a > b ? a : b);
  final pad = (maxY - minY) * 0.1;

  return LineChartData(
    minY: minY - pad,
    maxY: maxY + pad,
    gridData: FlGridData(
      show: showZeroLine,
      drawVerticalLine: false,
      checkToShowHorizontalLine: (v) => (v - 0).abs() < 0.01,
      getDrawingHorizontalLine: (_) => FlLine(
        color: Colors.white.withValues(alpha: 0.2),
        strokeWidth: 1,
        dashArray: [4, 4],
      ),
    ),
    borderData: FlBorderData(show: false),
    titlesData: const FlTitlesData(
      leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
      rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
      topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
      bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
    ),
    lineTouchData: const LineTouchData(enabled: false),
    lineBarsData: [
      LineChartBarData(
        spots: spots,
        isCurved: true,
        color: color,
        barWidth: 1.5,
        dotData: const FlDotData(show: false),
        belowBarData: BarAreaData(
          show: true,
          color: color.withValues(alpha: 0.08),
        ),
      ),
    ],
  );
}
