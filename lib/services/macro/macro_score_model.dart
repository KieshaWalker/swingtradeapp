// =============================================================================
// services/macro/macro_score_model.dart
// =============================================================================
// Macro market regime scoring model.
//
// Score components (total 100 pts):
//   VIX Level          — 20 pts  (VIXY quote history, Z-score normalized)
//   Yield Curve 2s10s  — 15 pts  (10Y - 2Y treasury spread, Z-score)
//   Fed Trajectory     — 15 pts  (fed funds 6-month delta, Z-score)
//   SPY Trend          — 15 pts  (price vs 30-day MA, Z-score)
//   Dollar (UUP)       — 10 pts  (UUP 30-day trend, Z-score)
//   Credit (HYG)       — 15 pts  (HYG 30-day trend, Z-score)
//   Gold/Copper        — 10 pts  (COPX vs GC=F ratio trend, Z-score)
//
// Regimes (5 tiers):
//   86–100  Risk-On        — momentum, long calls, debit spreads
//   71–85   Neutral-Bullish — mild tailwinds, favor bulls but be selective
//   45–70   Neutral        — iron condors, defined-risk, wait for setups
//   30–44   Caution        — reduce size, hedge, favor bears
//   0–29    Crisis         — sell premium (high IV), protect open trades
// =============================================================================

enum MacroRegime { riskOn, neutralBullish, neutral, caution, crisis }

extension MacroRegimeExt on MacroRegime {
  String get label => switch (this) {
        MacroRegime.riskOn         => 'Risk-On',
        MacroRegime.neutralBullish => 'Neutral-Bullish',
        MacroRegime.neutral        => 'Neutral',
        MacroRegime.caution        => 'Caution',
        MacroRegime.crisis         => 'Crisis',
      };

  String get emoji => switch (this) {
        MacroRegime.riskOn         => '🟢',
        MacroRegime.neutralBullish => '🔵',
        MacroRegime.neutral        => '🟡',
        MacroRegime.caution        => '🟠',
        MacroRegime.crisis         => '🔴',
      };

  // Best option strategies for each regime
  List<String> get strategies => switch (this) {
        MacroRegime.riskOn => [
            'Long Calls', 'Bull Call Spreads',
            'Cash-Secured Puts on strong names',
            'Momentum plays on breakouts',
          ],
        MacroRegime.neutralBullish => [
            'Bull Put Spreads (credit)', 'Diagonal Calls',
            'Covered Calls on holdings',
            'Defined-risk debit spreads with bullish bias',
          ],
        MacroRegime.neutral => [
            'Iron Condors', 'Defined-risk spreads',
            'Wait for high-quality setups',
            'Reduce position size and leverage',
          ],
        MacroRegime.caution => [
            'Bear Call Spreads', 'Protective Puts on holdings',
            'Raise cash, tighten stops',
            'Avoid new long premium positions',
          ],
        MacroRegime.crisis => [
            'Sell premium (IV elevated) — Iron Condors',
            'VIX call spreads for portfolio hedge',
            'Cash-secured puts on quality names at deep support',
            'Aggressively hedge all open positions',
          ],
      };

  String get description => switch (this) {
        MacroRegime.riskOn =>
            'Strong bullish backdrop: low fear, positive momentum, accommodative credit, '
            'and weak dollar supporting risk assets. Lean bullish — size up.',
        MacroRegime.neutralBullish =>
            'Mild tailwinds with some mixed signals. The trend is your friend but '
            'require higher-quality setups. Favor defined-risk bullish structures.',
        MacroRegime.neutral =>
            'Mixed macro signals. No strong directional edge. '
            'Premium-selling strategies and iron condors work best here.',
        MacroRegime.caution =>
            'Deteriorating conditions: elevated fear, tightening credit, or '
            'weakening trend. Reduce exposure, favor hedges and bearish structures.',
        MacroRegime.crisis =>
            'Extreme stress across multiple indicators. High IV creates premium-selling '
            'opportunities for disciplined traders. Protect all open positions aggressively.',
      };
}

class MacroSubScore {
  final String name;
  final String description;
  final double score;     // points earned
  final double maxScore;  // max possible points
  final String signal;    // e.g. "VIXY $14.2 — Elevated"
  final String detail;    // one-line explanation
  final bool isPositive;  // green vs red indicator
  final bool zScored;     // true = normalized from history; false = threshold fallback

  const MacroSubScore({
    required this.name,
    required this.description,
    required this.score,
    required this.maxScore,
    required this.signal,
    required this.detail,
    required this.isPositive,
    this.zScored = false,
  });

  double get pct => maxScore > 0 ? score / maxScore : 0;

  factory MacroSubScore.fromJson(Map<String, dynamic> j) => MacroSubScore(
    name:        j['name']        as String? ?? '',
    description: j['description'] as String? ?? '',
    score:       (j['score']      as num?  ?? 0).toDouble(),
    maxScore:    (j['max_score']  as num?  ?? 0).toDouble(),
    signal:      j['signal']      as String? ?? '',
    detail:      j['detail']      as String? ?? '',
    isPositive:  j['is_positive'] as bool?   ?? true,
    zScored:     j['z_scored']    as bool?   ?? false,
  );
}

class MacroScore {
  final double total;              // 0–100
  final MacroRegime regime;
  final List<MacroSubScore> components;
  final DateTime computedAt;
  final bool hasEnoughData;        // false if Supabase tables are empty
  final bool usedZScores;          // true if most components used Z-score normalization

  const MacroScore({
    required this.total,
    required this.regime,
    required this.components,
    required this.computedAt,
    this.hasEnoughData = true,
    this.usedZScores = false,
  });

  static MacroScore empty() => MacroScore(
        total: 50,
        regime: MacroRegime.neutral,
        components: [],
        computedAt: DateTime.now(),
        hasEnoughData: false,
      );

  static MacroRegime regimeFor(double score) {
    if (score >= 86) return MacroRegime.riskOn;
    if (score >= 71) return MacroRegime.neutralBullish;
    if (score >= 45) return MacroRegime.neutral;
    if (score >= 30) return MacroRegime.caution;
    return MacroRegime.crisis;
  }

  factory MacroScore.fromJson(Map<String, dynamic> j) => MacroScore(
    total:         (j['total']          as num?  ?? 50).toDouble(),
    regime:        regimeFor((j['total'] as num? ?? 50).toDouble()),
    components:    (j['components']     as List? ?? [])
        .map((c) => MacroSubScore.fromJson(c as Map<String, dynamic>))
        .toList(),
    computedAt:    DateTime.now(),
    hasEnoughData: j['has_enough_data'] as bool? ?? false,
    usedZScores:   j['used_z_scores']   as bool? ?? false,
  );
}
