// =============================================================================
// services/economy/economy_snapshot_models.dart
// =============================================================================
// Models for rows stored in the three economy snapshot tables:
//   economy_quote_snapshots       → QuoteSnapshot
//   economy_treasury_snapshots    → TreasurySnapshot
//
// EconomicIndicatorPoint (from schwab_models.dart) is reused directly for
// economy_indicator_snapshots rows.
// =============================================================================
import '../schwab/schwab_models.dart';

// ── Treasury yield curve snapshot ─────────────────────────────────────────────

class TreasuryRates {
  final DateTime date;
  final double? year1;
  final double? year2;
  final double? year5;
  final double? year10;
  final double? year20;
  final double? year30;

  const TreasuryRates({
    required this.date,
    this.year1,
    this.year2,
    this.year5,
    this.year10,
    this.year20,
    this.year30,
  });
}

// ── Composite economy pulse snapshot (Schwab quotes + economic indicators) ────
// Economic indicator fields are nullable — populated separately via BLS/BEA/FRED.

class EconomyPulseData {
  final DateTime fetchedAt;
  // Market quotes (from Schwab)
  final StockQuote? sp500;
  final StockQuote? nasdaq;
  final StockQuote? vix;
  final StockQuote? dxy;
  final StockQuote? gold;
  final StockQuote? silver;
  final StockQuote? wtiCrude;
  final StockQuote? natGas;
  final StockQuote? hyg;
  final StockQuote? lqd;
  final StockQuote? copx;
  // Treasury yields
  final TreasuryRates? treasury;
  // Economic indicators (null — shown in BLS/BEA/EIA/FRED tabs)
  final EconomicIndicatorPoint? fedFunds;
  final EconomicIndicatorPoint? unemployment;
  final EconomicIndicatorPoint? nfp;
  final EconomicIndicatorPoint? initialClaims;
  final EconomicIndicatorPoint? cpi;
  final EconomicIndicatorPoint? gdp;
  final EconomicIndicatorPoint? retailSales;
  final EconomicIndicatorPoint? consumerSentiment;
  final EconomicIndicatorPoint? mortgageRate;
  final EconomicIndicatorPoint? housingStarts;
  final EconomicIndicatorPoint? recessionProb;

  const EconomyPulseData({
    required this.fetchedAt,
    this.sp500,
    this.nasdaq,
    this.vix,
    this.dxy,
    this.gold,
    this.silver,
    this.wtiCrude,
    this.natGas,
    this.hyg,
    this.lqd,
    this.copx,
    this.treasury,
    this.fedFunds,
    this.unemployment,
    this.nfp,
    this.initialClaims,
    this.cpi,
    this.gdp,
    this.retailSales,
    this.consumerSentiment,
    this.mortgageRate,
    this.housingStarts,
    this.recessionProb,
  });
}

// ─────────────────────────────────────────────────────────────────────────────

class QuoteSnapshot {
  final String symbol;
  final DateTime date;
  final double price;
  final double changePercent;

  const QuoteSnapshot({
    required this.symbol,
    required this.date,
    required this.price,
    required this.changePercent,
  });

  factory QuoteSnapshot.fromRow(Map<String, dynamic> r) => QuoteSnapshot(
        symbol: r['symbol'] as String,
        date: DateTime.parse(r['date'] as String),
        price: (r['price'] as num).toDouble(),
        changePercent: (r['change_percent'] as num).toDouble(),
      );
}

// One monthly US unemployment rate point from us_unemployment_rate_history.
class UnemploymentRatePoint {
  final DateTime date;
  final double rate; // percent, e.g. 4.2

  const UnemploymentRatePoint({required this.date, required this.rate});
}

// One weekly US retail gasoline price point from us_gasoline_price_history.
class GasolinePricePoint {
  final DateTime date;
  final double price; // $/gallon

  const GasolinePricePoint({required this.date, required this.price});
}

// One month of natural gas import price data, flattened from the
// wide us_natural_gas_import_prices table (year × month columns).
class NatGasImportPoint {
  final DateTime date;
  final double price; // $/MMBTU

  const NatGasImportPoint({required this.date, required this.price});
}

class TreasurySnapshot {
  final DateTime date;
  final double? year1;
  final double? year2;
  final double? year5;
  final double? year10;
  final double? year20;
  final double? year30;

  const TreasurySnapshot({
    required this.date,
    this.year1,
    this.year2,
    this.year5,
    this.year10,
    this.year20,
    this.year30,
  });

  factory TreasurySnapshot.fromRow(Map<String, dynamic> r) => TreasurySnapshot(
        date: DateTime.parse(r['date'] as String),
        year1: (r['year1'] as num?)?.toDouble(),
        year2: (r['year2'] as num?)?.toDouble(),
        year5: (r['year5'] as num?)?.toDouble(),
        year10: (r['year10'] as num?)?.toDouble(),
        year20: (r['year20'] as num?)?.toDouble(),
        year30: (r['year30'] as num?)?.toDouble(),
      );
}
