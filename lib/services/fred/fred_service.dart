// =============================================================================
// services/fred/fred_service.dart
// =============================================================================
// HTTP client for the FRED (Federal Reserve Economic Data) API.
//
// Endpoint used:
//   GET /series/observations
//     ?series_id=VIXCLS
//     &api_key=...
//     &file_type=json
//     &limit=500
//     &sort_order=desc        ← newest first
//     &observation_start=...  ← optional date filter
//
// Response:
//   { "observations": [ {"date":"2024-01-02","value":"14.5"}, ... ] }
//   Missing values are represented as "." — these are skipped.
// =============================================================================
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../core/kalshi_config.dart';
import 'fred_models.dart';

class FredService {
  static final FredService _instance = FredService._();
  FredService._();
  factory FredService() => _instance;

  final _client = http.Client();

  /// Fetch up to [limit] observations for [seriesId], newest first.
  /// [observationStart] optionally limits how far back to go (YYYY-MM-DD).
  Future<FredSeries> getSeries(
    String seriesId, {
    int limit = 500,
    String? observationStart,
  }) async {
    final params = <String, String>{
      'api_key': FredConfig.apiKey,
      'file_type': 'json',
      'limit': '$limit',
      'sort_order': 'desc',
      'series_id': seriesId
    }; 
    if (observationStart != null) {
      params['observation_start'] = observationStart;
    }
    final uri = Uri.parse('${FredConfig.baseUrl}/series/observations')
        .replace(queryParameters: params);
    try {
      final res = await _client.get(uri);
if (res.statusCode != 200) {
      // FIX: Instead of returning empty, throw an error with the body
      // This allows Riverpod to move into the 'error' state
      throw Exception('FRED API Error ${res.statusCode}: ${res.body}');
    }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final raw = body['observations'] as List<dynamic>? ?? [];

      final observations = raw
          .map((e) => _parse(e as Map<String, dynamic>))
          .whereType<FredObservation>()
          .toList();
      return FredSeries(seriesId: seriesId, observations: observations);
    } catch (e) {
      print('Error fetching FRED series $seriesId: $e');
      return FredSeries(seriesId: seriesId, observations: []);
    }
  }

  FredObservation? _parse(Map<String, dynamic> e) {
    final dateStr = e['date'] as String?;
    final valueStr = e['value'] as String?;
    if (dateStr == null || valueStr == null || valueStr == '.') return null;
    final date = DateTime.tryParse(dateStr);
    final value = double.tryParse(valueStr);
    if (date == null || value == null) return null;
    return FredObservation(date: date, value: value);
  }
}
