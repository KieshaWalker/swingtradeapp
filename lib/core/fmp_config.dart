// =============================================================================
// core/fmp_config.dart — Financial Modeling Prep API configuration
// =============================================================================
// Consumed by:
//   • FmpService (services/fmp/fmp_service.dart) — baseUrl & apiKey for all
//     FMP HTTP requests
//
// Features powered by FMP:
//   • Ticker autocomplete in AddTradeScreen  (tickerSearchProvider)
//   • Live stock quote in TradeDetailScreen  (quoteProvider)
//   • Live price in DashboardScreen open positions (_OpenTradeRow → quoteProvider)
//
// Key injection: pass --dart-define=FMP_API_KEY=<key> at build time.
// =============================================================================
class FmpConfig {
  static const String baseUrl = 'https://financialmodelingprep.com/stable';
  static const String apiKey = String.fromEnvironment(
    'FMP_API_KEY',
    defaultValue: 'wwUPq2ualtz00o9DCrJqYRFyZLWHZiI6',
  );
}
