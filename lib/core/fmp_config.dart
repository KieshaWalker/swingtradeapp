class FmpConfig {
  static const String baseUrl = 'https://financialmodelingprep.com/stable';
  static const String apiKey = String.fromEnvironment(
    'FMP_API_KEY',
    defaultValue: 'wwUPq2ualtz00o9DCrJqYRFyZLWHZiI6',
  );
}
