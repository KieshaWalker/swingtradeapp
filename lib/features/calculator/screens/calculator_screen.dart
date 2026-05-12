// =============================================================================
// features/calculator/screens/calculator_screen.dart — Trading calculators
// =============================================================================
// Widgets defined here:
//   • CalculatorScreen       — scaffold + 5-tab TabBar
//   • _PnLEstimator          — tab 1: estimate trade outcome
//   • _PositionSizer         — tab 2: size a position by risk %
//   • _BlackScholesTab       — tab 3: BS price + all Greeks via /bs backend
//   • _SABRTab               — tab 4: SABR implied vol via /sabr backend
//   • _HestonTab             — tab 5: Heston price via /heston backend
//   • _ResultRow             — label ↔ colored value row (shared)
//   • _FormulaPanel          — expandable educational formula section (shared)
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
import '../../../services/python_api/python_api_client.dart';

class CalculatorScreen extends StatefulWidget {
  const CalculatorScreen({super.key});

  @override
  State<CalculatorScreen> createState() => _CalculatorScreenState();
}

class _CalculatorScreenState extends State<CalculatorScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 5, vsync: this);
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
          labelColor: AppTheme.profitColor,
          unselectedLabelColor: AppTheme.neutralColor,
          isScrollable: true,
          tabs: const [
            Tab(text: 'P&L'),
            Tab(text: 'Size'),
            Tab(text: 'Black-Scholes'),
            Tab(text: 'SABR'),
            Tab(text: 'Heston'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [
          _PnLEstimator(),
          _PositionSizer(),
          _BlackScholesTab(),
          _SABRTab(),
          _HestonTab(),
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
          Text(label, style: const TextStyle(color: AppTheme.neutralColor)),
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
  const _BlackScholesTab();

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
            decoration: const InputDecoration(labelText: 'Risk-free Rate (r)',
                suffixText: '%', helperText: 'SOFR ~4.33%'),
          )),
          const SizedBox(width: 12),
          Expanded(child: _OptionTypeToggle(
            isCall: _isCall,
            onChanged: (v) => setState(() => _isCall = v),
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
              Text(t.$1, style: const TextStyle(color: AppTheme.neutralColor, fontSize: 11)),
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
            decoration: const InputDecoration(labelText: 'Alpha (α)',
                helperText: 'ATM vol level ≈ IV'),
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
  const _HestonTab();

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
            decoration: const InputDecoration(labelText: 'Rate (r)', suffixText: '%'),
          )),
        ]),
        const SizedBox(height: 12),
        _OptionTypeToggle(isCall: _isCall, onChanged: (v) => setState(() => _isCall = v)),
        const SizedBox(height: 20),
        // ── Heston params ──
        const Text('Heston Parameters', style: TextStyle(color: Colors.white,
            fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: TextFormField(
            controller: _kappaCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Kappa (κ)',
                helperText: 'Mean reversion speed'),
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
            decoration: const InputDecoration(labelText: 'Xi (ξ)',
                helperText: 'Vol-of-vol'),
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
        Expanded(child: GestureDetector(
          onTap: () => onChanged(true),
          child: Container(
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
        Expanded(child: GestureDetector(
          onTap: () => onChanged(false),
          child: Container(
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
