// =============================================================================
// features/options/services/option_decision_engine.dart
// Pure Dart. Takes a contract + user inputs, returns full decision analysis.
// =============================================================================
import '../../../services/iv/iv_models.dart';
import '../../../services/schwab/schwab_models.dart';
import 'option_scoring_engine.dart';

enum TradeDirection { bullish, bearish }

enum Recommendation { buy, watch, avoid }

class OptionDecisionInput {
  final TradeDirection direction;
  final double         priceTarget;   // where trader thinks stock goes
  final double         maxBudget;     // max dollars to spend
  final int            contracts;     // how many contracts

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

  // Cost
  final double entryCost;        // ask × contracts × 100
  final int    contractsAffordable; // floor(maxBudget / (ask × 100))

  // P&L projection
  final double estimatedPnl;     // delta × move × 100 × contracts
  final double estimatedReturn;  // estimatedPnl / entryCost × 100

  // Break-even
  final double breakEvenPrice;   // strike ± ask
  final double breakEvenMove;    // breakEven − currentPrice (abs)
  final double breakEvenMovePct; // breakEvenMove / currentPrice × 100

  // Theta drag
  final double dailyThetaDrag;   // theta × 100 × contracts (negative = cost)
  final double totalThetaDrag;   // dailyThetaDrag × DTE

  // Pricing edge
  final double pricingEdge;      // theoreticalOptionValue − mark (+= cheap)
  final bool   isCheap;          // pricingEdge > 0.05

  // Volume/OI
  final double volOiRatio;       // totalVolume / openInterest
  final bool   unusualActivity;  // volOiRatio > 0.5

  // Vega exposure
  final double vegaDollarPer1PctIv; // vega × 100 × contracts

  // Gamma risk
  final bool   highGammaRisk;    // DTE < 10 && gamma > 0.05

  // Recommendation
  final Recommendation recommendation;
  final List<String>   reasons;   // bullet points shown to user
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
}

class OptionDecisionEngine {
  const OptionDecisionEngine._();

  static OptionDecisionResult analyze(
    SchwabOptionContract contract,
    double               underlyingPrice,
    OptionDecisionInput  input, {
    IvAnalysis? ivAnalysis,
  }) {
    // OCC symbol format: UNDERLYING + YYMMDD + C/P + STRIKE (e.g. ORCL260117C00155000)
    // symbol.contains('C') is ambiguous for tickers like C, CRM, CVX — use regex instead.
    final occMatch = RegExp(r'\d{6}([CP])\d').firstMatch(contract.symbol);
    final isCall = occMatch?.group(1) == 'C';
    final score  = OptionScoringEngine.score(contract, underlyingPrice,
        ivAnalysis: ivAnalysis);
    final c      = input.contracts;

    // ── Cost ──────────────────────────────────────────────────────────────────
    final entryCost = contract.ask * c * 100;
    final contractsAffordable =
        contract.ask == 0 ? 0 : (input.maxBudget / (contract.ask * 100)).floor();

    // ── P&L projection ────────────────────────────────────────────────────────
    final move         = (input.priceTarget - underlyingPrice);
    final estimatedPnl = contract.delta * move * 100 * c;
    final estimatedReturn =
        entryCost == 0 ? 0.0 : estimatedPnl / entryCost * 100;

    // ── Break-even ────────────────────────────────────────────────────────────
    final breakEvenPrice = isCall
        ? contract.strikePrice + contract.ask
        : contract.strikePrice - contract.ask;
    final breakEvenMove =
        (breakEvenPrice - underlyingPrice).abs();
    final breakEvenMovePct =
        underlyingPrice == 0 ? 0.0 : breakEvenMove / underlyingPrice * 100;

    // ── Theta drag ────────────────────────────────────────────────────────────
    final dailyThetaDrag = contract.theta * 100 * c;
    final totalThetaDrag = dailyThetaDrag * contract.daysToExpiration;

    // ── Pricing edge (cheap vs expensive vs fair) ─────────────────────────────
    // Threshold is relative to premium: 2% of midpoint, min $0.05.
    // A $0.05 edge on a $10 option is noise; on a $0.50 option it's 10%.
    final pricingEdge      = contract.theoreticalOptionValue - contract.midpoint;
    final edgeThreshold    = (contract.midpoint * 0.02).clamp(0.05, double.infinity);
    final isCheap          = pricingEdge > edgeThreshold;

    // ── Volume / OI ratio ─────────────────────────────────────────────────────
    final volOiRatio =
        contract.openInterest == 0 ? 0.0 : contract.totalVolume / contract.openInterest;
    final unusualActivity = volOiRatio > 0.5;

    // ── Vega ──────────────────────────────────────────────────────────────────
    final vegaDollarPer1PctIv = contract.vega * 100 * c;

    // ── Gamma risk ────────────────────────────────────────────────────────────
    final highGammaRisk =
        contract.daysToExpiration < 10 && contract.gamma > 0.05;

    // ── Direction alignment check ─────────────────────────────────────────────
    final directionAligned = isCall
        ? input.direction == TradeDirection.bullish
        : input.direction == TradeDirection.bearish;

    // ── Build reasons & warnings ──────────────────────────────────────────────
    final reasons  = <String>[];
    final warnings = <String>[];

    // Direction
    if (!directionAligned) {
      warnings.add(
          'Direction mismatch — ${isCall ? 'CALL' : 'PUT'} does not match ${input.direction.name} thesis');
    }

    // P&L
    if (estimatedPnl > 0) {
      reasons.add(
          'Estimated +\$${estimatedPnl.toStringAsFixed(0)} at \$${input.priceTarget.toStringAsFixed(2)} target');
    } else {
      warnings.add(
          'Negative P&L projected (\$${estimatedPnl.toStringAsFixed(0)}) — target may be insufficient');
    }

    // Return
    if (estimatedReturn >= 50) {
      reasons.add(
          '${estimatedReturn.toStringAsFixed(0)}% return if target hit');
    }

    // Break-even
    final targetMovePct = underlyingPrice == 0
        ? 0.0
        : (input.priceTarget - underlyingPrice).abs() / underlyingPrice * 100;
    if (breakEvenMovePct > targetMovePct && targetMovePct > 0) {
      warnings.add(
          'Break-even requires ${breakEvenMovePct.toStringAsFixed(1)}% move '
          'but target is only ${targetMovePct.toStringAsFixed(1)}% away — '
          'option expires worthless at target');
    } else {
      reasons.add(
          'Break-even at \$${breakEvenPrice.toStringAsFixed(2)} '
          '(${breakEvenMovePct.toStringAsFixed(1)}% move needed)');
    }

    // Pricing edge
    if (isCheap) {
      reasons.add(
          'Priced below theoretical by \$${pricingEdge.toStringAsFixed(2)} — potential edge');
    } else if (pricingEdge < -0.10) {
      warnings.add(
          'Priced \$${pricingEdge.abs().toStringAsFixed(2)} above theoretical — paying premium');
    }

    // Theta
    if (dailyThetaDrag.abs() > entryCost * 0.02) {
      warnings.add(
          'Heavy theta: −\$${dailyThetaDrag.abs().toStringAsFixed(2)}/day '
          '(total −\$${totalThetaDrag.abs().toStringAsFixed(0)} to expiry)');
    } else {
      reasons.add(
          'Theta drag manageable at −\$${dailyThetaDrag.abs().toStringAsFixed(2)}/day');
    }

    // Unusual activity
    if (unusualActivity) {
      reasons.add(
          'Unusual activity: vol/OI ratio ${volOiRatio.toStringAsFixed(2)} — elevated flow vs open interest');
    }

    // Vega
    if (vegaDollarPer1PctIv.abs() > entryCost * 0.05) {
      warnings.add(
          'High vega exposure: ±\$${vegaDollarPer1PctIv.abs().toStringAsFixed(0)} per 1% IV change');
    }

    // Gamma
    if (highGammaRisk) {
      warnings.add('High gamma risk — delta changes rapidly this close to expiry');
    }

    // Budget
    if (entryCost > input.maxBudget) {
      warnings.add(
          'Over budget — costs \$${entryCost.toStringAsFixed(0)} '
          'vs \$${input.maxBudget.toStringAsFixed(0)} max '
          '(can afford $contractsAffordable contract${contractsAffordable == 1 ? '' : 's'})');
    }

    // ── Recommendation ────────────────────────────────────────────────────────
    final Recommendation recommendation;
    if (!directionAligned || estimatedPnl <= 0 || entryCost > input.maxBudget * 1.5) {
      recommendation = Recommendation.avoid;
    } else if (score.total >= 65 &&
        directionAligned &&
        estimatedReturn >= 30 &&
        warnings.length <= 1) {
      recommendation = Recommendation.buy;
    } else {
      recommendation = Recommendation.watch;
    }

    return OptionDecisionResult(
      contract:              contract,
      score:                 score,
      entryCost:             entryCost,
      contractsAffordable:   contractsAffordable,
      estimatedPnl:          estimatedPnl,
      estimatedReturn:       estimatedReturn,
      breakEvenPrice:        breakEvenPrice,
      breakEvenMove:         breakEvenMove,
      breakEvenMovePct:      breakEvenMovePct,
      dailyThetaDrag:        dailyThetaDrag,
      totalThetaDrag:        totalThetaDrag,
      pricingEdge:           pricingEdge,
      isCheap:               isCheap,
      volOiRatio:            volOiRatio,
      unusualActivity:       unusualActivity,
      vegaDollarPer1PctIv:   vegaDollarPer1PctIv,
      highGammaRisk:         highGammaRisk,
      recommendation:        recommendation,
      reasons:               reasons,
      warnings:              warnings,
    );
  }

  /// Rank all contracts across all expirations, return top N by composite rank.
  /// Composite rank = score × direction_bonus × return_bonus
  static List<OptionDecisionResult> rankAll({
    required SchwabOptionsChain chain,
    required OptionDecisionInput input,
    IvAnalysis? ivAnalysis,
    int topN = 5,
  }) {
    final isCallDirection = input.direction == TradeDirection.bullish;
    final results = <OptionDecisionResult>[];

    for (final exp in chain.expirations) {
      final contracts = isCallDirection ? exp.calls : exp.puts;
      for (final c in contracts) {
        if (c.ask == 0 && c.bid == 0) continue; // skip illiquid
        results.add(analyze(c, chain.underlyingPrice, input, ivAnalysis: ivAnalysis));
      }
    }

    // Sort: Buy first, then Watch, then Avoid.
    // Within same recommendation sort by score desc.
    results.sort((a, b) {
      final recOrder = _recOrder(a.recommendation)
          .compareTo(_recOrder(b.recommendation));
      if (recOrder != 0) return recOrder;
      return b.score.total.compareTo(a.score.total);
    });

    return results.take(topN).toList();
  }

  static int _recOrder(Recommendation r) => switch (r) {
        Recommendation.buy   => 0,
        Recommendation.watch => 1,
        Recommendation.avoid => 2,
      };
}
