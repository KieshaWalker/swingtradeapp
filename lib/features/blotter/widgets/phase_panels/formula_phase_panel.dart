// =============================================================================
// features/blotter/widgets/phase_panels/formula_phase_panel.dart
// =============================================================================
// Phase 2 of 5 — Formula Gate
//
// Evaluates the specific contract (ticker + strike + expiry + call/put) against
// six quality dimensions and a pricing edge / R:R formula check.
//
// Flow:
//   1. Watches schwabOptionsChainProvider to fetch live contract data
//   2. Locates the specific contract by expiry date + closest strike match
//   3. Runs OptionScoringEngine.score()   → 6-component 0–100 score
//   4. Runs OptionDecisionEngine.analyze() → R:R, theta, edge, break-even
//   5. Computes PhaseResult and calls onResult when status changes
//
// Pass/Warn/Fail:
//   PASS  score ≥ 65  AND  estimated return ≥ 30%  AND  no hard flags
//   WARN  score 50–64  OR  return 15–29%  OR  any soft flag (wide spread, DTE<14)
//   FAIL  score < 50   OR  negative P&L  OR  illiquid  OR  no open interest
//
// The parent (FivePhaseBlotterScreen) fetches and passes:
//   ticker, strike (double), expiry ("YYYY-MM-DD"), contractType,
//   priceTarget (optional), maxBudget
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme.dart';
import '../../../../services/schwab/schwab_models.dart';
import '../../../../services/schwab/schwab_providers.dart';
import '../../../../services/python_api/python_api_client.dart';
import '../../../options/services/option_decision_engine.dart';
import '../../../options/services/option_scoring_engine.dart';
import '../../../options/widgets/option_score_sheet.dart';
import '../../models/blotter_models.dart';
import '../../models/phase_result.dart';

// ── Panel widget ──────────────────────────────────────────────────────────────

class FormulaPhasePanel extends ConsumerStatefulWidget {
  final String       ticker;
  final double?      strike;       // null → show "enter trade details" placeholder
  final String?      expiry;       // null → same; format expected: "YYYY-MM-DD"
  final ContractType contractType;
  final double?      priceTarget;  // null → skip R:R section
  final double       maxBudget;
  final void Function(PhaseResult)? onResult;

  const FormulaPhasePanel({
    super.key,
    required this.ticker,
    required this.contractType,
    required this.maxBudget,
    this.strike,
    this.expiry,
    this.priceTarget,
    this.onResult,
  });

  @override
  ConsumerState<FormulaPhasePanel> createState() => _FormulaPhasePanelState();
}

class _FormulaPhasePanelState extends ConsumerState<FormulaPhasePanel> {
  PhaseResult?         _lastResult;
  OptionScore?         _score;
  OptionDecisionResult? _decisionResult;
  String?              _lastFetchKey;

  Future<void> _fetchAnalysis(
    SchwabOptionContract contract,
    double               underlyingPrice,
  ) async {
    final isCall = widget.contractType == ContractType.call;

    try {
      final raw = await PythonApiClient.scoringScore(
        contract:        contract.toJson(),
        underlyingPrice: underlyingPrice,
      );
      if (mounted) setState(() => _score = OptionScore.fromJson(raw));
    } catch (_) {}

    if (widget.priceTarget != null && widget.priceTarget! > 0) {
      try {
        final raw = await PythonApiClient.decisionAnalyze(
          contract:        contract.toJson(),
          underlyingPrice: underlyingPrice,
          direction:       isCall ? 'bullish' : 'bearish',
          priceTarget:     widget.priceTarget!,
          maxBudget:       widget.maxBudget,
        );
        if (mounted) {
          setState(() => _decisionResult =
              OptionDecisionResult.fromJson(raw, contract: contract));
        }
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    // If trade details not entered yet, show placeholder
    if (widget.strike == null || widget.expiry == null) {
      return const _NotReadyTile();
    }

    final isCall = widget.contractType == ContractType.call;
    final params = OptionsChainParams(
      symbol:       widget.ticker,
      contractType: isCall ? 'CALL' : 'PUT',
      strikeCount:  20,
    );
    final chainAsync = ref.watch(schwabOptionsChainProvider(params));

    if (chainAsync.isLoading) return const _LoadingSkeleton();
    if (chainAsync.hasError) {
      return _ErrorTile(message: '${chainAsync.error}');
    }

    final chain = chainAsync.value;
    if (chain == null) {
      return const _ErrorTile(message: 'No chain data returned from Schwab');
    }

    // Find specific contract
    final contract = _findContract(
      chain:        chain,
      strike:       widget.strike!,
      expiry:       widget.expiry!,
      contractType: widget.contractType,
    );

    if (contract == null) {
      return _ErrorTile(
        message: 'Contract not found — '
            '\$${widget.strike!.toStringAsFixed(0)} '
            '${isCall ? 'call' : 'put'} '
            '${widget.expiry} '
            'not in chain (${chain.expirations.length} expirations loaded)',
      );
    }

    // Trigger async fetch when contract or price changes
    final fetchKey = '${contract.symbol}:${chain.underlyingPrice}:${widget.priceTarget}';
    if (fetchKey != _lastFetchKey) {
      _lastFetchKey = fetchKey;
      _score = null;
      _decisionResult = null;
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => _fetchAnalysis(contract, chain.underlyingPrice));
    }

    final score = _score;
    if (score == null) return const _LoadingSkeleton();

    final result = _computeResult(
      score:          score,
      decisionResult: _decisionResult,
      contract:       contract,
      underlying:     chain.underlyingPrice,
    );
    _notifyIfChanged(result);

    return _PanelBody(
      ticker:         widget.ticker,
      contractType:   widget.contractType,
      contract:       contract,
      underlying:     chain.underlyingPrice,
      score:          score,
      decisionResult: _decisionResult,
      result:         result,
    );
  }

  // ── Contract lookup ─────────────────────────────────────────────────────────

  static SchwabOptionContract? _findContract({
    required SchwabOptionsChain chain,
    required double              strike,
    required String              expiry,
    required ContractType        contractType,
  }) {
    // Flexible expiry match: exact or prefix
    final exp = chain.expirations.where((e) =>
        e.expirationDate == expiry ||
        e.expirationDate.startsWith(expiry) ||
        expiry.startsWith(e.expirationDate)).firstOrNull;
    if (exp == null) return null;

    final contracts = contractType == ContractType.call ? exp.calls : exp.puts;
    if (contracts.isEmpty) return null;

    // Return exact strike or closest
    return contracts.reduce((a, b) =>
        (a.strikePrice - strike).abs() < (b.strikePrice - strike).abs() ? a : b);
  }

  // ── Phase result computation ─────────────────────────────────────────────────

  PhaseResult _computeResult({
    required OptionScore          score,
    required OptionDecisionResult? decisionResult,
    required SchwabOptionContract  contract,
    required double                underlying,
  }) {
    // Hard fail conditions
    final isIlliquid = score.flags.any(
        (f) => f.contains('illiquid') || f.contains('No market'));
    final noOI = score.flags.any((f) => f.contains('No open interest'));
    final negPnl = decisionResult != null && decisionResult.estimatedPnl <= 0;
    final badReturn = decisionResult != null &&
        decisionResult.estimatedReturn < 15 &&
        widget.priceTarget != null;

    final PhaseStatus status;
    if (score.total < 50 || isIlliquid || noOI || negPnl) {
      status = PhaseStatus.fail;
    } else if (score.total < 65 ||
               badReturn ||
               score.flags.isNotEmpty) {
      status = PhaseStatus.warn;
    } else {
      status = PhaseStatus.pass;
    }

    // Signal bullets — top 2 scoring components + key formula outputs
    final components = _sortedComponents(score);
    final signals = <String>[
      '${components[0].$1}: ${components[0].$2}/${components[0].$3}',
      '${components[1].$1}: ${components[1].$2}/${components[1].$3}',
      if (decisionResult != null) ...[
        if (decisionResult.isCheap)
          'Pricing edge: +\$${decisionResult.pricingEdge.toStringAsFixed(2)} (cheap vs theoretical)',
        if (decisionResult.pricingEdge < -0.10)
          'Overpriced: \$${decisionResult.pricingEdge.abs().toStringAsFixed(2)} above theoretical',
        'R:R: ${decisionResult.estimatedReturn.toStringAsFixed(0)}% return at target',
        'Break-even: \$${decisionResult.breakEvenPrice.toStringAsFixed(2)} '
            '(${decisionResult.breakEvenMovePct.toStringAsFixed(1)}% move)',
      ],
      for (final f in score.flags) '⚠ $f',
    ];

    final isCall = widget.contractType == ContractType.call;
    final headline =
        '\$${contract.strikePrice.toStringAsFixed(0)} '
        '${isCall ? 'CALL' : 'PUT'}  '
        '${contract.daysToExpiration}d DTE  '
        'Score ${score.total}/100 (${score.grade})';

    return PhaseResult(status: status, headline: headline, signals: signals);
  }

  void _notifyIfChanged(PhaseResult result) {
    if (_lastResult == null || _lastResult!.status != result.status) {
      _lastResult = result;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onResult?.call(result);
      });
    }
  }
}

// ── Panel body ────────────────────────────────────────────────────────────────

class _PanelBody extends StatelessWidget {
  final String               ticker;
  final ContractType         contractType;
  final SchwabOptionContract contract;
  final double               underlying;
  final OptionScore          score;
  final OptionDecisionResult? decisionResult;
  final PhaseResult          result;

  const _PanelBody({
    required this.ticker,
    required this.contractType,
    required this.contract,
    required this.underlying,
    required this.score,
    required this.decisionResult,
    required this.result,
  });

  @override
  Widget build(BuildContext context) {
    final isCall = contractType == ContractType.call;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Phase status header
        _PhaseHeader(result: result),
        const SizedBox(height: 14),

        // 2. Contract identity
        _ContractIdentityRow(
          ticker:     ticker,
          contract:   contract,
          underlying: underlying,
          isCall:     isCall,
        ),
        const SizedBox(height: 12),

        // 3. Score card
        _ScoreCard(score: score),
        const SizedBox(height: 16),

        // 4. Component breakdown
        _SectionLabel('Score Breakdown'),
        const SizedBox(height: 8),
        _ComponentTable(
          score:      score,
          contract:   contract,
          underlying: underlying,
        ),
        const SizedBox(height: 16),

        // 5. Formula check (only when decision result available)
        if (decisionResult != null) ...[
          _SectionLabel('Formula Check'),
          const SizedBox(height: 8),
          _FormulaSection(r: decisionResult!),
          const SizedBox(height: 16),
        ] else ...[
          _SectionLabel('Formula Check'),
          const SizedBox(height: 8),
          const _NoPriceTargetNote(),
          const SizedBox(height: 16),
        ],

        // 6. Warnings + flags
        if (score.flags.isNotEmpty || (decisionResult?.warnings.isNotEmpty ?? false)) ...[
          _SectionLabel('Warnings'),
          const SizedBox(height: 8),
          _WarningsSection(flags: score.flags, warnings: decisionResult?.warnings ?? []),
          const SizedBox(height: 16),
        ],

        // 7. Deep link
        _DeepLinkButton(
          contract:   contract,
          underlying: underlying,
          ticker:     ticker,
        ),
        const SizedBox(height: 4),
      ],
    );
  }
}

// ── Phase header ──────────────────────────────────────────────────────────────

class _PhaseHeader extends StatelessWidget {
  final PhaseResult result;
  const _PhaseHeader({required this.result});

  @override
  Widget build(BuildContext context) {
    final color = result.status.color;
    return Row(
      children: [
        Icon(result.status.icon, color: color, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            result.headline,
            style: TextStyle(
              color: color, fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color:        color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
            border:       Border.all(color: color.withValues(alpha: 0.4)),
          ),
          child: Text(
            result.status.label.toUpperCase(),
            style: TextStyle(
              color: color, fontSize: 10, fontWeight: FontWeight.w800,
              letterSpacing: 0.8),
          ),
        ),
      ],
    );
  }
}

// ── Contract identity row ─────────────────────────────────────────────────────

class _ContractIdentityRow extends StatelessWidget {
  final String               ticker;
  final SchwabOptionContract contract;
  final double               underlying;
  final bool                 isCall;
  const _ContractIdentityRow({
    required this.ticker,
    required this.contract,
    required this.underlying,
    required this.isCall,
  });

  @override
  Widget build(BuildContext context) {
    final typeColor = isCall ? AppTheme.profitColor : AppTheme.lossColor;
    final pctOtm    = underlying == 0
        ? 0.0
        : ((contract.strikePrice - underlying) / underlying).abs() * 100;

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        _Chip(
          '$ticker  \$${contract.strikePrice.toStringAsFixed(0)}  ${isCall ? 'CALL' : 'PUT'}',
          typeColor,
          bold: true,
        ),
        _Chip('${contract.daysToExpiration}d DTE',
            contract.daysToExpiration <= 7
                ? AppTheme.lossColor
                : AppTheme.neutralColor),
        _Chip('IV ${contract.impliedVolatility.toStringAsFixed(1)}%',
            AppTheme.neutralColor),
        _Chip(contract.inTheMoney ? 'ITM' : 'OTM ${pctOtm.toStringAsFixed(1)}%',
            contract.inTheMoney ? typeColor : AppTheme.neutralColor),
        _Chip('OI ${_fmtInt(contract.openInterest)}', AppTheme.neutralColor),
        _Chip(
          'Spread ${(contract.spreadPct * 100).toStringAsFixed(1)}%',
          contract.spreadPct > 0.20
              ? AppTheme.lossColor
              : AppTheme.neutralColor,
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final Color  color;
  final bool   bold;
  const _Chip(this.label, this.color, {this.bold = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color:        color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
        border:       Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }
}

// ── Score card — grade badge + total bar ──────────────────────────────────────

class _ScoreCard extends StatelessWidget {
  final OptionScore score;
  const _ScoreCard({required this.score});

  @override
  Widget build(BuildContext context) {
    final gradeColor  = _gradeColor(score.grade);
    final totalColor  = _scoreBarColor(score.total);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      child: Row(
        children: [
          // Grade circle
          Container(
            width: 54, height: 54,
            decoration: BoxDecoration(
              shape:  BoxShape.circle,
              color:  gradeColor.withValues(alpha: 0.12),
              border: Border.all(color: gradeColor, width: 2),
            ),
            child: Center(
              child: Text(
                score.grade,
                style: TextStyle(
                  color:      gradeColor,
                  fontSize:   22,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Score  ',
                      style: const TextStyle(
                          color: AppTheme.neutralColor, fontSize: 12),
                    ),
                    Text(
                      '${score.total} / 100',
                      style: TextStyle(
                        color:      totalColor,
                        fontSize:   16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _scoreMeaning(score.total),
                      style: TextStyle(
                          color: totalColor, fontSize: 11,
                          fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value:           score.total / 100,
                    minHeight:       8,
                    backgroundColor: AppTheme.borderColor.withValues(alpha: 0.3),
                    valueColor:      AlwaysStoppedAnimation(totalColor),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _scoreAction(score.total),
                  style: const TextStyle(
                      color: AppTheme.neutralColor, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Component breakdown table ─────────────────────────────────────────────────

class _ComponentTable extends StatelessWidget {
  final OptionScore          score;
  final SchwabOptionContract contract;
  final double               underlying;

  const _ComponentTable({
    required this.score,
    required this.contract,
    required this.underlying,
  });

  @override
  Widget build(BuildContext context) {
    final pctOtm = underlying == 0
        ? 0.0
        : ((contract.strikePrice - underlying) / underlying).abs();

    final rows = [
      _ComponentData(
        icon:       Icons.trending_flat_rounded,
        label:      'Delta Quality',
        score:      score.deltaScore,
        maxScore:   20,
        detail:     _deltaDetail(contract.delta.abs(), score.deltaScore),
      ),
      _ComponentData(
        icon:       Icons.timer_outlined,
        label:      'DTE Zone',
        score:      score.dteScore,
        maxScore:   20,
        detail:     _dteDetail(contract.daysToExpiration, score.dteScore),
      ),
      _ComponentData(
        icon:       Icons.compare_arrows_rounded,
        label:      'Spread Quality',
        score:      score.spreadScore,
        maxScore:   15,
        detail:     _spreadDetail(contract.spreadPct, score.spreadScore),
      ),
      _ComponentData(
        icon:       Icons.show_chart_rounded,
        label:      'Implied Volatility',
        score:      score.ivScore,
        maxScore:   20,
        detail:     _ivDetail(contract.impliedVolatility, score.ivScore),
      ),
      _ComponentData(
        icon:       Icons.center_focus_strong_outlined,
        label:      'Moneyness',
        score:      score.moneynessScore,
        maxScore:   15,
        detail:     _moneynessDetail(pctOtm, contract.inTheMoney, score.moneynessScore),
      ),
    ];

    return Column(
      children: rows.map((r) => _ComponentRow(data: r)).toList(),
    );
  }
}

class _ComponentData {
  final IconData icon;
  final String   label;
  final int      score;
  final int      maxScore;
  final String   detail;
  const _ComponentData({
    required this.icon,
    required this.label,
    required this.score,
    required this.maxScore,
    required this.detail,
  });
}

class _ComponentRow extends StatelessWidget {
  final _ComponentData data;
  const _ComponentRow({required this.data});

  @override
  Widget build(BuildContext context) {
    final pct   = data.maxScore > 0 ? data.score / data.maxScore : 0.0;
    final color = _componentColor(pct);

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(8),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(data.icon, size: 14, color: color),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  data.label,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                '${data.score} / ${data.maxScore}',
                style: TextStyle(
                    color: color, fontSize: 12, fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value:           pct.clamp(0.0, 1.0),
              minHeight:       4,
              backgroundColor: AppTheme.borderColor.withValues(alpha: 0.3),
              valueColor:      AlwaysStoppedAnimation(color),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            data.detail,
            style: const TextStyle(
                color: AppTheme.neutralColor, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

// ── Formula check section ─────────────────────────────────────────────────────

class _FormulaSection extends StatelessWidget {
  final OptionDecisionResult r;
  const _FormulaSection({required this.r});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // R:R row
        _FormulaRow(
          icon:   Icons.percent_rounded,
          label:  'Estimated Return',
          value:  '${r.estimatedReturn.toStringAsFixed(0)}%',
          detail: 'at \$${r.priceTarget.toStringAsFixed(2)} target'
                  '  ·  P&L ${r.estimatedPnl >= 0 ? '+' : ''}'
                  '\$${r.estimatedPnl.toStringAsFixed(0)}',
          color:  r.estimatedReturn >= 30
              ? AppTheme.profitColor
              : r.estimatedReturn >= 15
                  ? const Color(0xFFFBBF24)
                  : AppTheme.lossColor,
        ),
        // Pricing edge
        _FormulaRow(
          icon:   Icons.balance_rounded,
          label:  'Pricing Edge',
          value:  '${r.pricingEdge >= 0 ? '+' : ''}\$${r.pricingEdge.toStringAsFixed(2)}',
          detail: r.isCheap
              ? 'Priced below theoretical — edge in your favor'
              : r.pricingEdge < -0.10
                  ? 'Overpriced — paying above theoretical'
                  : 'Fairly priced — near theoretical value',
          color:  r.isCheap
              ? AppTheme.profitColor
              : r.pricingEdge < -0.10
                  ? AppTheme.lossColor
                  : AppTheme.neutralColor,
        ),
        // Break-even
        _FormulaRow(
          icon:   Icons.flag_outlined,
          label:  'Break-Even',
          value:  '\$${r.breakEvenPrice.toStringAsFixed(2)}',
          detail: '${r.breakEvenMovePct.toStringAsFixed(1)}% move needed from current price',
          color:  r.breakEvenMovePct <= 3
              ? AppTheme.profitColor
              : r.breakEvenMovePct <= 7
                  ? const Color(0xFFFBBF24)
                  : AppTheme.lossColor,
        ),
        // Theta drag
        _FormulaRow(
          icon:   Icons.hourglass_bottom_rounded,
          label:  'Theta Drag',
          value:  '−\$${r.dailyThetaDrag.abs().toStringAsFixed(2)}/day',
          detail: 'Total −\$${r.totalThetaDrag.abs().toStringAsFixed(0)} to expiry'
                  '  ·  ${(r.dailyThetaDrag.abs() / (r.entryCost == 0 ? 1 : r.entryCost) * 100).toStringAsFixed(1)}% of cost/day',
          color:  r.dailyThetaDrag.abs() > r.entryCost * 0.02
              ? AppTheme.lossColor
              : AppTheme.neutralColor,
        ),
        // Unusual activity (only if notable)
        if (r.unusualActivity)
          _FormulaRow(
            icon:   Icons.bolt_rounded,
            label:  'Unusual Activity',
            value:  'Vol/OI ${r.volOiRatio.toStringAsFixed(2)}',
            detail: 'Elevated flow vs open interest — unusual activity',
            color:  AppTheme.profitColor,
          ),
        // Entry cost
        _FormulaRow(
          icon:   Icons.attach_money_rounded,
          label:  'Entry Cost',
          value:  '\$${r.entryCost.toStringAsFixed(0)}',
          detail: '${r.contractsAffordable} contract${r.contractsAffordable == 1 ? '' : 's'} affordable at budget',
          color:  AppTheme.neutralColor,
        ),
      ],
    );
  }
}

class _FormulaRow extends StatelessWidget {
  final IconData icon;
  final String   label;
  final String   value;
  final String   detail;
  final Color    color;
  const _FormulaRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.detail,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(8),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label,
                style: const TextStyle(
                    color: AppTheme.neutralColor, fontSize: 12)),
          ),
          Text(value,
              style: TextStyle(
                  color: color, fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(detail,
                style: const TextStyle(
                    color: AppTheme.neutralColor, fontSize: 11),
                textAlign: TextAlign.right,
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

// ── Warnings section ──────────────────────────────────────────────────────────

class _WarningsSection extends StatelessWidget {
  final List<String> flags;
  final List<String> warnings;
  const _WarningsSection({required this.flags, required this.warnings});

  @override
  Widget build(BuildContext context) {
    final all = [...flags, ...warnings];
    return Column(
      children: all.map((w) => Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color:        AppTheme.lossColor.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(8),
          border:       Border.all(
              color: AppTheme.lossColor.withValues(alpha: 0.35)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.warning_amber_outlined,
                size: 14, color: AppTheme.lossColor),
            const SizedBox(width: 7),
            Expanded(
              child: Text(w,
                  style: const TextStyle(
                      color: AppTheme.lossColor, fontSize: 12)),
            ),
          ],
        ),
      )).toList(),
    );
  }
}

// ── Deep link button ──────────────────────────────────────────────────────────

class _DeepLinkButton extends StatelessWidget {
  final SchwabOptionContract contract;
  final double               underlying;
  final String               ticker;
  const _DeepLinkButton({
    required this.contract,
    required this.underlying,
    required this.ticker,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => OptionScoreSheet(
          contract:        contract,
          underlyingPrice: underlying,
          symbol:          ticker,
        ),
      ),
      icon:  const Icon(Icons.open_in_new_rounded, size: 14),
      label: const Text('View Full Score Sheet'),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppTheme.neutralColor,
        side:            const BorderSide(color: AppTheme.borderColor),
        minimumSize:     const Size(double.infinity, 40),
        textStyle:       const TextStyle(fontSize: 12),
      ),
    );
  }
}

// ── No-price-target notice ────────────────────────────────────────────────────

class _NoPriceTargetNote extends StatelessWidget {
  const _NoPriceTargetNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(8),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      child: const Row(
        children: [
          Icon(Icons.info_outline_rounded,
              size: 14, color: AppTheme.neutralColor),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Enter a price target in the trade form to see '
              'R:R, theta drag, break-even, and pricing edge.',
              style: TextStyle(
                  color: AppTheme.neutralColor,
                  fontSize: 12,
                  height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Loading / error / not-ready ───────────────────────────────────────────────

class _LoadingSkeleton extends StatelessWidget {
  const _LoadingSkeleton();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(strokeWidth: 2),
              SizedBox(height: 12),
              Text('Fetching option chain…',
                  style: TextStyle(
                      color: AppTheme.neutralColor, fontSize: 12)),
            ],
          ),
        ),
      );
}

class _ErrorTile extends StatelessWidget {
  final String message;
  const _ErrorTile({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        AppTheme.lossColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border:       Border.all(
            color: AppTheme.lossColor.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline,
              color: AppTheme.lossColor, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text('Phase 2 error: $message',
                style: const TextStyle(
                    color: AppTheme.lossColor, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

class _NotReadyTile extends StatelessWidget {
  const _NotReadyTile();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(8),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      child: const Row(
        children: [
          Icon(Icons.edit_outlined, size: 16, color: AppTheme.neutralColor),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Enter ticker, strike, and expiry above to evaluate '
              'the Formula phase.',
              style: TextStyle(
                  color: AppTheme.neutralColor,
                  fontSize: 12,
                  height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Section label ─────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: const TextStyle(
          color:         AppTheme.neutralColor,
          fontSize:      10,
          fontWeight:    FontWeight.w700,
          letterSpacing: 1.2,
        ),
      );
}

// =============================================================================
// Helper functions
// =============================================================================

// ── Score color + meaning ─────────────────────────────────────────────────────

Color _gradeColor(String grade) => switch (grade) {
      'A' => AppTheme.profitColor,
      'B' => const Color(0xFF60A5FA),  // blue
      'C' => const Color(0xFFFBBF24),  // amber
      _   => AppTheme.lossColor,
    };

Color _scoreBarColor(int total) {
  if (total >= 75) return AppTheme.profitColor;
  if (total >= 55) return const Color(0xFF60A5FA);
  if (total >= 35) return const Color(0xFFFBBF24);
  return AppTheme.lossColor;
}

Color _componentColor(double pct) {
  if (pct >= 0.80) return AppTheme.profitColor;
  if (pct >= 0.55) return const Color(0xFF60A5FA);
  if (pct >= 0.35) return const Color(0xFFFBBF24);
  return AppTheme.lossColor;
}

String _scoreMeaning(int total) {
  if (total >= 75) return 'Excellent setup';
  if (total >= 65) return 'Strong setup';
  if (total >= 55) return 'Adequate setup';
  if (total >= 35) return 'Below average';
  return 'Poor — avoid';
}

String _scoreAction(int total) {
  if (total >= 75) return 'Full size — all criteria aligned';
  if (total >= 65) return 'Enter at 75–100% size — minor concerns';
  if (total >= 55) return 'Half size or wait for improvement';
  if (total >= 35) return 'Watch only — identify and fix weak components';
  return 'Do not trade — resolve hard flags first';
}

// ── Component detail strings ──────────────────────────────────────────────────

String _deltaDetail(double absDelta, int score) {
  if (absDelta == 0) return 'Delta unavailable — check chain data';
  if (absDelta >= 0.30 && absDelta <= 0.50) {
    return 'Δ ${absDelta.toStringAsFixed(2)} — directional sweet spot (0.30–0.50)';
  }
  if (absDelta > 0.70) {
    return 'Δ ${absDelta.toStringAsFixed(2)} — deep ITM, low leverage on move. '
        'High cost, stock-like behavior';
  }
  if (absDelta < 0.20) {
    return 'Δ ${absDelta.toStringAsFixed(2)} — shallow, needs violent move to win. '
        'Consider buying closer to ATM';
  }
  if (absDelta < 0.30) {
    return 'Δ ${absDelta.toStringAsFixed(2)} — slightly shallow. '
        'Good if expecting sharp move';
  }
  return 'Δ ${absDelta.toStringAsFixed(2)} — slightly above sweet spot, '
      'adequate directional exposure';
}

String _dteDetail(int dte, int score) {
  if (dte == 0) return 'Expiring today — do not enter';
  if (dte <= 7)  return '$dte DTE — gamma zone. Delta unstable, exit risk extreme';
  if (dte <= 14) return '$dte DTE — theta accelerating. Move must happen this week';
  if (dte <= 21) return '$dte DTE — short-dated. Need immediate catalyst';
  if (dte <= 45) return '$dte DTE — sweet spot. Theta manageable, enough runway';
  if (dte <= 90) return '$dte DTE — above ideal. Paying extra time premium';
  return '$dte DTE — LEAP zone. Slow, expensive, low leverage';
}

String _spreadDetail(double spreadPct, int score) {
  final pct = (spreadPct * 100).toStringAsFixed(1);
  if (spreadPct < 0.05) return '$pct% spread — liquid. Enter at midpoint';
  if (spreadPct < 0.10) return '$pct% spread — tight. Midpoint fill likely';
  if (spreadPct < 0.20) return '$pct% spread — manageable. Expect slight slippage';
  if (spreadPct < 0.50) {
    return '$pct% spread — wide. Market maker extracting margin. Use limit at midpoint';
  }
  return '$pct% spread — no real market. Do not trade this strike';
}

String _ivDetail(double iv, int score) {
  if (iv >= 60) {
    return 'IV ${iv.toStringAsFixed(1)}% — high premium. Selling is ideal; buying requires large move';
  }
  if (iv >= 30) return 'IV ${iv.toStringAsFixed(1)}% — elevated, normal for active names';
  if (iv >= 15) return 'IV ${iv.toStringAsFixed(1)}% — moderate. Balanced buyer/seller value';
  return 'IV ${iv.toStringAsFixed(1)}% — low premium. '
      'Cheap to buy; small moves dominate P&L';
}


String _moneynessDetail(double pctOtm, bool isItm, int score) {
  if (isItm) {
    if (pctOtm <= 0.05) {
      return 'Shallow ITM ${(pctOtm * 100).toStringAsFixed(1)}% — valid but heavy time value';
    }
    return 'Deep ITM ${(pctOtm * 100).toStringAsFixed(1)}% — stock-like exposure, low leverage';
  }
  final pct = (pctOtm * 100).toStringAsFixed(1);
  if (pctOtm <= 0.01) return 'ATM — best for "move expected, size uncertain" setups';
  if (pctOtm <= 0.07) return 'OTM $pct% — directional swing ideal. Best leverage/cost ratio';
  if (pctOtm <= 0.12) {
    return 'OTM $pct% — outside sweet spot. Needs above-average move';
  }
  return 'Deep OTM $pct% — lottery ticket. '
      'Only for high-conviction binary events';
}

// ── Sorted components for signal bullets ─────────────────────────────────────

List<(String, int, int)> _sortedComponents(OptionScore score) {
  final components = [
    ('Delta Quality', score.deltaScore, 20),
    ('DTE Zone',      score.dteScore,   20),
    ('Spread',        score.spreadScore, 15),
    ('IV',            score.ivScore,     20),
    ('Moneyness',     score.moneynessScore, 15),
  ];
  components.sort((a, b) => (b.$2 / b.$3).compareTo(a.$2 / a.$3));
  return components;
}

// ── OptionDecisionResult extension for price target ──────────────────────────

extension _DecisionResultExt on OptionDecisionResult {
  double get priceTarget {
    // Reverse-engineer target from estimatedPnl:
    //   estimatedPnl = delta × move × 100
    //   move = estimatedPnl / (delta × 100)
    //   target = underlying + move
    // This is approximate — the parent should display their entered target directly.
    if (contract.delta == 0) return contract.strikePrice;
    return contract.strikePrice + (estimatedPnl / (contract.delta * 100));
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

String _fmtInt(int n) =>
    n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';
