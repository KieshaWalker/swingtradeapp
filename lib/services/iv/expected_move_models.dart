// =============================================================================
// services/iv/expected_move_models.dart
// =============================================================================
// Model for expected_move_snapshots table rows.
// Populated by Job 9 (expected_move_pull) at 21:00 UTC each weekday.
//
// One row per (ticker, date, period_type).  period_type values:
//   'daily'   — 1σ move implied by the nearest expiry (~1 DTE)
//   'weekly'  — 1σ move implied by the ~7-DTE expiry
//   'monthly' — 1σ move implied by the ~30-DTE expiry
//
// Band convention (log-normal):
//   upper_nS = spot × exp( n × iv × √(dte/365))
//   lower_nS = spot × exp(-n × iv × √(dte/365))
//   ±1σ → 68.3%   ±2σ → 95.4%   ±3σ → 99.7%
// =============================================================================

class ExpectedMoveSnapshot {
  final String ticker;
  final DateTime date;
  final String periodType;
  final double spot;
  final double? iv;
  final int? dte;
  final double? emDollars;
  final double? emPct;
  final double? upper1s;
  final double? lower1s;
  final double? upper2s;
  final double? lower2s;
  final double? upper3s;
  final double? lower3s;

  const ExpectedMoveSnapshot({
    required this.ticker,
    required this.date,
    required this.periodType,
    required this.spot,
    this.iv,
    this.dte,
    this.emDollars,
    this.emPct,
    this.upper1s,
    this.lower1s,
    this.upper2s,
    this.lower2s,
    this.upper3s,
    this.lower3s,
  });

  factory ExpectedMoveSnapshot.fromJson(Map<String, dynamic> j) =>
      ExpectedMoveSnapshot(
        ticker:    j['ticker']     as String,
        date:      DateTime.parse(j['date'] as String),
        periodType: j['period_type'] as String,
        spot:      (j['spot']      as num).toDouble(),
        iv:        (j['iv']        as num?)?.toDouble(),
        dte:       j['dte']        as int?,
        emDollars: (j['em_dollars'] as num?)?.toDouble(),
        emPct:     (j['em_pct']    as num?)?.toDouble(),
        upper1s:   (j['upper_1s']  as num?)?.toDouble(),
        lower1s:   (j['lower_1s']  as num?)?.toDouble(),
        upper2s:   (j['upper_2s']  as num?)?.toDouble(),
        lower2s:   (j['lower_2s']  as num?)?.toDouble(),
        upper3s:   (j['upper_3s']  as num?)?.toDouble(),
        lower3s:   (j['lower_3s']  as num?)?.toDouble(),
      );

  bool get hasBands =>
      upper1s != null && lower1s != null &&
      upper2s != null && lower2s != null &&
      upper3s != null && lower3s != null;
}
