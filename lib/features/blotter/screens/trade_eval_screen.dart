// =============================================================================
// features/blotter/screens/trade_eval_screen.dart
// =============================================================================
// Unified trade evaluation dashboard. Enter ticker + call/put + strike + expiry
// and every analytical section renders from a single Schwab chain fetch.
//
// Replaces FivePhaseBlotterScreen — no gates, no pass/fail blocking.
// All data is displayed directly; the Commit button is always available
// once the form is complete.
//
// Sections (in order):
//   • Contract identity  — strike, DTE, bid/ask/mid, spread, OI, IV, moneyness
//   • Live quote         — spot price, change, OHLC
//   • Pricing stack      — BS → SABR → Heston, edge bps, term comparison
//   • Greeks             — Δ Γ θ ν (first-order) + Vanna Charm Volga (second-order)
//   • Vol surface        — IV rank, term structure, smile skew, earnings
//   • Macro & regime     — macro score, VIX, yield curve, Fed trajectory
//   • GEX / gamma        — regime, ZGL, gamma wall, direction alignment
//   • Portfolio impact   — ES₉₅, delta / vega what-if
//
// Providers consumed (all Riverpod-cached — no duplicate network calls):
//   schwabOptionsChainProvider  — chain + contract data          [1 fetch]
//   quoteProvider               — live spot quote
//   fairValueProvider           — BS/SABR/Heston pricing API
//   sabrSliceProvider           — surface-calibrated SABR params
//   ivAnalysisProvider          — GEX / gamma / IV percentile
//   volSurfaceProvider          — full vol surface snapshots
//   schwabEarningsDateProvider  — next earnings date
//   macroScoreProvider          — macro regime + score
//   fredVixProvider             — VIX history
//   fredSpreadProvider          — 2s10s yield curve
//   fredFedFundsProvider        — fed funds rate
//   portfolioStateProvider      — committed positions for what-if
// =============================================================================

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/app_menu_button.dart';
import '../../../services/schwab/schwab_models.dart';
import '../../../services/schwab/schwab_providers.dart';
import '../../../services/iv/iv_models.dart';
import '../../../services/iv/iv_providers.dart';
import '../../../services/fred/fred_providers.dart';
import '../../../services/macro/macro_score_provider.dart';
import '../../ideas/models/trade_idea.dart';
import '../../ideas/providers/trade_ideas_notifier.dart';
import '../../vol_surface/models/vol_surface_models.dart';
import '../../vol_surface/providers/vol_surface_provider.dart';
import '../../vol_surface/widgets/vol_heatmap.dart';
import '../models/blotter_models.dart';
import '../providers/fair_value_provider.dart';
import '../services/fair_value_engine.dart';
import '../widgets/phase_panels/blotter_phase_panel.dart' show portfolioStateProvider;
import '../../../services/macro/macro_score_model.dart';
import '../../vol_surface/providers/sabr_calibration_provider.dart';
import '../../../services/python_api/python_api_client.dart';
import '../../../services/vol_surface/arb_checker.dart';
import '../../../services/iv/realized_vol_models.dart';
import '../../../services/iv/realized_vol_providers.dart';
import '../../greek_grid/models/greek_grid_models.dart';
import '../../greek_grid/providers/greek_grid_providers.dart';
import '../../options/services/option_scoring_engine.dart';

// ── Screen ────────────────────────────────────────────────────────────────────

class TradeEvalScreen extends ConsumerStatefulWidget {
  final String? initialTicker;
  const TradeEvalScreen({super.key, this.initialTicker});

  @override
  ConsumerState<TradeEvalScreen> createState() => _TradeEvalScreenState();
}

class _TradeEvalScreenState extends ConsumerState<TradeEvalScreen> {
  final _tickerCtrl = TextEditingController();
  final _strikeCtrl = TextEditingController();
  final _qtyCtrl    = TextEditingController(text: '1');

  bool      _isCall = true;
  DateTime? _expiry;

  String   get _ticker    => _tickerCtrl.text.trim().toUpperCase();
  double?  get _strike    => double.tryParse(_strikeCtrl.text);
  int      get _qty       => int.tryParse(_qtyCtrl.text) ?? 1;
  int?     get _dte       => _expiry?.difference(DateTime.now()).inDays;
  String?  get _expiryStr =>
      _expiry != null ? DateFormat('yyyy-MM-dd').format(_expiry!) : null;

  bool get _hasFullTrade =>
      _ticker.isNotEmpty && _strike != null && _expiry != null;

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
    super.dispose();
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
            primary: AppTheme.profitColor,
            surface: AppTheme.elevatedColor,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _expiry = picked);
  }

  Future<void> _commitTrade(
    SchwabOptionContract contract,
    double underlyingPrice,
    FairValueResult? fv,
    WhatIfResult? whatIf,
  ) async {
    try {
      final trade = BlotterTrade(
        symbol:          _ticker,
        strike:          contract.strikePrice,
        expiration:      _expiryStr!,
        contractType:    _isCall ? ContractType.call : ContractType.put,
        quantity:        _qty,
        strategyTag:     StrategyTag.netLongPremium,
        status:          TradeStatus.committed,
        createdAt:       DateTime.now(),
        fairValueResult: fv,
        whatIfResult:    whatIf,
        delta:           contract.delta,
        gamma:           contract.gamma,
        theta:           contract.theta,
        vega:            contract.vega,
        underlyingPrice: underlyingPrice,
      );

      await Supabase.instance.client.from('blotter_trades').insert(trade.toJson());
      ref.invalidate(portfolioStateProvider);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: AppTheme.profitColor,
        content: Text(
          'Committed — ${_isCall ? 'CALL' : 'PUT'} $_ticker '
          '\$${contract.strikePrice.toStringAsFixed(0)} '
          '${_expiryStr ?? ''} ×$_qty',
          style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w600),
        ),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: AppTheme.lossColor,
        content: Text('Commit failed: $e',
            style: const TextStyle(color: Colors.black)),
      ));
    }
  }

  Future<void> _saveAsIdea() async {
    if (!_hasFullTrade) return;
    final idea = TradeIdea(
      id:          '',
      ticker:      _ticker,
      contractType: _isCall ? ContractType.call : ContractType.put,
      strike:      _strike!,
      expiryDate:  _expiry!,
      quantity:    _qty,
      budget:      0,
      createdAt:   DateTime.now(),
    );
    try {
      await ref.read(tradeIdeasNotifierProvider.notifier).add(idea);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: AppTheme.elevatedColor,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        content: Text(
          'Saved "$_ticker ${_isCall ? 'CALL' : 'PUT'} \$$_strike" to ideas',
          style: const TextStyle(color: Colors.white),
        ),
        action: SnackBarAction(
          label: 'View',
          textColor: AppTheme.profitColor,
          onPressed: () => context.push('/ideas'),
        ),
      ));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trade Evaluation'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_rounded, size: 18),
          onPressed: () => GoRouter.of(context).pop(),
        ),
        actions: const [AppMenuButton()],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 120),
        children: [
          _TradeFormCard(
            tickerCtrl:  _tickerCtrl,
            strikeCtrl:  _strikeCtrl,
            qtyCtrl:     _qtyCtrl,
            isCall:      _isCall,
            expiry:      _expiry,
            onTypeToggle: (v) => setState(() => _isCall = v),
            onExpiryTap:  _pickExpiry,
            onChanged:    () => setState(() {}),
          ),
          if (!_hasFullTrade) ...[
            const SizedBox(height: 32),
            Center(
              child: Text(
                'Enter ticker, strike, and expiry to evaluate.',
                style: TextStyle(color: AppTheme.neutralColor, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ),
          ],
          if (_hasFullTrade) ...[
            const SizedBox(height: 12),
            _TradeEvalContent(
              ticker:  _ticker,
              strike:  _strike!,
              expiry:  _expiryStr!,
              isCall:  _isCall,
              qty:     _qty,
              dte:     _dte ?? 30,
              onCommit: _commitTrade,
            ),
          ],
        ],
      ),
      bottomNavigationBar: _hasFullTrade
          ? _BottomBar(onSaveIdea: _saveAsIdea)
          : null,
    );
  }
}

// ── Trade form card ────────────────────────────────────────────────────────────

class _TradeFormCard extends StatelessWidget {
  final TextEditingController tickerCtrl;
  final TextEditingController strikeCtrl;
  final TextEditingController qtyCtrl;
  final bool      isCall;
  final DateTime? expiry;
  final ValueChanged<bool> onTypeToggle;
  final VoidCallback       onExpiryTap;
  final VoidCallback       onChanged;

  const _TradeFormCard({
    required this.tickerCtrl,
    required this.strikeCtrl,
    required this.qtyCtrl,
    required this.isCall,
    required this.expiry,
    required this.onTypeToggle,
    required this.onExpiryTap,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final expiryLabel = expiry == null
        ? 'Expiry'
        : DateFormat('MMM d, yyyy').format(expiry!);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Row 1: ticker + call/put
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    controller: tickerCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Ticker',
                      hintText: 'AAPL',
                      isDense: true,
                    ),
                    textCapitalization: TextCapitalization.characters,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z.]')),
                      LengthLimitingTextInputFormatter(6),
                    ],
                    onChanged: (_) => onChanged(),
                  ),
                ),
                const SizedBox(width: 10),
                _TypeToggle(value: isCall, onChanged: onTypeToggle),
              ],
            ),
            const SizedBox(height: 10),
            // Row 2: strike + expiry
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: strikeCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Strike',
                      prefixText: '\$',
                      isDense: true,
                    ),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    onChanged: (_) => onChanged(),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: InkWell(
                    onTap: onExpiryTap,
                    borderRadius: BorderRadius.circular(10),
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Expiry',
                        isDense: true,
                        suffixIcon: Icon(Icons.calendar_month_outlined, size: 16),
                      ),
                      child: Text(
                        expiryLabel,
                        style: TextStyle(
                          fontSize: 14,
                          color: expiry == null ? AppTheme.neutralColor : Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // Row 3: qty
            SizedBox(
              width: 130,
              child: TextFormField(
                controller: qtyCtrl,
                decoration: const InputDecoration(
                  labelText: 'Qty',
                  isDense: true,
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Call / Put toggle ──────────────────────────────────────────────────────────

class _TypeToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
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
          _Chip(label: 'CALL', selected: value,  color: AppTheme.profitColor, onTap: () => onChanged(true)),
          const SizedBox(width: 4),
          _Chip(label: 'PUT',  selected: !value, color: AppTheme.lossColor,   onTap: () => onChanged(false)),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String     label;
  final bool       selected;
  final Color      color;
  final VoidCallback onTap;
  const _Chip({required this.label, required this.selected, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color:        selected ? color.withValues(alpha: 0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          border:       selected ? Border.all(color: color, width: 1.5) : null,
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

// ── Unified content — watches all providers, renders sections ─────────────────

class _TradeEvalContent extends ConsumerWidget {
  final String  ticker;
  final double  strike;
  final String  expiry;
  final bool    isCall;
  final int     qty;
  final int     dte;
  final Future<void> Function(
    SchwabOptionContract contract,
    double underlyingPrice,
    FairValueResult? fv,
    WhatIfResult? whatIf,
  ) onCommit;

  const _TradeEvalContent({
    required this.ticker,
    required this.strike,
    required this.expiry,
    required this.isCall,
    required this.qty,
    required this.dte,
    required this.onCommit,
  });

  static ExpiryBucket _dteToExpiryBucket(int dte) {
    if (dte <= 7)  return ExpiryBucket.weekly;
    if (dte <= 30) return ExpiryBucket.nearMonthly;
    if (dte <= 60) return ExpiryBucket.monthly;
    if (dte <= 90) return ExpiryBucket.farMonthly;
    return ExpiryBucket.quarterly;
  }

  static GreekGridSnapshot? _latestGridSnapshot(
      List<GreekGridPoint> points, String ticker) {
    if (points.isEmpty) return null;
    final dates = points.map((p) => p.obsDate).toSet().toList()..sort();
    final latest = dates.last;
    final filtered = points
        .where((p) =>
            p.obsDate.year  == latest.year &&
            p.obsDate.month == latest.month &&
            p.obsDate.day   == latest.day)
        .toList();
    return GreekGridSnapshot(ticker: ticker, obsDate: latest, points: filtered);
  }

  static ({double? first, double? last, int count}) _gridAtm14dTrend(
      List<GreekGridPoint> all, ExpiryBucket bucket) {
    final cutoff = DateTime.now().subtract(const Duration(days: 14));
    final series = all
        .where((p) =>
            p.strikeBand   == StrikeBand.atm &&
            p.expiryBucket == bucket &&
            p.obsDate.isAfter(cutoff) &&
            p.gamma != null)
        .toList()
      ..sort((a, b) => a.obsDate.compareTo(b.obsDate));
    if (series.isEmpty) return (first: null, last: null, count: 0);
    if (series.length == 1) {
      return (first: series.first.gamma, last: series.first.gamma, count: 1);
    }
    return (first: series.first.gamma, last: series.last.gamma, count: series.length);
  }

  SchwabOptionContract? _findContract(SchwabOptionsChain? chain) {
    if (chain == null) return null;
    final exp = chain.expirations
        .where((e) =>
            e.expirationDate == expiry ||
            e.expirationDate.startsWith(expiry) ||
            expiry.startsWith(e.expirationDate))
        .firstOrNull;
    if (exp == null) return null;
    final contracts = isCall ? exp.calls : exp.puts;
    if (contracts.isEmpty) return null;
    final best = contracts.reduce((a, b) =>
        (a.strikePrice - strike).abs() < (b.strikePrice - strike).abs() ? a : b);
    return (best.strikePrice - strike).abs() <= 1.0 ? best : null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chainParams = OptionsChainParams(
      symbol:         ticker,
      contractType:   isCall ? 'CALL' : 'PUT',
      strikeCount:    60,
      expirationDate: expiry,
    );

    final chainAsync    = ref.watch(schwabOptionsChainProvider(chainParams));
    final quoteAsync    = ref.watch(quoteProvider(ticker));
    final ivAsync       = ref.watch(ivAnalysisProvider(ticker));
    final surfaceAsync  = ref.watch(volSurfaceProvider);
    final macroAsync    = ref.watch(macroScoreProvider);
    final vixAsync      = ref.watch(fredVixProvider);
    final spreadAsync   = ref.watch(fredSpreadProvider);
    final fedAsync      = ref.watch(fredFedFundsProvider);
    final earningsAsync = ref.watch(schwabEarningsDateProvider(ticker));
    final portfolioAsync = ref.watch(portfolioStateProvider);
    final vxvAsync      = ref.watch(fredSeriesProvider('VXVCLS'));
    final rvAsync       = ref.watch(realizedVolProvider(ticker));
    final gridAsync     = ref.watch(greekGridProvider(ticker));

    final chain    = chainAsync.valueOrNull;
    final contract = _findContract(chain);
    final spot     = chain?.underlyingPrice ?? 0.0;
    final iv       = (contract?.impliedVolatility ?? 0.0) / 100.0;
    final mid      = contract?.midpoint ?? 0.0;

    // SABR calibration params (non-blocking — null until ready)
    final sabrSlice = ref.watch(sabrSliceProvider((ticker, dte)));

    // Pricing provider key — only fires when contract data is ready
    final fvKey = (spot > 0 && mid > 0 && iv > 0 && dte > 0)
        ? FairValueKey(
            spot:      spot,
            strike:    contract?.strikePrice ?? strike,
            iv:        iv,
            dte:       dte,
            isCall:    isCall,
            brokerMid: mid,
            rho:       sabrSlice?.rho,
            nu:        sabrSlice?.nu,
          )
        : null;
    final fvAsync = fvKey != null ? ref.watch(fairValueProvider(fvKey)) : null;
    final fv      = fvAsync?.valueOrNull;

    // Portfolio what-if (computed inline when both contract + portfolio ready)
    final portfolio = portfolioAsync.value ?? PortfolioState.empty;
    final whatIf = contract != null && spot > 0
        ? FairValueEngine.computeWhatIf(
            current:      portfolio,
            delta:        contract.delta,
            gamma:        contract.gamma,
            vega:         contract.vega,
            spot:         spot,
            quantity:     qty,
            impliedVol:   iv,
            daysToExpiry: dte,
          )
        : null;

    // Vol surface for this ticker (most recent snapshot)
    final allSnaps = surfaceAsync.valueOrNull ?? [];
    final snaps    = allSnaps
        .where((s) => s.ticker.toUpperCase() == ticker.toUpperCase())
        .toList()
      ..sort((a, b) => b.obsDate.compareTo(a.obsDate));
    final snap = snaps.isNotEmpty ? snaps.first : null;

    // VXV (90-day vol) for VIX/VXV ratio
    final vxvObs = (vxvAsync.valueOrNull as dynamic)?.observations as List? ?? [];
    final vxvNow = vxvObs.isNotEmpty ? (vxvObs.last as dynamic).value as double? : null;

    // Realized vol windows
    final rvData = rvAsync.valueOrNull;

    // Greek grid — latest ATM snapshot for the trade's DTE bucket
    final gridPoints  = gridAsync.valueOrNull ?? [];
    final gridBucket  = _dteToExpiryBucket(dte);
    final gridSnap    = _latestGridSnapshot(gridPoints, ticker);
    final gridAtmCell = gridSnap?.cell(StrikeBand.atm, gridBucket);
    final gridTrend   = _gridAtm14dTrend(gridPoints, gridBucket);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Chain loading / error states
        if (chainAsync.isLoading)
          _LoadingCard('Loading options chain…')
        else if (chainAsync.hasError)
          _ErrorCard('Chain error: ${chainAsync.error}')
        else if (chain != null && contract == null)
          _StrikeNotFoundCard(strike: strike)
        else if (contract != null) ...[
          // ── Contract identity ────────────────────────────────────────────────
          _ContractCard(
            contract: contract,
            spot:     spot,
            isCall:   isCall,
            ticker:   ticker,
          ),
          const SizedBox(height: 10),

          // ── Live quote ───────────────────────────────────────────────────────
          if (quoteAsync.valueOrNull != null) ...[
            _LiveQuoteCard(quote: quoteAsync.valueOrNull!),
            const SizedBox(height: 10),
          ],

          // ── Option quality score ─────────────────────────────────────────────
          _OptionScoreCard(contract: contract, spot: spot),
          const SizedBox(height: 10),

          // ── Pricing stack ────────────────────────────────────────────────────
          if (fvAsync?.isLoading == true)
            _LoadingCard('Computing fair value…')
          else if (fv != null)
            _PricingCard(fv: fv, isCall: isCall, ivAnalysis: ivAsync.valueOrNull),
          const SizedBox(height: 10),

          // ── Greeks ───────────────────────────────────────────────────────────
          _GreeksCard(contract: contract, fv: fv, qty: qty),
          const SizedBox(height: 10),

          // ── Vol surface ──────────────────────────────────────────────────────
          _VolSurfaceCard(
            ticker:     ticker,
            strike:     contract.strikePrice,
            dte:        dte,
            isCall:     isCall,
            snap:       snap,
            ivAnalysis: ivAsync.valueOrNull,
            earnings:   earningsAsync.valueOrNull,
            vega:       contract.vega,
          ),
          const SizedBox(height: 10),

          // ── Greek grid (ATM IV history, gamma trend, Vanna, Charm) ───────────
          _GreekGridCard(
            atmCell:  gridAtmCell,
            trend:    gridTrend,
            bucket:   gridBucket,
            loading:  gridAsync.isLoading,
          ),
          const SizedBox(height: 10),

          // ── Realized vol ─────────────────────────────────────────────────────
          _RealizedVolCard(rvData: rvData, contractIv: iv, loading: rvAsync.isLoading),
          const SizedBox(height: 10),

          // ── Macro & regime ───────────────────────────────────────────────────
          _MacroCard(
            macro:     macroAsync.valueOrNull,
            vixAsync:  vixAsync,
            vxvNow:    vxvNow,
            spreadObs: spreadAsync.valueOrNull?.observations ?? [],
            fedObs:    fedAsync.valueOrNull?.observations ?? [],
            isCall:    isCall,
          ),
          const SizedBox(height: 10),

          // ── GEX / gamma ──────────────────────────────────────────────────────
          if (ivAsync.valueOrNull != null) ...[
            _GexCard(
              ivAnalysis: ivAsync.valueOrNull!,
              isCall:     isCall,
              spot:       spot,
            ),
            const SizedBox(height: 10),
          ],

          // ── Portfolio impact ─────────────────────────────────────────────────
          _PortfolioCard(
            contract: contract,
            whatIf:   whatIf,
            portfolio: portfolio,
            loading:  portfolioAsync.isLoading,
            spot:     spot,
            iv:       iv,
            qty:      qty,
          ),
          const SizedBox(height: 10),

          // ── Beta-adjusted notional ───────────────────────────────────────────
          _BetaNotionalCard(
            ticker:   ticker,
            spot:     spot,
            delta:    contract.delta,
            qty:      qty,
          ),
          const SizedBox(height: 10),

          // ── Commit bar (inline, gets access to live data) ────────────────────
          _CommitCard(
            contract:      contract,
            spot:          spot,
            fv:            fv,
            whatIf:        whatIf,
            onCommit:      onCommit,
            ticker:        ticker,
            isCall:        isCall,
            dte:           dte,
          ),
          const SizedBox(height: 4),
        ],
      ],
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Section cards
// ═════════════════════════════════════════════════════════════════════════════

// ── Contract identity ─────────────────────────────────────────────────────────

class _ContractCard extends StatelessWidget {
  final SchwabOptionContract contract;
  final double spot;
  final bool   isCall;
  final String ticker;

  const _ContractCard({
    required this.contract,
    required this.spot,
    required this.isCall,
    required this.ticker,
  });

  @override
  Widget build(BuildContext context) {
    final typeColor = isCall ? AppTheme.profitColor : AppTheme.lossColor;
    final pctOtm    = spot > 0
        ? ((contract.strikePrice - spot) / spot * 100).abs()
        : 0.0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Row(
              children: [
                Text(
                  '$ticker  \$${contract.strikePrice.toStringAsFixed(0)}  '
                  '${isCall ? 'CALL' : 'PUT'}',
                  style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w900, color: Colors.white),
                ),
                const Spacer(),
                _InfoChip(
                  label: contract.inTheMoney
                      ? 'ITM'
                      : 'OTM ${pctOtm.toStringAsFixed(1)}%',
                  color: contract.inTheMoney ? typeColor : AppTheme.neutralColor,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${contract.daysToExpiration}d DTE  ·  '
              'IV ${contract.impliedVolatility.toStringAsFixed(1)}%  ·  '
              'Δ ${contract.delta.toStringAsFixed(3)}',
              style: const TextStyle(color: AppTheme.neutralColor, fontSize: 12),
            ),
            const SizedBox(height: 14),
            // Bid / mid / ask row
            Row(
              children: [
                _PriceCell('Bid',  '\$${contract.bid.toStringAsFixed(3)}',  AppTheme.lossColor),
                _PriceCell('Mid',  '\$${contract.midpoint.toStringAsFixed(3)}', Colors.white),
                _PriceCell('Ask',  '\$${contract.ask.toStringAsFixed(3)}',  AppTheme.profitColor),
              ],
            ),
            const SizedBox(height: 12),
            // Stats row
            Row(
              children: [
                _StatChip(
                  'Spread',
                  '${(contract.spreadPct * 100).toStringAsFixed(1)}%',
                  contract.spreadPct > 0.20 ? AppTheme.lossColor : AppTheme.neutralColor,
                ),
                const SizedBox(width: 8),
                _StatChip('OI', _fmtInt(contract.openInterest), AppTheme.neutralColor),
                const SizedBox(width: 8),
                _StatChip('Vol', _fmtInt(contract.totalVolume), AppTheme.neutralColor),
                const SizedBox(width: 8),
                _StatChip('Spot', '\$${spot.toStringAsFixed(2)}', AppTheme.neutralColor),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PriceCell extends StatelessWidget {
  final String label;
  final String value;
  final Color  color;
  const _PriceCell(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(label,
              style: const TextStyle(color: AppTheme.neutralColor, fontSize: 10,
                  fontWeight: FontWeight.w600, letterSpacing: 0.8)),
          const SizedBox(height: 4),
          Text(value,
              style: TextStyle(color: color, fontSize: 16,
                  fontWeight: FontWeight.w800, fontFamily: 'monospace')),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final Color  color;
  const _StatChip(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(6),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(color: AppTheme.neutralColor, fontSize: 9,
                  fontWeight: FontWeight.w600, letterSpacing: 0.5)),
          const SizedBox(height: 2),
          Text(value,
              style: TextStyle(color: color, fontSize: 11,
                  fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

// ── Live quote ────────────────────────────────────────────────────────────────

class _LiveQuoteCard extends StatelessWidget {
  final StockQuote quote;
  const _LiveQuoteCard({required this.quote});

  @override
  Widget build(BuildContext context) {
    final changeColor = quote.isPositive ? AppTheme.profitColor : AppTheme.lossColor;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('SPOT', style: TextStyle(color: AppTheme.neutralColor,
                    fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.0)),
                const SizedBox(height: 2),
                Text('\$${quote.price.toStringAsFixed(2)}',
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
                Text(
                  '${quote.isPositive ? '+' : ''}\$${quote.change.toStringAsFixed(2)} '
                  '(${quote.isPositive ? '+' : ''}${quote.changePercent.toStringAsFixed(2)}%)',
                  style: TextStyle(color: changeColor, fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const Spacer(),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _QuoteStat('Open',  '\$${quote.open.toStringAsFixed(2)}'),
                _QuoteStat('High',  '\$${quote.dayHigh.toStringAsFixed(2)}'),
                _QuoteStat('Low',   '\$${quote.dayLow.toStringAsFixed(2)}'),
                _QuoteStat('Prev',  '\$${quote.previousClose.toStringAsFixed(2)}'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _QuoteStat extends StatelessWidget {
  final String label;
  final String value;
  const _QuoteStat(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$label  ', style: const TextStyle(color: AppTheme.neutralColor, fontSize: 10)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 11)),
        ],
      ),
    );
  }
}

// ── Pricing stack ─────────────────────────────────────────────────────────────

class _PricingCard extends StatelessWidget {
  final FairValueResult fv;
  final bool            isCall;
  final IvAnalysis?     ivAnalysis;

  const _PricingCard({required this.fv, required this.isCall, this.ivAnalysis});

  @override
  Widget build(BuildContext context) {
    final sabrDelta   = fv.sabrFairValue  - fv.bsFairValue;
    final hestonDelta = fv.modelFairValue - fv.sabrFairValue;
    final edgeColor   = fv.edgeColor;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionLabel('Pricing Stack'),
            const SizedBox(height: 12),

            // Model rows
            _PricingRow(label: 'Black-Scholes',
                sublabel: 'IV ${(fv.impliedVol * 100).toStringAsFixed(1)}% fixed  ·  r=${(fv.rateUsed * 100).toStringAsFixed(2)}%',
                value: '\$${fv.bsFairValue.toStringAsFixed(3)}', delta: null),
            _divider(),
            _PricingRow(label: 'SABR  (smile-adjusted)',
                sublabel: 'σ=${(fv.sabrVol * 100).toStringAsFixed(1)}%',
                value: '\$${fv.sabrFairValue.toStringAsFixed(3)}',
                delta: sabrDelta,
                deltaColor: sabrDelta >= 0 ? AppTheme.profitColor : AppTheme.lossColor),
            _divider(),
            _PricingRow(label: 'Model  (SABR + Heston)',
                sublabel: 'Stochastic vol correction',
                value: '\$${fv.modelFairValue.toStringAsFixed(3)}',
                delta: hestonDelta,
                deltaColor: hestonDelta >= 0 ? AppTheme.profitColor : AppTheme.lossColor),
            _divider(),
            _PricingRow(label: 'Broker Mid',
                sublabel: '(bid + ask) ÷ 2',
                value: '\$${fv.brokerMid.toStringAsFixed(3)}', delta: null),

            // Edge banner
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color:        edgeColor.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border:       Border.all(color: edgeColor.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Icon(
                    fv.edgeBps > 0 ? Icons.arrow_upward_rounded
                        : fv.edgeBps < 0 ? Icons.arrow_downward_rounded
                        : Icons.remove_rounded,
                    color: edgeColor, size: 16,
                  ),
                  const SizedBox(width: 8),
                  Text(fv.edgeLabel,
                      style: TextStyle(color: edgeColor, fontSize: 13,
                          fontWeight: FontWeight.w900, letterSpacing: 0.5)),
                  const SizedBox(width: 10),
                  Text(
                    '${fv.edgeBps >= 0 ? '+' : ''}${fv.edgeBps.toStringAsFixed(1)} bps',
                    style: TextStyle(color: edgeColor, fontSize: 13,
                        fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),

            // Term comparison
            if (fv.termComparison != null) ...[
              const SizedBox(height: 14),
              _SectionLabel('Term Comparison  (${fv.termComparison!.periodLabel})'),
              const SizedBox(height: 8),
              _TermRow(tc: fv.termComparison!),
            ],

            // IV note
            if (fv.ivNote != null) ...[
              const SizedBox(height: 8),
              _IvNote(note: fv.ivNote!),
            ],
          ],
        ),
      ),
    );
  }

  Widget _divider() =>
      Divider(height: 1, color: AppTheme.borderColor.withValues(alpha: 0.5));
}

class _PricingRow extends StatelessWidget {
  final String  label;
  final String  sublabel;
  final String  value;
  final double? delta;
  final Color   deltaColor;
  const _PricingRow({
    required this.label,
    required this.sublabel,
    required this.value,
    required this.delta,
    this.deltaColor = AppTheme.neutralColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(color: Colors.white,
                    fontSize: 12, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(sublabel, style: const TextStyle(
                    color: AppTheme.neutralColor, fontSize: 10)),
              ],
            ),
          ),
          if (delta != null) ...[
            Text(
              '${delta! >= 0 ? '+' : ''}\$${delta!.toStringAsFixed(3)}',
              style: TextStyle(color: deltaColor, fontSize: 11),
            ),
            const SizedBox(width: 8),
          ],
          Text(value, style: const TextStyle(
              color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class _TermRow extends StatelessWidget {
  final TermComparison tc;
  const _TermRow({required this.tc});

  @override
  Widget build(BuildContext context) {
    final premColor = tc.isExpensive ? AppTheme.lossColor
        : tc.isCheap ? AppTheme.profitColor : AppTheme.neutralColor;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:        AppTheme.cardColor,
        borderRadius: BorderRadius.circular(8),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      child: Row(
        children: [
          _TermCell('Rate', '${tc.termRate.toStringAsFixed(2)}%', tc.rateTenor),
          _TermCell('IV',   tc.termIv != null ? '${tc.termIv!.toStringAsFixed(1)}%' : '—',
              'Implied'),
          _TermCell('RV',   tc.termRv != null ? '${tc.termRv!.toStringAsFixed(1)}%' : '—',
              'Realized'),
          if (tc.volPremium != null)
            _TermCell(
              'Premium',
              '${tc.volPremium! >= 0 ? '+' : ''}${tc.volPremium!.toStringAsFixed(1)} vpts',
              tc.isExpensive ? 'Rich' : tc.isCheap ? 'Cheap' : 'Fair',
              color: premColor,
            ),
        ],
      ),
    );
  }
}

class _TermCell extends StatelessWidget {
  final String  label;
  final String  value;
  final String  sub;
  final Color   color;
  const _TermCell(this.label, this.value, this.sub,
      {this.color = AppTheme.neutralColor});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(value, style: TextStyle(color: color, fontSize: 14,
              fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(label, textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 10,
                  fontWeight: FontWeight.w600)),
          Text(sub, textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.neutralColor, fontSize: 9)),
        ],
      ),
    );
  }
}

class _IvNote extends StatelessWidget {
  final String note;
  const _IvNote({required this.note});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color:        AppTheme.neutralColor.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline_rounded,
              size: 12, color: AppTheme.neutralColor),
          const SizedBox(width: 6),
          Expanded(
            child: Text(note,
                style: const TextStyle(color: AppTheme.neutralColor,
                    fontSize: 10, height: 1.5)),
          ),
        ],
      ),
    );
  }
}

// ── Greeks ────────────────────────────────────────────────────────────────────

class _GreeksCard extends StatelessWidget {
  final SchwabOptionContract contract;
  final FairValueResult?     fv;
  final int                  qty;

  const _GreeksCard({required this.contract, required this.qty, this.fv});

  @override
  Widget build(BuildContext context) {
    final deltaColor = contract.delta >= 0 ? AppTheme.profitColor : AppTheme.lossColor;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionLabel('Greeks'),
            const SizedBox(height: 12),
            Row(
              children: [
                _GreekBox('Δ Delta',  contract.delta.toStringAsFixed(3),  valueColor: deltaColor),
                _GreekBox('Γ Gamma',  contract.gamma.toStringAsFixed(4)),
                _GreekBox('θ Theta',  contract.theta.toStringAsFixed(3)),
                _GreekBox('ν Vega',   contract.vega.toStringAsFixed(3)),
              ],
            ),
            if (fv?.vanna != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  _GreekBox('Vanna',
                      fv!.vanna!.toStringAsFixed(5),
                      valueColor: fv!.vanna! < 0 ? AppTheme.lossColor : AppTheme.profitColor,
                      small: true),
                  if (fv!.charm != null)
                    _GreekBox('Charm', fv!.charm!.toStringAsFixed(5), small: true),
                  if (fv!.volga != null)
                    _GreekBox('Volga',
                        fv!.volga!.toStringAsFixed(5),
                        valueColor: (fv!.volga ?? 0) > 0 ? AppTheme.profitColor : AppTheme.lossColor,
                        small: true),
                  const Expanded(child: SizedBox()),
                ],
              ),
            ],
            // Position-level context
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color:        AppTheme.cardColor,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Text('Position delta  ',
                      style: const TextStyle(color: AppTheme.neutralColor, fontSize: 11)),
                  Text(
                    '\$${(contract.delta * qty * 100).toStringAsFixed(0)}',
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                  ),
                  const SizedBox(width: 16),
                  Text('$qty contract${qty == 1 ? '' : 's'}  ·  '
                      'premium \$${(contract.midpoint * qty * 100).toStringAsFixed(0)}',
                      style: const TextStyle(color: AppTheme.neutralColor, fontSize: 11)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GreekBox extends StatelessWidget {
  final String  label;
  final String  value;
  final Color?  valueColor;
  final bool    small;
  const _GreekBox(this.label, this.value, {this.valueColor, this.small = false});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color:        AppTheme.cardColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(color: AppTheme.neutralColor, fontSize: 10)),
            const SizedBox(height: 3),
            Text(value,
                style: TextStyle(
                  fontSize:   small ? 12 : 16,
                  fontWeight: FontWeight.w800,
                  color:      valueColor,
                  fontFamily: 'monospace',
                )),
          ],
        ),
      ),
    );
  }
}

// ── Vol surface ───────────────────────────────────────────────────────────────

class _VolSurfaceCard extends StatefulWidget {
  final String       ticker;
  final double       strike;
  final int          dte;
  final bool         isCall;
  final VolSnapshot? snap;
  final IvAnalysis?  ivAnalysis;
  final EarningsDate? earnings;
  final double?      vega;

  const _VolSurfaceCard({
    required this.ticker,
    required this.strike,
    required this.dte,
    required this.isCall,
    required this.snap,
    this.ivAnalysis,
    this.earnings,
    this.vega,
  });

  @override
  State<_VolSurfaceCard> createState() => _VolSurfaceCardState();
}

class _VolSurfaceCardState extends State<_VolSurfaceCard> {
  String          _ivMode       = 'otm';
  ArbCheckResult? _arbCheck;
  String?         _lastArbId;

  void _maybeRefreshArb(VolSnapshot snap) {
    final id = '${snap.ticker}:${snap.obsDateStr}';
    if (id == _lastArbId) return;
    _lastArbId = id;
    checkArbForSnap(snap).then((result) {
      if (mounted) setState(() => _arbCheck = result);
    });
  }

  @override
  Widget build(BuildContext context) {
    final snap = widget.snap;
    final iv   = widget.ivAnalysis;

    // IV percentile — prefer historical IVP from analysis, fallback surface rank
    final ivpDisplay = iv?.ivPercentile != null
        ? '${iv!.ivPercentile!.toStringAsFixed(0)}th IVP'
        : snap != null
            ? '—'
            : 'No data';

    // Term structure from snap
    final atmByDte  = _buildAtmByDte(snap);
    final termSlope = _termSlope(atmByDte);
    final termLabel = termSlope > 0.030
        ? 'Backwardation'
        : termSlope < -0.005
            ? 'Contango'
            : 'Flat';
    final termColor = termSlope > 0.030
        ? AppTheme.lossColor
        : termSlope < -0.005
            ? AppTheme.profitColor
            : AppTheme.neutralColor;

    // IV interpretation (based on historical IVP when available)
    final ivp = iv?.ivPercentile;
    final ivInterpret = ivp == null ? null
        : ivp < 30 ? 'Very low IVP — premium historically cheap; favor buying outright'
        : ivp < 60 ? 'Normal IVP — balanced buyer/seller value'
        : ivp < 80 ? 'Elevated IVP — above-average cost; IV crush risk after catalyst'
        : 'High IVP — strong crush risk; prefer selling premium or defined-risk spreads';

    // Smile skew at closest DTE
    String smileLabel = 'Symmetric';
    Color  smileColor = AppTheme.neutralColor;
    String skewNote   = 'Balanced skew — no directional bias from surface';
    if (snap != null && snap.spotPrice != null) {
      final spot      = snap.spotPrice!;
      final closestDte = snap.dtes.isEmpty ? widget.dte
          : snap.dtes.reduce((a, b) =>
              (a - widget.dte).abs() < (b - widget.dte).abs() ? a : b);
      final row      = snap.points.where((p) => p.dte == closestDte).toList();
      final otmCalls = row.where((p) => p.strike > spot * 1.02 && p.callIv != null)
                          .map((p) => p.callIv!).toList();
      final otmPuts  = row.where((p) => p.strike < spot * 0.98 && p.putIv  != null)
                          .map((p) => p.putIv!).toList();
      if (otmCalls.isNotEmpty && otmPuts.isNotEmpty) {
        final avgPut  = otmPuts.reduce((a, b) => a + b)  / otmPuts.length;
        final avgCall = otmCalls.reduce((a, b) => a + b) / otmCalls.length;
        final ratio   = avgCall > 0 ? avgPut / avgCall : 1.0;
        if (ratio > 1.10) {
          smileLabel = 'Put Skew  ${ratio.toStringAsFixed(2)}';
          smileColor = widget.isCall ? const Color(0xFFFBBF24) : AppTheme.profitColor;
          skewNote   = widget.isCall
              ? 'Put skew is normal equity structure — calls are relatively cheap vs puts'
              : '✓ Put bid supports bearish position';
        } else if (ratio < 0.90) {
          smileLabel = 'Call Skew  ${ratio.toStringAsFixed(2)}';
          smileColor = widget.isCall ? AppTheme.profitColor : const Color(0xFFFBBF24);
          skewNote   = widget.isCall
              ? '✓ Call bid — market chasing upside; surface supports bullish thesis'
              : 'Call skew opposes bearish position';
        } else {
          smileLabel = 'Symmetric  ${ratio.toStringAsFixed(2)}';
          skewNote   = 'Balanced skew — no directional bias from surface';
        }
      }
    }

    // Crush estimate — backwardation × vega tells you the $ drag per contract
    String? crushNote;
    final vega = widget.vega;
    if (vega != null && vega != 0 && termSlope > 0.010) {
      final crushPp      = (termSlope * 100).clamp(0.0, 40.0);
      final crushDollars = crushPp * vega * 100;
      if (crushDollars > 30) {
        crushNote = 'Crush drag ≈ \$${crushDollars.toStringAsFixed(0)}/contract'
            '  (${crushPp.toStringAsFixed(1)}pp backwardation × vega)';
      }
    }

    // Earnings
    final today    = DateTime.now();
    final daysToE  = widget.earnings != null
        ? DateTime(widget.earnings!.date.year, widget.earnings!.date.month,
                   widget.earnings!.date.day)
            .difference(DateTime(today.year, today.month, today.day))
            .inDays
        : null;
    final earningsInWindow = daysToE != null && daysToE >= 0 && daysToE <= widget.dte;

    if (snap != null) _maybeRefreshArb(snap);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionLabel('Vol Surface'),
            const SizedBox(height: 12),

            // IV percentile + term structure + smile skew row
            Row(
              children: [
                _SurfaceStat(
                  label: 'IV Percentile',
                  value: ivpDisplay,
                  color: iv?.ivPercentile != null
                      ? _ivpColor(iv!.ivPercentile!)
                      : AppTheme.neutralColor,
                ),
                const SizedBox(width: 8),
                _SurfaceStat(
                  label: 'Term Structure',
                  value: termLabel,
                  color: termColor,
                ),
                const SizedBox(width: 8),
                _SurfaceStat(
                  label: 'Smile Skew',
                  value: smileLabel,
                  color: smileColor,
                ),
              ],
            ),
            const SizedBox(height: 8),

            // IV interpretation
            if (ivInterpret != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(ivInterpret,
                    style: const TextStyle(
                        color: AppTheme.neutralColor, fontSize: 11, height: 1.4)),
              ),

            // Smile skew direction alignment
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color:        smileColor.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(6),
                border:       Border.all(color: smileColor.withValues(alpha: 0.25)),
              ),
              child: Text(skewNote,
                  style: TextStyle(color: smileColor, fontSize: 11)),
            ),
            const SizedBox(height: 10),

            // Earnings banner
            if (widget.earnings != null && daysToE != null && daysToE >= 0) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: (earningsInWindow ? AppTheme.lossColor : const Color(0xFFFBBF24))
                      .withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: (earningsInWindow ? AppTheme.lossColor : const Color(0xFFFBBF24))
                        .withValues(alpha: 0.35),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      earningsInWindow ? Icons.warning_amber_rounded : Icons.event_note_rounded,
                      size: 14,
                      color: earningsInWindow ? AppTheme.lossColor : const Color(0xFFFBBF24),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      earningsInWindow
                          ? 'Earnings INSIDE window — $daysToE days away (${_earningsFmt(widget.earnings!)})'
                          : 'Next earnings: ${_earningsFmt(widget.earnings!)}  ·  $daysToE days away',
                      style: TextStyle(
                        color: earningsInWindow ? AppTheme.lossColor : const Color(0xFFFBBF24),
                        fontSize: 12,
                        fontWeight: earningsInWindow ? FontWeight.w700 : FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],

            // Crush estimate
            if (crushNote != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color:        AppTheme.lossColor.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(6),
                  border:       Border.all(color: AppTheme.lossColor.withValues(alpha: 0.25)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.compress_rounded,
                        size: 13, color: AppTheme.lossColor),
                    const SizedBox(width: 7),
                    Text(crushNote,
                        style: const TextStyle(
                            color: AppTheme.lossColor, fontSize: 11)),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],

            // Vol heatmap
            if (snap != null) ...[
              Row(
                children: [
                  const Spacer(),
                  for (final m in [('otm', 'OTM'), ('call', 'Call'), ('put', 'Put'), ('avg', 'Avg')])
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: GestureDetector(
                        onTap: () => setState(() => _ivMode = m.$1),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: _ivMode == m.$1 ? AppTheme.cardColor : Colors.transparent,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: _ivMode == m.$1
                                  ? AppTheme.borderColor : Colors.transparent),
                          ),
                          child: Text(m.$2,
                              style: TextStyle(
                                color: _ivMode == m.$1 ? Colors.white70 : Colors.white38,
                                fontSize: 10)),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Container(
                height: 180,
                decoration: BoxDecoration(
                  color:        AppTheme.cardColor,
                  borderRadius: BorderRadius.circular(10),
                  border:       Border.all(color: AppTheme.borderColor),
                ),
                child: VolHeatmap(
                  points:    snap.points,
                  spotPrice: snap.spotPrice,
                  ivMode:    _ivMode,
                ),
              ),
              // Arb check result
              if (_arbCheck != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: (_arbCheck!.isArbitrageFree
                            ? AppTheme.profitColor
                            : AppTheme.lossColor)
                        .withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(
                      color: (_arbCheck!.isArbitrageFree
                              ? AppTheme.profitColor
                              : AppTheme.lossColor)
                          .withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _arbCheck!.isArbitrageFree
                            ? Icons.check_circle_outline
                            : Icons.warning_amber_rounded,
                        size: 14,
                        color: _arbCheck!.isArbitrageFree
                            ? AppTheme.profitColor
                            : AppTheme.lossColor,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _arbCheck!.summary,
                          style: TextStyle(
                            color: _arbCheck!.isArbitrageFree
                                ? AppTheme.profitColor
                                : AppTheme.lossColor,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ] else ...[
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color:        AppTheme.cardColor,
                  borderRadius: BorderRadius.circular(8),
                  border:       Border.all(color: AppTheme.borderColor),
                ),
                child: Text(
                  'No surface data for ${widget.ticker}. '
                  'Load an options chain in the Vol Surface screen.',
                  style: const TextStyle(color: AppTheme.neutralColor,
                      fontSize: 12, height: 1.4),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static Map<int, double> _buildAtmByDte(VolSnapshot? snap) {
    if (snap == null || snap.spotPrice == null) return {};
    final spot = snap.spotPrice!;
    final result = <int, double>{};
    for (final dte in snap.dtes) {
      final row = snap.points.where((p) => p.dte == dte).toList();
      if (row.isEmpty) continue;
      final atm = row.reduce(
          (a, b) => (a.strike - spot).abs() < (b.strike - spot).abs() ? a : b);
      final iv = atm.iv('avg', spot) ?? atm.iv('call', spot) ?? atm.iv('put', spot);
      if (iv != null) result[dte] = iv;
    }
    return result;
  }

  static double _termSlope(Map<int, double> atmByDte) {
    if (atmByDte.length < 2) return 0;
    final sorted = atmByDte.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    return sorted.first.value - sorted.last.value;
  }

  static Color _ivpColor(double ivp) {
    if (ivp < 30) return AppTheme.profitColor;
    if (ivp < 60) return AppTheme.neutralColor;
    if (ivp < 80) return const Color(0xFFFBBF24);
    return AppTheme.lossColor;
  }

  static String _earningsFmt(EarningsDate e) {
    final d = e.date;
    final time = e.time == 'bmo' ? ' (before open)' : e.time == 'amc' ? ' (after close)' : '';
    return '${d.month}/${d.day}/${d.year}$time';
  }
}

class _SurfaceStat extends StatelessWidget {
  final String label;
  final String value;
  final Color  color;
  const _SurfaceStat({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color:        AppTheme.cardColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: AppTheme.neutralColor, fontSize: 10)),
            const SizedBox(height: 3),
            Text(value, style: TextStyle(color: color, fontSize: 13,
                fontWeight: FontWeight.w800)),
          ],
        ),
      ),
    );
  }
}

// ── Macro & regime ────────────────────────────────────────────────────────────

class _MacroCard extends StatelessWidget {
  final MacroScore?         macro;
  final AsyncValue<dynamic> vixAsync;
  final double?             vxvNow;
  final List<dynamic>       spreadObs;
  final List<dynamic>       fedObs;
  final bool                isCall;

  const _MacroCard({
    required this.macro,
    required this.vixAsync,
    required this.spreadObs,
    required this.fedObs,
    required this.isCall,
    this.vxvNow,
  });

  @override
  Widget build(BuildContext context) {
    final regime  = macro?.regime ?? MacroRegime.neutral;
    final score   = macro?.total ?? 50.0;
    final vxvLocal = vxvNow; // local copy so Dart can null-promote the field

    final Color regimeColor = switch (regime) {
      MacroRegime.riskOn         => AppTheme.profitColor,
      MacroRegime.neutralBullish => const Color(0xFF60A5FA),
      MacroRegime.neutral        => const Color(0xFFFBBF24),
      MacroRegime.caution        => const Color(0xFFF97316),
      MacroRegime.crisis         => AppTheme.lossColor,
    };

    final vixObs = (vixAsync.valueOrNull as dynamic)?.observations as List? ?? [];
    final vixNow = vixObs.isNotEmpty ? (vixObs.last as dynamic).value as double? : null;
    final yieldNow = spreadObs.isNotEmpty ? (spreadObs.last as dynamic).value as double? : null;
    final fedNow   = fedObs.isNotEmpty ? (fedObs.last as dynamic).value as double? : null;
    final fedSixMo = fedObs.length >= 130 ? (fedObs[fedObs.length - 130] as dynamic).value as double? : null;

    final fedDelta = (fedNow != null && fedSixMo != null) ? fedNow - fedSixMo : null;
    final fedLabel = fedDelta == null ? '—'
        : fedDelta > 0.25 ? 'Hiking ↑'
        : fedDelta < -0.25 ? 'Cutting ↓'
        : 'Holding →';
    final fedColor = fedDelta == null ? AppTheme.neutralColor
        : fedDelta > 0.25 ? AppTheme.lossColor
        : fedDelta < -0.25 ? AppTheme.profitColor
        : AppTheme.neutralColor;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionLabel('Macro & Regime'),
            const SizedBox(height: 12),

            // Regime + score
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(regime.label,
                          style: TextStyle(color: regimeColor, fontSize: 16,
                              fontWeight: FontWeight.w800)),
                      const SizedBox(height: 2),
                      Text('Score ${score.toStringAsFixed(0)} / 100',
                          style: const TextStyle(color: AppTheme.neutralColor, fontSize: 12)),
                    ],
                  ),
                ),
                _InfoChip(
                  label: isCall
                      ? (regime == MacroRegime.riskOn || regime == MacroRegime.neutralBullish
                          ? '✓ Aligned' : '⚠ Headwind')
                      : (regime == MacroRegime.caution || regime == MacroRegime.crisis
                          ? '✓ Aligned' : '⚠ Headwind'),
                  color: (isCall
                      ? (regime == MacroRegime.riskOn || regime == MacroRegime.neutralBullish)
                      : (regime == MacroRegime.caution || regime == MacroRegime.crisis))
                      ? AppTheme.profitColor : const Color(0xFFFBBF24),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value:           (score / 100).clamp(0.0, 1.0),
                minHeight:       5,
                backgroundColor: AppTheme.borderColor.withValues(alpha: 0.3),
                valueColor:      AlwaysStoppedAnimation(regimeColor),
              ),
            ),
            const SizedBox(height: 12),

            // Key indicators row
            Row(
              children: [
                if (vixNow != null)
                  _MacroStat('VIX', vixNow.toStringAsFixed(1),
                      vixNow < 15 ? AppTheme.profitColor
                      : vixNow < 30 ? const Color(0xFFFBBF24)
                      : AppTheme.lossColor),
                if (yieldNow != null) ...[
                  const SizedBox(width: 8),
                  _MacroStat('2s10s',
                      '${yieldNow >= 0 ? '+' : ''}${yieldNow.toStringAsFixed(2)}%',
                      yieldNow >= 0 ? AppTheme.profitColor : AppTheme.lossColor),
                ],
                if (fedNow != null) ...[
                  const SizedBox(width: 8),
                  _MacroStat('Fed', fedLabel, fedColor),
                ],
              ],
            ),
            // VIX / VXV ratio
            if (vixNow != null && vxvLocal != null && vxvLocal > 0) ...[
              const SizedBox(height: 8),
              Builder(builder: (context) {
                final ratio      = vixNow / vxvLocal;
                final ratioColor = ratio > 1.10
                    ? AppTheme.lossColor
                    : ratio > 1.00
                        ? const Color(0xFFFBBF24)
                        : ratio < 0.85
                            ? const Color(0xFF60A5FA)
                            : AppTheme.neutralColor;
                final ratioLabel = ratio > 1.10
                    ? 'Panic — near-term vol spike'
                    : ratio > 1.00
                        ? 'Mild inversion — event risk'
                        : ratio < 0.85
                            ? 'Complacency — near-term cheap'
                            : 'Normal term structure';
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color:        ratioColor.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(7),
                    border:       Border.all(color: ratioColor.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      Text('VIX/VXV  ',
                          style: const TextStyle(color: AppTheme.neutralColor, fontSize: 11)),
                      Text(ratio.toStringAsFixed(2),
                          style: TextStyle(color: ratioColor, fontSize: 13,
                              fontWeight: FontWeight.w800, fontFamily: 'monospace')),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(ratioLabel,
                            style: TextStyle(color: ratioColor, fontSize: 11)),
                      ),
                      Text(
                        'VXV ${vxvNow!.toStringAsFixed(1)}',
                        style: const TextStyle(color: AppTheme.neutralColor, fontSize: 10),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ],
        ),
      ),
    );
  }
}

class _MacroStat extends StatelessWidget {
  final String label;
  final String value;
  final Color  color;
  const _MacroStat(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color:        AppTheme.cardColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: AppTheme.neutralColor, fontSize: 10)),
            const SizedBox(height: 3),
            Text(value, style: TextStyle(color: color, fontSize: 13,
                fontWeight: FontWeight.w800)),
          ],
        ),
      ),
    );
  }
}

// ── GEX / gamma ───────────────────────────────────────────────────────────────

class _GexCard extends StatelessWidget {
  final IvAnalysis ivAnalysis;
  final bool       isCall;
  final double     spot;

  const _GexCard({required this.ivAnalysis, required this.isCall, required this.spot});

  @override
  Widget build(BuildContext context) {
    final regime  = ivAnalysis.gammaRegime;
    final gexWall = ivAnalysis.maxGexStrike;
    final zgl     = ivAnalysis.zeroGammaLevel;
    final zglPct  = ivAnalysis.spotToZeroGammaPct;

    final Color regimeColor = switch (regime) {
      GammaRegime.positive => AppTheme.profitColor,
      GammaRegime.negative => AppTheme.lossColor,
      GammaRegime.unknown  => AppTheme.neutralColor,
    };

    final gexMisaligned = regime != GammaRegime.unknown &&
        ((isCall && regime == GammaRegime.negative) ||
         (!isCall && regime == GammaRegime.positive));
    final alignColor = gexMisaligned ? AppTheme.lossColor : AppTheme.profitColor;
    final alignLabel = gexMisaligned
        ? (isCall ? '⚠ GEX headwind for calls' : '⚠ GEX headwind for puts')
        : regime == GammaRegime.unknown
            ? 'Regime unknown'
            : (isCall ? '✓ GEX supports calls' : '✓ GEX supports puts');

    final rm             = RegimeMultipliers.from(ivAnalysis);
    final regimeMult     = rm.regimeMultiplier;
    final multColor      = regimeMult >= 1.0 ? AppTheme.profitColor
        : regimeMult >= 0.85 ? const Color(0xFFFBBF24) : AppTheme.lossColor;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionLabel('GEX / Gamma Regime'),
            const SizedBox(height: 12),

            Row(
              children: [
                Text(regime.label, style: TextStyle(color: regimeColor,
                    fontSize: 16, fontWeight: FontWeight.w800)),
                const SizedBox(width: 10),
                Text(ivAnalysis.gexLabel,
                    style: TextStyle(color: regimeColor.withValues(alpha: 0.7),
                        fontSize: 12, fontFamily: 'monospace')),
                const Spacer(),
                _InfoChip(label: alignLabel, color: alignColor),
              ],
            ),
            const SizedBox(height: 4),
            Text(regime.description,
                style: const TextStyle(color: Colors.white70, fontSize: 11, height: 1.4)),
            const SizedBox(height: 12),

            // ZGL + wall row
            Row(
              children: [
                if (gexWall != null) ...[
                  _GexStat('Gamma Wall',
                      '\$${gexWall.toStringAsFixed(0)}',
                      '${_pct(gexWall, spot)}% ${gexWall >= spot ? 'above' : 'below'}',
                      AppTheme.neutralColor),
                  const SizedBox(width: 8),
                ],
                if (zgl != null && zglPct != null) ...[
                  _GexStat('Zero Gamma (ZGL)',
                      '\$${zgl.toStringAsFixed(0)}',
                      '${zglPct.abs().toStringAsFixed(1)}% ${zglPct > 0 ? 'below' : 'above'}',
                      zglPct.abs() < 2 ? const Color(0xFFFBBF24) : AppTheme.neutralColor),
                ],
              ],
            ),
            const SizedBox(height: 10),

            // Regime multiplier
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color:        AppTheme.cardColor,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Text('Regime multiplier  ',
                      style: const TextStyle(color: AppTheme.neutralColor, fontSize: 11)),
                  Text('${regimeMult.toStringAsFixed(2)}×',
                      style: TextStyle(color: multColor, fontSize: 13,
                          fontWeight: FontWeight.w800, fontFamily: 'monospace')),
                  const SizedBox(width: 8),
                  Text(
                    'Gm ${rm.gexMultiplier.toStringAsFixed(2)}×  ×  '
                    'Vm ${rm.vannaMultiplier.toStringAsFixed(2)}×',
                    style: const TextStyle(color: AppTheme.neutralColor, fontSize: 10),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _pct(double level, double spot) {
    if (spot <= 0) return '—';
    return ((level - spot) / spot * 100).abs().toStringAsFixed(1);
  }
}

class _GexStat extends StatelessWidget {
  final String label;
  final String value;
  final String sub;
  final Color  color;
  const _GexStat(this.label, this.value, this.sub, this.color);

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color:        AppTheme.cardColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: AppTheme.neutralColor, fontSize: 10)),
            const SizedBox(height: 3),
            Text(value, style: TextStyle(color: color, fontSize: 14,
                fontWeight: FontWeight.w800)),
            Text(sub, style: const TextStyle(color: AppTheme.neutralColor, fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

// ── Portfolio impact ───────────────────────────────────────────────────────────

class _PortfolioCard extends StatelessWidget {
  final SchwabOptionContract contract;
  final WhatIfResult?        whatIf;
  final PortfolioState       portfolio;
  final bool                 loading;
  final double               spot;
  final double               iv;
  final int                  qty;

  const _PortfolioCard({
    required this.contract,
    required this.whatIf,
    required this.portfolio,
    required this.loading,
    required this.spot,
    required this.iv,
    required this.qty,
  });

  @override
  Widget build(BuildContext context) {
    // ES₉₅ for this trade
    final T       = contract.daysToExpiration / 365.0;
    final sqrtT   = math.sqrt(T);
    final posDelta = contract.delta * qty * 100;
    final posGamma = contract.gamma * qty * 100;
    const es95Mult = 2.063;
    final deltaEs  = posDelta.abs() * spot * iv * sqrtT * es95Mult;
    final gammaEs  = 0.5 * posGamma.abs() * spot * spot * iv * iv * T * 1.5;
    final maxLoss  = contract.midpoint * qty * 100;
    final tradeEs  = (deltaEs + gammaEs).clamp(0.0, maxLoss);
    final esColor  = tradeEs < 300 ? AppTheme.profitColor
        : tradeEs < 700 ? const Color(0xFFFBBF24)
        : AppTheme.lossColor;

    final wi = whatIf;
    final deltaThreshold = wi?.deltaThreshold ?? 5000.0;
    final deltaAfter     = wi?.newDelta.abs() ?? 0.0;
    final deltaBreached  = wi?.exceedsDeltaThreshold ?? false;
    final deltaColor     = deltaBreached ? AppTheme.lossColor
        : deltaAfter > deltaThreshold * 0.80 ? const Color(0xFFFBBF24)
        : AppTheme.profitColor;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionLabel('Portfolio Impact'),
            const SizedBox(height: 12),

            // ES₉₅ this trade
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('ES₉₅  (this trade)',
                          style: TextStyle(color: AppTheme.neutralColor, fontSize: 11)),
                      const SizedBox(height: 4),
                      Text('\$${tradeEs.toStringAsFixed(0)}',
                          style: TextStyle(color: esColor, fontSize: 22,
                              fontWeight: FontWeight.w900)),
                      Text('Δ \$${deltaEs.toStringAsFixed(0)}  +  Γ \$${gammaEs.toStringAsFixed(0)}',
                          style: const TextStyle(color: AppTheme.neutralColor, fontSize: 10)),
                    ],
                  ),
                ),
                if (!loading && wi != null) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Portfolio ES₉₅',
                            style: TextStyle(color: AppTheme.neutralColor, fontSize: 11)),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Text(
                              '\$${(wi.newEs95 - wi.es95Impact).toStringAsFixed(0)}',
                              style: const TextStyle(color: AppTheme.neutralColor,
                                  fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                            const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 4),
                              child: Icon(Icons.arrow_forward_rounded,
                                  size: 12, color: AppTheme.neutralColor),
                            ),
                            Text('\$${wi.newEs95.toStringAsFixed(0)}',
                                style: TextStyle(
                                  color: _esColor(wi.newEs95),
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                )),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),

            if (!loading && wi != null) ...[
              const SizedBox(height: 12),
              // Delta bar
              Row(
                children: [
                  const SizedBox(
                    width: 90,
                    child: Text('Portfolio Δ',
                        style: TextStyle(color: AppTheme.neutralColor, fontSize: 11)),
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value:           (deltaAfter / deltaThreshold).clamp(0.0, 1.0),
                        minHeight:       5,
                        backgroundColor: AppTheme.borderColor.withValues(alpha: 0.3),
                        valueColor:      AlwaysStoppedAnimation(deltaColor),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('\$${deltaAfter.toStringAsFixed(0)}',
                      style: TextStyle(color: deltaColor, fontSize: 11,
                          fontWeight: FontWeight.w700)),
                ],
              ),
              if (deltaBreached) ...[
                const SizedBox(height: 4),
                Text('Delta threshold exceeded (\$${deltaThreshold.toStringAsFixed(0)})',
                    style: const TextStyle(color: AppTheme.lossColor, fontSize: 11)),
              ],
              const SizedBox(height: 6),
              Text('${portfolio.openPositions} committed position${portfolio.openPositions == 1 ? '' : 's'} in book',
                  style: const TextStyle(color: AppTheme.neutralColor, fontSize: 11)),
            ],

            if (loading)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: _InlineLoader('Loading portfolio…'),
              ),
          ],
        ),
      ),
    );
  }

  static Color _esColor(double es95) {
    if (es95 < 300) return AppTheme.profitColor;
    if (es95 < 700) return const Color(0xFFFBBF24);
    return AppTheme.lossColor;
  }
}

// ── Commit card ───────────────────────────────────────────────────────────────

class _CommitCard extends ConsumerStatefulWidget {
  final SchwabOptionContract contract;
  final double               spot;
  final FairValueResult?     fv;
  final WhatIfResult?        whatIf;
  final String               ticker;
  final bool                 isCall;
  final int                  dte;
  final Future<void> Function(
    SchwabOptionContract,
    double,
    FairValueResult?,
    WhatIfResult?,
  ) onCommit;

  const _CommitCard({
    required this.contract,
    required this.spot,
    required this.fv,
    required this.whatIf,
    required this.ticker,
    required this.isCall,
    required this.dte,
    required this.onCommit,
  });

  @override
  ConsumerState<_CommitCard> createState() => _CommitCardState();
}

class _CommitCardState extends ConsumerState<_CommitCard> {
  bool _committing = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        AppTheme.elevatedColor,
        borderRadius: BorderRadius.circular(12),
        border:       Border.all(color: AppTheme.borderColor),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${widget.ticker}  \$${widget.contract.strikePrice.toStringAsFixed(0)}'
                  '  ${widget.isCall ? 'CALL' : 'PUT'}  ·  ${widget.dte}d',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                ),
                const SizedBox(height: 2),
                Text(
                  'mid \$${widget.contract.midpoint.toStringAsFixed(3)}'
                  '${widget.fv != null ? '  ·  ${widget.fv!.edgeLabel}  ${widget.fv!.edgeBps >= 0 ? '+' : ''}${widget.fv!.edgeBps.toStringAsFixed(0)} bps' : ''}',
                  style: const TextStyle(color: AppTheme.neutralColor, fontSize: 11),
                ),
              ],
            ),
          ),
          ElevatedButton.icon(
            onPressed: _committing
                ? null
                : () async {
                    setState(() => _committing = true);
                    await widget.onCommit(
                        widget.contract, widget.spot, widget.fv, widget.whatIf);
                    if (mounted) setState(() => _committing = false);
                  },
            icon: _committing
                ? const SizedBox(
                    width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                : const Icon(Icons.check_circle_outline_rounded, size: 16),
            label: Text(_committing ? 'Committing…' : 'Commit Trade'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.profitColor,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Bottom bar (save as idea) ─────────────────────────────────────────────────

class _BottomBar extends StatelessWidget {
  final VoidCallback onSaveIdea;

  const _BottomBar({required this.onSaveIdea});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color:  AppTheme.elevatedColor,
        border: Border(top: BorderSide(color: AppTheme.borderColor)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: onSaveIdea,
          icon: const Icon(Icons.lightbulb_outline_rounded, size: 16),
          label: const Text('Save as Trade Idea'),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFFBBF24),
            side: const BorderSide(color: Color(0xFFFBBF24), width: 1.5),
            padding: const EdgeInsets.symmetric(vertical: 13),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Shared helpers
// ═════════════════════════════════════════════════════════════════════════════

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

class _InfoChip extends StatelessWidget {
  final String label;
  final Color  color;
  const _InfoChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color:        color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border:       Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(label,
          style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700)),
    );
  }
}

class _LoadingCard extends StatelessWidget {
  final String message;
  const _LoadingCard(this.message);

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const SizedBox(width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 12),
            Text(message,
                style: const TextStyle(color: AppTheme.neutralColor, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String message;
  const _ErrorCard(this.message);

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: AppTheme.lossColor, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message,
                  style: const TextStyle(color: AppTheme.lossColor, fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }
}

class _StrikeNotFoundCard extends StatelessWidget {
  final double strike;
  const _StrikeNotFoundCard({required this.strike});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded,
                color: Color(0xFFFBBF24), size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '\$$strike not found in chain. '
                'Check the strike is a valid listed expiry.',
                style: const TextStyle(color: Color(0xFFFBBF24), fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineLoader extends StatelessWidget {
  final String message;
  const _InlineLoader(this.message);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(width: 14, height: 14,
            child: CircularProgressIndicator(strokeWidth: 1.5)),
        const SizedBox(width: 8),
        Text(message,
            style: const TextStyle(color: AppTheme.neutralColor, fontSize: 11)),
      ],
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Option quality score card
// ═════════════════════════════════════════════════════════════════════════════

class _OptionScoreCard extends StatefulWidget {
  final SchwabOptionContract contract;
  final double               spot;
  const _OptionScoreCard({required this.contract, required this.spot});

  @override
  State<_OptionScoreCard> createState() => _OptionScoreCardState();
}

class _OptionScoreCardState extends State<_OptionScoreCard> {
  OptionScore? _score;
  bool         _loading = true;
  String?      _lastKey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeFetch());
  }

  @override
  void didUpdateWidget(_OptionScoreCard old) {
    super.didUpdateWidget(old);
    _maybeFetch();
  }

  void _maybeFetch() {
    final key = '${widget.contract.symbol}:${widget.spot.toStringAsFixed(2)}';
    if (key == _lastKey) return;
    _lastKey = key;
    if (mounted) setState(() { _score = null; _loading = true; });
    PythonApiClient.scoringScore(
      contract:        widget.contract.toJson(),
      underlyingPrice: widget.spot,
    ).then((raw) {
      if (mounted) setState(() { _score = OptionScore.fromJson(raw); _loading = false; });
    }).catchError((_) {
      if (mounted) setState(() => _loading = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return _LoadingCard('Scoring contract…');
    final score = _score;
    if (score == null) return const SizedBox.shrink();

    final gradeColor = switch (score.grade) {
      'A' => AppTheme.profitColor,
      'B' => const Color(0xFF60A5FA),
      'C' => const Color(0xFFFBBF24),
      _   => AppTheme.lossColor,
    };
    final totalColor = score.total >= 75 ? AppTheme.profitColor
        : score.total >= 55 ? const Color(0xFF60A5FA)
        : score.total >= 35 ? const Color(0xFFFBBF24)
        : AppTheme.lossColor;
    final meaning = score.total >= 75 ? 'Excellent'
        : score.total >= 65 ? 'Strong'
        : score.total >= 55 ? 'Adequate'
        : score.total >= 35 ? 'Below avg'
        : 'Avoid';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionLabel('Option Quality Score'),
            const SizedBox(height: 12),
            Row(
              children: [
                Container(
                  width: 52, height: 52,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color:  gradeColor.withValues(alpha: 0.12),
                    border: Border.all(color: gradeColor, width: 2),
                  ),
                  child: Center(
                    child: Text(score.grade,
                        style: TextStyle(color: gradeColor, fontSize: 22,
                            fontWeight: FontWeight.w900)),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text('${score.total} / 100',
                              style: TextStyle(color: totalColor, fontSize: 18,
                                  fontWeight: FontWeight.w900)),
                          const SizedBox(width: 10),
                          Text(meaning, style: TextStyle(color: totalColor, fontSize: 12,
                              fontWeight: FontWeight.w600)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: (score.total / 100).clamp(0.0, 1.0),
                          minHeight: 6,
                          backgroundColor: AppTheme.borderColor.withValues(alpha: 0.3),
                          valueColor: AlwaysStoppedAnimation(totalColor),
                        ),
                      ),
                      if (score.ivpUsed)
                        const Padding(
                          padding: EdgeInsets.only(top: 3),
                          child: Text('IV score uses historical IVP',
                              style: TextStyle(color: AppTheme.neutralColor, fontSize: 10)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _ScoreBar('Delta',     score.deltaScore,     20),
            _ScoreBar('DTE Zone',  score.dteScore,       20),
            _ScoreBar('IV',        score.ivScore,        20),
            _ScoreBar('Liquidity', score.liquidityScore, 15),
            _ScoreBar('Moneyness', score.moneynessScore, 15),
            _ScoreBar('Spread',    score.spreadScore,    10),
            if (score.regimeFail) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color:        AppTheme.lossColor.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(7),
                  border:       Border.all(color: AppTheme.lossColor.withValues(alpha: 0.3)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, size: 14, color: AppTheme.lossColor),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Regime gate: Short Gamma hard override — score capped at 35',
                        style: TextStyle(color: AppTheme.lossColor, fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            for (final f in score.flags)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('⚠ ',
                        style: TextStyle(color: Color(0xFFFBBF24), fontSize: 11)),
                    Expanded(
                      child: Text(f,
                          style: const TextStyle(
                              color: Color(0xFFFBBF24), fontSize: 11, height: 1.4)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ScoreBar extends StatelessWidget {
  final String label;
  final int    score;
  final int    maxScore;
  const _ScoreBar(this.label, this.score, this.maxScore);

  @override
  Widget build(BuildContext context) {
    final pct   = maxScore > 0 ? score / maxScore : 0.0;
    final color = pct >= 0.80 ? AppTheme.profitColor
        : pct >= 0.55 ? const Color(0xFF60A5FA)
        : pct >= 0.35 ? const Color(0xFFFBBF24)
        : AppTheme.lossColor;
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        children: [
          SizedBox(
            width: 76,
            child: Text(label,
                style: const TextStyle(color: AppTheme.neutralColor, fontSize: 11)),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value:           pct.clamp(0.0, 1.0),
                minHeight:       4,
                backgroundColor: AppTheme.borderColor.withValues(alpha: 0.3),
                valueColor:      AlwaysStoppedAnimation(color),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text('$score/$maxScore',
              style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Greek grid card
// ═════════════════════════════════════════════════════════════════════════════

class _GreekGridCard extends StatelessWidget {
  final GreekGridPoint?                            atmCell;
  final ({double? first, double? last, int count}) trend;
  final ExpiryBucket                               bucket;
  final bool                                       loading;

  const _GreekGridCard({
    required this.atmCell,
    required this.trend,
    required this.bucket,
    required this.loading,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) return _LoadingCard('Loading greek grid…');
    if (atmCell == null && trend.count == 0) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionLabel('Greek Grid  ·  ${bucket.label}'),
              const SizedBox(height: 10),
              const Text(
                'No greek grid data yet — accumulates with each Schwab pull.',
                style: TextStyle(color: AppTheme.neutralColor, fontSize: 12, height: 1.4),
              ),
            ],
          ),
        ),
      );
    }

    final gammaRising = trend.count >= 2 &&
        trend.last != null && trend.first != null &&
        trend.last! > trend.first!;
    final trendColor = trend.count < 2 ? AppTheme.neutralColor
        : gammaRising ? AppTheme.profitColor : AppTheme.lossColor;
    final trendLabel = trend.count < 2 ? '—'
        : gammaRising ? '↑ Rising' : '↓ Falling';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionLabel('Greek Grid  ·  ${bucket.label}'),
            const SizedBox(height: 12),
            Row(
              children: [
                _GexStat('ATM Gamma 14d', trendLabel, '${trend.count} obs', trendColor),
                if (trend.count >= 2 && trend.first != null && trend.last != null) ...[
                  const SizedBox(width: 8),
                  _GexStat('Range',
                      '${trend.first!.toStringAsFixed(4)} → ${trend.last!.toStringAsFixed(4)}',
                      '', AppTheme.neutralColor),
                ],
              ],
            ),
            if (atmCell != null) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  if (atmCell!.iv != null)
                    _GexStat('ATM IV', '${(atmCell!.iv! * 100).toStringAsFixed(1)}%',
                        'Current snapshot', AppTheme.neutralColor),
                  if (atmCell!.vanna != null) ...[
                    const SizedBox(width: 8),
                    _GexStat('Vanna', atmCell!.vanna!.toStringAsFixed(5),
                        atmCell!.vanna! < 0 ? 'Δ↓ on IV↓' : 'Δ↑ on IV↑',
                        atmCell!.vanna! < 0 ? AppTheme.lossColor : AppTheme.profitColor),
                  ],
                  if (atmCell!.charm != null) ...[
                    const SizedBox(width: 8),
                    _GexStat('Charm', atmCell!.charm!.toStringAsFixed(5),
                        '${(atmCell!.charm!.abs() * 1000).toStringAsFixed(1)}‰/day',
                        AppTheme.neutralColor),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (atmCell!.openInterest != null)
                    _StatChip('OI', _fmtInt(atmCell!.openInterest!), AppTheme.neutralColor),
                  if (atmCell!.volume != null) ...[
                    const SizedBox(width: 6),
                    _StatChip('Vol', _fmtInt(atmCell!.volume!), AppTheme.neutralColor),
                  ],
                  const SizedBox(width: 6),
                  _StatChip('Contracts', '${atmCell!.contractCount}', AppTheme.neutralColor),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Realized vol card
// ═════════════════════════════════════════════════════════════════════════════

class _RealizedVolCard extends StatelessWidget {
  final RealizedVolSnapshot? rvData;
  final double               contractIv; // decimal
  final bool                 loading;

  const _RealizedVolCard({
    required this.rvData,
    required this.contractIv,
    required this.loading,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) return _LoadingCard('Loading realized vol…');
    final rv = rvData;
    if (rv == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionLabel('Realized Volatility'),
              const SizedBox(height: 10),
              const Text('No realized vol data for this ticker.',
                  style: TextStyle(color: AppTheme.neutralColor, fontSize: 12)),
            ],
          ),
        ),
      );
    }

    final ivPct = contractIv * 100;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionLabel('Realized Volatility'),
            const SizedBox(height: 12),
            Row(
              children: [
                if (rv.rv1d  != null) _RvCell('1d',  rv.rv1d!,  ivPct),
                if (rv.rv5d  != null) ...[const SizedBox(width: 6), _RvCell('5d',  rv.rv5d!,  ivPct)],
                if (rv.rv21d != null) ...[const SizedBox(width: 6), _RvCell('21d', rv.rv21d!, ivPct)],
                if (rv.rv63d != null) ...[const SizedBox(width: 6), _RvCell('63d', rv.rv63d!, ivPct)],
              ],
            ),
            if (rv.rv21d != null) ...[
              const SizedBox(height: 10),
              Builder(builder: (ctx) {
                final rvVal       = rv.rv21d!;
                final diff        = contractIv - rvVal;
                final premPp      = diff * 100;
                final isExpensive = contractIv > rvVal * 1.20;
                final isCheap     = contractIv < rvVal * 0.85;
                final color       = isExpensive ? AppTheme.lossColor
                    : isCheap ? AppTheme.profitColor : AppTheme.neutralColor;
                final label       = isExpensive
                    ? 'Options RICH — ${premPp.toStringAsFixed(1)}pp above 21d realized'
                    : isCheap
                        ? 'Options CHEAP — ${premPp.abs().toStringAsFixed(1)}pp below 21d realized'
                        : 'Options fairly priced vs 21d realized moves';
                return Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color:        color.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(7),
                    border:       Border.all(color: color.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isExpensive ? Icons.trending_up_rounded
                            : isCheap ? Icons.trending_down_rounded
                            : Icons.trending_flat_rounded,
                        size: 14, color: color,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(label,
                            style: TextStyle(color: color, fontSize: 11, height: 1.4)),
                      ),
                    ],
                  ),
                );
              }),
            ],
            if (rv.rv21dPct != null || rv.rv63dPct != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  if (rv.rv21dPct != null) ...[
                    const Text('21d pct  ',
                        style: TextStyle(color: AppTheme.neutralColor, fontSize: 11)),
                    Text('${rv.rv21dPct!.toStringAsFixed(0)}th',
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                  ],
                  if (rv.rv21dPct != null && rv.rv63dPct != null)
                    const Text('  ·  ',
                        style: TextStyle(color: AppTheme.neutralColor, fontSize: 11)),
                  if (rv.rv63dPct != null) ...[
                    const Text('63d pct  ',
                        style: TextStyle(color: AppTheme.neutralColor, fontSize: 11)),
                    Text('${rv.rv63dPct!.toStringAsFixed(0)}th',
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RvCell extends StatelessWidget {
  final String label;
  final double rv;    // decimal
  final double ivPct; // percent

  const _RvCell(this.label, this.rv, this.ivPct);

  @override
  Widget build(BuildContext context) {
    final rvPct = rv * 100;
    final diff  = ivPct - rvPct;
    final color = diff > 5 ? AppTheme.lossColor
        : diff < -5 ? AppTheme.profitColor
        : AppTheme.neutralColor;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppTheme.cardColor, borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: AppTheme.neutralColor, fontSize: 10)),
            const SizedBox(height: 3),
            Text('${rvPct.toStringAsFixed(1)}%',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
            Text('${diff >= 0 ? '+' : ''}${diff.toStringAsFixed(1)}pp vs IV',
                style: TextStyle(color: color, fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Beta-adjusted notional card
// ═════════════════════════════════════════════════════════════════════════════

class _BetaNotionalCard extends StatelessWidget {
  final String ticker;
  final double spot;
  final double delta;
  final int    qty;

  const _BetaNotionalCard({
    required this.ticker,
    required this.spot,
    required this.delta,
    required this.qty,
  });

  static double _betaFor(String t) {
    const betas = {
      'SPY': 1.00, 'SPX': 1.00, 'IWM': 1.10, 'DIA': 0.95, 'MDY': 1.05,
      'NVDA': 1.85, 'AMD': 1.90, 'TSLA': 1.75, 'META': 1.45, 'AAPL': 1.20,
      'MSFT': 1.15, 'GOOGL': 1.20, 'GOOG': 1.20, 'AMZN': 1.35,
      'AVGO': 1.50, 'MU': 1.80, 'AMAT': 1.65, 'LRCX': 1.60, 'KLAC': 1.55,
      'QCOM': 1.30, 'INTC': 1.25, 'CRM': 1.30, 'ADBE': 1.25,
      'QQQ': 1.15, 'XLK': 1.15, 'SMH': 1.60, 'SOXX': 1.60,
      'JPM': 1.15, 'BAC': 1.30, 'GS': 1.40, 'MS': 1.35, 'C': 1.30,
      'WFC': 1.20, 'BX': 1.35, 'KKR': 1.30,
      'NKE': 1.05, 'SBUX': 0.90, 'HD': 0.95, 'TGT': 1.00, 'LULU': 1.30,
      'WMT': 0.55, 'COST': 0.65, 'MCD': 0.65,
      'XOM': 0.85, 'CVX': 0.80, 'OXY': 1.40, 'COP': 1.10, 'XLE': 1.05,
      'XLU': 0.35, 'O': 0.50, 'AMT': 0.60,
      'VXX': -4.00, 'UVXY': -7.00, 'SVXY': 3.50, 'VIXY': -4.20,
    };
    return betas[t.toUpperCase()] ?? 1.00;
  }

  @override
  Widget build(BuildContext context) {
    final beta        = _betaFor(ticker);
    final deltaDollar = delta.abs() * spot * qty * 100;
    final betaAdj     = deltaDollar * beta;
    final Color adjColor;
    final String adjLabel;
    if (betaAdj < 5000)       { adjColor = AppTheme.profitColor;          adjLabel = 'LOW';      }
    else if (betaAdj < 15000) { adjColor = const Color(0xFF60A5FA);       adjLabel = 'MODERATE'; }
    else if (betaAdj < 30000) { adjColor = const Color(0xFFFBBF24);       adjLabel = 'ELEVATED'; }
    else                      { adjColor = AppTheme.lossColor;            adjLabel = 'HIGH';     }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionLabel('Beta-Adjusted Notional'),
            const SizedBox(height: 12),
            Row(
              children: [
                _GexStat('Δ Notional', '\$${_fmtK(deltaDollar)}',
                    '|Δ| ${delta.abs().toStringAsFixed(2)} × \$${spot.toStringAsFixed(0)} × $qty × 100',
                    AppTheme.neutralColor),
                const SizedBox(width: 8),
                _GexStat('Beta ($ticker)',
                    '${beta >= 0 ? '+' : ''}${beta.toStringAsFixed(2)}',
                    beta.abs() > 1.5 ? 'High beta' : 'Moderate beta',
                    beta.abs() > 1.5 ? const Color(0xFFFBBF24) : AppTheme.neutralColor),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color:        adjColor.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border:       Border.all(color: adjColor.withValues(alpha: 0.35)),
              ),
              child: Row(
                children: [
                  Text('\$${_fmtK(betaAdj)}',
                      style: TextStyle(color: adjColor, fontSize: 20,
                          fontWeight: FontWeight.w900, fontFamily: 'monospace')),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('$adjLabel — SPY-equivalent exposure',
                            style: TextStyle(color: adjColor, fontSize: 11,
                                fontWeight: FontWeight.w700)),
                        Text('Moves like \$${_fmtK(betaAdj)} of SPY when the market moves',
                            style: const TextStyle(color: AppTheme.neutralColor,
                                fontSize: 10, height: 1.3)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Number formatters ─────────────────────────────────────────────────────────

String _fmtInt(int n) =>
    n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';

String _fmtK(double v) {
  if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(2)}M';
  if (v >= 1000)    return '${(v / 1000).toStringAsFixed(1)}K';
  return v.toStringAsFixed(0);
}
