// =============================================================================
// services/kalshi/kalshi_service.dart
// =============================================================================
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../core/kalshi_config.dart';
import 'kalshi_models.dart';

class KalshiService {
  static final KalshiService _instance = KalshiService._();
  KalshiService._();
  factory KalshiService() => _instance;

  final _client = http.Client();

  Uri _url(String path, [Map<String, String>? params]) {
    return Uri.parse('${KalshiConfig.baseUrl}$path')
        .replace(queryParameters: params);
  }

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${KalshiConfig.accessKey}',
        'Content-Type': 'application/json',
      };

  // ── Series ─────────────────────────────────────────────────────────────────

  /// Fetches all series (broad market categories like FOMC, CPI, NFP, etc.).
  /// Results are stable enough to cache for the session via FutureProvider.
  Future<List<KalshiSeries>> getSeries({int limit = 200}) async {
    final res = await _client.get(
      _url('/series', {'limit': '$limit'}),
      headers: _headers,
    );
    if (res.statusCode != 200) {
      throw Exception('Kalshi series ${res.statusCode}: ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final list = body['series'] as List? ?? [];
    return list
        .map((e) => KalshiSeries.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ── Events ─────────────────────────────────────────────────────────────────

  /// Fetches events. Pass [withNestedMarkets] = true to include
  /// Yes/No prices for each market nested inside the event — required
  /// for the Event Sentiment and options-chain overlay features.
  Future<List<KalshiEvent>> getEvents({
    String? seriesTicker,
    String? status,
    bool withNestedMarkets = false,
    int limit = 100,
  }) async {
    final params = <String, String>{'limit': '$limit'};
    if (seriesTicker != null) params['series_ticker'] = seriesTicker;
    if (status != null) params['status'] = status;
    if (withNestedMarkets) params['with_nested_markets'] = 'true';

    final res =
        await _client.get(_url('/events', params), headers: _headers);
    if (res.statusCode != 200) {
      throw Exception('Kalshi events ${res.statusCode}: ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final list = body['events'] as List? ?? [];
    return list
        .map((e) => KalshiEvent.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ── Markets ────────────────────────────────────────────────────────────────

  Future<List<KalshiMarket>> getMarkets({
    String? eventTicker,
    String? status,
    int limit = 100,
  }) async {
    final params = <String, String>{'limit': '$limit'};
    if (eventTicker != null) params['event_ticker'] = eventTicker;
    if (status != null) params['status'] = status;
    final res =
        await _client.get(_url('/markets', params), headers: _headers);
    if (res.statusCode != 200) {
      throw Exception('Kalshi markets ${res.statusCode}: ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final list = body['markets'] as List? ?? [];
    return list
        .map((e) => KalshiMarket.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ── Orderbook ──────────────────────────────────────────────────────────────

  Future<KalshiOrderbook> getOrderbook(String ticker) async {
    final res = await _client.get(
      _url('/markets/$ticker/orderbook'),
      headers: _headers,
    );
    if (res.statusCode != 200) {
      throw Exception('Kalshi orderbook ${res.statusCode}: ${res.body}');
    }
    return KalshiOrderbook.fromJson(
        ticker, jsonDecode(res.body) as Map<String, dynamic>);
  }

  // ── Single event ───────────────────────────────────────────────────────────

  Future<KalshiEvent> getEvent(String eventTicker) async {
    final res = await _client.get(
      _url('/events/$eventTicker'),
      headers: _headers,
    );
    if (res.statusCode != 200) {
      throw Exception('Kalshi event ${res.statusCode}: ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return KalshiEvent.fromJson(body['event'] as Map<String, dynamic>);
  }

  // ── Trades ─────────────────────────────────────────────────────────────────

  Future<List<KalshiTrade>> getTrades(String ticker,
      {int limit = 100}) async {
    final res = await _client.get(
      _url('/markets/$ticker/trades', {'limit': '$limit'}),
      headers: _headers,
    );
    if (res.statusCode != 200) {
      throw Exception('Kalshi trades ${res.statusCode}: ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final list = body['trades'] as List? ?? [];
    return list
        .map((e) => KalshiTrade.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
