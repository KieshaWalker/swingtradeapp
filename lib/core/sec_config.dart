// =============================================================================
// core/sec_config.dart — SEC Filing Data API configuration
// =============================================================================
// Consumed by:
//   • SecService (services/sec/sec_service.dart) — baseUrl & apiKey for all
//     SEC EDGAR HTTP requests
//
// Features powered by SEC API:
//   • _SecFilingsSection in TradeDetailScreen  (secFilingsForTickerProvider)
//   • _SearchTab in ResearchScreen             (secSearchProvider)
//   • _RecentEventsTab in ResearchScreen       (secRecentEventsProvider)
//
// Key injection: pass --dart-define=SEC_API_KEY=<key> at build time.
// =============================================================================
class SecConfig {
  static const String baseUrl = 'https://api.secfilingdata.com';
  static const String apiKey = String.fromEnvironment('SEC_API_KEY');
}

