import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'sec_models.dart';
import 'sec_service.dart';

final secServiceProvider = Provider<SecService>((_) => SecService());

/// Recent filings for a specific ticker (used on trade detail)
final secFilingsForTickerProvider =
    FutureProvider.family<List<SecFiling>, String>((ref, ticker) {
  return ref.watch(secServiceProvider).getFilingsForTicker(ticker);
});

/// Free-text search across all filings
final secSearchProvider =
    FutureProvider.family<List<SecFiling>, String>((ref, query) async {
  if (query.isEmpty) return [];
  return ref.watch(secServiceProvider).searchFilings(query);
});

/// Recent 8-K market events feed
final secRecentEventsProvider = FutureProvider<List<SecFiling>>((ref) {
  return ref.watch(secServiceProvider).getRecentEvents();
});
