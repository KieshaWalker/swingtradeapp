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
import 'package:supabase_flutter/supabase_flutter.dart';
import 'fred_models.dart';

class FredService {
  static final FredService _instance = FredService._();
  FredService._();
  factory FredService() => _instance;

  /// Fetch up to [limit] observations for [seriesId], newest first.
  /// [observationStart] optionally limits how far back to go (YYYY-MM-DD).
Future<FredSeries> getSeries(String seriesId, {int limit = 500}) async {
  try {
    // Call your Supabase Edge Function instead of FRED directly
    final response = await Supabase.instance.client.functions.invoke(
      'get-fred-data',
      body: {
        'series_id': seriesId,
        'limit': limit.toString(),
      },
    );

    if (response.status != 200) throw Exception('Function error');

    final body = response.data as Map<String, dynamic>;
    final raw = body['observations'] as List<dynamic>? ?? [];

    final observations = raw
        .map((e) => _parse(e as Map<String, dynamic>))
        .whereType<FredObservation>()
        .toList();

    return FredSeries(seriesId: seriesId, observations: observations);
  } catch (e) {
    // Swallow and return empty series — widgets handle empty gracefully.
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
