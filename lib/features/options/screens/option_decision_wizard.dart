// =============================================================================
// features/options/screens/option_decision_wizard.dart
// Route: /ticker/:symbol/chains/wizard
//
// Step 1 — User inputs: direction, price target, budget, contracts
// Step 2 — rankAll() runs; displays top contracts as decision cards
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme.dart';
import '../../../services/python_api/python_api_client.dart';
import '../../../services/schwab/schwab_models.dart';
import '../../../services/schwab/schwab_providers.dart';
import '../services/option_decision_engine.dart';
import '../widgets/option_score_sheet.dart';

class OptionDecisionWizard extends ConsumerStatefulWidget {
  final String symbol;
  const OptionDecisionWizard({super.key, required this.symbol});

  @override
  ConsumerState<OptionDecisionWizard> createState() =>
      _OptionDecisionWizardState();
}

class _OptionDecisionWizardState extends ConsumerState<OptionDecisionWizard> {
  // ── Inputs ──────────────────────────────────────────────────────────────────
  TradeDirection _direction  = TradeDirection.bullish;
  final _targetCtrl  = TextEditingController();
  final _budgetCtrl  = TextEditingController();
  final _contractsCtrl = TextEditingController(text: '1');
  final _formKey = GlobalKey<FormState>();

  // ── State ───────────────────────────────────────────────────────────────────
  bool _analyzed  = false;
  bool _analyzing = false;
  List<OptionDecisionResult> _results = [];

  @override
  void dispose() {
    _targetCtrl.dispose();
    _budgetCtrl.dispose();
    _contractsCtrl.dispose();
    super.dispose();
  }

  // ── Run analysis ─────────────────────────────────────────────────────────────
  Future<void> _analyze(SchwabOptionsChain chain) async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _analyzing = true; _results = []; });

    try {
      final rawList = await PythonApiClient.decisionRankAll(
        chain:       chain.rawJson,
        direction:   _direction == TradeDirection.bullish ? 'bullish' : 'bearish',
        priceTarget: double.parse(_targetCtrl.text),
        maxBudget:   double.parse(_budgetCtrl.text),
        contracts:   int.tryParse(_contractsCtrl.text) ?? 1,
        topN:        8,
      );

      // Build symbol → contract lookup so fromJson can attach the full object
      final contractMap = <String, SchwabOptionContract>{};
      for (final exp in chain.expirations) {
        for (final c in [...exp.calls, ...exp.puts]) {
          contractMap[c.symbol] = c;
        }
      }

      final results = <OptionDecisionResult>[];
      for (final raw in rawList) {
        final m        = raw as Map<String, dynamic>;
        final sym      = m['symbol'] as String? ?? '';
        final contract = contractMap[sym];
        if (contract != null) {
          results.add(OptionDecisionResult.fromJson(m, contract: contract));
        }
      }

      if (mounted) setState(() { _results = results; _analyzed = true; });
    } catch (_) {
      if (mounted) setState(() => _analyzed = false);
    } finally {
      if (mounted) setState(() => _analyzing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chainAsync = ref.watch(
      schwabOptionsChainProvider(
        OptionsChainParams(symbol: widget.symbol, contractType: 'ALL', strikeCount: 20),
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.symbol} — Decision Wizard'),
        actions: [
          if (_analyzed)
            TextButton(
              onPressed: () => setState(() => _analyzed = false),
              child: const Text('Edit', style: TextStyle(color: AppTheme.profitColor)),
            ),
        ],
      ),
      body: chainAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error:   (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: AppTheme.lossColor, size: 40),
              const SizedBox(height: 12),
              Text('$e', textAlign: TextAlign.center,
                  style: const TextStyle(color: AppTheme.neutralColor)),
            ],
          ),
        ),
        data: (chain) {
          if (chain == null) {
            return const Center(
              child: Text('No chain data', style: TextStyle(color: AppTheme.neutralColor)),
            );
          }

          // Prefill target from underlying price
          if (_targetCtrl.text.isEmpty) {
            final suggested = _direction == TradeDirection.bullish
                ? chain.underlyingPrice * 1.05
                : chain.underlyingPrice * 0.95;
            _targetCtrl.text = suggested.toStringAsFixed(2);
          }

          if (_analyzing) {
            return const Center(child: CircularProgressIndicator());
          }
          return _analyzed ? _ResultsView(
            results:    _results,
            chain:      chain,
            onReset:    () => setState(() => _analyzed = false),
          ) : _InputForm(
            formKey:      _formKey,
            direction:    _direction,
            targetCtrl:   _targetCtrl,
            budgetCtrl:   _budgetCtrl,
            contractsCtrl: _contractsCtrl,
            underlyingPrice: chain.underlyingPrice,
            onDirectionChanged: (d) {
              setState(() {
                _direction = d;
                // Recalculate suggested target on direction flip
                final suggested = d == TradeDirection.bullish
                    ? chain.underlyingPrice * 1.05
                    : chain.underlyingPrice * 0.95;
                _targetCtrl.text = suggested.toStringAsFixed(2);
              });
            },
            onAnalyze: () => _analyze(chain),
          );
        },
      ),
    );
  }
}

// ─── Input form ───────────────────────────────────────────────────────────────

class _InputForm extends StatelessWidget {
  final GlobalKey<FormState> formKey;
  final TradeDirection       direction;
  final TextEditingController targetCtrl;
  final TextEditingController budgetCtrl;
  final TextEditingController contractsCtrl;
  final double               underlyingPrice;
  final void Function(TradeDirection) onDirectionChanged;
  final VoidCallback         onAnalyze;

  const _InputForm({
    required this.formKey,
    required this.direction,
    required this.targetCtrl,
    required this.budgetCtrl,
    required this.contractsCtrl,
    required this.underlyingPrice,
    required this.onDirectionChanged,
    required this.onAnalyze,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Form(
        key: formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Current price banner
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color:        AppTheme.elevatedColor,
                borderRadius: BorderRadius.circular(12),
                border:       Border.all(color: AppTheme.borderColor.withValues(alpha: 0.4)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('Current Price  ',
                      style: TextStyle(color: AppTheme.neutralColor, fontSize: 14)),
                  Text(
                    '\$${underlyingPrice.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontSize: 28, fontWeight: FontWeight.w800, color: Colors.white),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Direction toggle
            const Text('DIRECTION',
                style: TextStyle(
                    color: AppTheme.neutralColor, fontSize: 11, fontWeight: FontWeight.w700,
                    letterSpacing: 1.0)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _DirectionButton(
                    label: 'Bullish',
                    icon:  Icons.trending_up_rounded,
                    color: AppTheme.profitColor,
                    selected: direction == TradeDirection.bullish,
                    onTap: () => onDirectionChanged(TradeDirection.bullish),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _DirectionButton(
                    label: 'Bearish',
                    icon:  Icons.trending_down_rounded,
                    color: AppTheme.lossColor,
                    selected: direction == TradeDirection.bearish,
                    onTap: () => onDirectionChanged(TradeDirection.bearish),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),

            // Price target
            const Text('PRICE TARGET',
                style: TextStyle(
                    color: AppTheme.neutralColor, fontSize: 11, fontWeight: FontWeight.w700,
                    letterSpacing: 1.0)),
            const SizedBox(height: 8),
            TextFormField(
              controller:  targetCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
              decoration: const InputDecoration(
                prefixText: '\$',
                hintText: '0.00',
              ),
              validator: (v) {
                final n = double.tryParse(v ?? '');
                if (n == null || n <= 0) return 'Enter a valid price';
                return null;
              },
            ),

            const SizedBox(height: 20),

            // Budget + contracts row
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('MAX BUDGET',
                          style: TextStyle(
                              color: AppTheme.neutralColor, fontSize: 11,
                              fontWeight: FontWeight.w700, letterSpacing: 1.0)),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller:  budgetCtrl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
                        decoration: const InputDecoration(
                          prefixText: '\$',
                          hintText: '500',
                        ),
                        validator: (v) {
                          final n = double.tryParse(v ?? '');
                          if (n == null || n <= 0) return 'Enter budget';
                          return null;
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('CONTRACTS',
                          style: TextStyle(
                              color: AppTheme.neutralColor, fontSize: 11,
                              fontWeight: FontWeight.w700, letterSpacing: 1.0)),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller:  contractsCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        decoration: const InputDecoration(
                          hintText: '1',
                        ),
                        validator: (v) {
                          final n = int.tryParse(v ?? '');
                          if (n == null || n < 1) return 'Min 1';
                          return null;
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 32),

            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onAnalyze,
                icon: const Icon(Icons.auto_awesome),
                label: const Text('Find Best Contracts'),
                style: FilledButton.styleFrom(
                  padding:    const EdgeInsets.symmetric(vertical: 16),
                  textStyle:  const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
            ),

            const SizedBox(height: 20),
            const _HowItWorksCard(),
          ],
        ),
      ),
    );
  }
}

class _DirectionButton extends StatelessWidget {
  final String   label;
  final IconData icon;
  final Color    color;
  final bool     selected;
  final VoidCallback onTap;

  const _DirectionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color:        selected ? color.withValues(alpha: 0.12) : AppTheme.cardColor,
          borderRadius: BorderRadius.circular(12),
          border:       Border.all(
            color: selected ? color : AppTheme.borderColor.withValues(alpha: 0.3),
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Icon(icon, color: selected ? color : AppTheme.neutralColor, size: 28),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                color:      selected ? color : AppTheme.neutralColor,
                fontWeight: FontWeight.w700,
                fontSize:   15,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HowItWorksCard extends StatelessWidget {
  const _HowItWorksCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color:        AppTheme.elevatedColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderColor.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.info_outline, color: AppTheme.neutralColor, size: 16),
              SizedBox(width: 6),
              Text('How it works',
                  style: TextStyle(
                      color: AppTheme.neutralColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 10),
          for (final line in const [
            'Scans all strikes × expirations for the chain',
            'Scores each contract (delta, DTE, spread, IV, OI, moneyness)',
            'Projects P&L at your price target using live delta',
            'Evaluates break-even, theta drag, pricing edge & gamma risk',
            'Returns top 8 ranked as Buy / Watch / Avoid',
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('• ',
                      style: TextStyle(color: AppTheme.neutralColor, fontSize: 12)),
                  Expanded(
                    child: Text(line,
                        style: const TextStyle(
                            color: AppTheme.neutralColor, fontSize: 12)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Results view ──────────────────────────────────────────────────────────────

class _ResultsView extends StatelessWidget {
  final List<OptionDecisionResult> results;
  final SchwabOptionsChain         chain;
  final VoidCallback               onReset;

  const _ResultsView({
    required this.results,
    required this.chain,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    if (results.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off, color: AppTheme.neutralColor, size: 48),
            const SizedBox(height: 12),
            const Text('No contracts matched your criteria',
                style: TextStyle(color: AppTheme.neutralColor)),
            const SizedBox(height: 16),
            FilledButton(onPressed: onReset, child: const Text('Try Again')),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: results.length,
      itemBuilder: (ctx, i) => _DecisionCard(
        result: results[i],
        rank:   i + 1,
        underlyingPrice: chain.underlyingPrice,
        symbol: chain.symbol,
      ),
    );
  }
}

// ─── Decision card ────────────────────────────────────────────────────────────

class _DecisionCard extends StatelessWidget {
  final OptionDecisionResult result;
  final int                  rank;
  final double               underlyingPrice;
  final String               symbol;

  const _DecisionCard({
    required this.result,
    required this.rank,
    required this.underlyingPrice,
    required this.symbol,
  });

  @override
  Widget build(BuildContext context) {
    final c   = result.contract;
    final rec = result.recommendation;

    final recColor = switch (rec) {
      Recommendation.buy   => AppTheme.profitColor,
      Recommendation.watch => const Color(0xFFFBBF24),
      Recommendation.avoid => AppTheme.lossColor,
    };
    final recLabel = switch (rec) {
      Recommendation.buy   => 'BUY',
      Recommendation.watch => 'WATCH',
      Recommendation.avoid => 'AVOID',
    };
    final recIcon = switch (rec) {
      Recommendation.buy   => Icons.thumb_up_rounded,
      Recommendation.watch => Icons.visibility_rounded,
      Recommendation.avoid => Icons.thumb_down_rounded,
    };

    final occMatch = RegExp(r'\d{6}([CP])\d').firstMatch(c.symbol);
    final isCall = occMatch?.group(1) == 'C';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => showModalBottomSheet(
          context:        context,
          isScrollControlled: true,
          backgroundColor:    Colors.transparent,
          builder: (_) => OptionScoreSheet(
            contract:        c,
            underlyingPrice: underlyingPrice,
            symbol:          symbol,
          ),
        ),
        child: Column(
          children: [
            // ── Header ──────────────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color:        recColor.withValues(alpha: 0.08),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                border: Border(
                  left: BorderSide(color: recColor, width: 4),
                ),
              ),
              child: Row(
                children: [
                  // Rank
                  Container(
                    width: 28, height: 28,
                    decoration: BoxDecoration(
                      color:        AppTheme.cardColor,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    alignment: Alignment.center,
                    child: Text('#$rank',
                        style: const TextStyle(
                            fontSize: 11, fontWeight: FontWeight.w800,
                            color: AppTheme.neutralColor)),
                  ),
                  const SizedBox(width: 10),

                  // Strike / type / DTE
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '\$${c.strikePrice.toStringAsFixed(0)} ${isCall ? 'CALL' : 'PUT'}',
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w800),
                        ),
                        Text(
                          '${c.expirationDate}  ·  ${c.daysToExpiration}d',
                          style: const TextStyle(
                              color: AppTheme.neutralColor, fontSize: 12),
                        ),
                      ],
                    ),
                  ),

                  // Recommendation badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color:        recColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                      border:       Border.all(color: recColor.withValues(alpha: 0.5)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(recIcon, color: recColor, size: 14),
                        const SizedBox(width: 4),
                        Text(recLabel,
                            style: TextStyle(
                                color:      recColor,
                                fontSize:   12,
                                fontWeight: FontWeight.w800)),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // ── Key metrics ──────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      _Metric(
                        label: 'Entry Cost',
                        value: '\$${result.entryCost.toStringAsFixed(0)}',
                      ),
                      _Metric(
                        label: 'Est. P&L',
                        value: '${result.estimatedPnl >= 0 ? '+' : ''}'
                            '\$${result.estimatedPnl.toStringAsFixed(0)}',
                        color: result.estimatedPnl >= 0
                            ? AppTheme.profitColor
                            : AppTheme.lossColor,
                      ),
                      _Metric(
                        label: 'Est. Return',
                        value: '${result.estimatedReturn >= 0 ? '+' : ''}'
                            '${result.estimatedReturn.toStringAsFixed(0)}%',
                        color: result.estimatedReturn >= 0
                            ? AppTheme.profitColor
                            : AppTheme.lossColor,
                      ),
                      _Metric(
                        label: 'Score',
                        value: '${result.score.total} ${result.score.grade}',
                        color: switch (result.score.grade) {
                          'A' => AppTheme.profitColor,
                          'B' => const Color(0xFF60A5FA),
                          'C' => const Color(0xFFFBBF24),
                          _   => AppTheme.lossColor,
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _Metric(
                        label: 'Break-even',
                        value: '\$${result.breakEvenPrice.toStringAsFixed(2)}',
                      ),
                      _Metric(
                        label: 'BE Move',
                        value: '${result.breakEvenMovePct.toStringAsFixed(1)}%',
                      ),
                      _Metric(
                        label: 'Theta/day',
                        value: '-\$${result.dailyThetaDrag.abs().toStringAsFixed(2)}',
                        color: AppTheme.lossColor,
                      ),
                      _Metric(
                        label: 'Δ Delta',
                        value: c.delta.toStringAsFixed(2),
                        color: c.delta.abs() >= 0.3 && c.delta.abs() <= 0.5
                            ? AppTheme.profitColor
                            : AppTheme.neutralColor,
                      ),
                    ],
                  ),

                  // ── Reasons ────────────────────────────────────────────────
                  if (result.reasons.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Divider(height: 1, color: AppTheme.borderColor.withValues(alpha: 0.4)),
                    const SizedBox(height: 10),
                    for (final r in result.reasons)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.check_circle_outline_rounded,
                                color: AppTheme.profitColor, size: 14),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(r,
                                  style: const TextStyle(
                                      fontSize: 12, color: Colors.white)),
                            ),
                          ],
                        ),
                      ),
                  ],

                  // ── Warnings ───────────────────────────────────────────────
                  if (result.warnings.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    for (final w in result.warnings)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.warning_amber_rounded,
                                color: Color(0xFFFBBF24), size: 14),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(w,
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color: Color(0xFFFBBF24))),
                            ),
                          ],
                        ),
                      ),
                  ],

                  // ── Log trade CTA ──────────────────────────────────────────
                  if (rec == Recommendation.buy) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () => context.push('/trades/add', extra: {
                          'prefill': {
                            'ticker':         c.symbol.substring(0, c.symbol.indexOf(RegExp(r'\d'))),
                            'optionType':     isCall ? 'call' : 'put',
                            'strikePrice':    c.strikePrice,
                            'expirationDate': c.expirationDate,
                            'premium':        c.ask,
                            'contracts':      result.contractsAffordable.clamp(1, 99),
                          },
                        }),
                        icon:  const Icon(Icons.add_rounded, size: 16),
                        label: const Text('Log This Trade'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.profitColor,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          textStyle: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _Metric({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(
                    color: AppTheme.neutralColor, fontSize: 10)),
            const SizedBox(height: 2),
            Text(value,
                style: TextStyle(
                    fontSize:   13,
                    fontWeight: FontWeight.w700,
                    color:      color ?? Colors.white)),
          ],
        ),
      );
}
