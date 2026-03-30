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
    final query = {
      'key': KalshiConfig.accessKey,
      ...?params,
    };
    return Uri.parse('${KalshiConfig.baseUrl}$path').replace(queryParameters: query);
  }

  Map<String, String> get _headers => {
    'Authorization': 'Bearer ${KalshiConfig.accessKey}',
    'Content-Type': 'application/json',
  };

  Future<List<KalshiMarket>> getMarkets({String? eventTicker, String? status, int limit = 100}) async {
    final params = <String, String>{'limit': '$limit'};
    if (eventTicker != null) params['event_ticker'] = eventTicker;
    if (status != null) params['status'] = status;
    final res = await _client.get(_url('/markets', params), headers: _headers);
    if (res.statusCode != 200) throw Exception('Kalshi markets ${res.statusCode}');
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final list = body['markets'] as List? ?? [];
    return list.map((e) => KalshiMarket.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<KalshiOrderbook> getOrderbook(String ticker) async {
    final res = await _client.get(_url('/markets/$ticker/orderbook'), headers: _headers);
    if (res.statusCode != 200) throw Exception('Kalshi orderbook ${res.statusCode}');
    return KalshiOrderbook.fromJson(ticker, jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<KalshiEvent> getEvent(String eventTicker) async {
    final res = await _client.get(_url('/events/$eventTicker'), headers: _headers);
    if (res.statusCode != 200) throw Exception('Kalshi event ${res.statusCode}');
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return KalshiEvent.fromJson(body['event'] as Map<String, dynamic>);
  }

  Future<List<KalshiTrade>> getTrades(String ticker, {int limit = 100}) async {
    final res = await _client.get(
      _url('/markets/$ticker/trades', {'limit': '$limit'}),
      headers: _headers,
    );
    if (res.statusCode != 200) throw Exception('Kalshi trades ${res.statusCode}');
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final list = body['trades'] as List? ?? [];
    return list.map((e) => KalshiTrade.fromJson(e as Map<String, dynamic>)).toList();
  }
}
