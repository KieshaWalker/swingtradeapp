// =============================================================================
// features/options/services/option_decision_engine.dart
// Decision models — analysis is performed by the Python /decision/* endpoints.
// =============================================================================
import '../../../services/schwab/schwab_models.dart';
import 'option_scoring_engine.dart';

enum TradeDirection { bullish, bearish }

enum Recommendation { buy, watch, avoid }

class OptionDecisionInput {
  final TradeDirection direction;
  final double         priceTarget;
  final double         maxBudget;
  final int            contracts;

  const OptionDecisionInput({
    required this.direction,
    required this.priceTarget,
    required this.maxBudget,
    this.contracts = 1,
  });
}

class OptionDecisionResult {
  final SchwabOptionContract contract;
  final OptionScore          score;

  final double entryCost;
  final int    contractsAffordable;

  final double estimatedPnl;
  final double estimatedReturn;

  final double breakEvenPrice;
  final double breakEvenMove;
  final double breakEvenMovePct;

  final double dailyThetaDrag;
  final double totalThetaDrag;
  final double thetaDecayToTarget;

  final double maxLoss;
  final double riskRewardRatio;

  final double pricingEdge;
  final bool   isCheap;

  final double volOiRatio;
  final bool   unusualActivity;

  final double vegaDollarPer1PctIv;
  final bool   highGammaRisk;

  final Recommendation recommendation;
  final List<String>   reasons;
  final List<String>   warnings;

  const OptionDecisionResult({
    required this.contract,
    required this.score,
    required this.entryCost,
    required this.contractsAffordable,
    required this.estimatedPnl,
    required this.estimatedReturn,
    required this.breakEvenPrice,
    required this.breakEvenMove,
    required this.breakEvenMovePct,
    required this.dailyThetaDrag,
    required this.totalThetaDrag,
    required this.thetaDecayToTarget,
    required this.maxLoss,
    required this.riskRewardRatio,
    required this.pricingEdge,
    required this.isCheap,
    required this.volOiRatio,
    required this.unusualActivity,
    required this.vegaDollarPer1PctIv,
    required this.highGammaRisk,
    required this.recommendation,
    required this.reasons,
    required this.warnings,
  });

  factory OptionDecisionResult.fromJson(
    Map<String, dynamic> j, {
    required SchwabOptionContract contract,
  }) {
    final scoreJ = j['score'] as Map<String, dynamic>? ?? {};
    return OptionDecisionResult(
      contract:              contract,
      score:                 OptionScore.fromJson(scoreJ),
      entryCost:             (j['entry_cost']              as num? ?? 0).toDouble(),
      contractsAffordable:   (j['contracts_affordable']    as num? ?? 0).toInt(),
      estimatedPnl:          (j['estimated_pnl']           as num? ?? 0).toDouble(),
      estimatedReturn:       (j['estimated_return']        as num? ?? 0).toDouble(),
      breakEvenPrice:        (j['break_even_price']        as num? ?? 0).toDouble(),
      breakEvenMove:         (j['break_even_move']         as num? ?? 0).toDouble(),
      breakEvenMovePct:      (j['break_even_move_pct']     as num? ?? 0).toDouble(),
      dailyThetaDrag:        (j['daily_theta_drag']         as num? ?? 0).toDouble(),
      totalThetaDrag:        (j['total_theta_drag']         as num? ?? 0).toDouble(),
      thetaDecayToTarget:    (j['theta_decay_to_target']   as num? ?? 0).toDouble(),
      maxLoss:               (j['max_loss']                as num? ?? 0).toDouble(),
      riskRewardRatio:       (j['risk_reward_ratio']       as num? ?? 0).toDouble(),
      pricingEdge:           (j['pricing_edge']            as num? ?? 0).toDouble(),
      isCheap:               j['is_cheap']                 as bool? ?? false,
      volOiRatio:            (j['vol_oi_ratio']            as num? ?? 0).toDouble(),
      unusualActivity:       j['unusual_activity']         as bool? ?? false,
      vegaDollarPer1PctIv:   (j['vega_dollar_per_1pct_iv'] as num? ?? 0).toDouble(),
      highGammaRisk:         j['high_gamma_risk']          as bool? ?? false,
      recommendation:        _parseRec(j['recommendation'] as String? ?? 'watch'),
      reasons:               (j['reasons']                 as List? ?? []).cast<String>(),
      warnings:              (j['warnings']                as List? ?? []).cast<String>(),
    );
  }

  static Recommendation _parseRec(String s) => switch (s) {
    'buy'   => Recommendation.buy,
    'avoid' => Recommendation.avoid,
    _       => Recommendation.watch,
  };
}
