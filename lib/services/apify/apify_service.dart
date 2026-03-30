import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../core/kalshi_config.dart';
import 'apify_models.dart';

class ApifyService {
  static final ApifyService _instance = ApifyService._();
  ApifyService._();
  factory ApifyService() => _instance;

  final _client = http.Client();

  // ── Run an actor ──────────────────────────────────────────────────────────

  Future<ApifyRun> runActor(
    String actorId, {
    Map<String, dynamic> input = const {},
    String? build,
    int? memoryMbytes,
    int? timeoutSecs,
  }) async {
    final params = <String, String>{'token': ApifyConfig.apiKey};
    if (build != null) params['build'] = build;
    if (memoryMbytes != null) params['memoryMbytes'] = memoryMbytes.toString();
    if (timeoutSecs != null) params['timeout'] = timeoutSecs.toString();

    final uri = Uri.parse('${ApifyConfig.baseUrl}/acts/$actorId/runs')
        .replace(queryParameters: params);
    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(input),
    );
    _checkStatus(response);
    return ApifyRun.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  // ── Run actor synchronously (waits for result) ────────────────────────────

  Future<List<Map<String, dynamic>>> runActorSync(
    String actorId, {
    Map<String, dynamic> input = const {},
    int timeoutSecs = 300,
    int memoryMbytes = 512,
  }) async {
    final uri = Uri.parse('${ApifyConfig.baseUrl}/acts/$actorId/run-sync-get-dataset-items')
        .replace(queryParameters: {
      'token': ApifyConfig.apiKey,
      'timeout': timeoutSecs.toString(),
      'memoryMbytes': memoryMbytes.toString(),
      'format': 'json',
    });
    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(input),
    );
    _checkStatus(response);
    final body = jsonDecode(response.body);
    if (body is List) return body.cast<Map<String, dynamic>>();
    return [];
  }

  // ── Poll run status ───────────────────────────────────────────────────────

  Future<ApifyRun> getRunStatus(String runId) async {
    final uri = Uri.parse('${ApifyConfig.baseUrl}/actor-runs/$runId')
        .replace(queryParameters: {'token': ApifyConfig.apiKey});
    final response = await _client.get(uri);
    _checkStatus(response);
    return ApifyRun.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  // ── Retrieve dataset items ────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getDatasetItems(
    String datasetId, {
    int limit = 1000,
    int offset = 0,
    String format = 'json',
  }) async {
    final uri = Uri.parse('${ApifyConfig.baseUrl}/datasets/$datasetId/items')
        .replace(queryParameters: {
      'token': ApifyConfig.apiKey,
      'format': format,
      'limit': limit.toString(),
      'offset': offset.toString(),
    });
    final response = await _client.get(uri);
    _checkStatus(response);
    final body = jsonDecode(response.body);
    if (body is List) return body.cast<Map<String, dynamic>>();
    return [];
  }

  /// Get items from the last successful run of an actor
  Future<List<Map<String, dynamic>>> getLastRunDataset(
    String actorId, {
    int limit = 1000,
  }) async {
    final uri = Uri.parse(
            '${ApifyConfig.baseUrl}/acts/$actorId/runs/last/dataset/items')
        .replace(queryParameters: {
      'token': ApifyConfig.apiKey,
      'format': 'json',
      'limit': limit.toString(),
      'status': 'SUCCEEDED',
    });
    final response = await _client.get(uri);
    _checkStatus(response);
    final body = jsonDecode(response.body);
    if (body is List) return body.cast<Map<String, dynamic>>();
    return [];
  }

  /// Get dataset info (item count, name, etc.)
  Future<ApifyDatasetInfo> getDatasetInfo(String datasetId) async {
    final uri = Uri.parse('${ApifyConfig.baseUrl}/datasets/$datasetId')
        .replace(queryParameters: {'token': ApifyConfig.apiKey});
    final response = await _client.get(uri);
    _checkStatus(response);
    return ApifyDatasetInfo.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
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

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _checkStatus(http.Response r) {
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw Exception('Apify API error ${r.statusCode}: ${r.body}');
    }
  }
}
