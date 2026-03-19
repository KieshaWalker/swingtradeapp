import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../core/sec_config.dart';
import 'sec_models.dart';

class SecService {
  static final SecService _instance = SecService._();
  SecService._();
  factory SecService() => _instance;

  final _client = http.Client();

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Authorization': SecConfig.apiKey,
      };

  /// Fetch recent filings for a given ticker symbol.
  Future<List<SecFiling>> getFilingsForTicker(
    String ticker, {
    List<String> formTypes = const ['10-K', '10-Q', '8-K', '4'],
    int limit = 20,
  }) async {
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
        Uri.parse('${SecConfig.baseUrl}/live-query-api'),
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
  Future<List<SecFiling>> searchFilings(
    String query, {
    int limit = 20,
  }) async {
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
        Uri.parse('${SecConfig.baseUrl}/live-query-api'),
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
  Future<List<SecFiling>> getRecentEvents({int limit = 30}) async {
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
        Uri.parse('${SecConfig.baseUrl}/live-query-api'),
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
