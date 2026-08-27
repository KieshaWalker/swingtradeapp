// =============================================================================
// features/trend_lines/providers/trend_lines_provider.dart
// =============================================================================
// Providers:
//   trendLinesProvider(ticker)   — FutureProvider.family<List<TrendLineRecord>>
//     All saved lines for one ticker, newest first. Plain Supabase read —
//     saving/renaming/deleting a line never touches the Python backend.
//
//   trendLineAccuracyProvider(record) — FutureProvider.family, keyed on the
//     record's own id so each line's status is fetched and cached
//     independently. Calls the Python backend (services/channel_fit) fresh
//     every time — nothing about "is this line still holding" is stored.
//
//   TrendLinesNotifier — mutations: add, rename, delete.
//
//   trendLineCandidatesProvider — NOT a provider. Fetching candidates depends
//   on live slider values a user is actively dragging, which is a poor fit for
//   a cached, key-based FutureProvider (see the screen for why this is a plain
//   async call from screen state instead).
// =============================================================================
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../services/python_api/python_api_client.dart';
import '../models/trend_line.dart';

final trendLinesProvider =
    FutureProvider.family<List<TrendLineRecord>, String>((ref, ticker) async {
  final db = Supabase.instance.client;
  if (db.auth.currentUser == null) return [];

  final rows = await db
      .from('trend_lines')
      .select()
      .eq('ticker', ticker)
      .order('created_at', ascending: false);

  return (rows as List)
      .map((r) => TrendLineRecord.fromJson(r as Map<String, dynamic>))
      .toList();
});

/// Live accuracy for one saved line. Family-keyed on the line's id (not the
/// whole record) so Riverpod treats two lines with identical anchors as
/// distinct requests, and a rename doesn't invalidate an unrelated cache entry.
final trendLineAccuracyProvider =
    FutureProvider.family<TrendLineAccuracy, TrendLineRecord>((ref, line) async {
  final json = await PythonApiClient.trendLineAccuracy(
    ticker: line.ticker,
    anchor1Date: TrendLineRecord.toIsoDateStatic(line.anchor1Date),
    anchor1Price: line.anchor1Price,
    anchor2Date: TrendLineRecord.toIsoDateStatic(line.anchor2Date),
    anchor2Price: line.anchor2Price,
    kind: line.kind == TrendLineKind.manual ? null : line.kind.dbValue,
  );
  return TrendLineAccuracy.fromJson(json);
});

class TrendLinesNotifier extends AsyncNotifier<void> {
  @override
  Future<void> build() async {}

  SupabaseClient get _db => Supabase.instance.client;

  Future<void> add({
    required String ticker,
    required String name,
    required TrendLineKind kind,
    required TrendLineSource source,
    required DateTime anchor1Date,
    required double anchor1Price,
    required DateTime anchor2Date,
    required double anchor2Price,
  }) async {
    final user = _db.auth.currentUser;
    if (user == null) return;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await _db.from('trend_lines').insert({
        'user_id': user.id,
        'ticker': ticker,
        'name': name,
        'kind': kind.dbValue,
        'source': source.dbValue,
        'anchor1_date': TrendLineRecord.toIsoDateStatic(anchor1Date),
        'anchor1_price': anchor1Price,
        'anchor2_date': TrendLineRecord.toIsoDateStatic(anchor2Date),
        'anchor2_price': anchor2Price,
      });
      ref.invalidate(trendLinesProvider(ticker));
    });
  }

  Future<void> rename(String id, String ticker, String newName) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await _db.from('trend_lines').update({'name': newName}).eq('id', id);
      ref.invalidate(trendLinesProvider(ticker));
    });
  }

  Future<void> delete(String id, String ticker) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await _db.from('trend_lines').delete().eq('id', id);
      ref.invalidate(trendLinesProvider(ticker));
    });
  }
}

final trendLinesNotifierProvider =
    AsyncNotifierProvider<TrendLinesNotifier, void>(TrendLinesNotifier.new);
