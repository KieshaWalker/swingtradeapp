import 'dart:math';
import 'package:flutter/material.dart';
import '../../../core/theme.dart';

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
    _tabs = TabController(length: 2, vsync: this);
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
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: AppTheme.profitColor,
          labelColor: AppTheme.profitColor,
          unselectedLabelColor: AppTheme.neutralColor,
          tabs: const [
            Tab(text: 'P&L Estimator'),
            Tab(text: 'Position Size'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [
          _PnLEstimator(),
          _PositionSizer(),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------
// P&L Estimator (uses simplified Black-Scholes for Greeks display)
// ----------------------------------------------------------------
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

        // Results
        if (_costBasis != null) ...[
          const Divider(color: Color(0xFF30363D)),
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

// ----------------------------------------------------------------
// Position Sizer
// ----------------------------------------------------------------
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
          const Divider(color: Color(0xFF30363D)),
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
