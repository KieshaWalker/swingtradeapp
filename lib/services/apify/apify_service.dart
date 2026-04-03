import 'package:supabase_flutter/supabase_flutter.dart';
import 'apify_models.dart';

class ApifyService {
  static final ApifyService _instance = ApifyService._();
  ApifyService._();
  factory ApifyService() => _instance;

  Future<dynamic> _invoke(Map<String, dynamic> body) async {
    final response = await Supabase.instance.client.functions.invoke(
      'get-apify-data',
      body: body,
    );
    if (response.status != 200) {
      throw Exception('Apify Edge Function error ${response.status}');
    }
    return response.data;
  }

  // ── Run an actor ──────────────────────────────────────────────────────────

  Future<ApifyRun> runActor(
    String actorId, {
    Map<String, dynamic> input = const {},
    String? build,
    int? memoryMbytes,
    int? timeoutSecs,
  }) async {
    final data = await _invoke({
      'action': 'runActor',
      'actorId': actorId,
      'input': input,
      'build': ?build,
      'memoryMbytes': ?memoryMbytes,
      'timeoutSecs': ?timeoutSecs,
    });
    return ApifyRun.fromJson(data as Map<String, dynamic>);
  }

  // ── Run actor synchronously (waits for result) ────────────────────────────

  Future<List<Map<String, dynamic>>> runActorSync(
    String actorId, {
    Map<String, dynamic> input = const {},
    int timeoutSecs = 300,
    int memoryMbytes = 512,
  }) async {
    final data = await _invoke({
      'action': 'runActorSync',
      'actorId': actorId,
      'input': input,
      'timeoutSecs': timeoutSecs,
      'memoryMbytes': memoryMbytes,
    });
    if (data is List) return data.cast<Map<String, dynamic>>();
    return [];
  }

  // ── Poll run status ───────────────────────────────────────────────────────

  Future<ApifyRun> getRunStatus(String runId) async {
    final data = await _invoke({'action': 'getRunStatus', 'runId': runId});
    return ApifyRun.fromJson(data as Map<String, dynamic>);
  }

  // ── Retrieve dataset items ────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getDatasetItems(
    String datasetId, {
    int limit = 1000,
    int offset = 0,
    String format = 'json',
  }) async {
    final data = await _invoke({
      'action': 'getDatasetItems',
      'datasetId': datasetId,
      'limit': limit,
      'offset': offset,
    });
    if (data is List) return data.cast<Map<String, dynamic>>();
    return [];
  }

  /// Get items from the last successful run of an actor
  Future<List<Map<String, dynamic>>> getLastRunDataset(
    String actorId, {
    int limit = 1000,
  }) async {
    final data = await _invoke({
      'action': 'getLastRunDataset',
      'actorId': actorId,
      'limit': limit,
    });
    if (data is List) return data.cast<Map<String, dynamic>>();
    return [];
  }

  /// Get dataset info (item count, name, etc.)
  Future<ApifyDatasetInfo> getDatasetInfo(String datasetId) async {
    final data = await _invoke({'action': 'getDatasetInfo', 'datasetId': datasetId});
    return ApifyDatasetInfo.fromJson(data as Map<String, dynamic>);
  }

  // ── Convenience wrappers for known actors ────────────────────────────────

  Future<List<Map<String, dynamic>>> scrapeGoogleNews({
    required List<String> queries,
    int maxItems = 100,
  }) =>
      runActorSync(
        ApifyActors.googleNews,
        input: {
          'queries': queries,
          'maxItems': maxItems,
          'dateRange': 'lastWeek',
        },
      );

  Future<List<Map<String, dynamic>>> scrapeReddit({
    required List<String> subreddits,
    int maxItems = 50,
  }) =>
      runActorSync(
        ApifyActors.redditScraper,
        input: {
          'startUrls': subreddits
              .map((s) => {'url': 'https://www.reddit.com/r/$s/'})
              .toList(),
          'maxItems': maxItems,
        },
      );

}
