// =============================================================================
// services/sec/sec_service.dart — SEC EDGAR HTTP client
// =============================================================================
// Singleton service; accessed via secServiceProvider (sec_providers.dart).
// Uses Elasticsearch query syntax against the SEC Filing Data API.
//
// Methods & where they are used:
//   • getFilingsForTicker(ticker, formTypes, limit)
//       → secFilingsForTickerProvider
//       → TradeDetailScreen (_SecFilingsSection) — shows recent 10-K/10-Q/8-K/4
//         filings for the trade's ticker symbol
//
//   • searchFilings(query, limit)
//       → secSearchProvider
//       → ResearchScreen (_SearchTab) — free-text search across 18M+ filings
//
//   • getRecentEvents(limit)
//       → secRecentEventsProvider
//       → ResearchScreen (_RecentEventsTab) — recent 8-K market events feed
//
// Config: SecConfig.baseUrl + SecConfig.apiKey (core/sec_config.dart)
// Models: SecFiling (sec_models.dart)
// =============================================================================
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../core/sec_config.dart';
import 'sec_models.dart';

class SecService {
  static final SecService _instance = SecService._();
  SecService._();
  factory SecService() => _instance;

  final _client = http.Client();

  // sec-api.io authenticates via ?token= query param, not Authorization header.
  Uri get _endpoint => Uri.parse(SecConfig.baseUrl)
      .replace(queryParameters: {'token': SecConfig.apiKey});

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
      };

  /// Fetch recent filings for a given ticker symbol.
  /// API maximum is 50 filings per request.
  Future<List<SecFiling>> getFilingsForTicker(
    String ticker, {
    List<String> formTypes = const ['10-K', '10-Q', '8-K', '4'],
    int limit = 20,
  }) async {
    assert(limit <= 50, 'SEC API maximum size is 50');
    try {
      final formTypeFilter = formTypes.map((f) => '"$f"').join(' OR ');
      final body = jsonEncode({
        'query': {
          'query_string': {
            'query': 'ticker:$ticker AND formType:($formTypeFilter)',
          },
        },
        'from': '0',
        'size': '$limit',
        'sort': [
          {
            'filedAt': {'order': 'desc'},
          },
        ],
      });

      final res = await _client.post(
        _endpoint,
        headers: _headers,
        body: body,
      );

      if (res.statusCode != 200) return [];
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final filings = json['filings'] as List?;
      if (filings == null) return [];

      return filings
          .map((e) => SecFiling.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Search filings by free-text query (company name, form type, etc.)
  /// API maximum is 50 filings per request.
  Future<List<SecFiling>> searchFilings(
    String query, {
    int limit = 20,
  }) async {
    assert(limit <= 50, 'SEC API maximum size is 50');
    try {
      final body = jsonEncode({
        'query': {
          'query_string': {
            'query': query,
          },
        },
        'from': '0',
        'size': '$limit',
        'sort': [
          {
            'filedAt': {'order': 'desc'},
          },
        ],
      });

      final res = await _client.post(
        _endpoint,
        headers: _headers,
        body: body,
      );

      if (res.statusCode != 200) return [];
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final filings = json['filings'] as List?;
      if (filings == null) return [];

      return filings
          .map((e) => SecFiling.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Get recent 8-K filings across all tickers (market events feed)
  /// API maximum is 50 filings per request.
  Future<List<SecFiling>> getRecentEvents({int limit = 30}) async {
    assert(limit <= 50, 'SEC API maximum size is 50');
    try {
      final body = jsonEncode({
        'query': {
          'query_string': {
            'query': 'formType:"8-K"',
          },
        },
        'from': '0',
        'size': '$limit',
        'sort': [
          {
            'filedAt': {'order': 'desc'},
          },
        ],
      });

      final res = await _client.post(
        _endpoint,
        headers: _headers,
        body: body,
      );

      if (res.statusCode != 200) return [];
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final filings = json['filings'] as List?;
      if (filings == null) return [];

      return filings
          .map((e) => SecFiling.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }
}
