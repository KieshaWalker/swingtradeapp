class KalshiConfig {
  static const String accessKey = String.fromEnvironment('KALSHI-ACCESS-KEY');
  static const String email = String.fromEnvironment('KALSHI_EMAIL');
  static const String password = String.fromEnvironment('KALSHI_PASSWORD');
  static const String baseUrl = 'https://api.elections.kalshi.com/trade-api/v2';
}

class FredConfig {
  static const String apiKey = String.fromEnvironment('FRED_API_KEY');
  static const String baseUrl = 'https://api.stlouisfed.org/fred';
}

class BeaConfig {
  static const String apiKey = String.fromEnvironment('BEA_API_KEY');
  static const String baseUrl = 'https://apps.bea.gov/api/data';
}

class BlsConfig {
  static const String apiKey = String.fromEnvironment('BLS_API_KEY');
  static const String baseUrl = 'https://api.bls.gov/publicAPI/v2';
}

class ApifyConfig {
  static const String apiKey = String.fromEnvironment('APIFY_API_KEY');
  static const String baseUrl = 'https://api.apify.com/v2';
}

// USAspending is a public API — no key required
class UsaSpendingConfig {
  static const String baseUrl = 'https://api.usaspending.gov/api/v2';
}

class EiaConfig {
  static const String apiKey = String.fromEnvironment('EIA_API_KEY');
  static const String baseUrl = 'https://api.eia.gov/v2';
}

class CensusConfig {
  static const String apiKey = String.fromEnvironment('CENSUS_API_KEY');
  static const String baseUrl = 'https://api.census.gov/data';
}
