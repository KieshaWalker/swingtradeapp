// =============================================================================
// features/calculator/screens/calculator_screen.dart — Trading calculators
// =============================================================================
// Widgets defined here:
//   • CalculatorScreen         — scaffold + 8-tab TabBar
//   • _PnLEstimator            — tab 1: estimate trade outcome
//   • _PositionSizer           — tab 2: size a position by risk %
//   • _BlackScholesTab         — tab 3: BS price + all Greeks via /bs backend
//   • _SABRTab                 — tab 4: SABR implied vol via /sabr backend
//   • _HestonTab               — tab 5: Heston price via /heston backend
//   • _ForwardPriceTab         — tab 6: forward price F = S·e^{(r−q)T} (local)
//   • _TheoreticalPriceTab     — tab 7: fair value vs broker mid via /fair-value backend
//   • _IntrinsicValueTab       — tab 8: intrinsic + time value breakdown (local)
//   • _ResultRow               — label ↔ colored value row (shared)
//   • _FormulaPanel            — expandable educational formula section (shared)
//
// Route: '/calculator' in router.dart
//
// Model tabs call the Python backend (PythonApiClient) on button press.
// Each model tab includes an expandable formula/theory section.
// =============================================================================
import 'dart:math';
import 'package:flutter/material.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/app_menu_button.dart';
import '../../../services/fred/fred_service.dart';
import '../../../services/python_api/python_api_client.dart';

class CalculatorScreen extends StatefulWidget {
  const CalculatorScreen({super.key});

  @override
  State<CalculatorScreen> createState() => _CalculatorScreenState();
}

class _CalculatorScreenState extends State<CalculatorScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  double? _liveRate;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 11, vsync: this);
    FredService().getSeries('SOFR30DAYAVG', limit: 1).then((series) {
      if (mounted && series.observations.isNotEmpty) {
        setState(() => _liveRate = series.observations.first.value);
      }
    }).catchError((_) {});
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
        title: const Text('Calculator'),
        actions: const [AppMenuButton()],
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: AppTheme.profitColor,
          indicatorWeight: 3,
          indicatorSize: TabBarIndicatorSize.label,
          labelColor: AppTheme.profitColor,
          unselectedLabelColor: AppTheme.neutralColor,
          isScrollable: true,
          tabs: const [
            Tab(text: 'P&L'),
            Tab(text: 'Size'),
            Tab(text: 'Black-Scholes'),
            Tab(text: 'SABR'),
            Tab(text: 'Heston'),
            Tab(text: 'Forward Price'),
            Tab(text: 'Theoretical Price'),
            Tab(text: 'Intrinsic Value'),
            Tab(text: 'Implied Vol'),
            Tab(text: 'Kappa'),
            Tab(text: 'Vomma'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          const _PnLEstimator(),
          const _PositionSizer(),
          _BlackScholesTab(initialRate: _liveRate),
          const _SABRTab(),
          _HestonTab(initialRate: _liveRate),
          _ForwardPriceTab(initialRate: _liveRate),
          _TheoreticalPriceTab(initialRate: _liveRate),
          const _IntrinsicValueTab(),
          _ImpliedVolTab(initialRate: _liveRate),
          const _KappaTab(),
          _VommaTab(initialRate: _liveRate),
        ],
      ),
    );
  }
}

// =============================================================================
// Shared helpers
// =============================================================================

class _ResultRow extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _ResultRow({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: AppTheme.neutralColor, fontSize: 13)),
          Text(value,
              style: TextStyle(
                  color: color, fontWeight: FontWeight.w700, fontSize: 16)),
        ],
      ),
    );
  }
}

class _FormulaPanel extends StatelessWidget {
  final String title;
  final List<_FormulaLine> lines;
  const _FormulaPanel({required this.title, required this.lines});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.elevatedColor.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderColor.withValues(alpha: 0.4)),
      ),
      child: ExpansionTile(
        backgroundColor: Colors.transparent,
        collapsedBackgroundColor: Colors.transparent,
        title: Text(title,
            style: const TextStyle(
                color: AppTheme.neutralColor,
                fontWeight: FontWeight.w600,
                fontSize: 14)),
        iconColor: AppTheme.neutralColor,
        collapsedIconColor: AppTheme.neutralColor,
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: lines
            .map((l) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (l.heading != null)
                        Text(l.heading!,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 13)),
                      const SizedBox(height: 2),
                      Text(l.body,
                          style: const TextStyle(
                              color: AppTheme.neutralColor, fontSize: 12, height: 1.5)),
                    ],
                  ),
                ))
            .toList(),
      ),
    );
  }
}

class _FormulaLine {
  final String? heading;
  final String body;
  const _FormulaLine(this.body, {this.heading});
}

// =============================================================================
// Tab 1 — P&L Estimator
// =============================================================================
class _PnLEstimator extends StatefulWidget {
  const _PnLEstimator();

  @override
  State<_PnLEstimator> createState() => _PnLEstimatorState();
}

class _PnLEstimatorState extends State<_PnLEstimator> {
  final _entryCtrl = TextEditingController(text: '2.50');
  final _contractsCtrl = TextEditingController(text: '1');
  final _targetPctCtrl = TextEditingController(text: '50');
  final _stopPctCtrl = TextEditingController(text: '25');

  double? get _entry => double.tryParse(_entryCtrl.text);
  int? get _contracts => int.tryParse(_contractsCtrl.text);
  double? get _targetPct => double.tryParse(_targetPctCtrl.text);
  double? get _stopPct => double.tryParse(_stopPctCtrl.text);

  double? get _costBasis {
    if (_entry == null || _contracts == null) return null;
    return _entry! * _contracts! * 100;
  }

  double? get _targetPnl {
    if (_costBasis == null || _targetPct == null) return null;
    return _costBasis! * (_targetPct! / 100);
  }

  double? get _stopPnl {
    if (_costBasis == null || _stopPct == null) return null;
    return -_costBasis! * (_stopPct! / 100);
  }

  double? get _riskReward {
    if (_targetPnl == null || _stopPnl == null || _stopPnl == 0) return null;
    return _targetPnl! / _stopPnl!.abs();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Estimate your trade outcome before entering.',
          style: TextStyle(color: AppTheme.neutralColor),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: _entryCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Entry Premium',
                  prefixText: '\$',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: _contractsCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Contracts'),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: _targetPctCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Profit Target',
                  suffixText: '%',
                  helperText: 'of premium',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: _stopPctCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Stop Loss',
                  suffixText: '%',
                  helperText: 'of premium',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        if (_costBasis != null) ...[
          Divider(color: AppTheme.borderColor),
          const SizedBox(height: 16),
          _ResultRow(
            label: 'Cost Basis',
            value: '\$${_costBasis!.toStringAsFixed(2)}',
            color: Colors.white,
          ),
          if (_targetPnl != null)
            _ResultRow(
              label: 'Target Profit',
              value: '+\$${_targetPnl!.toStringAsFixed(2)}',
              color: AppTheme.profitColor,
            ),
          if (_stopPnl != null)
            _ResultRow(
              label: 'Max Loss (stop)',
              value: '-\$${_stopPnl!.abs().toStringAsFixed(2)}',
              color: AppTheme.lossColor,
            ),
          if (_riskReward != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _riskReward! >= 2
                    ? AppTheme.profitColor.withValues(alpha: 0.1)
                    : AppTheme.lossColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _riskReward! >= 2
                      ? AppTheme.profitColor.withValues(alpha: 0.3)
                      : AppTheme.lossColor.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Risk : Reward',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  Text(
                    '1 : ${_riskReward!.toStringAsFixed(2)}',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                      color: _riskReward! >= 2
                          ? AppTheme.profitColor
                          : AppTheme.lossColor,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _riskReward! >= 2
                  ? '✓ Meets the minimum 2:1 R/R threshold.'
                  : '✗ Below 2:1 R/R — consider adjusting your targets.',
              style: TextStyle(
                color: _riskReward! >= 2
                    ? AppTheme.profitColor
                    : AppTheme.lossColor,
                fontSize: 13,
              ),
            ),
          ],
        ],
      ],
    );
  }
}

// =============================================================================
// Tab 2 — Position Sizer
// =============================================================================
class _PositionSizer extends StatefulWidget {
  const _PositionSizer();

  @override
  State<_PositionSizer> createState() => _PositionSizerState();
}

class _PositionSizerState extends State<_PositionSizer> {
  final _accountCtrl = TextEditingController(text: '10000');
  final _riskPctCtrl = TextEditingController(text: '2');
  final _premiumCtrl = TextEditingController(text: '2.50');
  final _stopPctCtrl = TextEditingController(text: '25');

  double? get _account => double.tryParse(_accountCtrl.text);
  double? get _riskPct => double.tryParse(_riskPctCtrl.text);
  double? get _premium => double.tryParse(_premiumCtrl.text);
  double? get _stopPct => double.tryParse(_stopPctCtrl.text);

  double? get _maxRiskDollars {
    if (_account == null || _riskPct == null) return null;
    return _account! * (_riskPct! / 100);
  }

  double? get _lossPerContract {
    if (_premium == null || _stopPct == null) return null;
    return _premium! * (_stopPct! / 100) * 100;
  }

  int? get _recommendedContracts {
    if (_maxRiskDollars == null || _lossPerContract == null || _lossPerContract == 0) {
      return null;
    }
    return max(1, (_maxRiskDollars! / _lossPerContract!).floor());
  }

  double? get _totalCost {
    if (_recommendedContracts == null || _premium == null) return null;
    return _recommendedContracts! * _premium! * 100;
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Never risk more than you can afford to lose per trade.',
          style: TextStyle(color: AppTheme.neutralColor),
        ),
        const SizedBox(height: 20),
        TextFormField(
          controller: _accountCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Account Size',
            prefixText: '\$',
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _riskPctCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Max Risk Per Trade',
            suffixText: '%',
            helperText: 'Recommended: 1–2%',
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: _premiumCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Option Premium',
                  prefixText: '\$',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: _stopPctCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Stop Loss',
                  suffixText: '%',
                  helperText: 'of premium',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        if (_maxRiskDollars != null) ...[
          Divider(color: AppTheme.borderColor),
          const SizedBox(height: 16),
          _ResultRow(
            label: 'Max Risk \$',
            value: '\$${_maxRiskDollars!.toStringAsFixed(2)}',
            color: Colors.white,
          ),
          if (_lossPerContract != null)
            _ResultRow(
              label: 'Loss Per Contract (at stop)',
              value: '\$${_lossPerContract!.toStringAsFixed(2)}',
              color: AppTheme.lossColor,
            ),
          if (_recommendedContracts != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppTheme.profitColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: AppTheme.profitColor.withValues(alpha: 0.3)),
              ),
              child: Column(
                children: [
                  const Text('Recommended Contracts',
                      style: TextStyle(color: AppTheme.neutralColor)),
                  const SizedBox(height: 8),
                  Text(
                    '$_recommendedContracts',
                    style: const TextStyle(
                      fontSize: 48,
                      fontWeight: FontWeight.w900,
                      color: AppTheme.profitColor,
                    ),
                  ),
                  if (_totalCost != null)
                    Text(
                      'Total cost: \$${_totalCost!.toStringAsFixed(2)}',
                      style: const TextStyle(color: AppTheme.neutralColor),
                    ),
                ],
              ),
            ),
          ],
        ],
      ],
    );
  }
}

// =============================================================================
// Tab 3 — Black-Scholes
// =============================================================================
class _BlackScholesTab extends StatefulWidget {
  const _BlackScholesTab({this.initialRate});
  final double? initialRate;

  @override
  State<_BlackScholesTab> createState() => _BlackScholesTabState();
}

class _BlackScholesTabState extends State<_BlackScholesTab> {
  final _spotCtrl = TextEditingController(text: '100');
  final _strikeCtrl = TextEditingController(text: '100');
  final _dteCtrl = TextEditingController(text: '30');
  final _ivCtrl = TextEditingController(text: '20');
  final _rCtrl = TextEditingController(text: '4.33');
  bool _isCall = true;

  bool _loading = false;
  Map<String, dynamic>? _priceResult;

  @override
  void didUpdateWidget(covariant _BlackScholesTab old) {
    super.didUpdateWidget(old);
    if (widget.initialRate != null && old.initialRate == null) {
      _rCtrl.text = widget.initialRate!.toStringAsFixed(2);
    }
  }
  Map<String, dynamic>? _greeksResult;

  Future<void> _calculate() async {
    final spot = double.tryParse(_spotCtrl.text);
    final strike = double.tryParse(_strikeCtrl.text);
    final dte = int.tryParse(_dteCtrl.text);
    final iv = double.tryParse(_ivCtrl.text);
    final r = double.tryParse(_rCtrl.text);
    if (spot == null || strike == null || dte == null || iv == null || r == null) {
      return;
    }
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        PythonApiClient.bsPrice(
          s: spot, k: strike, t: dte / 365.0, sigma: iv / 100, r: r / 100,
          optionType: _isCall ? 'call' : 'put',
        ),
        PythonApiClient.bsGreeks(
          s: spot, k: strike, t: dte / 365.0, sigma: iv / 100, r: r / 100,
          optionType: _isCall ? 'call' : 'put',
        ),
      ]);
      if (!mounted) return;
      setState(() {
        _priceResult = results[0];
        _greeksResult = results[1];
      });
    } on PythonApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('API error: ${e.message}'),
              backgroundColor: AppTheme.lossColor),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _spotCtrl.dispose(); _strikeCtrl.dispose(); _dteCtrl.dispose();
    _ivCtrl.dispose(); _rCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── Inputs ──
        Row(children: [
          Expanded(child: TextFormField(
            controller: _spotCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Spot (S)', prefixText: '\$',
                helperText: 'Underlying price'),
          )),
          const SizedBox(width: 12),
          Expanded(child: TextFormField(
            controller: _strikeCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Strike (K)', prefixText: '\$',
                helperText: 'Option strike price'),
          )),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextFormField(
            controller: _dteCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Days to Expiry',
                helperText: 'Calendar days'),
          )),
          const SizedBox(width: 12),
          Expanded(child: TextFormField(
            controller: _ivCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Implied Vol (σ)',
                suffixText: '%', helperText: 'e.g. 20 = 20%'),
          )),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextFormField(
            controller: _rCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: 'Risk-free Rate (r)',
                suffixText: '%', helperText: 'SOFR ${(widget.initialRate ?? 4.33).toStringAsFixed(2)}%'),
          )),
          const SizedBox(width: 12),
          Expanded(child: _OptionTypeToggle(
            isCall: _isCall,
            onChanged: (v) => setState(() { _isCall = v; _priceResult = null; _greeksResult = null; }),
          )),
        ]),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _loading ? null : _calculate,
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.profitColor,
                foregroundColor: Colors.black, padding: const EdgeInsets.symmetric(vertical: 14)),
            child: _loading
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                : const Text('Calculate', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ),
        // ── Results ──
        if (_priceResult != null && _greeksResult != null) ...[
          const SizedBox(height: 24),
          Divider(color: AppTheme.borderColor),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.profitColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.profitColor.withValues(alpha: 0.3)),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text('Option Price', style: TextStyle(color: AppTheme.neutralColor,
                  fontWeight: FontWeight.w600)),
              Text('\$${(_priceResult!['price'] as num).toStringAsFixed(4)}',
                  style: const TextStyle(color: AppTheme.profitColor,
                      fontWeight: FontWeight.w900, fontSize: 22)),
            ]),
          ),
          const SizedBox(height: 8),
          _ResultRow(
            label: 'Forward (F = Se^{rT})',
            value: '\$${(_priceResult!['forward'] as num).toStringAsFixed(4)}',
            color: Colors.white,
          ),
          const SizedBox(height: 16),
          const Text('Greeks', style: TextStyle(color: Colors.white,
              fontWeight: FontWeight.w700, fontSize: 14)),
          const SizedBox(height: 8),
          _greekGrid(_greeksResult!),
        ],
        const SizedBox(height: 24),
        // ── Formula Panel ──
        const _FormulaPanel(
          title: 'About Black-Scholes',
          lines: [
            _FormulaLine(
              'C = S·N(d₁) − K·e^{−rT}·N(d₂)\n'
              'd₁ = [ln(S/K) + (r + σ²/2)T] / (σ√T)\n'
              'd₂ = d₁ − σ√T',
              heading: 'Formula',
            ),
            _FormulaLine(
              '• Constant volatility σ across all strikes and expiries\n'
              '• Underlying follows geometric Brownian motion\n'
              '• Continuous, frictionless trading; no dividends\n'
              '• Log-normal return distribution',
              heading: 'Assumptions',
            ),
            _FormulaLine(
              'Delta (Δ): rate of price change per \$1 move in spot. Call delta ∈ (0,1), put ∈ (−1,0).\n\n'
              'Gamma (Γ): rate of delta change per \$1 move. Peaks at ATM. Long gamma = benefits from big moves.\n\n'
              'Theta (Θ): daily time decay in dollars. Long options lose value each day (negative theta).\n\n'
              'Vega (ν): price change per 1% IV move. High vega = sensitive to volatility changes.\n\n'
              'Rho (ρ): price change per 1% rate move. Less impactful on short-dated options.\n\n'
              'Vanna: delta change per 1% IV move. Key for vol-skew hedging.\n\n'
              'Charm: delta change per day (delta decay). Important for overnight risk.\n\n'
              'Vomma: vega change per 1% IV move (vol convexity). High vomma = benefits from vol-of-vol.',
              heading: 'Greeks interpreted',
            ),
            _FormulaLine(
              'Best for quick, model-consistent pricing when you have a single IV. '
              'Limitation: assumes flat vol surface — use SABR for strike-dependent pricing '
              'or Heston when you need stochastic volatility dynamics.',
              heading: 'When to use',
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _greekGrid(Map<String, dynamic> g) {
    final greeks = [
      ('Delta (Δ)', g['delta'], false),
      ('Gamma (Γ)', g['gamma'], false),
      ('Theta (Θ) /day', g['theta'], true),
      ('Vega (ν) /1%', g['vega'], false),
      ('Rho (ρ) /1%', g['rho'], false),
      ('Vanna', g['vanna'], false),
      ('Charm /day', g['charm'], true),
      ('Vomma', g['vomma'], false),
    ];
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 2.8,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: greeks.map((t) {
        final val = (t.$2 as num).toDouble();
        final color = t.$3
            ? (val < 0 ? AppTheme.lossColor : AppTheme.profitColor)
            : Colors.white;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: AppTheme.elevatedColor,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(t.$1, style: const TextStyle(color: AppTheme.neutralColor, fontSize: 11), overflow: TextOverflow.ellipsis),
              Text(val.toStringAsFixed(4),
                  style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 13)),
            ],
          ),
        );
      }).toList(),
    );
  }
}

// =============================================================================
// Tab 4 — SABR
// =============================================================================
class _SABRTab extends StatefulWidget {
  const _SABRTab();

  @override
  State<_SABRTab> createState() => _SABRTabState();
}

class _SABRTabState extends State<_SABRTab> {
  final _fCtrl = TextEditingController(text: '100');
  final _kCtrl = TextEditingController(text: '100');
  final _tCtrl = TextEditingController(text: '0.25');
  final _alphaCtrl = TextEditingController(text: '0.25');
  final _rhoCtrl = TextEditingController(text: '-0.70');
  final _nuCtrl = TextEditingController(text: '0.40');
  // Beta is fixed at 0.5 (equity square-root CEV)
  static const double _beta = 0.5;

  bool _loading = false;
  double? _sabrVol;

  Future<void> _calculate() async {
    final f = double.tryParse(_fCtrl.text);
    final k = double.tryParse(_kCtrl.text);
    final t = double.tryParse(_tCtrl.text);
    final alpha = double.tryParse(_alphaCtrl.text);
    final rho = double.tryParse(_rhoCtrl.text);
    final nu = double.tryParse(_nuCtrl.text);
    if (f == null || k == null || t == null || alpha == null ||
        rho == null || nu == null) { return; }
    setState(() => _loading = true);
    try {
      final result = await PythonApiClient.sabrIv(
        f: f, k: k, t: t, alpha: alpha, beta: _beta, rho: rho, nu: nu,
      );
      if (!mounted) return;
      setState(() => _sabrVol = (result['sabr_vol'] as num).toDouble());
    } on PythonApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('API error: ${e.message}'),
              backgroundColor: AppTheme.lossColor),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _fCtrl.dispose(); _kCtrl.dispose(); _tCtrl.dispose();
    _alphaCtrl.dispose(); _rhoCtrl.dispose(); _nuCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('SABR produces a strike-dependent implied vol — '
            'it fits the vol smile/skew you observe in the market.',
            style: TextStyle(color: AppTheme.neutralColor)),
        const SizedBox(height: 20),
        // ── Inputs ──
        Row(children: [
          Expanded(child: TextFormField(
            controller: _fCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Forward (F)',
                helperText: 'F = S·e^{rT}'),
          )),
          const SizedBox(width: 12),
          Expanded(child: TextFormField(
            controller: _kCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Strike (K)',
                helperText: 'Option strike'),
          )),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextFormField(
            controller: _tCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Time (T years)',
                helperText: '30 days = 0.082'),
          )),
          const SizedBox(width: 12),
          Expanded(child: TextFormField(
            controller: _alphaCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Alpha (α)',
              helperText: 'ATM vol level ≈ IV',
              suffixIcon: const _InfoButton(
                title: 'Estimating Alpha (α)',
                lines: [
                  _FormulaLine('α ≈ ATM implied vol for your expiry.\n'
                      'If the 30-day ATM option shows 22% IV, start with α = 0.22.',
                      heading: 'Quick estimate'),
                  _FormulaLine('For β = 0.5 (equity square-root model), a more precise '
                      'starting point is α ≈ IV_ATM × F^{0.5}. But the ATM approximation '
                      'is usually close enough to seed calibration.',
                      heading: 'Precise formula'),
                  _FormulaLine('SABR calibration fits α, ρ, and ν simultaneously to '
                      'minimize the IV error across all strikes for a given expiry. '
                      'α sets the level, ρ tilts the skew, ν controls curvature. '
                      'Recalibrate each expiry separately — α changes with term.',
                      heading: 'Calibration'),
                ],
              ),
            ),
          )),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextFormField(
            controller: _rhoCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            decoration: const InputDecoration(labelText: 'Rho (ρ)',
                helperText: 'Spot-vol corr, typically −0.7'),
          )),
          const SizedBox(width: 12),
          Expanded(child: TextFormField(
            controller: _nuCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Nu (ν)',
                helperText: 'Vol-of-vol, typically 0.40'),
          )),
        ]),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppTheme.elevatedColor,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const Text('Beta (β) — fixed',
                style: TextStyle(color: AppTheme.neutralColor, fontSize: 13)),
            Text('${_beta.toStringAsFixed(1)}  (equity square-root CEV)',
                style: const TextStyle(color: Colors.white, fontSize: 13)),
          ]),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _loading ? null : _calculate,
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.profitColor,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14)),
            child: _loading
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                : const Text('Calculate SABR Vol',
                    style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ),
        // ── Results ──
        if (_sabrVol != null) ...[
          const SizedBox(height: 24),
          Divider(color: AppTheme.borderColor),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppTheme.profitColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.profitColor.withValues(alpha: 0.3)),
            ),
            child: Column(children: [
              const Text('SABR Implied Vol', style: TextStyle(color: AppTheme.neutralColor)),
              const SizedBox(height: 8),
              Text('${(_sabrVol! * 100).toStringAsFixed(2)}%',
                  style: const TextStyle(color: AppTheme.profitColor,
                      fontWeight: FontWeight.w900, fontSize: 36)),
              const SizedBox(height: 4),
              Text('(${_sabrVol!.toStringAsFixed(4)} decimal)',
                  style: const TextStyle(color: AppTheme.neutralColor, fontSize: 12)),
            ]),
          ),
          const SizedBox(height: 8),
          Text(
            _sabrVol! > 0.5
                ? 'High IV — this strike is deep OTM or the surface is elevated.'
                : _sabrVol! < 0.10
                    ? 'Low IV — near-ATM short-dated or very low vol environment.'
                    : 'Normal range.',
            style: const TextStyle(color: AppTheme.neutralColor, fontSize: 13),
          ),
        ],
        const SizedBox(height: 24),
        // ── Formula Panel ──
        const _FormulaPanel(
          title: 'About SABR',
          lines: [
            _FormulaLine(
              'SABR = Stochastic Alpha Beta Rho\n\n'
              'dF = α · Fᵝ · dW₁\n'
              'dα = ν · α · dW₂\n'
              'Corr(dW₁, dW₂) = ρ\n\n'
              'The Hagan et al. (2002) approximation gives a closed-form IV:\n'
              'σ_SABR(F, K) ≈ [α·z/χ(z)] · [1 + correction terms]',
              heading: 'Formula',
            ),
            _FormulaLine(
              'α (alpha): controls the overall level of implied volatility. '
              'At-the-money, α ≈ ATM IV. Increase α → entire smile shifts up.\n\n'
              'β (beta): CEV exponent controlling backbone shape. β=0 is normal model '
              '(absolute vol), β=1 is lognormal (Black-Scholes backbone), β=0.5 '
              'is square-root (equity standard). Fixed here at 0.5.\n\n'
              'ρ (rho): spot-vol correlation. Negative ρ creates put skew '
              '(lower strikes have higher IV). Equity typically ρ ≈ −0.5 to −0.8.\n\n'
              'ν (nu): vol-of-vol. Controls smile curvature — higher ν = '
              'more pronounced smile (both wings up). Typical range 0.20–0.80.',
              heading: 'Parameters explained',
            ),
            _FormulaLine(
              'Use SABR when you need a strike-consistent IV for pricing or hedging '
              'across the vol surface. Unlike BS (flat vol), SABR naturally reproduces '
              'the vol smile. Calibrate α, ρ, ν to market quotes for a given expiry.',
              heading: 'When to use',
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

// =============================================================================
// Tab 5 — Heston
// =============================================================================
class _HestonTab extends StatefulWidget {
  const _HestonTab({this.initialRate});
  final double? initialRate;

  @override
  State<_HestonTab> createState() => _HestonTabState();
}

class _HestonTabState extends State<_HestonTab> {
  final _spotCtrl   = TextEditingController(text: '100');
  final _strikeCtrl = TextEditingController(text: '100');
  final _dteCtrl    = TextEditingController(text: '30');
  final _rCtrl      = TextEditingController(text: '4.33');
  final _kappaCtrl  = TextEditingController(text: '2.0');
  final _thetaCtrl  = TextEditingController(text: '0.04');
  final _xiCtrl     = TextEditingController(text: '0.50');
  final _rhoCtrl    = TextEditingController(text: '-0.70');
  final _v0Ctrl     = TextEditingController(text: '0.04');
  bool _isCall = true;

  @override
  void didUpdateWidget(covariant _HestonTab old) {
    super.didUpdateWidget(old);
    if (widget.initialRate != null && old.initialRate == null) {
      _rCtrl.text = widget.initialRate!.toStringAsFixed(2);
    }
  }

  bool _loading = false;
  Map<String, dynamic>? _result;

  Future<void> _calculate() async {
    final spot   = double.tryParse(_spotCtrl.text);
    final strike = double.tryParse(_strikeCtrl.text);
    final dte    = int.tryParse(_dteCtrl.text);
    final r      = double.tryParse(_rCtrl.text);
    final kappa  = double.tryParse(_kappaCtrl.text);
    final theta  = double.tryParse(_thetaCtrl.text);
    final xi     = double.tryParse(_xiCtrl.text);
    final rho    = double.tryParse(_rhoCtrl.text);
    final v0     = double.tryParse(_v0Ctrl.text);
    if (spot == null || strike == null || dte == null || r == null ||
        kappa == null || theta == null || xi == null || rho == null || v0 == null) {
      return;
    }
    setState(() => _loading = true);
    try {
      final res = await PythonApiClient.hestonPrice(
        spot: spot, strike: strike, daysToExpiry: dte,
        r: r / 100, isCall: _isCall,
        kappa: kappa, theta: theta, xi: xi, rho: rho, v0: v0,
      );
      if (!mounted) return;
      setState(() => _result = res);
    } on PythonApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('API error: ${e.message}'),
              backgroundColor: AppTheme.lossColor),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _spotCtrl.dispose(); _strikeCtrl.dispose(); _dteCtrl.dispose();
    _rCtrl.dispose(); _kappaCtrl.dispose(); _thetaCtrl.dispose();
    _xiCtrl.dispose(); _rhoCtrl.dispose(); _v0Ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Heston prices options under stochastic volatility — '
            'variance itself follows a mean-reverting process.',
            style: TextStyle(color: AppTheme.neutralColor)),
        const SizedBox(height: 20),
        // ── Option inputs ──
        const Text('Option', style: TextStyle(color: Colors.white,
            fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: TextFormField(
            controller: _spotCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Spot (S)', prefixText: '\$'),
          )),
          const SizedBox(width: 12),
          Expanded(child: TextFormField(
            controller: _strikeCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Strike (K)', prefixText: '\$'),
          )),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextFormField(
            controller: _dteCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Days to Expiry'),
          )),
          const SizedBox(width: 12),
          Expanded(child: TextFormField(
            controller: _rCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: 'Rate (r)', suffixText: '%', helperText: 'SOFR ${(widget.initialRate ?? 4.33).toStringAsFixed(2)}%'),
          )),
        ]),
        const SizedBox(height: 12),
        _OptionTypeToggle(isCall: _isCall, onChanged: (v) => setState(() { _isCall = v; _result = null; })),
        const SizedBox(height: 20),
        // ── Heston params ──
        const Text('Heston Parameters', style: TextStyle(color: Colors.white,
            fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: TextFormField(
            controller: _kappaCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Kappa (κ)',
              helperText: 'Mean reversion speed',
              suffixIcon: _InfoButton(
                title: 'Estimating Kappa (κ)',
                lines: [
                  _FormulaLine('κ = mean-reversion speed of variance. '
                      'Half-life of a vol shock = ln(2) / κ years.\n'
                      'κ = 2 → ~4-month half-life.  κ = 4 → ~2-month half-life.',
                      heading: 'What it controls'),
                  _FormulaLine('1. Collect daily realized variance (σ²) for 1–2 years.\n'
                      '2. Fit AR(1): σ²_t = a + b·σ²_{t-1}.\n'
                      '3. κ ≈ −252 · ln(b).\n\n'
                      'Example: b = 0.992 → κ ≈ −252 · ln(0.992) ≈ 2.0',
                      heading: 'From historical variance'),
                  _FormulaLine('κ is most accurately estimated from the vol surface '
                      'term structure — the shape of ATM IV across maturities encodes '
                      'how fast vol mean-reverts under the risk-neutral measure. '
                      'Typical calibrated equity range: 1–5.',
                      heading: 'From the vol surface'),
                ],
              ),
            ),
          )),
          const SizedBox(width: 12),
          Expanded(child: TextFormField(
            controller: _thetaCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Theta (θ)',
                helperText: 'Long-run variance'),
          )),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextFormField(
            controller: _xiCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Xi (ξ)',
              helperText: 'Vol-of-vol',
              suffixIcon: _InfoButton(
                title: 'Estimating Vol-of-Vol (ξ)',
                lines: [
                  _FormulaLine('ξ measures how much the variance process fluctuates. '
                      'Higher ξ = fatter vol smile wings. Typical equity range: 0.3–0.8.',
                      heading: 'What it controls'),
                  _FormulaLine('1. Collect daily ATM IV for ≥ 1 year.\n'
                      '2. Compute daily changes: Δσ_i = σ_i − σ_{i-1}.\n'
                      '3. ξ ≈ std(Δσ) × √252  (annualised vol-of-vol).\n\n'
                      'Example: daily IV moves avg 0.8% → ξ ≈ 0.008 × √252 ≈ 0.13.\n'
                      'Note: calibrated ξ is often 2–5× the historical estimate '
                      'because options embed a vol-of-vol risk premium.',
                      heading: 'From historical IV moves'),
                  _FormulaLine('ξ is most reliably extracted by fitting the Heston '
                      'model to the full vol surface. The wings of the smile '
                      '(deep OTM strikes) are most sensitive to ξ. '
                      'VIX options have ξ ≈ 1.5–3 — equity single-stocks are lower.',
                      heading: 'From the vol surface'),
                ],
              ),
            ),
          )),
          const SizedBox(width: 12),
          Expanded(child: TextFormField(
            controller: _rhoCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            decoration: const InputDecoration(labelText: 'Rho (ρ)',
                helperText: 'Spot-vol correlation'),
          )),
        ]),
        const SizedBox(height: 12),
        TextFormField(
          controller: _v0Ctrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'V₀ — Initial Variance',
              helperText: 'Initial vol = √V₀   e.g. 0.04 → 20% vol'),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _loading ? null : _calculate,
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.profitColor,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14)),
            child: _loading
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                : const Text('Calculate (Heston)',
                    style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ),
        // ── Results ──
        if (_result != null) ...[
          const SizedBox(height: 24),
          Divider(color: AppTheme.borderColor),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.profitColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.profitColor.withValues(alpha: 0.3)),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text('Option Price', style: TextStyle(color: AppTheme.neutralColor,
                  fontWeight: FontWeight.w600)),
              Text('\$${(_result!['price'] as num).toStringAsFixed(4)}',
                  style: const TextStyle(color: AppTheme.profitColor,
                      fontWeight: FontWeight.w900, fontSize: 22)),
            ]),
          ),
          const SizedBox(height: 8),
          _ResultRow(
            label: 'Forward price',
            value: '\$${(_result!['forward'] as num).toStringAsFixed(4)}',
            color: Colors.white,
          ),
          _ResultRow(
            label: 'Initial vol (√V₀)',
            value: '${((_result!['initial_vol'] as num) * 100).toStringAsFixed(1)}%',
            color: Colors.white,
          ),
          _ResultRow(
            label: 'Long-run vol (√θ)',
            value: '${((_result!['long_run_vol'] as num) * 100).toStringAsFixed(1)}%',
            color: Colors.white,
          ),
          _FellerBadge(satisfied: _result!['feller_satisfied'] as bool),
        ],
        const SizedBox(height: 24),
        // ── Formula Panel ──
        const _FormulaPanel(
          title: 'About Heston (1993)',
          lines: [
            _FormulaLine(
              'dS/S  = r dt + √V · dW₁\n'
              'dV    = κ(θ − V) dt + ξ√V · dW₂\n'
              'Corr(dW₁, dW₂) = ρ\n\n'
              'Price via Gil-Pelaez Fourier inversion:\n'
              'C = e^{−rT}(F·P₁ − K·P₂)\n'
              'Pⱼ = ½ + (1/π)∫₀^∞ Re[e^{−iuk} φⱼ(u)/(iu)] du',
              heading: 'Model & formula',
            ),
            _FormulaLine(
              'κ (kappa): mean reversion speed. Higher κ → variance snaps back '
              'to θ faster. Typical calibrated values: 1–5.\n\n'
              'θ (theta): long-run variance. Long-run volatility = √θ. '
              'E.g. θ=0.04 → 20% long-run vol.\n\n'
              'ξ (xi): vol-of-vol. How much variance fluctuates. Higher ξ → '
              'fatter wings in the vol surface. Typical: 0.3–0.8.\n\n'
              'ρ (rho): spot-vol correlation. Negative ρ produces put skew '
              '(leverage effect). Equity typically −0.5 to −0.8.\n\n'
              'V₀: initial variance. Current implied vol = √V₀. '
              'Should match near-term ATM IV.',
              heading: 'Parameters explained',
            ),
            _FormulaLine(
              'Feller condition: 2κθ ≥ ξ²\n'
              'When satisfied, variance V stays strictly positive (never hits zero). '
              'Violated parameters can produce negative variance — a warning sign '
              'that your calibration may be unstable.',
              heading: 'Feller condition',
            ),
            _FormulaLine(
              'Use Heston when you need a stochastic vol model that can replicate '
              'the full vol surface (smile + skew + term structure). Unlike BS, '
              'the vol itself evolves randomly. More expensive to calibrate than SABR '
              'but provides richer dynamics for exotic option pricing.',
              heading: 'When to use',
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

// =============================================================================
// Shared small widgets
// =============================================================================

class _OptionTypeToggle extends StatelessWidget {
  final bool isCall;
  final ValueChanged<bool> onChanged;
  const _OptionTypeToggle({required this.isCall, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.elevatedColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.borderColor.withValues(alpha: 0.5)),
      ),
      child: Row(children: [
        Expanded(child: InkWell(
          onTap: () => onChanged(true),
          borderRadius: const BorderRadius.horizontal(left: Radius.circular(7)),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: isCall ? AppTheme.profitColor.withValues(alpha: 0.2) : Colors.transparent,
              borderRadius: const BorderRadius.horizontal(left: Radius.circular(7)),
            ),
            child: Center(child: Text('Call',
                style: TextStyle(
                    color: isCall ? AppTheme.profitColor : AppTheme.neutralColor,
                    fontWeight: FontWeight.w700))),
          ),
        )),
        Expanded(child: InkWell(
          onTap: () => onChanged(false),
          borderRadius: const BorderRadius.horizontal(right: Radius.circular(7)),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: !isCall ? AppTheme.lossColor.withValues(alpha: 0.2) : Colors.transparent,
              borderRadius: const BorderRadius.horizontal(right: Radius.circular(7)),
            ),
            child: Center(child: Text('Put',
                style: TextStyle(
                    color: !isCall ? AppTheme.lossColor : AppTheme.neutralColor,
                    fontWeight: FontWeight.w700))),
          ),
        )),
      ]),
    );
  }
}

class _FellerBadge extends StatelessWidget {
  final bool satisfied;
  const _FellerBadge({required this.satisfied});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const Text('Feller condition (2κθ ≥ ξ²)',
            style: TextStyle(color: AppTheme.neutralColor)),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: satisfied
                ? AppTheme.profitColor.withValues(alpha: 0.15)
                : AppTheme.lossColor.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: satisfied
                  ? AppTheme.profitColor.withValues(alpha: 0.4)
                  : AppTheme.lossColor.withValues(alpha: 0.4),
            ),
          ),
          child: Text(
            satisfied ? 'Satisfied' : 'Violated',
            style: TextStyle(
              color: satisfied ? AppTheme.profitColor : AppTheme.lossColor,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ),
      ]),
    );
  }
}

// =============================================================================
// Tab 6 — Forward Price
// =============================================================================
class _ForwardPriceTab extends StatefulWidget {
  const _ForwardPriceTab({this.initialRate});
  final double? initialRate;
  @override
  State<_ForwardPriceTab> createState() => _ForwardPriceTabState();
}

class _ForwardPriceTabState extends State<_ForwardPriceTab> {
  final _spotCtrl = TextEditingController(text: '100');
  final _rCtrl    = TextEditingController(text: '4.33');
  final _qCtrl    = TextEditingController(text: '0');
  final _dteCtrl  = TextEditingController(text: '30');

  @override
  void didUpdateWidget(covariant _ForwardPriceTab old) {
    super.didUpdateWidget(old);
    if (widget.initialRate != null && old.initialRate == null) {
      _rCtrl.text = widget.initialRate!.toStringAsFixed(2);
    }
  }

  double? get _spot => double.tryParse(_spotCtrl.text);
  double? get _r    => double.tryParse(_rCtrl.text);
  double? get _q    => double.tryParse(_qCtrl.text);
  double? get _dte  => double.tryParse(_dteCtrl.text);

  double? get _timeYears => _dte != null ? _dte! / 365.0 : null;

  double? get _forward {
    if (_spot == null || _r == null || _q == null || _timeYears == null) return null;
    return _spot! * exp((_r! / 100 - _q! / 100) * _timeYears!);
  }

  double? get _costOfCarry => (_forward != null) ? _forward! - _spot! : null;

  @override
  void dispose() {
    _spotCtrl.dispose(); _rCtrl.dispose(); _qCtrl.dispose(); _dteCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fwd = _forward;
    final coc = _costOfCarry;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'The forward price is the fair delivery price of an asset at expiry, '
          'used to compute option strike moneyness and put-call parity.',
          style: TextStyle(color: AppTheme.neutralColor),
        ),
        const SizedBox(height: 20),
        Row(children: [
          Expanded(child: TextFormField(
            controller: _spotCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Spot (S)', prefixText: '\$'),
            onChanged: (_) => setState(() {}),
          )),
          const SizedBox(width: 12),
          Expanded(child: TextFormField(
            controller: _dteCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Days (T)', helperText: 'Calendar days'),
            onChanged: (_) => setState(() {}),
          )),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextFormField(
            controller: _rCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                labelText: 'Risk-free Rate (r)', suffixText: '%', helperText: 'SOFR ${(widget.initialRate ?? 4.33).toStringAsFixed(2)}%'),
            onChanged: (_) => setState(() {}),
          )),
          const SizedBox(width: 12),
          Expanded(child: TextFormField(
            controller: _qCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
                labelText: 'Dividend Yield (q)', suffixText: '%', helperText: '0 for no dividend'),
            onChanged: (_) => setState(() {}),
          )),
        ]),
        if (fwd != null) ...[
          const SizedBox(height: 24),
          Divider(color: AppTheme.borderColor),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.profitColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.profitColor.withValues(alpha: 0.3)),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text('Forward Price (F)',
                  style: TextStyle(color: AppTheme.neutralColor, fontWeight: FontWeight.w600)),
              Text('\$${fwd.toStringAsFixed(4)}',
                  style: const TextStyle(
                      color: AppTheme.profitColor, fontWeight: FontWeight.w900, fontSize: 22)),
            ]),
          ),
          const SizedBox(height: 8),
          if (coc != null)
            _ResultRow(
              label: 'Cost of Carry (F − S)',
              value: '${coc >= 0 ? '+' : ''}\$${coc.toStringAsFixed(4)}',
              color: coc >= 0 ? AppTheme.profitColor : AppTheme.lossColor,
            ),
          if (_timeYears != null && _timeYears! > 0 && coc != null)
            _ResultRow(
              label: 'Annualised carry',
              value: '${((coc / _spot!) * (1 / _timeYears!) * 100).toStringAsFixed(2)}%',
              color: Colors.white,
            ),
          const SizedBox(height: 8),
          Text(
            fwd > _spot!
                ? 'F > S — positive carry: the risk-free return outweighs dividends.'
                : fwd < _spot!
                    ? 'F < S — negative carry: dividend yield exceeds the risk-free rate.'
                    : 'F = S — zero carry: rate equals dividend yield.',
            style: const TextStyle(color: AppTheme.neutralColor, fontSize: 13),
          ),
        ],
        const SizedBox(height: 24),
        const _FormulaPanel(
          title: 'About Forward Price',
          lines: [
            _FormulaLine('F = S · e^{(r − q)T}\n\n'
                'r = risk-free rate, q = continuous dividend yield, '
                'T = time in years', heading: 'Formula'),
            _FormulaLine(
              'The forward price is the spot price grown at the net cost of carry '
              '(r − q). It is NOT a forecast — it is an arbitrage-free price '
              'derived from the cost of replicating ownership until expiry.\n\n'
              'If F > market forward, buy spot and sell futures (cash-and-carry arb).\n'
              'If F < market forward, sell spot and buy futures (reverse carry arb).',
              heading: 'Why it matters',
            ),
            _FormulaLine(
              'Put-Call Parity (European options):\n'
              'C − P = e^{−rT}(F − K)\n\n'
              'At-the-money forward (ATMF) is where K = F. '
              'SABR and Heston use F, not S, as the "at-the-money" reference — '
              'so strike selection relative to F matters more than relative to S.',
              heading: 'Put-call parity & ATMF',
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

// =============================================================================
// Tab 7 — Theoretical Price (Fair Value)
// =============================================================================
class _TheoreticalPriceTab extends StatefulWidget {
  const _TheoreticalPriceTab({this.initialRate});
  final double? initialRate;
  @override
  State<_TheoreticalPriceTab> createState() => _TheoreticalPriceTabState();
}

class _TheoreticalPriceTabState extends State<_TheoreticalPriceTab> {
  final _spotCtrl   = TextEditingController(text: '100');
  final _strikeCtrl = TextEditingController(text: '100');
  final _dteCtrl    = TextEditingController(text: '30');
  final _ivCtrl     = TextEditingController(text: '20');
  final _midCtrl    = TextEditingController(text: '2.50');
  final _rCtrl      = TextEditingController(text: '4.33');
  bool _isCall = true;

  @override
  void didUpdateWidget(covariant _TheoreticalPriceTab old) {
    super.didUpdateWidget(old);
    if (widget.initialRate != null && old.initialRate == null) {
      _rCtrl.text = widget.initialRate!.toStringAsFixed(2);
    }
  }

  bool _loading = false;
  Map<String, dynamic>? _result;

  Future<void> _calculate() async {
    final spot   = double.tryParse(_spotCtrl.text);
    final strike = double.tryParse(_strikeCtrl.text);
    final dte    = int.tryParse(_dteCtrl.text);
    final iv     = double.tryParse(_ivCtrl.text);
    final mid    = double.tryParse(_midCtrl.text);
    final r      = double.tryParse(_rCtrl.text);
    if (spot == null || strike == null || dte == null ||
        iv == null || mid == null || r == null) { return; }
    setState(() => _loading = true);
    try {
      final res = await PythonApiClient.fairValueCompute(
        spot: spot,
        strike: strike,
        impliedVol: iv / 100,
        daysToExpiry: dte,
        isCall: _isCall,
        brokerMid: mid,
        r: r / 100,
      );
      if (!mounted) return;
      setState(() => _result = res);
    } on PythonApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('API error: ${e.message}'),
              backgroundColor: AppTheme.lossColor),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _spotCtrl.dispose(); _strikeCtrl.dispose(); _dteCtrl.dispose();
    _ivCtrl.dispose(); _midCtrl.dispose(); _rCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final res = _result;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Compare theoretical model prices against a broker mid quote '
          'to find edge — how much the market is over- or under-pricing the option.',
          style: TextStyle(color: AppTheme.neutralColor),
        ),
        const SizedBox(height: 20),
        Row(children: [
          Expanded(child: TextFormField(
            controller: _spotCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Spot (S)', prefixText: '\$'),
          )),
          const SizedBox(width: 12),
          Expanded(child: TextFormField(
            controller: _strikeCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Strike (K)', prefixText: '\$'),
          )),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextFormField(
            controller: _dteCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Days to Expiry'),
          )),
          const SizedBox(width: 12),
          Expanded(child: TextFormField(
            controller: _ivCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
                labelText: 'Implied Vol (σ)', suffixText: '%'),
          )),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextFormField(
            controller: _midCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
                labelText: 'Broker Mid', prefixText: '\$',
                helperText: 'Market mid price'),
          )),
          const SizedBox(width: 12),
          Expanded(child: TextFormField(
            controller: _rCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                labelText: 'Risk-free Rate', suffixText: '%', helperText: 'SOFR ${(widget.initialRate ?? 4.33).toStringAsFixed(2)}%'),
          )),
        ]),
        const SizedBox(height: 12),
        _OptionTypeToggle(isCall: _isCall, onChanged: (v) => setState(() { _isCall = v; _result = null; })),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _loading ? null : _calculate,
            style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.profitColor,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14)),
            child: _loading
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                : const Text('Calculate Theoretical Price',
                    style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ),
        if (res != null) ...[
          const SizedBox(height: 24),
          Divider(color: AppTheme.borderColor),
          const SizedBox(height: 12),
          // Edge badge
          _EdgeBadge(
            brokerMid: (res['broker_mid'] as num).toDouble(),
            modelFairValue: (res['model_fair_value'] as num).toDouble(),
            edgeBps: (res['edge_bps'] as num).toDouble(),
          ),
          const SizedBox(height: 16),
          const Text('Model Prices',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
          const SizedBox(height: 8),
          _ResultRow(
            label: 'BS Fair Value',
            value: '\$${(res['bs_fair_value'] as num).toStringAsFixed(4)}',
            color: Colors.white,
          ),
          _ResultRow(
            label: 'SABR Fair Value',
            value: '\$${(res['sabr_fair_value'] as num).toStringAsFixed(4)}',
            color: Colors.white,
          ),
          if (res['heston_fair_value'] != null)
            _ResultRow(
              label: 'Heston Fair Value',
              value: '\$${(res['heston_fair_value'] as num).toStringAsFixed(4)}',
              color: Colors.white,
            ),
          _ResultRow(
            label: 'Model Fair Value (blended)',
            value: '\$${(res['model_fair_value'] as num).toStringAsFixed(4)}',
            color: AppTheme.profitColor,
          ),
          const SizedBox(height: 16),
          const Text('Vol Check',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
          const SizedBox(height: 8),
          _ResultRow(
            label: 'Input IV',
            value: '${((res['implied_vol'] as num) * 100).toStringAsFixed(2)}%',
            color: Colors.white,
          ),
          _ResultRow(
            label: 'SABR Vol (at this strike)',
            value: '${((res['sabr_vol'] as num) * 100).toStringAsFixed(2)}%',
            color: Colors.white,
          ),
          if (res['computed_iv'] != null)
            _ResultRow(
              label: 'Back-solved IV (from mid)',
              value: '${((res['computed_iv'] as num) * 100).toStringAsFixed(2)}%',
              color: Colors.white,
            ),
          if (res['iv_note'] != null && (res['iv_note'] as String).isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(res['iv_note'] as String,
                  style: const TextStyle(color: AppTheme.neutralColor, fontSize: 13)),
            ),
        ],
        const SizedBox(height: 24),
        const _FormulaPanel(
          title: 'About Theoretical / Fair Value',
          lines: [
            _FormulaLine(
              'Model Fair Value = weighted average of BS, SABR, and (when available) '
              'Heston prices. Edge = Broker Mid − Model Fair Value.\n\n'
              'Positive edge (bps > 0): market is pricing the option above theoretical — '
              'you are selling at a premium, or paying up to buy.\n'
              'Negative edge (bps < 0): market prices below theoretical — '
              'potential mispricing in your favour as a buyer.',
              heading: 'Edge (basis points)',
            ),
            _FormulaLine(
              'BS is a single-vol model — it uses your input IV flat across all strikes. '
              'SABR adjusts for the vol smile at this specific strike. '
              'Heston incorporates stochastic vol dynamics from the calibrated surface. '
              'The blended model price reflects all three, weighted by availability.',
              heading: 'Why three models?',
            ),
            _FormulaLine(
              'Back-solved IV is the implied volatility derived from the broker mid '
              'price via Newton-Raphson inversion of the BS formula. '
              'Comparing it to your input IV reveals how the market is pricing '
              'this option relative to your vol assumption.',
              heading: 'Back-solved IV',
            ),
            _FormulaLine(
              'Edge alone does not mean a trade is good. '
              'Also consider: bid-ask spread (is edge > half spread?), '
              'liquidity risk, directional risk, and whether your IV input '
              'reflects the true market IV.',
              heading: 'Caveats',
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _EdgeBadge extends StatelessWidget {
  final double brokerMid;
  final double modelFairValue;
  final double edgeBps;
  const _EdgeBadge(
      {required this.brokerMid,
      required this.modelFairValue,
      required this.edgeBps});

  @override
  Widget build(BuildContext context) {
    final positive = edgeBps >= 0;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: positive
            ? AppTheme.profitColor.withValues(alpha: 0.08)
            : AppTheme.lossColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: positive
              ? AppTheme.profitColor.withValues(alpha: 0.3)
              : AppTheme.lossColor.withValues(alpha: 0.3),
        ),
      ),
      child: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('Broker Mid',
              style: TextStyle(color: AppTheme.neutralColor)),
          Text('\$${brokerMid.toStringAsFixed(4)}',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 6),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('Model Fair Value',
              style: TextStyle(color: AppTheme.neutralColor)),
          Text('\$${modelFairValue.toStringAsFixed(4)}',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        ]),
        const Divider(height: 20),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('Edge',
              style: TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
          Text(
            '${positive ? '+' : ''}${edgeBps.toStringAsFixed(1)} bps',
            style: TextStyle(
              color: positive ? AppTheme.profitColor : AppTheme.lossColor,
              fontWeight: FontWeight.w900,
              fontSize: 22,
            ),
          ),
        ]),
        const SizedBox(height: 6),
        Text(
          positive
              ? 'Market is above theoretical — selling edge.'
              : 'Market is below theoretical — buying edge.',
          style: TextStyle(
            color: positive ? AppTheme.profitColor : AppTheme.lossColor,
            fontSize: 12,
          ),
        ),
      ]),
    );
  }
}

// =============================================================================
// Tab 8 — Intrinsic Value
// =============================================================================
class _IntrinsicValueTab extends StatefulWidget {
  const _IntrinsicValueTab();
  @override
  State<_IntrinsicValueTab> createState() => _IntrinsicValueTabState();
}

class _IntrinsicValueTabState extends State<_IntrinsicValueTab> {
  final _spotCtrl    = TextEditingController(text: '105');
  final _strikeCtrl  = TextEditingController(text: '100');
  final _premiumCtrl = TextEditingController(text: '6.50');
  bool _isCall = true;

  double? get _spot    => double.tryParse(_spotCtrl.text);
  double? get _strike  => double.tryParse(_strikeCtrl.text);
  double? get _premium => double.tryParse(_premiumCtrl.text);

  double? get _intrinsic {
    if (_spot == null || _strike == null) return null;
    return _isCall
        ? max(0, _spot! - _strike!)
        : max(0, _strike! - _spot!);
  }

  double? get _timeValue {
    if (_intrinsic == null || _premium == null) return null;
    return max(0, _premium! - _intrinsic!);
  }

  double? get _timeValuePct {
    if (_timeValue == null || _premium == null || _premium == 0) return null;
    return (_timeValue! / _premium!) * 100;
  }

  String get _moneyness {
    if (_spot == null || _strike == null) return '—';
    final diff = _isCall ? _spot! - _strike! : _strike! - _spot!;
    final pct = diff / _strike! * 100;
    if (pct.abs() < 1) return 'ATM (within 1%)';
    if (pct > 0) return 'ITM ${pct.abs().toStringAsFixed(1)}%';
    return 'OTM ${pct.abs().toStringAsFixed(1)}%';
  }

  bool get _isItm => _intrinsic != null && _intrinsic! > 0;

  @override
  void dispose() {
    _spotCtrl.dispose(); _strikeCtrl.dispose(); _premiumCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final iv = _intrinsic;
    final tv = _timeValue;
    final tvPct = _timeValuePct;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Breaks down an option premium into intrinsic value '
          '(real, immediate worth) and time value (what you pay for optionality).',
          style: TextStyle(color: AppTheme.neutralColor),
        ),
        const SizedBox(height: 20),
        Row(children: [
          Expanded(child: TextFormField(
            controller: _spotCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
                labelText: 'Spot (S)', prefixText: '\$', helperText: 'Current price'),
            onChanged: (_) => setState(() {}),
          )),
          const SizedBox(width: 12),
          Expanded(child: TextFormField(
            controller: _strikeCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
                labelText: 'Strike (K)', prefixText: '\$'),
            onChanged: (_) => setState(() {}),
          )),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextFormField(
            controller: _premiumCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
                labelText: 'Option Premium', prefixText: '\$',
                helperText: 'Market price of option'),
            onChanged: (_) => setState(() {}),
          )),
          const SizedBox(width: 12),
          Expanded(child: _OptionTypeToggle(
            isCall: _isCall,
            onChanged: (v) => setState(() => _isCall = v),
          )),
        ]),
        if (iv != null && tv != null) ...[
          const SizedBox(height: 24),
          Divider(color: AppTheme.borderColor),
          const SizedBox(height: 12),
          // Moneyness badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: _isItm
                  ? AppTheme.profitColor.withValues(alpha: 0.12)
                  : AppTheme.neutralColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _isItm
                    ? AppTheme.profitColor.withValues(alpha: 0.35)
                    : AppTheme.neutralColor.withValues(alpha: 0.35),
              ),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text('Moneyness',
                  style: TextStyle(color: AppTheme.neutralColor)),
              Text(_moneyness,
                  style: TextStyle(
                      color: _isItm ? AppTheme.profitColor : AppTheme.neutralColor,
                      fontWeight: FontWeight.w700)),
            ]),
          ),
          const SizedBox(height: 16),
          // Breakdown bar
          if (_premium != null && _premium! > 0) ...[
            _ValueBreakdownBar(
              intrinsicFraction: iv / _premium!,
              intrinsicLabel: '\$${iv.toStringAsFixed(2)}',
              timeLabel: '\$${tv.toStringAsFixed(2)}',
            ),
            const SizedBox(height: 16),
          ],
          _ResultRow(
            label: 'Intrinsic Value',
            value: '\$${iv.toStringAsFixed(4)}',
            color: _isItm ? AppTheme.profitColor : AppTheme.neutralColor,
          ),
          _ResultRow(
            label: 'Time Value (extrinsic)',
            value: '\$${tv.toStringAsFixed(4)}',
            color: Colors.white,
          ),
          if (tvPct != null)
            _ResultRow(
              label: '% of premium that is time value',
              value: '${tvPct.toStringAsFixed(1)}%',
              color: Colors.white,
            ),
          if (_premium != null && iv > _premium!)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Premium < intrinsic value — possible data error or wide spread.',
                style: const TextStyle(color: AppTheme.lossColor, fontSize: 13),
              ),
            ),
        ],
        const SizedBox(height: 24),
        const _FormulaPanel(
          title: 'About Intrinsic & Time Value',
          lines: [
            _FormulaLine(
              'Intrinsic = max(S − K, 0)  for calls\n'
              'Intrinsic = max(K − S, 0)  for puts\n\n'
              'Time Value = Premium − Intrinsic Value\n'
              '(also called extrinsic value)',
              heading: 'Formula',
            ),
            _FormulaLine(
              'Intrinsic value is the amount an option is in-the-money right now — '
              'what you could profit by exercising immediately. '
              'An OTM option has zero intrinsic value.\n\n'
              'Time value is everything else in the premium: '
              'the market\'s price for the probability that the option goes deeper ITM '
              'before expiry. It decays to zero at expiration (theta decay).',
              heading: 'What each component means',
            ),
            _FormulaLine(
              'Deep ITM options: mostly intrinsic, little time value. '
              'They move almost 1-for-1 with spot (high delta).\n\n'
              'ATM options: mostly time value. '
              'Maximum theta decay and highest sensitivity to IV changes (high vega).\n\n'
              'Deep OTM options: 100% time value (lottery tickets). '
              'High leverage but most likely to expire worthless.',
              heading: 'ITM / ATM / OTM profile',
            ),
            _FormulaLine(
              'When selling options (covered calls, cash-secured puts, spreads), '
              'you collect time value as premium income. '
              'The goal is for time value to decay before expiry. '
              'IV crush after earnings is a rapid collapse in time value.',
              heading: 'Trading implication',
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _ValueBreakdownBar extends StatelessWidget {
  final double intrinsicFraction;
  final String intrinsicLabel;
  final String timeLabel;
  const _ValueBreakdownBar(
      {required this.intrinsicFraction,
      required this.intrinsicLabel,
      required this.timeLabel});

  @override
  Widget build(BuildContext context) {
    final frac = intrinsicFraction.clamp(0.0, 1.0);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 22,
              child: Row(children: [
                if (frac > 0)
                  Expanded(
                    flex: (frac * 1000).round(),
                    child: Container(
                      color: AppTheme.profitColor.withValues(alpha: 0.7),
                      alignment: Alignment.center,
                      child: frac > 0.15
                          ? Text(intrinsicLabel,
                              style: const TextStyle(
                                  fontSize: 11, fontWeight: FontWeight.w700, color: Colors.black))
                          : null,
                    ),
                  ),
                Expanded(
                  flex: ((1 - frac) * 1000).round().clamp(1, 1000),
                  child: Container(
                    color: AppTheme.cardColor,
                    alignment: Alignment.center,
                    child: (1 - frac) > 0.15
                        ? Text(timeLabel,
                            style: const TextStyle(
                                fontSize: 11, fontWeight: FontWeight.w700,
                                color: AppTheme.neutralColor))
                        : null,
                  ),
                ),
              ]),
            ),
          ),
        ),
      ]),
      const SizedBox(height: 6),
      Row(children: [
        _LegendDot(color: AppTheme.profitColor.withValues(alpha: 0.7),
            label: 'Intrinsic'),
        const SizedBox(width: 16),
        _LegendDot(color: AppTheme.cardColor, label: 'Time Value'),
      ]),
    ]);
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Container(width: 10, height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 6),
      Text(label, style: const TextStyle(color: AppTheme.neutralColor, fontSize: 12)),
    ]);
  }
}

// Small ⓘ button that opens a dialog explaining how to estimate a parameter.
class _InfoButton extends StatelessWidget {
  final String title;
  final List<_FormulaLine> lines;
  const _InfoButton({required this.title, required this.lines});

  void _show(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.elevatedColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(title,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: lines
                .map((l) => Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (l.heading != null)
                            Text(l.heading!,
                                style: const TextStyle(
                                    color: AppTheme.profitColor,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13)),
                          if (l.heading != null) const SizedBox(height: 4),
                          Text(l.body,
                              style: const TextStyle(
                                  color: AppTheme.neutralColor,
                                  fontSize: 13,
                                  height: 1.55)),
                        ],
                      ),
                    ))
                .toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Got it',
                style: TextStyle(color: AppTheme.profitColor, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.info_outline_rounded, size: 18),
      color: AppTheme.neutralColor,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      visualDensity: VisualDensity.compact,
      tooltip: 'How to estimate $title',
      onPressed: () => _show(context),
    );
  }
}

// =============================================================================
// Tab 9 — Implied Volatility Solver
// =============================================================================
class _ImpliedVolTab extends StatefulWidget {
  const _ImpliedVolTab({this.initialRate});
  final double? initialRate;

  @override
  State<_ImpliedVolTab> createState() => _ImpliedVolTabState();
}

class _ImpliedVolTabState extends State<_ImpliedVolTab> {
  final _marketPriceCtrl = TextEditingController(text: '3.50');
  final _spotCtrl        = TextEditingController(text: '100');
  final _strikeCtrl      = TextEditingController(text: '100');
  final _dteCtrl         = TextEditingController(text: '30');
  final _rCtrl           = TextEditingController(text: '4.33');
  bool _isCall = true;

  @override
  void didUpdateWidget(covariant _ImpliedVolTab old) {
    super.didUpdateWidget(old);
    if (widget.initialRate != null && old.initialRate == null) {
      _rCtrl.text = widget.initialRate!.toStringAsFixed(2);
    }
  }

  bool _loading = false;
  Map<String, dynamic>? _result;
  String? _error;

  Future<void> _calculate() async {
    final marketPrice = double.tryParse(_marketPriceCtrl.text);
    final spot        = double.tryParse(_spotCtrl.text);
    final strike      = double.tryParse(_strikeCtrl.text);
    final dte         = int.tryParse(_dteCtrl.text);
    final r           = double.tryParse(_rCtrl.text);
    if (marketPrice == null || spot == null || strike == null ||
        dte == null || r == null) { return; }

    setState(() { _loading = true; _error = null; _result = null; });
    try {
      final res = await PythonApiClient.bsImpliedVol(
        marketPrice: marketPrice,
        s: spot,
        k: strike,
        dte: dte,
        r: r / 100,
        optionType: _isCall ? 'call' : 'put',
      );
      if (!mounted) return;
      setState(() => _result = res);
    } on PythonApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = 'API error (${e.statusCode}): ${e.message}');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _marketPriceCtrl.dispose(); _spotCtrl.dispose(); _strikeCtrl.dispose();
    _dteCtrl.dispose(); _rCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Enter an observed market price to back out the implied volatility '
          'using Newton-Raphson iteration on the Black-Scholes formula.',
          style: TextStyle(color: AppTheme.neutralColor),
        ),
        const SizedBox(height: 20),
        // ── Inputs ──
        Row(children: [
          Expanded(child: TextFormField(
            controller: _spotCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
                labelText: 'Spot (S)', prefixText: '\$', helperText: 'Underlying price'),
          )),
          const SizedBox(width: 12),
          Expanded(child: TextFormField(
            controller: _strikeCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
                labelText: 'Strike (K)', prefixText: '\$'),
          )),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextFormField(
            controller: _dteCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
                labelText: 'Days to Expiry', helperText: 'Calendar days'),
          )),
          const SizedBox(width: 12),
          Expanded(child: TextFormField(
            controller: _rCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                labelText: 'Risk-free Rate', suffixText: '%', helperText: 'SOFR ${(widget.initialRate ?? 4.33).toStringAsFixed(2)}%'),
          )),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextFormField(
            controller: _marketPriceCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
                labelText: 'Market Price', prefixText: '\$',
                helperText: 'Observed option mid-price'),
          )),
          const SizedBox(width: 12),
          Expanded(child: _OptionTypeToggle(
            isCall: _isCall,
            onChanged: (v) => setState(() { _isCall = v; _result = null; _error = null; }),
          )),
        ]),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _loading ? null : _calculate,
            style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.profitColor,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14)),
            child: _loading
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                : const Text('Solve for IV', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ),
        // ── Error ──
        if (_error != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.lossColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.lossColor.withValues(alpha: 0.4)),
            ),
            child: Text(_error!, style: const TextStyle(color: AppTheme.lossColor, fontSize: 13)),
          ),
        ],
        // ── Results ──
        if (_result != null) ...[
          const SizedBox(height: 24),
          Divider(color: AppTheme.borderColor),
          const SizedBox(height: 12),
          // Primary IV result
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppTheme.profitColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.profitColor.withValues(alpha: 0.3)),
            ),
            child: Column(children: [
              const Text('Implied Volatility',
                  style: TextStyle(color: AppTheme.neutralColor, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(
                '${(_result!['implied_vol_pct'] as num).toStringAsFixed(2)}%',
                style: const TextStyle(
                    color: AppTheme.profitColor, fontWeight: FontWeight.w900, fontSize: 36),
              ),
              const SizedBox(height: 4),
              Text(
                'σ = ${(_result!['implied_vol'] as num).toStringAsFixed(6)}',
                style: const TextStyle(color: AppTheme.neutralColor, fontSize: 12),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          _ResultRow(
            label: 'Price check (BS @ IV)',
            value: '\$${(_result!['price_check'] as num).toStringAsFixed(4)}',
            color: Colors.white,
          ),
          _ResultRow(
            label: 'Forward (F = Se^{rT})',
            value: '\$${(_result!['forward'] as num).toStringAsFixed(4)}',
            color: AppTheme.neutralColor,
          ),
          const SizedBox(height: 16),
          const Text('Greeks at solved IV',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
          const SizedBox(height: 8),
          _ivGreekGrid(_result!),
        ],
        const SizedBox(height: 24),
        // ── Formula Panel ──
        const _FormulaPanel(
          title: 'About Implied Volatility',
          lines: [
            _FormulaLine(
              'Given a market price P_mkt, find σ such that:\n'
              '  BS(S, K, T, r, σ) = P_mkt\n\n'
              'Solved iteratively: σ_{n+1} = σ_n − (BS(σ_n) − P_mkt) / Vega(σ_n)',
              heading: 'Newton-Raphson method',
            ),
            _FormulaLine(
              'The solver converges to 1e-7 accuracy in < 10 iterations for '
              'well-behaved inputs. It returns no solution when:\n'
              '  • Price ≤ intrinsic value (deep ITM at expiry)\n'
              '  • Price ≥ discounted forward (arbitrage violation)\n'
              '  • Vega ≈ 0 (extremely deep ITM/OTM or very short DTE)',
              heading: 'Convergence & edge cases',
            ),
            _FormulaLine(
              'IV reflects market consensus on future realized vol. '
              'Compare it to historical realized vol to assess whether options '
              'are rich or cheap. A 30-day IV of 25% implies the market expects '
              'the underlying to move ±25% annualized.',
              heading: 'Interpreting the result',
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _ivGreekGrid(Map<String, dynamic> r) {
    final greeks = [
      ('Delta (Δ)', r['delta'], false),
      ('Gamma (Γ)', r['gamma'], false),
      ('Theta (Θ) /day', r['theta'], true),
      ('Vega (ν) /1%', r['vega'], false),
      ('Rho (ρ) /1%', r['rho'], false),
      ('Vanna', r['vanna'], false),
      ('Charm /day', r['charm'], true),
      ('Vomma', r['vomma'], false),
    ];
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 2.8,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: greeks.map((t) {
        final val = (t.$2 as num).toDouble();
        final color = t.$3
            ? (val < 0 ? AppTheme.lossColor : AppTheme.profitColor)
            : Colors.white;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: AppTheme.elevatedColor,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(t.$1,
                  style: const TextStyle(color: AppTheme.neutralColor, fontSize: 11)),
              Text(val.toStringAsFixed(4),
                  style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 13)),
            ],
          ),
        );
      }).toList(),
    );
  }
}

// =============================================================================
// Tab 10 — Heston κ (Kappa) Calculator
// =============================================================================
class _KappaTab extends StatefulWidget {
  const _KappaTab();
  @override
  State<_KappaTab> createState() => _KappaTabState();
}

class _KappaTabState extends State<_KappaTab> {
  final _kappaCtrl = TextEditingController(text: '2.0');
  final _thetaCtrl = TextEditingController(text: '20');
  final _v0Ctrl    = TextEditingController(text: '20');
  final _xiCtrl    = TextEditingController(text: '0.50');
  final _dteCtrl   = TextEditingController(text: '30');
  Map<String, dynamic>? _result;

  @override
  void dispose() {
    _kappaCtrl.dispose(); _thetaCtrl.dispose(); _v0Ctrl.dispose();
    _xiCtrl.dispose(); _dteCtrl.dispose();
    super.dispose();
  }

  void _calculate() {
    final kappa    = double.tryParse(_kappaCtrl.text);
    final thetaVol = double.tryParse(_thetaCtrl.text);
    final v0Vol    = double.tryParse(_v0Ctrl.text);
    final xi       = double.tryParse(_xiCtrl.text);
    final dte      = int.tryParse(_dteCtrl.text);
    if (kappa == null || kappa <= 0 || thetaVol == null ||
        v0Vol == null || xi == null || dte == null) { return; }

    final theta        = (thetaVol / 100) * (thetaVol / 100);
    final v0           = (v0Vol   / 100) * (v0Vol   / 100);
    final T            = dte / 365.0;
    final halfLifeDays = (log(2) / kappa) * 365;
    final eVarT        = theta + (v0 - theta) * exp(-kappa * T);
    final eVolT        = sqrt(eVarT.clamp(0.0, double.infinity)) * 100;
    final lhs          = 2 * kappa * theta;
    final rhs          = xi * xi;

    setState(() {
      _result = {
        'half_life_days':   halfLifeDays,
        'e_vol_pct':        eVolT,
        'half_lives':       (dte / 365.0) / (log(2) / kappa),
        'feller_satisfied': lhs >= rhs,
        'feller_lhs':       lhs,
        'feller_rhs':       rhs,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: TextFormField(
            controller: _kappaCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'κ (kappa)', helperText: 'Mean reversion speed'),
          )),
          const SizedBox(width: 12),
          Expanded(child: TextFormField(
            controller: _thetaCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'θ — Long-run Vol', suffixText: '%', helperText: 'Long-run variance target'),
          )),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextFormField(
            controller: _v0Ctrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'v₀ — Current Vol', suffixText: '%', helperText: 'Spot variance today'),
          )),
          const SizedBox(width: 12),
          Expanded(child: TextFormField(
            controller: _xiCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'ξ — Vol of Vol', helperText: 'Heston noise term'),
          )),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextFormField(
            controller: _dteCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'DTE', suffixText: 'days'),
          )),
          const Expanded(child: SizedBox()),
        ]),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(onPressed: _calculate, child: const Text('Calculate')),
        ),
        if (r != null) ...[
          const SizedBox(height: 20),
          _ResultRow(
            label: 'Half-life of mean reversion',
            value: '${(r['half_life_days'] as double).toStringAsFixed(1)} days',
            color: AppTheme.neutralColor,
          ),
          _ResultRow(
            label: 'Expected vol at expiry',
            value: '${(r['e_vol_pct'] as double).toStringAsFixed(2)}%',
            color: AppTheme.neutralColor,
          ),
          _ResultRow(
            label: 'Half-lives until expiry',
            value: (r['half_lives'] as double).toStringAsFixed(2),
            color: AppTheme.neutralColor,
          ),
          _ResultRow(
            label: 'Feller  (2κθ ≥ ξ²)',
            value: '${(r['feller_lhs'] as double).toStringAsFixed(4)} vs '
                '${(r['feller_rhs'] as double).toStringAsFixed(4)}  '
                '${(r['feller_satisfied'] as bool) ? '✓ satisfied' : '✗ violated'}',
            color: (r['feller_satisfied'] as bool) ? AppTheme.profitColor : AppTheme.lossColor,
          ),
        ],
      ]),
    );
  }
}

// =============================================================================
// Tab 11 — Vomma / Volga Calculator  (∂²V/∂σ²)
// =============================================================================
class _VommaTab extends StatefulWidget {
  const _VommaTab({this.initialRate});
  final double? initialRate;
  @override
  State<_VommaTab> createState() => _VommaTabState();
}

class _VommaTabState extends State<_VommaTab> {
  final _spotCtrl   = TextEditingController(text: '100');
  final _strikeCtrl = TextEditingController(text: '100');
  final _dteCtrl    = TextEditingController(text: '30');
  final _ivCtrl     = TextEditingController(text: '20');
  final _rCtrl      = TextEditingController(text: '4.33');
  bool _isCall  = true;
  bool _loading = false;
  Map<String, dynamic>? _result;
  String? _error;

  @override
  void didUpdateWidget(covariant _VommaTab old) {
    super.didUpdateWidget(old);
    if (widget.initialRate != null && old.initialRate == null) {
      _rCtrl.text = widget.initialRate!.toStringAsFixed(2);
    }
  }

  @override
  void dispose() {
    _spotCtrl.dispose(); _strikeCtrl.dispose(); _dteCtrl.dispose();
    _ivCtrl.dispose(); _rCtrl.dispose();
    super.dispose();
  }

  Future<void> _calculate() async {
    final spot   = double.tryParse(_spotCtrl.text);
    final strike = double.tryParse(_strikeCtrl.text);
    final dte    = int.tryParse(_dteCtrl.text);
    final iv     = double.tryParse(_ivCtrl.text);
    final r      = double.tryParse(_rCtrl.text);
    if (spot == null || strike == null || dte == null || iv == null || r == null) return;
    setState(() { _loading = true; _error = null; });
    try {
      final res = await PythonApiClient.bsGreeks(
        s: spot, k: strike, t: dte / 365.0,
        sigma: iv / 100, r: r / 100,
        optionType: _isCall ? 'call' : 'put',
      );
      if (!mounted) return;
      setState(() { _result = res; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final res   = _result;
    final vomma = (res?['vomma'] as num?)?.toDouble();
    final vega  = (res?['vega']  as num?)?.toDouble();
    final vanna = (res?['vanna'] as num?)?.toDouble();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: TextFormField(
            controller: _spotCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Spot (S)', prefixText: '\$'),
          )),
          const SizedBox(width: 12),
          Expanded(child: TextFormField(
            controller: _strikeCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Strike (K)', prefixText: '\$'),
          )),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextFormField(
            controller: _dteCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'DTE', suffixText: 'days'),
          )),
          const SizedBox(width: 12),
          Expanded(child: TextFormField(
            controller: _ivCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'IV (σ)', suffixText: '%'),
          )),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextFormField(
            controller: _rCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Risk-free Rate (r)',
              suffixText: '%',
              helperText: 'SOFR ${(widget.initialRate ?? 4.33).toStringAsFixed(2)}%',
            ),
          )),
          const SizedBox(width: 12),
          _OptionTypeToggle(isCall: _isCall, onChanged: (v) => setState(() => _isCall = v)),
        ]),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _loading ? null : _calculate,
            child: _loading
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Calculate'),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: AppTheme.lossColor, fontSize: 12)),
        ],
        if (vomma != null) ...[
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF1C2128),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF30363D)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Vomma  (∂²V/∂σ²)',
                  style: TextStyle(fontSize: 11, color: AppTheme.neutralColor)),
              const SizedBox(height: 4),
              Text(vomma.toStringAsFixed(4),
                  style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(
                'Vega shifts ${(vomma * 0.01).abs().toStringAsFixed(4)} per +1 vol pt in IV',
                style: const TextStyle(fontSize: 11, color: AppTheme.neutralColor),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          if (vega  != null) _ResultRow(label: 'Vega  (∂V/∂σ)',    value: vega.toStringAsFixed(4),  color: AppTheme.neutralColor),
          if (vanna != null) _ResultRow(label: 'Vanna (∂²V/∂S∂σ)', value: vanna.toStringAsFixed(4), color: AppTheme.neutralColor),
        ],
      ]),
    );
  }
}
