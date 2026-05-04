// =============================================================================
// services/fred/fred_models.dart
// =============================================================================
// Endpoint: https://api.stlouisfed.org/fred/series/observations
//   via Supabase Edge Function: get-fred-data
//   (direct FRED calls are proxied to keep the API key server-side)
// Auth: api_key= query param via FRED_API_KEY secret (set in Supabase)
// Response shape: { observations: [ { date: "YYYY-MM-DD", value: "14.5" } ] }
//   Missing values come as "." and are skipped in FredService._parse().
//
// This module defines FRED series constants and value models for all FRED data
// used by the app. If a new series is introduced, update:
//   lib/services/fred/fred_providers.dart -> provider for the series
//   lib/services/fred/fred_service.dart   -> getSeries() parsing behavior
//   lib/services/fred/fred_storage_service.dart -> saved storage contract
//   lib/services/fred/fred_models.dart        -> FredSeriesIds and FredStorageIds
//   lib/services/macro/macro_score_provider.dart -> macro score consumers
//
// The FRED IDs here are also referenced by Supabase storage and UI chart logic.
// =============================================================================

class FredObservation {
  final DateTime date;
  final double value;

  const FredObservation({required this.date, required this.value});
}

class FredSeries {
  final String seriesId;
  final List<FredObservation> observations;

  const FredSeries({required this.seriesId, required this.observations});
}

// FRED series IDs used in this app
abstract class FredSeriesIds {
  // Existing — charts + macro score
  static const vix         = 'VIXCLS';
  static const gold        = 'GOLDAMGBD228NLBM';
  static const silver      = 'SLVPRUSD';
  static const hyOas       = 'BAMLH0A0HYM2';
  static const igOas       = 'BAMLC0A0CM';
  static const spread2s10s = 'T10Y2Y';
  static const fedFunds    = 'DFF';

  // Snapshot — interest rates
  static const mortgageRate30y = 'MORTGAGE30US';
  static const treasury1y      = 'GS1';
  static const treasury2y      = 'GS2';
  static const treasury5y      = 'GS5';
  static const treasury10y     = 'GS10';
  static const treasury20y     = 'GS20';
  static const treasury30y     = 'GS30';

  // Snapshot — commodities (daily spot/fix prices)
  static const crudeOilWti    = 'DCOILWTICO';
  static const natGasHenryHub = 'DHHNGSP';

  // Snapshot — labor market
  static const unemploymentRate    = 'UNRATE';
  static const nonfarmPayrolls     = 'PAYEMS';
  static const initialClaims       = 'ICSA';
  static const consumerSentiment   = 'UMCSENT';

  // Snapshot — economy
  static const cpiAllItems   = 'CPIAUCSL';
  static const realGdp       = 'GDPC1';
  static const retailSales   = 'RSXFS';
  static const recessionProb = 'RECPROUSM156N';

  // Snapshot — housing
  static const housingStarts = 'HOUST';
}

// Identifier constants used when storing to economy_indicator_snapshots
abstract class FredStorageIds {
  // Existing
  static const hyOas       = 'fred_bamlh0a0hym2';
  static const igOas       = 'fred_bamlc0a0cm';
  static const spread2s10s = 'fred_t10y2y';
  static const fedFunds    = 'fred_dff';

  // New snapshot indicators
  static const mortgageRate30y = 'fred_mortgage30y';
  static const treasury1y      = 'fred_gs1';
  static const treasury2y      = 'fred_gs2';
  static const treasury5y      = 'fred_gs5';
  static const treasury10y     = 'fred_gs10';
  static const treasury20y     = 'fred_gs20';
  static const treasury30y     = 'fred_gs30';
  static const crudeOilWti     = 'fred_dcoilwtico';
  static const natGasHenryHub  = 'fred_dhhngsp';
  static const unemploymentRate  = 'fred_unrate';
  static const nonfarmPayrolls   = 'fred_payems';
  static const initialClaims     = 'fred_icsa';
  static const consumerSentiment = 'fred_umcsent';
  static const cpiAllItems       = 'fred_cpiaucsl';
  static const realGdp           = 'fred_gdpc1';
  static const retailSales       = 'fred_rsxfs';
  static const recessionProb     = 'fred_recprousm156n';
  static const housingStarts     = 'fred_houst';
}
