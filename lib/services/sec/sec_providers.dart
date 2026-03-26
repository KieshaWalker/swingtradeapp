// =============================================================================
// services/sec/sec_providers.dart — Riverpod providers for SEC EDGAR data
// =============================================================================
// All providers below call the SEC Filing Data API (secfilingdata.com).
// Base URL : https://api.secfilingdata.com             (SecConfig.baseUrl)
// Auth     : Authorization: <key> header               (SecConfig.apiKey)
// Method   : POST /live-query-api  with Elasticsearch query body
// Docs     : https://api.secfilingdata.com/docs
//
//   secServiceProvider                   — SecService singleton
//
//   secFilingsForTickerProvider(ticker)  POST /live-query-api
//     query: ticker:{t} AND formType:("10-K" OR "10-Q" OR "8-K" OR "4")
//     → TradeDetailScreen   _SecFilingsSection  (5 most recent filings)
//     → TickerProfileScreen Timeline tab        (secFiling events in feed)
//
//   secSearchProvider(query)             POST /live-query-api
//     query: <free text>  (company name, form type, accession #, etc.)
//     → ResearchScreen    _SearchTab            (live search as user types)
//
//   secRecentEventsProvider              POST /live-query-api
//     query: formType:"8-K"  sorted by filedAt desc
//     → ResearchScreen    _RecentEventsTab      (market-wide 8-K event feed)
// =============================================================================
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
