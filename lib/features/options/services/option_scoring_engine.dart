// =============================================================================
// features/options/services/option_scoring_engine.dart
// OptionScore model — scoring is performed by the Python /scoring/score endpoint.
// =============================================================================
import '../../../services/schwab/schwab_models.dart';
import '../../../services/iv/iv_models.dart';

// ignore_for_file: unused_import
// schwab_models and iv_models kept so callers that import this file transitively
// still compile when they reference SchwabOptionContract or IvAnalysis.

class OptionScore {
  final int    total;           // 0–100 final (regime-adjusted)
  final int    baseScore;       // 0–100 before regime multiplier
  final int    deltaScore;      // 0–20
  final int    dteScore;        // 0–20
  final int    spreadScore;     // 0–10
  final int    ivScore;         // 0–20  (IVP-based when available)
  final int    liquidityScore;  // 0–15  (OI + Vol/OI)
  final int    moneynessScore;  // 0–15
  final double gexMultiplier;   // Gm — 0.50–1.20
  final double vannaMultiplier; // Vm — 0.60–1.00
  final bool   regimeFail;      // true = short gamma hard gate triggered
  final bool   ivpUsed;         // true = IVP data was used for ivScore
  final String grade;           // A / B / C / D
  final List<String> flags;

  const OptionScore({
    required this.total,
    required this.baseScore,
    required this.deltaScore,
    required this.dteScore,
    required this.spreadScore,
    required this.ivScore,
    required this.liquidityScore,
    required this.moneynessScore,
    required this.gexMultiplier,
    required this.vannaMultiplier,
    required this.regimeFail,
    required this.ivpUsed,
    required this.grade,
    required this.flags,
  });

  double get regimeMultiplier => gexMultiplier * vannaMultiplier;

  factory OptionScore.fromJson(Map<String, dynamic> j) => OptionScore(
    total:           (j['total']            as num? ?? 0).toInt(),
    baseScore:       (j['base_score']       as num? ?? 0).toInt(),
    deltaScore:      (j['delta_score']      as num? ?? 0).toInt(),
    dteScore:        (j['dte_score']        as num? ?? 0).toInt(),
    spreadScore:     (j['spread_score']     as num? ?? 0).toInt(),
    ivScore:         (j['iv_score']         as num? ?? 0).toInt(),
    liquidityScore:  (j['liquidity_score']  as num? ?? 0).toInt(),
    moneynessScore:  (j['moneyness_score']  as num? ?? 0).toInt(),
    gexMultiplier:   (j['gex_multiplier']   as num? ?? 1.0).toDouble(),
    vannaMultiplier: (j['vanna_multiplier'] as num? ?? 1.0).toDouble(),
    regimeFail:      j['regime_fail']       as bool? ?? false,
    ivpUsed:         j['ivp_used']          as bool? ?? false,
    grade:           j['grade']             as String? ?? 'D',
    flags:           (j['flags']            as List? ?? []).cast<String>(),
  );
}
