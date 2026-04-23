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
// FredSeries / FredObservation
//   → FredService.getSeries(seriesId)
//   → fredVixProvider, fredGoldProvider, fredSilverProvider,
//     fredHyOasProvider, fredIgOasProvider, fredSpreadProvider, fredFedFundsProvider
//   → FredTab (economy/widgets/fred_tab.dart) — historical line charts
//   → macroScoreProvider (services/macro/macro_score_provider.dart) → POST /macro/score

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
  static const vix      = 'VIXCLS';
  static const gold     = 'GOLDAMGBD228NLBM';
  static const silver   = 'SLVPRUSD';
  static const hyOas    = 'BAMLH0A0HYM2';
  static const igOas    = 'BAMLC0A0CM';
  static const spread2s10s = 'T10Y2Y';
  static const fedFunds = 'DFF';
}

// Identifier constants used when storing to economy_indicator_snapshots
abstract class FredStorageIds {
  static const hyOas       = 'fred_bamlh0a0hym2';
  static const igOas       = 'fred_bamlc0a0cm';
  static const spread2s10s = 'fred_t10y2y';
  static const fedFunds    = 'fred_dff';
}
