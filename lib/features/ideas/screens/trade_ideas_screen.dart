// =============================================================================
// features/ideas/screens/trade_ideas_screen.dart
// =============================================================================
// "Trade Ideas" watchlist — saved setups that haven't yet passed all 5 phases.
//
// Each idea card runs all 5 phase panels offstage (invisible but built) so the
// full phase logic stays live and consistent with the blotter evaluation screen.
// Card border and phase dots update automatically as market conditions change:
//   • Green border = all 5 phases pass → ready to trade
//   • Amber border = warnings but no hard fails
//   • Red border   = one or more hard fails
//   • Grey border  = still evaluating
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/app_menu_button.dart';
import '../../../services/schwab/schwab_models.dart';
import '../../../services/schwab/schwab_providers.dart';
import '../../blotter/models/phase_result.dart';
import '../../blotter/widgets/phase_panels/economic_phase_panel.dart';
import '../../blotter/widgets/phase_panels/formula_phase_panel.dart';
import '../../blotter/widgets/phase_panels/blotter_phase_panel.dart';
import '../../blotter/widgets/phase_panels/vol_surface_phase_panel.dart';
import '../../blotter/widgets/phase_panels/kalshi_phase_panel.dart';
import '../models/trade_idea.dart';
import '../providers/trade_ideas_notifier.dart';

// ── Main screen ───────────────────────────────────────────────────────────────

class TradeIdeasScreen extends ConsumerWidget {
  const TradeIdeasScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ideasAsync = ref.watch(tradeIdeasNotifierProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Trade Ideas'),
        actions: const [AppMenuButton()],
      ),
      body: ideasAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Text('Error loading ideas: $e',
              style: const TextStyle(color: AppTheme.lossColor)),
        ),
        data: (ideas) {
          final active  = ideas.where((i) => !i.isExpired).toList();
          final expired = ideas.where((i) => i.isExpired).toList();

          if (ideas.isEmpty) return const _EmptyState();

          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
            children: [
              if (active.isNotEmpty) ...[
                _SectionLabel('Active (${active.length})'),
                const SizedBox(height: 8),
                for (final idea in active) _IdeaCard(idea: idea),
              ],
              if (expired.isNotEmpty) ...[
                const SizedBox(height: 16),
                _SectionLabel('Expired (${expired.length})'),
                const SizedBox(height: 8),
                for (final idea in expired) _IdeaCard(idea: idea),
              ],
            ],
          );
        },
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
          color:       AppTheme.neutralColor,
          fontSize:    11,
          fontWeight:  FontWeight.w700,
          letterSpacing: 1.0,
        ),
      );
}

// ── Idea card ─────────────────────────────────────────────────────────────────

class _IdeaCard extends ConsumerStatefulWidget {
  final TradeIdea idea;
  const _IdeaCard({required this.idea});

  @override
  ConsumerState<_IdeaCard> createState() => _IdeaCardState();
}

class _IdeaCardState extends ConsumerState<_IdeaCard> {
  PhaseResult _p1 = PhaseResult.none;
  PhaseResult _p2 = PhaseResult.none;
  PhaseResult _p3 = PhaseResult.none;
  PhaseResult _p4 = PhaseResult.none;
  PhaseResult _p5 = PhaseResult.none;

  void _onResult(int phase, PhaseResult r) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        if (phase == 1) {
          _p1 = r;
        } else if (phase == 2) {
          _p2 = r;
        } else if (phase == 3) {
          _p3 = r;
        } else if (phase == 4) {
          _p4 = r;
        } else {
          _p5 = r;
        }
      });
    });
  }

  SchwabOptionContract? _findContract(SchwabOptionsChain? chain) {
    final idea = widget.idea;
    if (chain == null) return null;
    final exp = chain.expirations
        .where((e) => e.expirationDate == idea.expiryStr)
        .firstOrNull;
    if (exp == null) return null;
    final contracts = idea.isCall ? exp.calls : exp.puts;
    if (contracts.isEmpty) return null;
    return contracts.reduce((a, b) =>
        (a.strikePrice - idea.strike).abs() <
                (b.strikePrice - idea.strike).abs()
            ? a
            : b);
  }

  @override
  Widget build(BuildContext context) {
    final idea    = widget.idea;
    final results = [_p1, _p2, _p3, _p4, _p5];
    final allPass = results.every((r) => r.status == PhaseStatus.pass);
    final anyFail = results.any((r) => r.status == PhaseStatus.fail);
    final anyWarn = results.any((r) => r.status == PhaseStatus.warn);
    final allEval = results.every((r) => r.status != PhaseStatus.pending);

    // Watch Schwab chain — needed to pass live data to BlotterPhasePanel (P3)
    final chainAsync = idea.isExpired
        ? null
        : ref.watch(schwabOptionsChainProvider(OptionsChainParams(
            symbol:         idea.ticker,
            contractType:   idea.isCall ? 'CALL' : 'PUT',
            strikeCount:    20,
            expirationDate: idea.expiryStr,
          )));

    final chain    = chainAsync?.valueOrNull;
    final contract = _findContract(chain);
    final spot     = chain?.underlyingPrice ?? 0.0;
    final iv       = (contract?.impliedVolatility ?? 0.0) / 100.0;
    final mid      = contract?.midpoint ?? 0.0;
    final delta    = contract?.delta    ?? 0.0;
    final gamma    = contract?.gamma    ?? 0.0;
    final vega     = contract?.vega     ?? 0.0;

    // Card border colour tracks evaluation state
    final Color borderColor;
    final double borderWidth;
    if (!allEval) {
      borderColor = AppTheme.borderColor;
      borderWidth = 1;
    } else if (allPass) {
      borderColor = AppTheme.profitColor;
      borderWidth = 2;
    } else if (anyFail) {
      borderColor = AppTheme.lossColor;
      borderWidth = 1.5;
    } else if (anyWarn) {
      borderColor = const Color(0xFFFBBF24);
      borderWidth = 1.5;
    } else {
      borderColor = AppTheme.borderColor;
      borderWidth = 1;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Stack(
        children: [
          // ── Visible card ─────────────────────────────────────────────────────
          Card(
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: borderColor.withValues(alpha: allEval ? 0.7 : 0.3),
                width: borderWidth,
              ),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => context.push(
                '/blotter/evaluate?ticker=${idea.ticker}',
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Top row: ticker + direction badge + status icon + delete
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(
                          idea.ticker,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _DirectionBadge(isCall: idea.isCall),
                        const Spacer(),
                        if (allPass) ...[
                          const Icon(Icons.check_circle_rounded,
                              size: 16, color: AppTheme.profitColor),
                          const SizedBox(width: 4),
                        ],
                        if (idea.isExpired)
                          const _Badge(
                              label: 'EXPIRED',
                              color: AppTheme.neutralColor),
                        const SizedBox(width: 4),
                        GestureDetector(
                          onTap: () => ref
                              .read(tradeIdeasNotifierProvider.notifier)
                              .delete(idea.id),
                          child: const Icon(Icons.close,
                              size: 16, color: AppTheme.neutralColor),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),

                    // Strike · expiry · DTE · qty · budget
                    Text(
                      '\$${_fmtStrike(idea.strike)}  ·  '
                      '${DateFormat('MMM d, yy').format(idea.expiryDate)}  ·  '
                      '${idea.isExpired ? 'Expired' : '${idea.dte}d'}  ·  '
                      '${idea.quantity}x  ·  '
                      '\$${(idea.budget / 1000).toStringAsFixed(0)}k budget',
                      style: const TextStyle(
                        color:    AppTheme.neutralColor,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 10),

                    // Phase dots row
                    Row(
                      children: [
                        for (int i = 0; i < results.length; i++) ...[
                          _PhaseDot(phase: i + 1, result: results[i]),
                          if (i < results.length - 1)
                            const SizedBox(width: 6),
                        ],
                        const SizedBox(width: 10),
                        if (!allEval && !idea.isExpired) ...[
                          const SizedBox(
                            width:  10,
                            height: 10,
                            child: CircularProgressIndicator(strokeWidth: 1.5),
                          ),
                          const SizedBox(width: 5),
                          const Text(
                            'evaluating…',
                            style: TextStyle(
                              color:    AppTheme.neutralColor,
                              fontSize: 10,
                            ),
                          ),
                        ],
                        if (allPass) ...[
                          const Spacer(),
                          const Text(
                            'READY TO TRADE',
                            style: TextStyle(
                              color:      AppTheme.profitColor,
                              fontSize:   10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ── Offstage phase evaluator ─────────────────────────────────────────
          // Builds all 5 phase panels invisibly so their onResult callbacks fire
          // and keep the phase dots up to date. Not painted or interactable.
          if (!idea.isExpired)
            Offstage(
              offstage: true,
              child: _PhaseEvaluator(
                idea:     idea,
                spot:     spot,
                iv:       iv,
                mid:      mid,
                delta:    delta,
                gamma:    gamma,
                vega:     vega,
                onResult: _onResult,
              ),
            ),
        ],
      ),
    );
  }
}

// ── Offstage phase evaluator ──────────────────────────────────────────────────
// Mounts all 5 phase panels in the widget tree without painting them.
// Each panel watches its own providers and fires onResult when computed.
// BlotterPhasePanel (P3) requires spot/iv/mid from the parent's chain watch.

class _PhaseEvaluator extends StatelessWidget {
  final TradeIdea idea;
  final double    spot;
  final double    iv;
  final double    mid;
  final double    delta;
  final double    gamma;
  final double    vega;
  final void Function(int phase, PhaseResult) onResult;

  const _PhaseEvaluator({
    required this.idea,
    required this.spot,
    required this.iv,
    required this.mid,
    required this.delta,
    required this.gamma,
    required this.vega,
    required this.onResult,
  });

  @override
  Widget build(BuildContext context) {
    final dte = idea.dte > 0 ? idea.dte : 1;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Phase 1 — Economic gate
        EconomicPhasePanel(
          ticker:       idea.ticker,
          contractType: idea.contractType,
          dte:          dte,
          onResult:     (r) => onResult(1, r),
        ),

        // Phase 2 — Formula gate
        FormulaPhasePanel(
          ticker:       idea.ticker,
          contractType: idea.contractType,
          strike:       idea.strike,
          expiry:       idea.expiryStr,
          priceTarget:  idea.priceTarget,
          maxBudget:    idea.budget,
          onResult:     (r) => onResult(2, r),
        ),

        // Phase 3 — Blotter gate (needs live chain data from parent)
        BlotterPhasePanel(
          key:          ValueKey('idea-p3-${idea.id}'),
          ticker:       idea.ticker,
          spot:         spot > 0 ? spot : idea.strike,
          strike:       idea.strike,
          impliedVol:   iv > 0 ? iv : 0.25,
          daysToExpiry: dte,
          isCall:       idea.isCall,
          brokerMid:    mid,
          delta:        delta,
          gamma:        gamma,
          vega:         vega,
          quantity:     idea.quantity,
          onResult:     (r) => onResult(3, r),
        ),

        // Phase 4 — Vol surface gate
        VolSurfacePhasePanel(
          key:          ValueKey('idea-p4-${idea.id}'),
          ticker:       idea.ticker,
          strike:       idea.strike,
          daysToExpiry: dte,
          isCall:       idea.isCall,
          vega:         vega != 0 ? vega : null,
          onResult:     (r) => onResult(4, r),
        ),

        // Phase 5 — Kalshi gate
        KalshiPhasePanel(
          ticker:     idea.ticker,
          expiryDate: idea.expiryDate,
          isCall:     idea.isCall,
          onResult:   (r) => onResult(5, r),
        ),
      ],
    );
  }
}

// ── Phase dot ─────────────────────────────────────────────────────────────────

class _PhaseDot extends StatelessWidget {
  final int         phase;
  final PhaseResult result;

  const _PhaseDot({required this.phase, required this.result});

  @override
  Widget build(BuildContext context) {
    final status    = result.status;
    final color     = status.color;
    final isPending = status == PhaseStatus.pending;

    return Tooltip(
      message: 'P$phase: ${status.label}'
          '${result.headline.isNotEmpty && result.headline != 'Not evaluated' ? '\n${result.headline}' : ''}',
      child: Container(
        width:  26,
        height: 26,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isPending
              ? AppTheme.elevatedColor
              : color.withValues(alpha: 0.15),
          border: Border.all(
            color: isPending ? AppTheme.borderColor : color,
            width: 1.5,
          ),
        ),
        child: Center(
          child: isPending
              ? Text(
                  '$phase',
                  style: const TextStyle(
                    fontSize:   10,
                    fontWeight: FontWeight.w700,
                    color:      AppTheme.neutralColor,
                  ),
                )
              : Icon(status.icon, size: 12, color: color),
        ),
      ),
    );
  }
}

// ── Direction badge ───────────────────────────────────────────────────────────

class _DirectionBadge extends StatelessWidget {
  final bool isCall;
  const _DirectionBadge({required this.isCall});

  @override
  Widget build(BuildContext context) {
    final color = isCall ? AppTheme.profitColor : AppTheme.lossColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color:        color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border:       Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        isCall ? 'CALL' : 'PUT',
        style: TextStyle(
          fontSize:   10,
          fontWeight: FontWeight.w800,
          color:      color,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

// ── Generic badge ─────────────────────────────────────────────────────────────

class _Badge extends StatelessWidget {
  final String label;
  final Color  color;
  const _Badge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color:        color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(4),
          border:       Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize:   9,
            fontWeight: FontWeight.w700,
            color:      color,
            letterSpacing: 0.4,
          ),
        ),
      );
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lightbulb_outline_rounded,
                size: 64, color: AppTheme.neutralColor),
            const SizedBox(height: 16),
            const Text(
              'No trade ideas yet',
              style: TextStyle(
                color:      Colors.white,
                fontWeight: FontWeight.w700,
                fontSize:   18,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Save a setup from the Trade Evaluation screen\n'
              'to monitor it here — even if it hasn\'t passed\n'
              'all five phases yet.',
              style:     TextStyle(color: AppTheme.neutralColor, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),
            ElevatedButton.icon(
              onPressed: () => context.push('/blotter/evaluate'),
              icon:  const Icon(Icons.fact_check_rounded, size: 16),
              label: const Text('Open Trade Evaluation'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.profitColor,
                foregroundColor: Colors.black,
                textStyle: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 13),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

String _fmtStrike(double v) =>
    v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);
