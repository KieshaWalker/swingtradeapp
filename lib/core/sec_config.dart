class SecConfig {
  static const String baseUrl = 'https://api.secfilingdata.com';
  static const String apiKey = String.fromEnvironment(
    'SEC_API_KEY',
    defaultValue: 'YOUR_SEC_API_KEY_HERE',
  );
}
