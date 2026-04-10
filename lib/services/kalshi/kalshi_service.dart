// =============================================================================
// services/kalshi/kalshi_service.dart
// =============================================================================
// All Kalshi calls go through the Supabase Edge Function 'get-kalshi-data'
// to avoid CORS on Flutter Web. The edge function forwards to
// api.elections.kalshi.com/trade-api/v2 and injects the API key server-side.
// =============================================================================
import 'package:supabase_flutter/supabase_flutter.dart';
import 'kalshi_models.dart';

class KalshiService {
  static final KalshiService _instance = KalshiService._();
  KalshiService._();
  factory KalshiService() => _instance;

  FunctionsClient get _fn => Supabase.instance.client.functions;

  Future<Map<String, dynamic>> _get(
    String path, [
    Map<String, String>? params,
  ]) async {
    try {
      final body = {'path': path, 'params': params ?? <String, String>{}};

      final res = await _fn.invoke('get-kalshi-data', body: body);

      if (res.status != 200) {
        throw Exception('Kalshi $path ${res.status}');
      }

      final data = res.data;
      if (data is Map<String, dynamic> && data.containsKey('error')) {
        throw Exception('Kalshi $path: ${data['error']}');
      }
      return data as Map<String, dynamic>;
    } catch (e) {
      print('Kalshi API Error: $e');
      rethrow;
    }
  }

  // ── Series ─────────────────────────────────────────────────────────────────

  Future<List<KalshiSeries>> getSeries({int limit = 200}) async {
    final body = await _get('/series', {'limit': '$limit'});
    final list = body['series'] as List? ?? [];
    return list
        .map((e) => KalshiSeries.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ── Events ─────────────────────────────────────────────────────────────────

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

    final body = await _get('/events', params);
    final list = body['events'] as List? ?? [];
    return list
        .map((e) => KalshiEvent.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ── Single event ───────────────────────────────────────────────────────────

  Future<KalshiEvent> getEvent(String eventTicker) async {
    final body = await _get('/events/$eventTicker');
    final eventMap = Map<String, dynamic>.from(
      body['event'] as Map<String, dynamic>,
    );
    eventMap['markets'] = body['markets'] ?? [];
    return KalshiEvent.fromJson(eventMap);
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

    final body = await _get('/markets', params);
    final list = body['markets'] as List? ?? [];
    return list
        .map((e) => KalshiMarket.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ── Orderbook ──────────────────────────────────────────────────────────────

  Future<KalshiOrderbook> getOrderbook(String ticker) async {
    final body = await _get('/markets/$ticker/orderbook');
    return KalshiOrderbook.fromJson(ticker, body);
  }

  // ── Trades ─────────────────────────────────────────────────────────────────

  Future<List<KalshiTrade>> getTrades(String ticker, {int limit = 100}) async {
    final body = await _get('/markets/$ticker/trades', {'limit': '$limit'});
    final list = body['trades'] as List? ?? [];
    return list
        .map((e) => KalshiTrade.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
