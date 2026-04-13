// =============================================================================
// features/blotter/screens/five_phase_blotter_screen.dart
// =============================================================================
// Main screen that assembles all 5 phase panels into a single trade evaluation
// workflow.
//
// Layout:
//   AppBar          — "Trade Evaluation" + menu
//   PhaseStepper    — horizontal 5-step status bar (always visible)
//   Trade form card — ticker / type / strike / expiry / qty / budget / target
//   Phase tiles     — ExpansionTile per phase (auto-expands on status change)
//   Sticky bar      — overall status + Commit button (lifecycle-gated)
//
// Data flow:
//   • The form drives all 5 panels — panels only mount when _hasFullTrade.
//   • schwabOptionsChainProvider fetches the chain for the selected ticker +
//     expiry; the screen extracts spot/IV/greeks and passes them to
//     BlotterPhasePanel (the only panel that cannot self-fetch these values).
//   • Each panel calls onResult() when its computed PhaseResult changes; the
//     screen stores them in _p1…_p5 and propagates to PhaseStepper.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/app_menu_button.dart';
import '../../../services/schwab/schwab_models.dart';
import '../../../services/schwab/schwab_providers.dart';
import '../models/blotter_models.dart';
import '../models/phase_result.dart';
import '../widgets/phase_stepper.dart';
import '../widgets/phase_panels/economic_phase_panel.dart';
import '../widgets/phase_panels/formula_phase_panel.dart';
import '../widgets/phase_panels/blotter_phase_panel.dart';
import '../widgets/phase_panels/vol_surface_phase_panel.dart';
import '../widgets/phase_panels/kalshi_phase_panel.dart';

// ── Screen ────────────────────────────────────────────────────────────────────

class FivePhaseBlotterScreen extends ConsumerStatefulWidget {
  final String? initialTicker;

  const FivePhaseBlotterScreen({super.key, this.initialTicker});

  @override
  ConsumerState<FivePhaseBlotterScreen> createState() =>
      _FivePhaseBlotterScreenState();
}

class _FivePhaseBlotterScreenState
    extends ConsumerState<FivePhaseBlotterScreen> {
  // ── Form controllers ────────────────────────────────────────────────────────
  final _formKey    = GlobalKey<FormState>();
  final _tickerCtrl = TextEditingController();
  final _strikeCtrl = TextEditingController();
  final _qtyCtrl    = TextEditingController(text: '1');
  final _budgetCtrl = TextEditingController(text: '5000');
  final _targetCtrl = TextEditingController();

  ContractType _contractType = ContractType.call;
  DateTime?    _expiry;

  // ── Phase results ────────────────────────────────────────────────────────────
  PhaseResult _p1 = PhaseResult.none;
  PhaseResult _p2 = PhaseResult.none;
  PhaseResult _p3 = PhaseResult.none;
  PhaseResult _p4 = PhaseResult.none;
  PhaseResult _p5 = PhaseResult.none;

  // ── ExpansionTile controllers ────────────────────────────────────────────────
  bool _exp1 = false;
  bool _exp2 = false;
  bool _exp3 = false;
  bool _exp4 = false;
  bool _exp5 = false;

  // ── Derived form values ──────────────────────────────────────────────────────
  String   get _ticker    => _tickerCtrl.text.trim().toUpperCase();
  double?  get _strike    => double.tryParse(_strikeCtrl.text);
  int      get _qty       => int.tryParse(_qtyCtrl.text) ?? 1;
  double   get _budget    => double.tryParse(_budgetCtrl.text) ?? 5000;
  double?  get _target    => double.tryParse(_targetCtrl.text);
  int?     get _dte       => _expiry?.difference(DateTime.now()).inDays;
  String?  get _expiryStr {
    final d = _expiry;
    if (d == null) return null;
    return DateFormat('yyyy-MM-dd').format(d);
  }

  bool get _hasFullTrade =>
      _ticker.isNotEmpty && _strike != null && _expiry != null;

  // ── Overall gate logic ───────────────────────────────────────────────────────
  bool get _anyFail =>
      [_p1, _p2, _p3, _p4, _p5].any((r) => r.status == PhaseStatus.fail);

  bool get _allEvaluated =>
      [_p1, _p2, _p3, _p4, _p5]
          .every((r) => r.status != PhaseStatus.pending);

  bool get _canCommit => _hasFullTrade && _allEvaluated && !_anyFail;

  // ── Helpers ──────────────────────────────────────────────────────────────────

  void _notifyResult(
    int phase,
    PhaseResult result, {
    bool autoExpand = false,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        switch (phase) {
          case 1: _p1 = result; if (autoExpand && result.status != PhaseStatus.pass) _exp1 = true;
          case 2: _p2 = result; if (autoExpand && result.status != PhaseStatus.pass) _exp2 = true;
          case 3: _p3 = result; if (autoExpand && result.status != PhaseStatus.pass) _exp3 = true;
          case 4: _p4 = result; if (autoExpand && result.status != PhaseStatus.pass) _exp4 = true;
          case 5: _p5 = result; if (autoExpand && result.status != PhaseStatus.pass) _exp5 = true;
        }
      });
    });
  }

  // Extract the specific contract from the chain
  SchwabOptionContract? _findContract(SchwabOptionsChain? chain) {
    if (chain == null || _expiryStr == null || _strike == null) return null;
    final exp = chain.expirations.where(
        (e) => e.expirationDate == _expiryStr).firstOrNull;
    if (exp == null) return null;
    final contracts = _contractType == ContractType.call ? exp.calls : exp.puts;
    if (contracts.isEmpty) return null;
    return contracts.reduce((a, b) =>
        (a.strikePrice - _strike!).abs() < (b.strikePrice - _strike!).abs()
            ? a
            : b);
  }

  Future<void> _pickExpiry() async {
    final picked = await showDatePicker(
      context:     context,
      initialDate: _expiry ?? DateTime.now().add(const Duration(days: 30)),
      firstDate:   DateTime.now(),
      lastDate:    DateTime.now().add(const Duration(days: 730)),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.dark(
            primary:  AppTheme.profitColor,
            surface:  AppTheme.elevatedColor,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() {
        _expiry = picked;
        // Reset phase results when trade parameters change
        _p1 = PhaseResult.none;
        _p2 = PhaseResult.none;
        _p3 = PhaseResult.none;
        _p4 = PhaseResult.none;
        _p5 = PhaseResult.none;
      });
    }
  }

  void _onTickerOrStrikeChanged() {
    setState(() {
      _p1 = PhaseResult.none;
      _p2 = PhaseResult.none;
      _p3 = PhaseResult.none;
      _p4 = PhaseResult.none;
      _p5 = PhaseResult.none;
    });
  }

  Future<void> _commitTrade() async {
    // No-op for now; wire to blotter save in a future iteration
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: AppTheme.profitColor,
        content: Text(
          'Trade committed to blotter — ${_contractType.label} ${'$_ticker \$$_strike'} '
          '${_expiryStr ?? ''} x$_qty',
          style: const TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    if (widget.initialTicker != null) {
      _tickerCtrl.text = widget.initialTicker!;
    }
  }

  @override
  void dispose() {
    _tickerCtrl.dispose();
    _strikeCtrl.dispose();
    _qtyCtrl.dispose();
    _budgetCtrl.dispose();
    _targetCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Watch Schwab chain for the current ticker + expiry (for BlotterPhasePanel)
    final chainAsync = _hasFullTrade
        ? ref.watch(schwabOptionsChainProvider(OptionsChainParams(
            symbol:         _ticker,
            contractType:   _contractType == ContractType.call ? 'CALL' : 'PUT',
            strikeCount:    20,
            expirationDate: _expiryStr,
          )))
        : null;

    final chain    = chainAsync?.valueOrNull;
    final contract = _findContract(chain);
    final spot     = chain?.underlyingPrice ?? 0.0;
    final iv       = (contract?.impliedVolatility ?? 0.0) / 100.0;
    final mid      = contract?.midpoint ?? 0.0;
    final delta    = contract?.delta  ?? 0.0;
    final gamma    = contract?.gamma  ?? 0.0;
    final vega     = contract?.vega   ?? 0.0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Trade Evaluation'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_rounded, size: 18),
          onPressed: () => GoRouter.of(context).pop(),
        ),
        actions: const [AppMenuButton()],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(70),
          child: PhaseStepper(results: [_p1, _p2, _p3, _p4, _p5]),
        ),
      ),

      bottomNavigationBar: _hasFullTrade
          ? _ActionBar(
              results:   [_p1, _p2, _p3, _p4, _p5],
              canCommit: _canCommit,
              onCommit:  _commitTrade,
            )
          : null,

      body: ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
            children: [
              // Trade form card
              _TradeFormCard(
                formKey:       _formKey,
                tickerCtrl:    _tickerCtrl,
                strikeCtrl:    _strikeCtrl,
                qtyCtrl:       _qtyCtrl,
                budgetCtrl:    _budgetCtrl,
                targetCtrl:    _targetCtrl,
                contractType:  _contractType,
                expiry:        _expiry,
                onTypeChanged: (t) => setState(() {
                  _contractType = t;
                  _onTickerOrStrikeChanged();
                }),
                onExpiryTap:   _pickExpiry,
                onFieldChanged: _onTickerOrStrikeChanged,
              ),

              if (!_hasFullTrade) ...[
                const SizedBox(height: 24),
                Center(
                  child: Text(
                    'Enter ticker, strike, and expiry to begin evaluation.',
                    style: TextStyle(
                      color: AppTheme.neutralColor,
                      fontSize: 13,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],

              if (_hasFullTrade) ...[
                const SizedBox(height: 16),
                _sectionLabel('Phase Analysis'),
                const SizedBox(height: 8),

                // ── Phase 1 — Economic ─────────────────────────────────────────
                _PhaseTile(
                  phaseNum:  1,
                  title:     'Economic Gate',
                  result:    _p1,
                  expanded:  _exp1,
                  onChanged: (v) => setState(() => _exp1 = v),
                  child: EconomicPhasePanel(
                    ticker:       _ticker,
                    contractType: _contractType,
                    onResult:     (r) => _notifyResult(1, r, autoExpand: true),
                  ),
                ),

                // ── Phase 2 — Formula ──────────────────────────────────────────
                _PhaseTile(
                  phaseNum:  2,
                  title:     'Formula Gate',
                  result:    _p2,
                  expanded:  _exp2,
                  onChanged: (v) => setState(() => _exp2 = v),
                  child: FormulaPhasePanel(
                    ticker:       _ticker,
                    contractType: _contractType,
                    strike:       _strike,
                    expiry:       _expiryStr,
                    priceTarget:  _target,
                    maxBudget:    _budget,
                    onResult:     (r) => _notifyResult(2, r, autoExpand: true),
                  ),
                ),

                // ── Phase 3 — Blotter ──────────────────────────────────────────
                _PhaseTile(
                  phaseNum:  3,
                  title:     'Blotter Gate',
                  result:    _p3,
                  expanded:  _exp3,
                  onChanged: (v) => setState(() => _exp3 = v),
                  child: (spot == 0.0 && chainAsync?.isLoading == true)
                      ? const _LoadingPlaceholder('Loading contract data…')
                      : BlotterPhasePanel(
                          ticker:       _ticker,
                          spot:         spot > 0 ? spot : _strike!,
                          strike:       _strike!,
                          impliedVol:   iv > 0 ? iv : 0.25,
                          daysToExpiry: _dte ?? 30,
                          isCall:       _contractType == ContractType.call,
                          brokerMid:    mid,
                          delta:        delta,
                          gamma:        gamma,
                          vega:         vega,
                          quantity:     _qty,
                          onResult:     (r) =>
                              _notifyResult(3, r, autoExpand: true),
                        ),
                ),

                // ── Phase 4 — Vol Surface ──────────────────────────────────────
                _PhaseTile(
                  phaseNum:  4,
                  title:     'Vol Surface Gate',
                  result:    _p4,
                  expanded:  _exp4,
                  onChanged: (v) => setState(() => _exp4 = v),
                  child: VolSurfacePhasePanel(
                    ticker:       _ticker,
                    strike:       _strike!,
                    daysToExpiry: _dte ?? 30,
                    isCall:       _contractType == ContractType.call,
                    onResult:     (r) => _notifyResult(4, r, autoExpand: true),
                  ),
                ),

                // ── Phase 5 — Kalshi ───────────────────────────────────────────
                _PhaseTile(
                  phaseNum:  5,
                  title:     'Kalshi Gate',
                  result:    _p5,
                  expanded:  _exp5,
                  onChanged: (v) => setState(() => _exp5 = v),
                  child: KalshiPhasePanel(
                    ticker:     _ticker,
                    expiryDate: _expiry!,
                    isCall:     _contractType == ContractType.call,
                    onResult:   (r) => _notifyResult(5, r, autoExpand: true),
                  ),
                ),
              ], // end if _hasFullTrade spread
            ], // end ListView children
          ), // end ListView
    );
  }

  Widget _sectionLabel(String label) => Text(
        label.toUpperCase(),
        style: TextStyle(
          color:       AppTheme.neutralColor,
          fontSize:    11,
          fontWeight:  FontWeight.w700,
          letterSpacing: 1.0,
        ),
      );
}

// ── Trade form card ────────────────────────────────────────────────────────────

class _TradeFormCard extends StatelessWidget {
  final GlobalKey<FormState> formKey;
  final TextEditingController tickerCtrl;
  final TextEditingController strikeCtrl;
  final TextEditingController qtyCtrl;
  final TextEditingController budgetCtrl;
  final TextEditingController targetCtrl;
  final ContractType          contractType;
  final DateTime?             expiry;
  final ValueChanged<ContractType> onTypeChanged;
  final VoidCallback               onExpiryTap;
  final VoidCallback               onFieldChanged;

  const _TradeFormCard({
    required this.formKey,
    required this.tickerCtrl,
    required this.strikeCtrl,
    required this.qtyCtrl,
    required this.budgetCtrl,
    required this.targetCtrl,
    required this.contractType,
    required this.expiry,
    required this.onTypeChanged,
    required this.onExpiryTap,
    required this.onFieldChanged,
  });

  @override
  Widget build(BuildContext context) {
    final expiryLabel = expiry == null
        ? 'Expiry date'
        : DateFormat('MMM d, yyyy').format(expiry!);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Form(
          key: formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Trade Details',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 12),

              // Row 1: Ticker + Call/Put toggle
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextFormField(
                      controller:  tickerCtrl,
                      decoration:  const InputDecoration(
                        labelText:   'Ticker',
                        hintText:    'AAPL',
                        isDense:     true,
                      ),
                      textCapitalization: TextCapitalization.characters,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z.]')),
                        LengthLimitingTextInputFormatter(6),
                      ],
                      onChanged: (_) => onFieldChanged(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // Call / Put toggle
                  _TypeToggle(
                    value:     contractType,
                    onChanged: onTypeChanged,
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Row 2: Strike + Expiry
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller:  strikeCtrl,
                      decoration:  const InputDecoration(
                        labelText: 'Strike',
                        hintText:  '200',
                        prefixText: '\$',
                        isDense:   true,
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                            RegExp(r'[0-9.]')),
                      ],
                      onChanged: (_) => onFieldChanged(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: InkWell(
                      onTap:         onExpiryTap,
                      borderRadius:  BorderRadius.circular(10),
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Expiry',
                          isDense:  true,
                          suffixIcon: Icon(Icons.calendar_month_outlined,
                              size: 16),
                        ),
                        child: Text(
                          expiryLabel,
                          style: TextStyle(
                            fontSize: 14,
                            color: expiry == null
                                ? AppTheme.neutralColor
                                : Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Row 3: Qty + Budget
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller:  qtyCtrl,
                      decoration:  const InputDecoration(
                        labelText: 'Qty (contracts)',
                        isDense:   true,
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextFormField(
                      controller:  budgetCtrl,
                      decoration:  const InputDecoration(
                        labelText:  'Max Budget',
                        prefixText: '\$',
                        isDense:    true,
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                            RegExp(r'[0-9.]')),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Row 4: Price target (optional)
              TextFormField(
                controller:  targetCtrl,
                decoration:  const InputDecoration(
                  labelText:   'Price Target (optional)',
                  hintText:    'e.g. 220 — used for R:R calc',
                  prefixText:  '\$',
                  isDense:     true,
                ),
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Call / Put toggle ─────────────────────────────────────────────────────────

class _TypeToggle extends StatelessWidget {
  final ContractType           value;
  final ValueChanged<ContractType> onChanged;

  const _TypeToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color:        AppTheme.elevatedColor,
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      padding: const EdgeInsets.all(3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Chip(
            label:    'CALL',
            selected: value == ContractType.call,
            color:    AppTheme.profitColor,
            onTap:    () => onChanged(ContractType.call),
          ),
          const SizedBox(width: 4),
          _Chip(
            label:    'PUT',
            selected: value == ContractType.put,
            color:    AppTheme.lossColor,
            onTap:    () => onChanged(ContractType.put),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String   label;
  final bool     selected;
  final Color    color;
  final VoidCallback onTap;

  const _Chip({
    required this.label,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color:        selected ? color.withValues(alpha: 0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          border:       selected
              ? Border.all(color: color, width: 1.5)
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize:   12,
            fontWeight: FontWeight.w700,
            color:      selected ? color : AppTheme.neutralColor,
          ),
        ),
      ),
    );
  }
}

// ── Phase ExpansionTile wrapper ────────────────────────────────────────────────

class _PhaseTile extends StatelessWidget {
  final int         phaseNum;
  final String      title;
  final PhaseResult result;
  final bool        expanded;
  final ValueChanged<bool> onChanged;
  final Widget      child;

  const _PhaseTile({
    required this.phaseNum,
    required this.title,
    required this.result,
    required this.expanded,
    required this.onChanged,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final status = result.status;
    final color  = status.color;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: status == PhaseStatus.pending
              ? AppTheme.borderColor.withValues(alpha: 0.4)
              : color.withValues(alpha: 0.5),
          width: 1.5,
        ),
      ),
      child: Theme(
        // Remove the extra divider ExpansionTile adds
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        // NOTE: initiallyExpanded only works at first build — key forces rebuild
        // when expanded changes so the tile actually opens/closes programmatically.
        child: ExpansionTile(
          key: ValueKey('phase-$phaseNum-$expanded'),
          initiallyExpanded: expanded,
          onExpansionChanged: onChanged,
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          childrenPadding: EdgeInsets.zero,
          leading: _StepBadge(phase: phaseNum, status: status),
          title: Row(
            children: [
              Text(
                'Phase $phaseNum — $title',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  color: Colors.white,
                ),
              ),
              const Spacer(),
              _StatusChip(result: result),
            ],
          ),
          subtitle: result.status != PhaseStatus.pending
              ? Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    result.headline,
                    style: TextStyle(
                      fontSize: 11,
                      color: color.withValues(alpha: 0.85),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                )
              : null,
          children: [
            const Divider(height: 1, color: AppTheme.borderColor),
            child,
          ],
        ),
      ),
    );
  }
}

// ── Step badge (numbered circle) ──────────────────────────────────────────────

class _StepBadge extends StatelessWidget {
  final int         phase;
  final PhaseStatus status;

  const _StepBadge({required this.phase, required this.status});

  @override
  Widget build(BuildContext context) {
    final isPending = status == PhaseStatus.pending;
    final color     = status.color;

    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isPending
            ? AppTheme.elevatedColor
            : color.withValues(alpha: 0.15),
        border: Border.all(
          color: isPending ? AppTheme.borderColor : color,
          width: 2,
        ),
      ),
      child: Center(
        child: isPending
            ? Text(
                '$phase',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.neutralColor,
                ),
              )
            : Icon(status.icon, size: 14, color: color),
      ),
    );
  }
}

// ── Status chip (PASS / WARN / FAIL / PENDING) ────────────────────────────────

class _StatusChip extends StatelessWidget {
  final PhaseResult result;

  const _StatusChip({required this.result});

  @override
  Widget build(BuildContext context) {
    final status = result.status;
    final color  = status.color;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color:        color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border:       Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        status.label.toUpperCase(),
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

// ── Loading placeholder ────────────────────────────────────────────────────────

class _LoadingPlaceholder extends StatelessWidget {
  final String message;

  const _LoadingPlaceholder(this.message);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Text(
            message,
            style: TextStyle(color: AppTheme.neutralColor, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

// ── Sticky action bar ─────────────────────────────────────────────────────────

class _ActionBar extends StatelessWidget {
  final List<PhaseResult> results;
  final bool              canCommit;
  final VoidCallback      onCommit;

  const _ActionBar({
    required this.results,
    required this.canCommit,
    required this.onCommit,
  });

  @override
  Widget build(BuildContext context) {
    final anyFail = results.any((r) => r.status == PhaseStatus.fail);
    final allDone = results.every((r) => r.status != PhaseStatus.pending);
    final anyWarn = results.any((r) => r.status == PhaseStatus.warn);

    final String statusText;
    final Color  statusColor;

    if (!allDone) {
      statusText  = 'Evaluating…';
      statusColor = AppTheme.neutralColor;
    } else if (anyFail) {
      statusText  = 'Blocked — resolve FAIL phases';
      statusColor = AppTheme.lossColor;
    } else if (anyWarn) {
      statusText  = 'Ready with warnings';
      statusColor = const Color(0xFFFBBF24);
    } else {
      statusText  = 'All phases passed';
      statusColor = AppTheme.profitColor;
    }

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.elevatedColor,
        border: Border(
          top: BorderSide(color: AppTheme.borderColor, width: 1),
        ),
        boxShadow: [
          BoxShadow(
            color:      Colors.black.withValues(alpha: 0.3),
            blurRadius: 12,
            offset:     const Offset(0, -4),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      child: Row(
        children: [
          // Status indicator
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize:       MainAxisSize.min,
              children: [
                Text(
                  'Overall Status',
                  style: TextStyle(
                    fontSize:  10,
                    color:     AppTheme.neutralColor,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  statusText,
                  style: TextStyle(
                    fontSize:   13,
                    fontWeight: FontWeight.w700,
                    color:      statusColor,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Commit button
          ElevatedButton.icon(
            onPressed: canCommit ? onCommit : null,
            icon:  const Icon(Icons.check_circle_outline_rounded, size: 18),
            label: const Text('Commit Trade'),
            style: ElevatedButton.styleFrom(
              backgroundColor: canCommit
                  ? AppTheme.profitColor
                  : AppTheme.borderColor,
              foregroundColor: canCommit
                  ? Colors.black
                  : AppTheme.neutralColor,
              padding: const EdgeInsets.symmetric(
                  horizontal: 20, vertical: 12),
              textStyle: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize:   13,
              ),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ],
      ),
    );
  }
}
