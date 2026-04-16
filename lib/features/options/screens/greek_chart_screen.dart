// =============================================================================
// features/options/screens/greek_chart_screen.dart
// Route: /ticker/:symbol/chains/greeks
// =============================================================================
// Displays ATM option Greeks tracked daily over time.
// Three DTE tabs: 4 DTE · 7 DTE · 31 DTE
// Each tab: one card per Greek (Delta, Gamma, Theta, Vega, Rho, IV)
//   Call — AppTheme.profitColor (green)
//   Put  — AppTheme.lossColor  (pink)
//
// Data source: greek_snapshots Supabase table, ingested automatically each
// time the options chain loads for this ticker.
// =============================================================================
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart'; 
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme.dart';
import '../../../features/greek_grid/services/greek_interpreter.dart';
import '../../../features/greek_grid/widgets/greek_interpretation_panel.dart';
import '../../../services/greeks/greek_snapshot_models.dart';
import '../../../services/greeks/greek_snapshot_providers.dart';
 
// ── DTE bucket config ─────────────────────────────────────────────────────────

const _buckets = [
  _BucketDef(dte: 4,  label: '4 DTE',  description: 'Weekly / near-expiry'),
  _BucketDef(dte: 7,  label: '7 DTE',  description: 'Weekly'),
  _BucketDef(dte: 31, label: '31 DTE', description: 'Monthly'),
];

class _BucketDef {
  final int    dte;
  final String label;
  final String description;
  const _BucketDef({required this.dte, required this.label, required this.description});
}

// ── Greek descriptor ──────────────────────────────────────────────────────────

class _GreekDef {
  final String  label;
  final String  subtitle;
  final bool    showZeroLine;
  final String  Function(double) fmt;
  final double? Function(GreekSnapshot) callVal;
  final double? Function(GreekSnapshot) putVal;

  const _GreekDef({
    required this.label,
    required this.subtitle,
    required this.showZeroLine,
    required this.fmt,
    required this.callVal,
    required this.putVal,
  });
}

const _greeks = [
  _GreekDef(
    label:        'Delta',
    subtitle:     'Rate of change of option price per \$1 move in underlying',
    showZeroLine: false,
    fmt:          _fmt3,
    callVal:      _callDelta,
    putVal:       _putDelta,
  ),
  _GreekDef(
    label:        'Gamma',
    subtitle:     'Rate of change of delta per \$1 move — acceleration',
    showZeroLine: false,
    fmt:          _fmt4,
    callVal:      _callGamma,
    putVal:       _putGamma,
  ),
  _GreekDef(
    label:        'Theta',
    subtitle:     'Daily time decay — dollars lost per day per contract',
    showZeroLine: true,
    fmt:          _fmt3,
    callVal:      _callTheta,
    putVal:       _putTheta,
  ),
  _GreekDef(
    label:        'Vega',
    subtitle:     'Dollar change per 1% move in implied volatility',
    showZeroLine: false,
    fmt:          _fmt3,
    callVal:      _callVega,
    putVal:       _putVega,
  ),
  _GreekDef(
    label:        'Rho',
    subtitle:     'Dollar change per 1% move in risk-free interest rate',
    showZeroLine: true,
    fmt:          _fmt3,
    callVal:      _callRho,
    putVal:       _putRho,
  ),
  _GreekDef(
    label:        'IV',
    subtitle:     'Implied volatility of ATM contract (%)',
    showZeroLine: false,
    fmt:          _fmtPct,
    callVal:      _callIv,
    putVal:       _putIv,
  ),
];

// Accessor functions — needed because Dart const constructors can't use lambdas
double? _callDelta(GreekSnapshot s) => s.callDelta;
double? _putDelta (GreekSnapshot s) => s.putDelta;
double? _callGamma(GreekSnapshot s) => s.callGamma;
double? _putGamma (GreekSnapshot s) => s.putGamma;
double? _callTheta(GreekSnapshot s) => s.callTheta;
double? _putTheta (GreekSnapshot s) => s.putTheta;
double? _callVega (GreekSnapshot s) => s.callVega;
double? _putVega  (GreekSnapshot s) => s.putVega;
double? _callRho  (GreekSnapshot s) => s.callRho;
double? _putRho   (GreekSnapshot s) => s.putRho;
double? _callIv   (GreekSnapshot s) => s.callIv;
double? _putIv    (GreekSnapshot s) => s.putIv;

String _fmt3 (double v) => v.toStringAsFixed(3);
String _fmt4 (double v) => v.toStringAsFixed(4);
String _fmtPct(double v) => '${v.toStringAsFixed(1)}%';

// ── Screen ────────────────────────────────────────────────────────────────────

class GreekChartScreen extends ConsumerStatefulWidget {
  final String symbol;
  const GreekChartScreen({super.key, required this.symbol});

  @override
  ConsumerState<GreekChartScreen> createState() => _GreekChartScreenState();
}

class _GreekChartScreenState extends ConsumerState<GreekChartScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: _buckets.length, vsync: this, initialIndex: 2);
    // Default to 31 DTE tab (index 2) — most history data
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${widget.symbol}  Greeks'),
            const Text(
              'ATM greeks by DTE bucket — tracked daily',
              style: TextStyle(
                  color: AppTheme.neutralColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w400),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 20),
            tooltip: 'Refresh',
            onPressed: () {
              for (final b in _buckets) {
                ref.invalidate(greekHistoryProvider((widget.symbol, b.dte)));
              }
            },
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: _buckets
              .map((b) => Tab(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(b.label,
                            style: const TextStyle(
                                fontSize: 12, fontWeight: FontWeight.w700)),
                        Text(b.description,
                            style: const TextStyle(
                                color: AppTheme.neutralColor, fontSize: 9)),
                      ],
                    ),
                  ))
              .toList(),
          labelColor:         Colors.white,
          unselectedLabelColor: AppTheme.neutralColor,
          indicatorColor:     AppTheme.profitColor,
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: _buckets
            .map((b) => _BucketView(symbol: widget.symbol, bucket: b))
            .toList(),
      ),
    );
  }
}

// ── Bucket tab view ───────────────────────────────────────────────────────────

class _BucketView extends ConsumerWidget {
  final String     symbol;
  final _BucketDef bucket;
  const _BucketView({required this.symbol, required this.bucket});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final histAsync = ref.watch(greekHistoryProvider((symbol, bucket.dte)));

    return histAsync.when(
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Error loading greek history: $e',
              style: const TextStyle(color: AppTheme.lossColor)),
        ),
      ),
      data: (history) {
        if (history.isEmpty) {
          return _EmptyState(bucket: bucket);
        }
        return _GreekChartBody(symbol: symbol, history: history, bucket: bucket);
      },
    );
  }
}

// ── Body ──────────────────────────────────────────────────────────────────────

class _GreekChartBody extends StatelessWidget {
  final String              symbol;
  final List<GreekSnapshot> history;
  final _BucketDef          bucket;
  const _GreekChartBody({
    required this.symbol,
    required this.history,
    required this.bucket,
  });

  @override
  Widget build(BuildContext context) {
    final latest    = history.last;
    final callStrike = latest.callStrike;
    final putStrike  = latest.putStrike;
    final callDte    = latest.callDte;

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        // ── Header summary ──────────────────────────────────────────────────
        _SummaryBar(
          underlying:  latest.underlyingPrice,
          callStrike:  callStrike,
          putStrike:   putStrike,
          dte:         callDte,
          dteBucket:   bucket.dte,
          dayCount:    history.length,
        ),
        const SizedBox(height: 10),

        // ── Interpretation ───────────────────────────────────────────────────
        GreekInterpretationPanel(
          result: interpretGreekChart(history, bucket.dte),
        ),
        const SizedBox(height: 10),

        // ── Legend ──────────────────────────────────────────────────────────
        const _Legend(),
        const SizedBox(height: 12),

        // ── One chart per Greek ──────────────────────────────────────────────
        for (final def in _greeks) ...[
          _GreekCard(def: def, history: history),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

// ── Summary bar ───────────────────────────────────────────────────────────────

class _SummaryBar extends StatelessWidget {
  final double  underlying;
  final double? callStrike;
  final double? putStrike;
  final int?    dte;
  final int     dteBucket;
  final int     dayCount;
  const _SummaryBar({
    required this.underlying,
    required this.callStrike,
    required this.putStrike,
    required this.dte,
    required this.dteBucket,
    required this.dayCount,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      child: Row(
        children: [
          _StatCell('Underlying', '\$${underlying.toStringAsFixed(2)}',
              AppTheme.neutralColor),
          const _Divider(),
          _StatCell(
            'ATM Call',
            callStrike != null ? '\$${callStrike!.toStringAsFixed(0)}' : '—',
            AppTheme.profitColor,
          ),
          const _Divider(),
          _StatCell(
            'ATM Put',
            putStrike != null ? '\$${putStrike!.toStringAsFixed(0)}' : '—',
            AppTheme.lossColor,
          ),
          const _Divider(),
          _StatCell(
            'Actual DTE',
            dte != null ? '${dte}d' : '—',
            AppTheme.neutralColor,
          ),
          const _Divider(),
          _StatCell('History', '${dayCount}d', AppTheme.neutralColor),
        ],
      ),
    );
  }
}

class _StatCell extends StatelessWidget {
  final String label;
  final String value;
  final Color  color;
  const _StatCell(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      children: [
        Text(label,
            style: const TextStyle(
                color: AppTheme.neutralColor,
                fontSize: 9,
                letterSpacing: 0.5)),
        const SizedBox(height: 2),
        Text(value,
            style: TextStyle(
                color: color, fontSize: 12, fontWeight: FontWeight.w700)),
      ],
    ),
  );
}

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) => Container(
    width: 1, height: 28,
    color: AppTheme.borderColor.withValues(alpha: 0.5),
    margin: const EdgeInsets.symmetric(horizontal: 4),
  );
}

// ── Legend ────────────────────────────────────────────────────────────────────

class _Legend extends StatelessWidget {
  const _Legend();
  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      _LegendDot(color: AppTheme.profitColor, label: 'ATM Call'),
      const SizedBox(width: 20),
      _LegendDot(color: AppTheme.lossColor,   label: 'ATM Put'),
    ],
  );
}

class _LegendDot extends StatelessWidget {
  final Color  color;
  final String label;
  const _LegendDot({required this.color, required this.label});
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 10, height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 5),
      Text(label,
          style: const TextStyle(
              color: AppTheme.neutralColor, fontSize: 11)),
    ],
  );
}

// ── Greek card ────────────────────────────────────────────────────────────────

class _GreekCard extends StatelessWidget {
  final _GreekDef           def;
  final List<GreekSnapshot> history;
  const _GreekCard({required this.def, required this.history});

  @override
  Widget build(BuildContext context) {
    // Build spot lists — skip points where value is null
    final callSpots = <FlSpot>[];
    final putSpots  = <FlSpot>[];
    for (var i = 0; i < history.length; i++) {
      final cv = def.callVal(history[i]);
      final pv = def.putVal(history[i]);
      if (cv != null && cv.isFinite) callSpots.add(FlSpot(i.toDouble(), cv));
      if (pv != null && pv.isFinite) putSpots.add(FlSpot(i.toDouble(), pv));
    }

    if (callSpots.isEmpty && putSpots.isEmpty) {
      return _CardShell(
        label:    def.label,
        subtitle: def.subtitle,
        child: const SizedBox(
          height: 100,
          child: Center(
            child: Text('No data yet',
                style: TextStyle(color: AppTheme.neutralColor, fontSize: 12)),
          ),
        ),
      );
    }

    // Y-axis range
    final allY = [...callSpots.map((s) => s.y), ...putSpots.map((s) => s.y)];
    final minY = allY.reduce((a, b) => a < b ? a : b);
    final maxY = allY.reduce((a, b) => a > b ? a : b);
    final pad  = ((maxY - minY) * 0.12).abs().clamp(0.001, double.infinity);

    // Latest values for header badge
    final latestCall = callSpots.isNotEmpty ? callSpots.last.y : null;
    final latestPut  = putSpots.isNotEmpty  ? putSpots.last.y  : null;

    return _CardShell(
      label:    def.label,
      subtitle: def.subtitle,
      latestCall: latestCall != null ? def.fmt(latestCall) : null,
      latestPut:  latestPut  != null ? def.fmt(latestPut)  : null,
      child: SizedBox(
        height: 160,
        child: LineChart(
          LineChartData(
            minY: minY - pad,
            maxY: maxY + pad,
            clipData: const FlClipData.all(),
            gridData: FlGridData(
              show: true,
              drawVerticalLine: false,
              getDrawingHorizontalLine: (_) => FlLine(
                color:       AppTheme.borderColor.withValues(alpha: 0.25),
                strokeWidth: 1,
              ),
            ),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles:   true,
                  reservedSize: 44,
                  getTitlesWidget: (v, _) => Text(
                    def.fmt(v),
                    style: const TextStyle(
                        color: AppTheme.neutralColor, fontSize: 8),
                  ),
                ),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles:   true,
                  reservedSize: 20,
                  interval: (history.length / 4)
                      .ceilToDouble()
                      .clamp(1, double.infinity),
                  getTitlesWidget: (v, _) {
                    final i = v.toInt().clamp(0, history.length - 1);
                    final d = history[i].obsDate;
                    return Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '${d.month}/${d.day}',
                        style: const TextStyle(
                            color: AppTheme.neutralColor, fontSize: 8),
                      ),
                    );
                  },
                ),
              ),
              rightTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false)),
              topTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false)),
            ),
            // Zero reference line for theta, rho
            extraLinesData: def.showZeroLine
                ? ExtraLinesData(horizontalLines: [
                    HorizontalLine(
                      y:           0,
                      color:       AppTheme.neutralColor.withValues(alpha: 0.4),
                      strokeWidth: 1,
                      dashArray:   [4, 4],
                    ),
                  ])
                : null,
            lineBarsData: [
              if (callSpots.isNotEmpty)
                LineChartBarData(
                  spots:        callSpots,
                  isCurved:     true,
                  curveSmoothness: 0.25,
                  color:        AppTheme.profitColor,
                  barWidth:     2,
                  dotData:      FlDotData(
                    show: true,
                    checkToShowDot: (spot, _) =>
                        spot.x == callSpots.last.x,
                  ),
                  belowBarData: BarAreaData(
                    show:  true,
                    color: AppTheme.profitColor.withValues(alpha: 0.06),
                  ),
                ),
              if (putSpots.isNotEmpty)
                LineChartBarData(
                  spots:        putSpots,
                  isCurved:     true,
                  curveSmoothness: 0.25,
                  color:        AppTheme.lossColor,
                  barWidth:     2,
                  dotData:      FlDotData(
                    show: true,
                    checkToShowDot: (spot, _) =>
                        spot.x == putSpots.last.x,
                  ),
                  belowBarData: BarAreaData(
                    show:  true,
                    color: AppTheme.lossColor.withValues(alpha: 0.06),
                  ),
                ),
            ],
            lineTouchData: LineTouchData(
              touchTooltipData: LineTouchTooltipData(
                getTooltipColor: (_) => AppTheme.elevatedColor,
                getTooltipItems: (touchedSpots) =>
                    touchedSpots.map((s) {
                  final i = s.x.toInt().clamp(0, history.length - 1);
                  final d    = history[i].obsDate;
                  final isCall = s.barIndex == 0 && callSpots.isNotEmpty;
                  final side = isCall ? 'Call' : 'Put';
                  return LineTooltipItem(
                    '${d.month}/${d.day}  $side: ${def.fmt(s.y)}',
                    TextStyle(
                      color:    isCall ? AppTheme.profitColor : AppTheme.lossColor,
                      fontSize: 11,
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Card shell ────────────────────────────────────────────────────────────────

class _CardShell extends StatelessWidget {
  final String  label;
  final String  subtitle;
  final String? latestCall;
  final String? latestPut;
  final Widget  child;
  const _CardShell({
    required this.label,
    required this.subtitle,
    required this.child,
    this.latestCall,
    this.latestPut,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                          color:      Colors.white,
                          fontSize:   13,
                          fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                          color:    AppTheme.neutralColor,
                          fontSize: 10,
                          height:   1.3),
                    ),
                  ],
                ),
              ),
              // Latest value badges
              if (latestCall != null || latestPut != null) ...[
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (latestCall != null)
                      _ValueBadge(value: latestCall!, color: AppTheme.profitColor),
                    if (latestPut != null) ...[
                      const SizedBox(height: 3),
                      _ValueBadge(value: latestPut!, color: AppTheme.lossColor),
                    ],
                  ],
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _ValueBadge extends StatelessWidget {
  final String value;
  final Color  color;
  const _ValueBadge({required this.value, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color:        color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(6),
      border:       Border.all(color: color.withValues(alpha: 0.35)),
    ),
    child: Text(
      value,
      style: TextStyle(
          color: color, fontSize: 11, fontWeight: FontWeight.w700),
    ),
  );
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final _BucketDef bucket;
  const _EmptyState({required this.bucket});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.show_chart_rounded,
                size: 48, color: AppTheme.neutralColor.withValues(alpha: 0.4)),
            const SizedBox(height: 16),
            Text(
              'No ${bucket.label} history yet',
              style: const TextStyle(
                  color:      Colors.white,
                  fontSize:   16,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'Open the options chain for this ticker to start tracking '
              'ATM greeks daily at the ${bucket.label} expiry. '
              'Data builds automatically each time you view the chain.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color:  AppTheme.neutralColor,
                  fontSize: 13,
                  height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}
