// =============================================================================
// features/blotter/models/blotter_models.dart
// =============================================================================
import 'package:flutter/material.dart';

// ── Lifecycle stages ──────────────────────────────────────────────────────────

enum TradeStatus {
  draft,
  validated,
  committed,
  sent;

  String get label => switch (this) {
        draft     => 'DRAFT',
        validated => 'VALIDATED',
        committed => 'DB COMMITTED',
        sent      => 'TRANSMITTED',
      };

  Color get color => switch (this) {
        draft     => const Color(0xFF94A3B8),
        validated => const Color(0xFFFBBF24),
        committed => const Color(0xFF60A5FA),
        sent      => const Color(0xFF4ADE80),
      };

  int get step => index;
}

// ── Contract type ─────────────────────────────────────────────────────────────

enum ContractType {
  call,
  put;

  String get label => name.toUpperCase();
}

// ── Strategy taxonomy ─────────────────────────────────────────────────────────

enum StrategyTag {
  netLongPremium('Net-Long Premium'),
  netShortPremium('Net-Short Premium'),
  tailHedge('Tail Hedge'),
  volArbitrage('Volatility Arbitrage'),
  deltaNeutral('Delta Neutral'),
  gammaScalp('Gamma Scalp'),
  skewTrade('Skew Trade'),
  calendarSpread('Calendar Spread');

  final String label;
  const StrategyTag(this.label);
}

// ── Fair value result ─────────────────────────────────────────────────────────

class FairValueResult {
  final double bsFairValue;
  final double sabrFairValue;
  final double modelFairValue; // SABR + Heston correction
  final double brokerMid;
  final double edgeBps;
  final double sabrVol;
  final double impliedVol;

  const FairValueResult({
    required this.bsFairValue,
    required this.sabrFairValue,
    required this.modelFairValue,
    required this.brokerMid,
    required this.edgeBps,
    required this.sabrVol,
    required this.impliedVol,
  });

  /// Positive edge = model thinks contract is cheap vs broker → buy signal.
  bool get isBuySignal => edgeBps > 5;
  bool get isSellSignal => edgeBps < -5;

  String get edgeLabel {
    if (edgeBps > 20)  return 'STRONG BUY';
    if (edgeBps > 5)   return 'BUY';
    if (edgeBps < -20) return 'STRONG SELL';
    if (edgeBps < -5)  return 'SELL';
    return 'FAIR';
  }

  Color get edgeColor {
    if (edgeBps > 10)  return const Color(0xFF4ADE80);
    if (edgeBps > 0)   return const Color(0xFF86EFAC);
    if (edgeBps < -10) return const Color(0xFFFF6B8A);
    if (edgeBps < 0)   return const Color(0xFFFFB3C1);
    return const Color(0xFFA09FC8);
  }
}

// ── Portfolio state ───────────────────────────────────────────────────────────

class PortfolioState {
  final double totalDelta;  // aggregate position delta
  final double totalVega;
  final double totalEs95;   // $ Expected Shortfall
  final int    openPositions;

  const PortfolioState({
    required this.totalDelta,
    required this.totalVega,
    required this.totalEs95,
    required this.openPositions,
  });

  static const empty = PortfolioState(
      totalDelta: 0, totalVega: 0, totalEs95: 0, openPositions: 0);
}

// ── Pre-trade What-If result ──────────────────────────────────────────────────

class WhatIfResult {
  final double deltaImpact;
  final double vegaImpact;
  final double es95Impact;
  final double newDelta;
  final double newVega;
  final double newEs95;
  final bool   exceedsDeltaThreshold;
  final double deltaThreshold;

  const WhatIfResult({
    required this.deltaImpact,
    required this.vegaImpact,
    required this.es95Impact,
    required this.newDelta,
    required this.newVega,
    required this.newEs95,
    required this.exceedsDeltaThreshold,
    required this.deltaThreshold,
  });
}

// ── Staged trade record ───────────────────────────────────────────────────────

class BlotterTrade {
  final String?       id;
  final String        symbol;
  final double        strike;
  final String        expiration;
  final ContractType  contractType;
  final int           quantity;
  final StrategyTag   strategyTag;
  final String?       notes;
  final TradeStatus   status;
  final DateTime      createdAt;

  // Validation output
  final FairValueResult? fairValueResult;
  final WhatIfResult?    whatIfResult;

  // Greeks
  final double? delta;
  final double? gamma;
  final double? theta;
  final double? vega;
  final double? underlyingPrice;

  const BlotterTrade({
    this.id,
    required this.symbol,
    required this.strike,
    required this.expiration,
    required this.contractType,
    required this.quantity,
    required this.strategyTag,
    this.notes,
    this.status = TradeStatus.draft,
    required this.createdAt,
    this.fairValueResult,
    this.whatIfResult,
    this.delta,
    this.gamma,
    this.theta,
    this.vega,
    this.underlyingPrice,
  });

  BlotterTrade copyWith({
    String?        id,
    TradeStatus?   status,
    FairValueResult? fairValueResult,
    WhatIfResult?    whatIfResult,
    double? delta, double? gamma, double? theta, double? vega,
    double? underlyingPrice,
  }) =>
      BlotterTrade(
        id:              id              ?? this.id,
        symbol:          symbol,
        strike:          strike,
        expiration:      expiration,
        contractType:    contractType,
        quantity:        quantity,
        strategyTag:     strategyTag,
        notes:           notes,
        status:          status          ?? this.status,
        createdAt:       createdAt,
        fairValueResult: fairValueResult ?? this.fairValueResult,
        whatIfResult:    whatIfResult    ?? this.whatIfResult,
        delta:           delta           ?? this.delta,
        gamma:           gamma           ?? this.gamma,
        theta:           theta           ?? this.theta,
        vega:            vega            ?? this.vega,
        underlyingPrice: underlyingPrice ?? this.underlyingPrice,
      );

  Map<String, dynamic> toJson() => {
        'symbol':                 symbol,
        'strike':                 strike,
        'expiration':             expiration,
        'contract_type':          contractType.name,
        'quantity':               quantity,
        'strategy_tag':           strategyTag.label,
        'notes':                  notes,
        'status':                 status.name,
        'broker_mid':             fairValueResult?.brokerMid,
        'bs_fair_value':          fairValueResult?.bsFairValue,
        'sabr_fair_value':        fairValueResult?.sabrFairValue,
        'model_fair_value':       fairValueResult?.modelFairValue,
        'edge_bps':               fairValueResult?.edgeBps,
        'implied_vol':            fairValueResult?.impliedVol,
        'sabr_vol':               fairValueResult?.sabrVol,
        'delta':                  delta,
        'gamma':                  gamma,
        'theta':                  theta,
        'vega':                   vega,
        'underlying_price':       underlyingPrice,
        'portfolio_delta_before': whatIfResult != null
            ? whatIfResult!.newDelta - whatIfResult!.deltaImpact
            : null,
        'portfolio_delta_after':  whatIfResult?.newDelta,
        'portfolio_vega_before':  whatIfResult != null
            ? whatIfResult!.newVega - whatIfResult!.vegaImpact
            : null,
        'portfolio_vega_after':   whatIfResult?.newVega,
        'es95_before':            whatIfResult != null
            ? whatIfResult!.newEs95 - whatIfResult!.es95Impact
            : null,
        'es95_after':             whatIfResult?.newEs95,
      };

  static BlotterTrade fromJson(Map<String, dynamic> j) => BlotterTrade(
        id:           j['id'] as String?,
        symbol:       j['symbol'] as String,
        strike:       (j['strike'] as num).toDouble(),
        expiration:   j['expiration'] as String,
        contractType: j['contract_type'] == 'call'
            ? ContractType.call
            : ContractType.put,
        quantity:     j['quantity'] as int,
        strategyTag:  StrategyTag.values.firstWhere(
            (s) => s.label == j['strategy_tag'],
            orElse: () => StrategyTag.deltaNeutral),
        notes:        j['notes'] as String?,
        status:       TradeStatus.values.firstWhere(
            (s) => s.name == j['status'],
            orElse: () => TradeStatus.draft),
        createdAt: DateTime.parse(j['created_at'] as String),
        delta:           (j['delta']            as num?)?.toDouble(),
        gamma:           (j['gamma']            as num?)?.toDouble(),
        theta:           (j['theta']            as num?)?.toDouble(),
        vega:            (j['vega']             as num?)?.toDouble(),
        underlyingPrice: (j['underlying_price'] as num?)?.toDouble(),
      );
}
