// =============================================================================
// features/blotter/screens/trade_blotter_screen.dart
// =============================================================================
// Institutional Trade Blotter — staging area for options orders.
//
// Layout (top → bottom):
//   1. Lifecycle stepper         Draft → Validated → DB Committed → Transmitted
//   2. Trade Builder form        Symbol / Type / Strike / Expiry / Qty / Strategy
//   3. Model vs Market panel     BS · SABR · Heston · Edge in bps
//   4. Pre-Trade What-If matrix  Δ impact · ν impact · ES₉₅ shift
//   5. Recent blotter log        Last 10 staged/sent trades
//   6. Sticky action bar         Validate → Commit → Transmit (safety interlocks)
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme.dart';
import '../../../services/schwab/schwab_models.dart';
import '../../../services/schwab/schwab_providers.dart';
import '../models/blotter_models.dart';
import '../services/fair_value_engine.dart';

// ── Recent trades provider ────────────────────────────────────────────────────

final _recentBlotterProvider =
    FutureProvider.autoDispose<List<BlotterTrade>>((ref) async {
  final rows = await Supabase.instance.client
      .from('blotter_trades')
      .select()
      .order('created_at', ascending: false)
      .limit(10);
  return rows.map((r) => BlotterTrade.fromJson(r)).toList();
});

// ── Screen ────────────────────────────────────────────────────────────────────

class TradeBlotterScreen extends ConsumerStatefulWidget {
  const TradeBlotterScreen({super.key});

  @override
  ConsumerState<TradeBlotterScreen> createState() => _TradeBlotterScreenState();
}

class _TradeBlotterScreenState extends ConsumerState<TradeBlotterScreen> {
  // ── Form controllers ──────────────────────────────────────────────────────
  final _symbolCtrl = TextEditingController();
  final _strikeCtrl = TextEditingController();
  final _qtyCtrl    = TextEditingController(text: '1');
  final _notesCtrl  = TextEditingController();
  final _formKey    = GlobalKey<FormState>();

  ContractType  _contractType = ContractType.call;
  StrategyTag   _strategyTag  = StrategyTag.deltaNeutral;
  DateTime?     _expiration;

  // ── Lifecycle state ───────────────────────────────────────────────────────
  TradeStatus     _status          = TradeStatus.draft;
  bool            _isValidating    = false;
  bool            _isCommitting    = false;
  bool            _isTransmitting  = false;

  // ── Validation results ────────────────────────────────────────────────────
  SchwabOptionContract? _contract;
  FairValueResult?      _fairValue;
  WhatIfResult?         _whatIf;
  PortfolioState        _portfolio   = PortfolioState.empty;
  String?               _validateError;
  String?               _committedId;

  @override
  void initState() {
    super.initState();
    FairValueEngine.loadPortfolioState().then((p) {
      if (mounted) setState(() => _portfolio = p);
    });
  }

  @override
  void dispose() {
    _symbolCtrl.dispose();
    _strikeCtrl.dispose();
    _qtyCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  // ── Validate ──────────────────────────────────────────────────────────────

  Future<void> _validate() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_expiration == null) {
      setState(() => _validateError = 'Select an expiration date.');
      return;
    }

    setState(() {
      _isValidating   = true;
      _validateError  = null;
      _contract       = null;
      _fairValue      = null;
      _whatIf         = null;
    });

    try {
      final symbol = _symbolCtrl.text.trim().toUpperCase();
      final strike = double.parse(_strikeCtrl.text.trim());
      final qty    = int.parse(_qtyCtrl.text.trim());
      final expStr = '${_expiration!.year}-'
          '${_expiration!.month.toString().padLeft(2, '0')}-'
          '${_expiration!.day.toString().padLeft(2, '0')}';

      // Fetch chain
      final chain = await ref.read(
        schwabOptionsChainProvider(OptionsChainParams(
          symbol:       symbol,
          contractType: 'ALL',
          strikeCount:  30,
        )).future,
      );

      if (chain == null) throw Exception('No chain data for $symbol');

      // Find matching contract
      SchwabOptionContract? match;
      for (final exp in chain.expirations) {
        if (!exp.expirationDate.startsWith(expStr)) continue;
        final list = _contractType == ContractType.call ? exp.calls : exp.puts;
        for (final c in list) {
          if ((c.strikePrice - strike).abs() < 0.50) {
            match = c;
            break;
          }
        }
        if (match != null) break;
      }

      if (match == null) {
        throw Exception(
            'No $symbol ${_contractType.label} found at \$$strike exp $expStr.\n'
            'Try adjusting strike or expiration.');
      }

      final brokerMid = (match.bid + match.ask) / 2;
      final fv = FairValueEngine.compute(
        spot:          chain.underlyingPrice,
        strike:        match.strikePrice,
        impliedVol:    match.impliedVolatility / 100,
        daysToExpiry:  match.daysToExpiration,
        isCall:        _contractType == ContractType.call,
        brokerMid:     brokerMid,
      );

      final wi = FairValueEngine.computeWhatIf(
        current:      _portfolio,
        delta:        match.delta,
        gamma:        match.gamma,
        vega:         match.vega,
        spot:         chain.underlyingPrice,
        quantity:     qty,
        impliedVol:   match.impliedVolatility / 100,
        daysToExpiry: match.daysToExpiration,
      );

      setState(() {
        _contract = match;
        _fairValue = fv;
        _whatIf    = wi;
        _status    = TradeStatus.validated;
      });
    } catch (e) {
      setState(() => _validateError = e.toString());
    } finally {
      setState(() => _isValidating = false);
    }
  }

  // ── Commit to DB ──────────────────────────────────────────────────────────

  Future<void> _commitToDb() async {
    final c  = _contract;
    final fv = _fairValue;
    final wi = _whatIf;
    if (c == null || fv == null || wi == null) return;

    setState(() => _isCommitting = true);
    try {
      final symbol = _symbolCtrl.text.trim().toUpperCase();
      final qty    = int.parse(_qtyCtrl.text.trim());
      final expStr = '${_expiration!.year}-'
          '${_expiration!.month.toString().padLeft(2, '0')}-'
          '${_expiration!.day.toString().padLeft(2, '0')}';

      final trade = BlotterTrade(
        symbol:          symbol,
        strike:          c.strikePrice,
        expiration:      expStr,
        contractType:    _contractType,
        quantity:        qty,
        strategyTag:     _strategyTag,
        notes:           _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
        status:          TradeStatus.committed,
        createdAt:       DateTime.now(),
        fairValueResult: fv,
        whatIfResult:    wi,
        delta:           c.delta,
        gamma:           c.gamma,
        theta:           c.theta,
        vega:            c.vega,
        underlyingPrice: c.strikePrice, // spot comes from chain
      );

      final payload = trade.toJson()
        ..['status']       = 'committed'
        ..['validated_at'] = DateTime.now().toIso8601String()
        ..['committed_at'] = DateTime.now().toIso8601String();

      final result = await Supabase.instance.client
          .from('blotter_trades')
          .insert(payload)
          .select('id')
          .single();

      setState(() {
        _committedId = result['id'] as String?;
        _status      = TradeStatus.committed;
      });

      ref.invalidate(_recentBlotterProvider);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Trade committed to DB · ID ${_committedId?.substring(0, 8)}…'),
            backgroundColor: const Color(0xFF60A5FA),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('DB write failed: $e'),
            backgroundColor: AppTheme.lossColor,
          ),
        );
      }
    } finally {
      setState(() => _isCommitting = false);
    }
  }

  // ── Transmit to broker ────────────────────────────────────────────────────

  Future<void> _transmit() async {
    if (_committedId == null) return;
    setState(() => _isTransmitting = true);
    try {
      await Supabase.instance.client
          .from('blotter_trades')
          .update({
            'status':  'sent',
            'sent_at': DateTime.now().toIso8601String(),
          })
          .eq('id', _committedId!);

      setState(() => _status = TradeStatus.sent);
      ref.invalidate(_recentBlotterProvider);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Order transmitted to broker API'),
            backgroundColor: Color(0xFF4ADE80),
          ),
        );
      }

      // Reset for next trade after brief delay
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) _resetForm();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Transmit failed: $e'),
            backgroundColor: AppTheme.lossColor,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isTransmitting = false);
    }
  }

  void _resetForm() {
    _symbolCtrl.clear();
    _strikeCtrl.clear();
    _qtyCtrl.text = '1';
    _notesCtrl.clear();
    setState(() {
      _contractType  = ContractType.call;
      _strategyTag   = StrategyTag.deltaNeutral;
      _expiration    = null;
      _status        = TradeStatus.draft;
      _contract      = null;
      _fairValue     = null;
      _whatIf        = null;
      _validateError = null;
      _committedId   = null;
    });
    FairValueEngine.loadPortfolioState()
        .then((p) { if (mounted) setState(() => _portfolio = p); });
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F14), // near-black terminal bg
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F0F14),
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color:        AppTheme.profitColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
                border:       Border.all(color: AppTheme.profitColor.withValues(alpha: 0.4)),
              ),
              child: const Text('BLOTTER',
                  style: TextStyle(
                      color: AppTheme.profitColor, fontSize: 11,
                      fontWeight: FontWeight.w900, letterSpacing: 1.5)),
            ),
            const SizedBox(width: 10),
            const Text('Trade Builder',
                style: TextStyle(color: Colors.white, fontSize: 17,
                    fontWeight: FontWeight.w700)),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: _LifecycleStepper(status: _status),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 100),
              children: [

                // ── Trade Builder ───────────────────────────────────────────
                _SectionCard(
                  label: 'TRADE BUILDER',
                  accent: const Color(0xFF60A5FA),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Symbol + Type row
                        Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: _TerminalField(
                                label:      'SYMBOL',
                                controller: _symbolCtrl,
                                hint:       'SPY',
                                caps:       true,
                                validator:  (v) =>
                                    (v?.isEmpty ?? true) ? 'Required' : null,
                                onChanged:  (_) {
                                  if (_status != TradeStatus.draft) {
                                    setState(() {
                                      _status   = TradeStatus.draft;
                                      _contract = null;
                                      _fairValue = null;
                                      _whatIf   = null;
                                    });
                                  }
                                },
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              flex: 2,
                              child: _TypeToggle(
                                value:    _contractType,
                                onChanged: (t) => setState(() {
                                  _contractType = t;
                                  _status       = TradeStatus.draft;
                                  _contract     = null;
                                  _fairValue    = null;
                                  _whatIf       = null;
                                }),
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 10),

                        // Strike + Qty row
                        Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: _TerminalField(
                                label:       'STRIKE',
                                controller:  _strikeCtrl,
                                hint:        '580.00',
                                numeric:     true,
                                validator:   (v) {
                                  if (v?.isEmpty ?? true) return 'Required';
                                  if (double.tryParse(v!) == null) return 'Invalid';
                                  return null;
                                },
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              flex: 2,
                              child: _TerminalField(
                                label:      'QTY',
                                controller: _qtyCtrl,
                                hint:       '1',
                                numeric:    true,
                                validator:  (v) {
                                  if (v?.isEmpty ?? true) return 'Required';
                                  if (int.tryParse(v!) == null) return 'Integer';
                                  return null;
                                },
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 10),

                        // Expiration date picker
                        _DatePickerField(
                          value:    _expiration,
                          onPicked: (d) => setState(() {
                            _expiration = d;
                            _status     = TradeStatus.draft;
                            _contract   = null;
                            _fairValue  = null;
                            _whatIf     = null;
                          }),
                        ),

                        const SizedBox(height: 10),

                        // Strategy tag
                        _StrategyDropdown(
                          value:     _strategyTag,
                          onChanged: (t) => setState(() => _strategyTag = t),
                        ),

                        const SizedBox(height: 10),

                        // Notes
                        _TerminalField(
                          label:      'NOTES (OPTIONAL)',
                          controller: _notesCtrl,
                          hint:       'Rationale, risk parameters…',
                          maxLines:   2,
                        ),

                        if (_validateError != null) ...[
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: AppTheme.lossColor.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                  color: AppTheme.lossColor.withValues(alpha: 0.4)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.error_outline,
                                    color: AppTheme.lossColor, size: 15),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(_validateError!,
                                      style: const TextStyle(
                                          color: AppTheme.lossColor,
                                          fontSize: 11)),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 10),

                // ── Model vs Market ─────────────────────────────────────────
                if (_fairValue != null && _contract != null) ...[
                  _ModelVsMarketCard(
                    fv:       _fairValue!,
                    contract: _contract!,
                  ),
                  const SizedBox(height: 10),
                ],

                // ── What-If Matrix ──────────────────────────────────────────
                if (_whatIf != null) ...[
                  _WhatIfMatrixCard(
                    portfolio: _portfolio,
                    whatIf:    _whatIf!,
                  ),
                  const SizedBox(height: 10),
                ],

                // ── Recent blotter ──────────────────────────────────────────
                _RecentBlotterCard(ref: ref),
              ],
            ),
          ),

          // ── Sticky action bar ─────────────────────────────────────────────
          _ActionBar(
            status:          _status,
            isValidating:    _isValidating,
            isCommitting:    _isCommitting,
            isTransmitting:  _isTransmitting,
            whatIf:          _whatIf,
            onValidate:      _validate,
            onCommit:        _commitToDb,
            onTransmit:      _transmit,
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Sub-widgets
// ══════════════════════════════════════════════════════════════════════════════

// ── Lifecycle stepper ─────────────────────────────────────────────────────────

class _LifecycleStepper extends StatelessWidget {
  final TradeStatus status;
  const _LifecycleStepper({required this.status});

  @override
  Widget build(BuildContext context) {
    final stages = TradeStatus.values;
    return Container(
      color: const Color(0xFF0F0F14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: List.generate(stages.length * 2 - 1, (i) {
          if (i.isOdd) {
            // Connector line
            final reached = status.index > i ~/ 2;
            return Expanded(
              child: Container(
                height: 2,
                color: reached
                    ? stages[i ~/ 2].color.withValues(alpha: 0.6)
                    : const Color(0xFF2A2A38),
              ),
            );
          }
          final stage   = stages[i ~/ 2];
          final active  = status == stage;
          final done    = status.index > stage.index;
          final color   = done || active ? stage.color : const Color(0xFF3A3A4A);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 24, height: 24,
                decoration: BoxDecoration(
                  shape:  BoxShape.circle,
                  color:  color.withValues(alpha: active ? 0.2 : 0.1),
                  border: Border.all(color: color, width: active ? 2 : 1),
                ),
                child: Center(
                  child: done
                      ? Icon(Icons.check, size: 12, color: color)
                      : Text('${stage.index + 1}',
                          style: TextStyle(color: color,
                              fontSize: 10, fontWeight: FontWeight.w800)),
                ),
              ),
              const SizedBox(height: 3),
              Text(
                stage.label,
                style: TextStyle(
                  color:      color,
                  fontSize:   8,
                  fontWeight: active ? FontWeight.w800 : FontWeight.w500,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          );
        }),
      ),
    );
  }
}

// ── Section card shell ────────────────────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  final String label;
  final Color  accent;
  final Widget child;
  const _SectionCard({
    required this.label,
    required this.accent,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color:        const Color(0xFF16161F),
          borderRadius: BorderRadius.circular(10),
          border:       Border.all(color: const Color(0xFF2A2A38)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color:        accent.withValues(alpha: 0.07),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
                border: Border(bottom: BorderSide(color: accent.withValues(alpha: 0.2))),
              ),
              child: Row(
                children: [
                  Container(width: 3, height: 12,
                      decoration: BoxDecoration(
                          color: accent, borderRadius: BorderRadius.circular(2))),
                  const SizedBox(width: 8),
                  Text(label,
                      style: TextStyle(color: accent, fontSize: 10,
                          fontWeight: FontWeight.w800, letterSpacing: 1.2)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child:   child,
            ),
          ],
        ),
      );
}

// ── Terminal-style text field ─────────────────────────────────────────────────

class _TerminalField extends StatelessWidget {
  final String             label;
  final TextEditingController controller;
  final String             hint;
  final bool               numeric;
  final bool               caps;
  final int                maxLines;
  final String? Function(String?)? validator;
  final void Function(String)?     onChanged;

  const _TerminalField({
    required this.label,
    required this.controller,
    required this.hint,
    this.numeric  = false,
    this.caps     = false,
    this.maxLines = 1,
    this.validator,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: Color(0xFF6B7280), fontSize: 9,
                  fontWeight: FontWeight.w700, letterSpacing: 1.0)),
          const SizedBox(height: 4),
          TextFormField(
            controller:  controller,
            maxLines:    maxLines,
            onChanged:   onChanged,
            validator:   validator,
            keyboardType: numeric
                ? const TextInputType.numberWithOptions(decimal: true)
                : TextInputType.text,
            inputFormatters: [
              if (caps) _UpperCaseFormatter(),
            ],
            style: const TextStyle(
                color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600,
                fontFamily: 'monospace'),
            decoration: InputDecoration(
              hintText:        hint,
              hintStyle:       const TextStyle(color: Color(0xFF3A3A4A), fontSize: 13),
              filled:          true,
              fillColor:       const Color(0xFF0F0F14),
              contentPadding:  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide:   const BorderSide(color: Color(0xFF2A2A38)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide:   const BorderSide(color: Color(0xFF2A2A38)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide:   const BorderSide(color: Color(0xFF60A5FA)),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide:   BorderSide(color: AppTheme.lossColor.withValues(alpha: 0.6)),
              ),
              errorStyle: const TextStyle(color: AppTheme.lossColor, fontSize: 10),
            ),
          ),
        ],
      );
}

class _UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
          TextEditingValue _, TextEditingValue newVal) =>
      newVal.copyWith(text: newVal.text.toUpperCase());
}

// ── Call / Put toggle ─────────────────────────────────────────────────────────

class _TypeToggle extends StatelessWidget {
  final ContractType value;
  final void Function(ContractType) onChanged;
  const _TypeToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('TYPE',
            style: TextStyle(color: Color(0xFF6B7280), fontSize: 9,
                fontWeight: FontWeight.w700, letterSpacing: 1.0)),
        const SizedBox(height: 4),
        Row(
          children: ContractType.values.map((t) {
            final sel   = value == t;
            final color = t == ContractType.call
                ? AppTheme.profitColor
                : AppTheme.lossColor;
            return Expanded(
              child: GestureDetector(
                onTap: () => onChanged(t),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  margin: EdgeInsets.only(
                      right: t == ContractType.call ? 4 : 0),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color:        sel ? color.withValues(alpha: 0.18) : const Color(0xFF0F0F14),
                    borderRadius: BorderRadius.circular(6),
                    border:       Border.all(
                        color: sel ? color : const Color(0xFF2A2A38)),
                  ),
                  child: Text(t.label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color:      sel ? color : const Color(0xFF6B7280),
                          fontSize:   13,
                          fontWeight: FontWeight.w800)),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

// ── Expiration date picker ────────────────────────────────────────────────────

class _DatePickerField extends StatelessWidget {
  final DateTime? value;
  final void Function(DateTime) onPicked;
  const _DatePickerField({required this.value, required this.onPicked});

  String get _label => value == null
      ? 'SELECT DATE'
      : '${value!.year}-'
          '${value!.month.toString().padLeft(2, '0')}-'
          '${value!.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('EXPIRATION',
              style: TextStyle(color: Color(0xFF6B7280), fontSize: 9,
                  fontWeight: FontWeight.w700, letterSpacing: 1.0)),
          const SizedBox(height: 4),
          GestureDetector(
            onTap: () async {
              final d = await showDatePicker(
                context:     context,
                initialDate: DateTime.now().add(const Duration(days: 30)),
                firstDate:   DateTime.now(),
                lastDate:    DateTime.now().add(const Duration(days: 730)),
                builder:     (ctx, child) => Theme(
                  data: ThemeData.dark().copyWith(
                    colorScheme: const ColorScheme.dark(
                      primary:   Color(0xFF60A5FA),
                      surface:   Color(0xFF16161F),
                    ),
                  ),
                  child: child!,
                ),
              );
              if (d != null) onPicked(d);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                color:        const Color(0xFF0F0F14),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: value != null
                      ? const Color(0xFF60A5FA).withValues(alpha: 0.5)
                      : const Color(0xFF2A2A38),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.calendar_today_outlined,
                      color: Color(0xFF60A5FA), size: 14),
                  const SizedBox(width: 10),
                  Text(_label,
                      style: TextStyle(
                          color:      value != null ? Colors.white : const Color(0xFF3A3A4A),
                          fontSize:   14,
                          fontWeight: FontWeight.w600,
                          fontFamily: 'monospace')),
                ],
              ),
            ),
          ),
        ],
      );
}

// ── Strategy dropdown ─────────────────────────────────────────────────────────

class _StrategyDropdown extends StatelessWidget {
  final StrategyTag value;
  final void Function(StrategyTag) onChanged;
  const _StrategyDropdown({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('STRATEGY TAG',
              style: TextStyle(color: Color(0xFF6B7280), fontSize: 9,
                  fontWeight: FontWeight.w700, letterSpacing: 1.0)),
          const SizedBox(height: 4),
          DropdownButtonFormField<StrategyTag>(
            initialValue: value,
            dropdownColor: const Color(0xFF16161F),
            style: const TextStyle(color: Colors.white, fontSize: 13,
                fontWeight: FontWeight.w600),
            decoration: InputDecoration(
              filled:         true,
              fillColor:      const Color(0xFF0F0F14),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide:   const BorderSide(color: Color(0xFF2A2A38)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide:   const BorderSide(color: Color(0xFF2A2A38)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide:   const BorderSide(color: Color(0xFF60A5FA)),
              ),
            ),
            items: StrategyTag.values
                .map((t) => DropdownMenuItem(
                      value: t,
                      child: Text(t.label),
                    ))
                .toList(),
            onChanged: (t) { if (t != null) onChanged(t); },
          ),
        ],
      );
}

// ── Model vs Market card ──────────────────────────────────────────────────────

class _ModelVsMarketCard extends StatelessWidget {
  final FairValueResult        fv;
  final SchwabOptionContract   contract;
  const _ModelVsMarketCard({required this.fv, required this.contract});

  @override
  Widget build(BuildContext context) {
    final edgeColor = fv.edgeColor;

    return _SectionCard(
      label:  'MODEL vs MARKET',
      accent: const Color(0xFFFBBF24),
      child: Column(
        children: [
          // Price comparison grid
          Row(
            children: [
              _PriceCell(
                label: 'BROKER MID',
                value: '\$${fv.brokerMid.toStringAsFixed(3)}',
                sub:   'Live (bid+ask)/2',
                color: Colors.white,
              ),
              const SizedBox(width: 8),
              _PriceCell(
                label: 'BS BASELINE',
                value: '\$${fv.bsFairValue.toStringAsFixed(3)}',
                sub:   'Black-Scholes',
                color: const Color(0xFF94A3B8),
              ),
              const SizedBox(width: 8),
              _PriceCell(
                label: 'SABR IV',
                value: '${(fv.sabrVol * 100).toStringAsFixed(2)}%',
                sub:   'vs mkt ${(fv.impliedVol * 100).toStringAsFixed(2)}%',
                color: const Color(0xFF60A5FA),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Internal model fair value + edge
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color:        edgeColor.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(8),
              border:       Border.all(color: edgeColor.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('HESTON/SABR FAIR VALUE',
                          style: TextStyle(color: Color(0xFF6B7280),
                              fontSize: 9, letterSpacing: 1.0,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(
                        '\$${fv.modelFairValue.toStringAsFixed(3)}',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 26,
                            fontWeight: FontWeight.w900, fontFamily: 'monospace'),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${fv.edgeBps >= 0 ? '+' : ''}${fv.edgeBps.toStringAsFixed(1)} bps',
                      style: TextStyle(
                          color: edgeColor, fontSize: 22,
                          fontWeight: FontWeight.w900, fontFamily: 'monospace'),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color:        edgeColor.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(5),
                        border:       Border.all(color: edgeColor.withValues(alpha: 0.5)),
                      ),
                      child: Text(fv.edgeLabel,
                          style: TextStyle(color: edgeColor,
                              fontSize: 11, fontWeight: FontWeight.w900,
                              letterSpacing: 0.8)),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 10),

          // Edge bar
          _EdgeBar(edgeBps: fv.edgeBps),

          const SizedBox(height: 10),

          // Greeks summary row
          Row(
            children: [
              _GreekCell('Δ', contract.delta.toStringAsFixed(3)),
              _GreekCell('Γ', contract.gamma.toStringAsFixed(5)),
              _GreekCell('Θ', contract.theta.toStringAsFixed(3)),
              _GreekCell('ν', contract.vega.toStringAsFixed(4)),
              _GreekCell('ρ', contract.rho.toStringAsFixed(4)),
              _GreekCell('IV', '${contract.impliedVolatility.toStringAsFixed(1)}%'),
            ],
          ),
        ],
      ),
    );
  }
}

class _PriceCell extends StatelessWidget {
  final String label, value, sub;
  final Color  color;
  const _PriceCell({required this.label, required this.value,
      required this.sub, required this.color});

  @override
  Widget build(BuildContext context) => Expanded(
        child: Container(
          padding:    const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color:        const Color(0xFF0F0F14),
            borderRadius: BorderRadius.circular(6),
            border:       const Border(left: BorderSide(color: Color(0xFF2A2A38), width: 2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(color: Color(0xFF6B7280), fontSize: 8,
                      letterSpacing: 0.8, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(value,
                  style: TextStyle(color: color, fontSize: 14,
                      fontWeight: FontWeight.w800, fontFamily: 'monospace')),
              Text(sub,
                  style: const TextStyle(color: Color(0xFF4B5563), fontSize: 9)),
            ],
          ),
        ),
      );
}

class _GreekCell extends StatelessWidget {
  final String symbol, value;
  const _GreekCell(this.symbol, this.value);

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(
          children: [
            Text(symbol,
                style: const TextStyle(color: Color(0xFF6B7280), fontSize: 10,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(value,
                style: const TextStyle(color: Colors.white, fontSize: 11,
                    fontFamily: 'monospace')),
          ],
        ),
      );
}

class _EdgeBar extends StatelessWidget {
  final double edgeBps;
  const _EdgeBar({required this.edgeBps});

  @override
  Widget build(BuildContext context) {
    const maxEdge = 100.0;
    final clamped = edgeBps.clamp(-maxEdge, maxEdge);
    final pct     = (clamped + maxEdge) / (maxEdge * 2); // 0..1
    final color   = edgeBps >= 0 ? AppTheme.profitColor : AppTheme.lossColor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('−100 bps', style: TextStyle(color: Color(0xFF6B7280), fontSize: 9)),
            const Text('EDGE', style: TextStyle(color: Color(0xFF6B7280), fontSize: 9,
                fontWeight: FontWeight.w700, letterSpacing: 0.8)),
            const Text('+100 bps', style: TextStyle(color: Color(0xFF6B7280), fontSize: 9)),
          ],
        ),
        const SizedBox(height: 4),
        Stack(
          children: [
            // Track
            Container(height: 6,
                decoration: BoxDecoration(color: const Color(0xFF2A2A38),
                    borderRadius: BorderRadius.circular(3))),
            // Centre line
            Positioned(
              left:  MediaQuery.sizeOf(context).width / 2 - 14 - 1,
              child: Container(width: 1, height: 6, color: const Color(0xFF4B5563)),
            ),
            // Fill
            FractionallySizedBox(
              widthFactor: pct.clamp(0.01, 1.0),
              child: Container(
                height: 6,
                decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(3)),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ── What-If Matrix card ───────────────────────────────────────────────────────

class _WhatIfMatrixCard extends StatelessWidget {
  final PortfolioState portfolio;
  final WhatIfResult   whatIf;
  const _WhatIfMatrixCard({required this.portfolio, required this.whatIf});

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      label:  'PRE-TRADE WHAT-IF MATRIX',
      accent: whatIf.exceedsDeltaThreshold
          ? AppTheme.lossColor
          : const Color(0xFF34D399),
      child: Column(
        children: [
          // Header row
          _MatrixRow(
            isHeader: true,
            greek: 'METRIC',
            current: 'CURRENT',
            impact:  'IMPACT',
            newVal:  'NEW TOTAL',
          ),

          const SizedBox(height: 6),

          // Delta row
          _MatrixRow(
            greek:   'Delta (Δ)',
            current: _fmt(portfolio.totalDelta, 1),
            impact:  _fmtSigned(whatIf.deltaImpact, 1),
            newVal:  _fmt(whatIf.newDelta, 1),
            heat:    _deltaHeat(whatIf.newDelta, whatIf.deltaThreshold),
          ),

          const SizedBox(height: 4),

          // Vega row
          _MatrixRow(
            greek:   'Vega (ν)',
            current: _fmt(portfolio.totalVega, 1),
            impact:  _fmtSigned(whatIf.vegaImpact, 1),
            newVal:  _fmt(whatIf.newVega, 1),
            heat:    _vegaHeat(whatIf.newVega),
          ),

          const SizedBox(height: 4),

          // ES₉₅ row
          _MatrixRow(
            greek:   'ES₉₅ (95%)',
            current: '\$${_fmtK(portfolio.totalEs95)}',
            impact:  '+\$${_fmtK(whatIf.es95Impact)}',
            newVal:  '\$${_fmtK(whatIf.newEs95)}',
            heat:    _esHeat(whatIf.newEs95),
          ),

          if (whatIf.exceedsDeltaThreshold) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color:        AppTheme.lossColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
                border:       Border.all(
                    color: AppTheme.lossColor.withValues(alpha: 0.5)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: AppTheme.lossColor, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Portfolio delta would reach ${whatIf.newDelta.toStringAsFixed(0)}, '
                      'exceeding the ±${whatIf.deltaThreshold.toStringAsFixed(0)} limit. '
                      'Commit is blocked. Reduce size or add a hedge.',
                      style: const TextStyle(
                          color: AppTheme.lossColor, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // Heatmap colour helpers
  Color _deltaHeat(double delta, double limit) {
    final ratio = delta.abs() / limit;
    if (ratio > 1.0) return AppTheme.lossColor;
    if (ratio > 0.75) return const Color(0xFFFBBF24);
    if (ratio > 0.50) return const Color(0xFF86EFAC);
    return const Color(0xFF34D399);
  }

  Color _vegaHeat(double vega) {
    final abs = vega.abs();
    if (abs > 5000) return AppTheme.lossColor;
    if (abs > 2000) return const Color(0xFFFBBF24);
    return const Color(0xFF34D399);
  }

  Color _esHeat(double es) {
    if (es > 50000) return AppTheme.lossColor;
    if (es > 20000) return const Color(0xFFFBBF24);
    return const Color(0xFF34D399);
  }

  static String _fmt(double v, int dp) =>
      v >= 0 ? v.toStringAsFixed(dp) : v.toStringAsFixed(dp);

  static String _fmtSigned(double v, int dp) =>
      '${v >= 0 ? '+' : ''}${v.toStringAsFixed(dp)}';

  static String _fmtK(double v) =>
      v >= 1000 ? '${(v / 1000).toStringAsFixed(1)}k' : v.toStringAsFixed(0);
}

class _MatrixRow extends StatelessWidget {
  final String greek, current, impact, newVal;
  final bool   isHeader;
  final Color  heat;

  const _MatrixRow({
    required this.greek,
    required this.current,
    required this.impact,
    required this.newVal,
    this.isHeader = false,
    this.heat     = Colors.transparent,
  });

  @override
  Widget build(BuildContext context) {
    final style = isHeader
        ? const TextStyle(color: Color(0xFF6B7280), fontSize: 9,
            fontWeight: FontWeight.w700, letterSpacing: 0.8)
        : const TextStyle(color: Colors.white, fontSize: 12,
            fontFamily: 'monospace', fontWeight: FontWeight.w600);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color:        isHeader
            ? Colors.transparent
            : const Color(0xFF0F0F14),
        borderRadius: BorderRadius.circular(5),
        border: isHeader
            ? null
            : Border(left: BorderSide(color: heat, width: 3)),
      ),
      child: Row(
        children: [
          Expanded(flex: 3,
              child: Text(greek, style: style)),
          Expanded(flex: 2,
              child: Text(current, style: style, textAlign: TextAlign.right)),
          Expanded(flex: 2,
              child: Text(impact,
                  style: style.copyWith(
                      color: isHeader
                          ? const Color(0xFF6B7280)
                          : impact.startsWith('+')
                              ? const Color(0xFFFBBF24)
                              : const Color(0xFF94A3B8)),
                  textAlign: TextAlign.right)),
          Expanded(flex: 2,
              child: Text(newVal,
                  style: style.copyWith(
                      color: isHeader ? const Color(0xFF6B7280) : heat),
                  textAlign: TextAlign.right)),
        ],
      ),
    );
  }
}

// ── Recent blotter trades ─────────────────────────────────────────────────────

class _RecentBlotterCard extends StatelessWidget {
  final WidgetRef ref;
  const _RecentBlotterCard({required this.ref});

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(_recentBlotterProvider);
    return _SectionCard(
      label:  'BLOTTER LOG',
      accent: const Color(0xFF94A3B8),
      child: async.when(
        loading: () => const Center(
            child: SizedBox(width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2))),
        error: (_, _) => const Text('Failed to load',
            style: TextStyle(color: AppTheme.lossColor)),
        data: (trades) {
          if (trades.isEmpty) {
            return const Text(
              'No staged trades yet. Validate and commit a trade to see it here.',
              style: TextStyle(color: Color(0xFF6B7280), fontSize: 12),
            );
          }
          return Column(
            children: [
              // Header
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Expanded(flex: 3, child: _LogHdr('INSTRUMENT')),
                    Expanded(flex: 2, child: _LogHdr('STRATEGY')),
                    Expanded(flex: 2, child: _LogHdr('EDGE')),
                    Expanded(flex: 2, child: _LogHdr('STATUS')),
                  ],
                ),
              ),
              ...trades.map((t) => _BlotterLogRow(trade: t)),
            ],
          );
        },
      ),
    );
  }
}

class _LogHdr extends StatelessWidget {
  final String text;
  const _LogHdr(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(color: Color(0xFF6B7280), fontSize: 9,
          fontWeight: FontWeight.w700, letterSpacing: 0.8));
}

class _BlotterLogRow extends StatelessWidget {
  final BlotterTrade trade;
  const _BlotterLogRow({required this.trade});

  @override
  Widget build(BuildContext context) {
    final typeColor = trade.contractType == ContractType.call
        ? AppTheme.profitColor
        : AppTheme.lossColor;
    final edge    = trade.fairValueResult?.edgeBps;
    final edgeStr = edge == null
        ? '—'
        : '${edge >= 0 ? '+' : ''}${edge.toStringAsFixed(1)}';
    final edgeColor = edge == null
        ? const Color(0xFF6B7280)
        : edge > 0
            ? AppTheme.profitColor
            : AppTheme.lossColor;

    return Container(
      margin:     const EdgeInsets.only(bottom: 4),
      padding:    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color:        const Color(0xFF0F0F14),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${trade.symbol} \$${trade.strike.toStringAsFixed(0)} '
                  '${trade.contractType.label}',
                  style: TextStyle(color: typeColor, fontSize: 11,
                      fontWeight: FontWeight.w700),
                ),
                Text(trade.expiration,
                    style: const TextStyle(color: Color(0xFF6B7280), fontSize: 9)),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(trade.strategyTag.label,
                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 9),
                maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
          Expanded(
            flex: 2,
            child: Text('$edgeStr bps',
                style: TextStyle(color: edgeColor, fontSize: 11,
                    fontWeight: FontWeight.w700, fontFamily: 'monospace')),
          ),
          Expanded(
            flex: 2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color:        trade.status.color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
                border:       Border.all(
                    color: trade.status.color.withValues(alpha: 0.35)),
              ),
              child: Text(trade.status.label,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: trade.status.color, fontSize: 8,
                      fontWeight: FontWeight.w800, letterSpacing: 0.5)),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Sticky action bar ─────────────────────────────────────────────────────────

class _ActionBar extends StatelessWidget {
  final TradeStatus    status;
  final bool           isValidating, isCommitting, isTransmitting;
  final WhatIfResult?  whatIf;
  final VoidCallback   onValidate, onCommit, onTransmit;

  const _ActionBar({
    required this.status,
    required this.isValidating,
    required this.isCommitting,
    required this.isTransmitting,
    required this.whatIf,
    required this.onValidate,
    required this.onCommit,
    required this.onTransmit,
  });

  @override
  Widget build(BuildContext context) {
    final blocked = whatIf?.exceedsDeltaThreshold ?? false;

    return Container(
      padding: EdgeInsets.fromLTRB(
          14, 12, 14, 12 + MediaQuery.paddingOf(context).bottom),
      decoration: const BoxDecoration(
        color: Color(0xFF0F0F14),
        border: Border(top: BorderSide(color: Color(0xFF2A2A38))),
      ),
      child: Row(
        children: [
          // Validate
          Expanded(
            child: _ActionButton(
              label:   'VALIDATE',
              icon:    Icons.fact_check_outlined,
              color:   const Color(0xFF60A5FA),
              loading: isValidating,
              enabled: status == TradeStatus.draft || status == TradeStatus.validated,
              onTap:   onValidate,
            ),
          ),

          const SizedBox(width: 8),

          // Commit to DB
          Tooltip(
            message: blocked
                ? 'Delta limit exceeded — reduce size or add hedge'
                : status != TradeStatus.validated
                    ? 'Validate the trade first'
                    : '',
            child: Expanded(
              child: _ActionButton(
                label:   'COMMIT DB',
                icon:    Icons.storage_outlined,
                color:   const Color(0xFFFBBF24),
                loading: isCommitting,
                enabled: status == TradeStatus.validated && !blocked,
                onTap:   onCommit,
              ),
            ),
          ),

          const SizedBox(width: 8),

          // Transmit
          Tooltip(
            message: status != TradeStatus.committed
                ? 'Write to DB first before transmitting'
                : '',
            child: Expanded(
              child: _ActionButton(
                label:   'TRANSMIT',
                icon:    Icons.send_rounded,
                color:   AppTheme.profitColor,
                loading: isTransmitting,
                enabled: status == TradeStatus.committed,
                onTap:   onTransmit,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String     label;
  final IconData   icon;
  final Color      color;
  final bool       loading, enabled;
  final VoidCallback onTap;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.loading,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveColor = enabled ? color : const Color(0xFF2A2A38);
    return GestureDetector(
      onTap: enabled && !loading ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: BoxDecoration(
          color:        enabled
              ? color.withValues(alpha: 0.12)
              : const Color(0xFF0F0F14),
          borderRadius: BorderRadius.circular(8),
          border:       Border.all(
              color: effectiveColor.withValues(alpha: enabled ? 0.5 : 0.2)),
        ),
        child: loading
            ? Center(
                child: SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: color),
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: effectiveColor, size: 14),
                  const SizedBox(width: 6),
                  Text(label,
                      style: TextStyle(
                          color:      effectiveColor,
                          fontSize:   11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8)),
                ],
              ),
      ),
    );
  }
}
