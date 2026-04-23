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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/app_menu_button.dart';
import '../../../services/schwab/schwab_models.dart';
import '../../../services/schwab/schwab_providers.dart';
import '../models/blotter_models.dart';
import '../../../services/python_api/python_api_client.dart';
import '../services/fair_value_engine.dart';
import 'validated_blotters_screen.dart';
import 'trade_blotter_form_widgets.dart';
import 'trade_blotter_analysis_widgets.dart';
import 'trade_blotter_action_widgets.dart';

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
  final _qtyCtrl = TextEditingController(text: '1');
  final _notesCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  ContractType _contractType = ContractType.call;
  StrategyTag _strategyTag = StrategyTag.deltaNeutral;
  DateTime? _expiration;
  double? _spot;

  // ── Lifecycle state ───────────────────────────────────────────────────────
  TradeStatus _status = TradeStatus.draft;
  bool _isValidating = false;
  bool _isCommitting = false;
  bool _isTransmitting = false;

  // ── Validation results ────────────────────────────────────────────────────
  SchwabOptionContract? _contract;
  FairValueResult? _fairValue;
  WhatIfResult? _whatIf;
  PortfolioState _portfolio = PortfolioState.empty;
  String? _validateError;
  String? _committedId;

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
      _isValidating = true;
      _validateError = null;
      _contract = null;
      _fairValue = null;
      _whatIf = null;
    });

    try {
      final symbol = _symbolCtrl.text.trim().toUpperCase();
      final strike = double.parse(_strikeCtrl.text.trim());
      final qty = int.parse(_qtyCtrl.text.trim());
      final expStr =
          '${_expiration!.year}-'
          '${_expiration!.month.toString().padLeft(2, '0')}-'
          '${_expiration!.day.toString().padLeft(2, '0')}';

      // Fetch chain
      final chain = await ref.read(
        schwabOptionsChainProvider(
          OptionsChainParams(
            symbol: symbol,
            contractType: 'ALL',
            strikeCount: 30,
          ),
        ).future,
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
          'Try adjusting strike or expiration.',
        );
      }

      final brokerMid = (match.bid + match.ask) / 2;
      final fvRaw = await PythonApiClient.fairValueCompute(
        spot:         chain.underlyingPrice,
        strike:       match.strikePrice,
        impliedVol:   match.impliedVolatility / 100,
        daysToExpiry: match.daysToExpiration,
        isCall:       _contractType == ContractType.call,
        brokerMid:    brokerMid,
      );
      final fv = FairValueResult.fromJson(fvRaw) ??
          FairValueResult(
            bsFairValue:    brokerMid,
            sabrFairValue:  brokerMid,
            modelFairValue: brokerMid,
            brokerMid:      brokerMid,
            edgeBps:        0,
            sabrVol:        match.impliedVolatility / 100,
            impliedVol:     match.impliedVolatility / 100,
          );

      final wi = FairValueEngine.computeWhatIf(
        current: _portfolio,
        delta: match.delta,
        gamma: match.gamma,
        vega: match.vega,
        spot: chain.underlyingPrice,
        quantity: qty,
        impliedVol: match.impliedVolatility / 100,
        daysToExpiry: match.daysToExpiration,
      );

      setState(() {
        _spot = chain.underlyingPrice;
        _contract = match;
        _fairValue = fv;
        _whatIf = wi;
        _status = TradeStatus.validated;
      });
    } catch (e) {
      setState(() => _validateError = e.toString());
    } finally {
      setState(() => _isValidating = false);
    }
  }

  // ── Commit to DB ──────────────────────────────────────────────────────────

  Future<void> _commitToDb() async {
    final c = _contract;
    final fv = _fairValue;
    final wi = _whatIf;
    if (c == null || fv == null || wi == null) return;

    setState(() => _isCommitting = true);
    try {
      final symbol = _symbolCtrl.text.trim().toUpperCase();
      final qty = int.parse(_qtyCtrl.text.trim());
      final expStr =
          '${_expiration!.year}-'
          '${_expiration!.month.toString().padLeft(2, '0')}-'
          '${_expiration!.day.toString().padLeft(2, '0')}';

      final trade = BlotterTrade(
        symbol: symbol,
        strike: c.strikePrice,
        expiration: expStr,
        contractType: _contractType,
        quantity: qty,
        strategyTag: _strategyTag,
        notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
        status: TradeStatus.committed,
        createdAt: DateTime.now(),
        fairValueResult: fv,
        whatIfResult: wi,
        delta: c.delta,
        gamma: c.gamma,
        theta: c.theta,
        vega: c.vega,
        rho: c.rho,
        underlyingPrice: _spot ?? c.strikePrice,
      );

      final payload = trade.toJson()
        ..['status'] = 'committed'
        ..['validated_at'] = DateTime.now().toIso8601String()
        ..['committed_at'] = DateTime.now().toIso8601String();

      final result = await Supabase.instance.client
          .from('blotter_trades')
          .insert(payload)
          .select('id')
          .single();

      final committedId = result['id']?.toString();
      if (committedId == null || committedId.isEmpty) {
        throw Exception('DB write succeeded but returned no record id.');
      }

      setState(() {
        _committedId = committedId;
        _status = TradeStatus.committed;
      });

      ref.invalidate(recentBlotterProvider);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Trade committed to DB · ID ${_committedId?.substring(0, 8)}…',
            ),
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
      if (_committedId == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Cannot transmit: missing committed trade ID.'),
              backgroundColor: AppTheme.lossColor,
            ),
          );
        }
        return;
      }

      await Supabase.instance.client
          .from('blotter_trades')
          .update({
            'status': 'sent',
            'sent_at': DateTime.now().toIso8601String(),
          })
          .eq('id', _committedId!);

      setState(() => _status = TradeStatus.sent);
      ref.invalidate(recentBlotterProvider);

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
      _contractType = ContractType.call;
      _strategyTag = StrategyTag.deltaNeutral;
      _expiration = null;
      _status = TradeStatus.draft;
      _contract = null;
      _fairValue = null;
      _whatIf = null;
      _validateError = null;
      _committedId = null;
    });
    FairValueEngine.loadPortfolioState().then((p) {
      if (mounted) setState(() => _portfolio = p);
    });
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: const Color(0xFF0F0F14), // near-black terminal bg
        appBar: AppBar(
          backgroundColor: const Color(0xFF0F0F14),
          elevation: 0,
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppTheme.profitColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: AppTheme.profitColor.withValues(alpha: 0.4),
                  ),
                ),
                child: const Text(
                  'BLOTTER',
                  style: TextStyle(
                    color: AppTheme.profitColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
            ],
          ),
          actions: const [AppMenuButton()],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Builder'),
              Tab(text: 'Committed'),
            ],
          ),
        ),
        body: TabBarView(children: [_buildBuilderTab(), _buildValidatedTab()]),
      ),
    );
  }

  Widget _buildBuilderTab() {
    return Column(
      children: [
        LifecycleStepper(status: _status),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 100),
            children: [
              // ── Trade Builder ───────────────────────────────────────────
              SectionCard(
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
                            child: TerminalField(
                              label: 'SYMBOL',
                              controller: _symbolCtrl,
                              hint: 'e.g. AAPL',
                              caps: true,
                              validator: (v) =>
                                  v?.isEmpty ?? true ? 'Required' : null,
                              onChanged: (_) {
                                if (_status != TradeStatus.draft) {
                                  setState(() {
                                    _status = TradeStatus.draft;
                                    _contract = null;
                                    _fairValue = null;
                                    _whatIf = null;
                                  });
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          SizedBox(
                            width: 130,
                            child: TypeToggle(
                              value: _contractType,
                              onChanged: (t) => setState(() {
                                _contractType = t;
                                _status = TradeStatus.draft;
                                _contract = null;
                                _fairValue = null;
                                _whatIf = null;
                              }),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 10),

                      // Strike + Expiry row
                      Row(
                        children: [
                          Expanded(
                            child: TerminalField(
                              label: 'STRIKE',
                              controller: _strikeCtrl,
                              hint: 'e.g. 150.00',
                              numeric: true,
                              validator: (v) {
                                if (v?.isEmpty ?? true) return 'Required';
                                if (double.tryParse(v!) == null) {
                                  return 'Invalid number';
                                }
                                return null;
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: DatePickerField(
                              value: _expiration,
                              onPicked: (d) => setState(() {
                                _expiration = d;
                                _status = TradeStatus.draft;
                                _contract = null;
                                _fairValue = null;
                                _whatIf = null;
                              }),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 10),

                      // Quantity + Strategy row
                      Row(
                        children: [
                          Expanded(
                            child: TerminalField(
                              label: 'QUANTITY',
                              controller: _qtyCtrl,
                              hint: 'e.g. 1',
                              numeric: true,
                              validator: (v) {
                                if (v?.isEmpty ?? true) return 'Required';
                                if (int.tryParse(v!) == null) {
                                  return 'Invalid integer';
                                }
                                return null;
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: StrategyDropdown(
                              value: _strategyTag,
                              onChanged: (t) =>
                                  setState(() => _strategyTag = t),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 10),

                      // Notes
                      TerminalField(
                        label: 'NOTES (OPTIONAL)',
                        controller: _notesCtrl,
                        hint: 'Rationale, risk parameters…',
                        maxLines: 2,
                      ),

                      if (_validateError != null) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppTheme.lossColor.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: AppTheme.lossColor.withValues(alpha: 0.4),
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.error_outline,
                                color: AppTheme.lossColor,
                                size: 15,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _validateError!,
                                  style: const TextStyle(
                                    color: AppTheme.lossColor,
                                    fontSize: 11,
                                  ),
                                ),
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
                ModelVsMarketCard(fv: _fairValue!, contract: _contract!),
                const SizedBox(height: 10),
              ],

              // ── What-If Matrix ──────────────────────────────────────────
              if (_whatIf != null) ...[
                WhatIfMatrixCard(portfolio: _portfolio, whatIf: _whatIf!),
                const SizedBox(height: 10),
              ],

              // ── Recent blotter ──────────────────────────────────────────
              RecentBlotterCard(ref: ref),
            ],
          ),
        ),
        ActionBar(
          status: _status,
          isValidating: _isValidating,
          isCommitting: _isCommitting,
          isTransmitting: _isTransmitting,
          whatIf: _whatIf,
          onValidate: _validate,
          onCommit: _commitToDb,
          onTransmit: _transmit,
        ),
      ],
    );
  }

  Widget _buildValidatedTab() {
    final asyncBlotters = ref.watch(committedBlottersProvider);

    return asyncBlotters.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(
        child: Text(
          'Error loading committed blotters: $err',
          style: const TextStyle(color: AppTheme.lossColor),
        ),
      ),
      data: (blotters) {
        if (blotters.isEmpty) {
          return const Center(
            child: Text(
              'No committed blotters yet.',
              style: TextStyle(color: AppTheme.neutralColor),
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: blotters.length,
          itemBuilder: (context, index) {
            final trade = blotters[index];
            return CommittedBlotterCard(trade: trade);
          },
        );
      },
    );
  }
}
