// =============================================================================
// services/schwab/schwab_service.dart — Schwab Market Data client
// All calls go through Supabase Edge Functions (never direct to Schwab).
// =============================================================================
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'schwab_models.dart';

class SchwabReauthRequiredException implements Exception {
  const SchwabReauthRequiredException();
}

class SchwabService {
  static final SchwabService _instance = SchwabService._();
  SchwabService._();
  factory SchwabService() => _instance;

  FunctionsClient get _fn => Supabase.instance.client.functions;

  Future<FunctionResponse> _invoke(
    String name, {
    Object? body,
    Duration timeout = const Duration(seconds: 15),
  }) =>
      _fn.invoke(name, body: body).timeout(timeout);

  // ── Quotes ──────────────────────────────────────────────────────────────────

  Future<StockQuote?> getQuote(String symbol) async {
    final results = await getQuotes([symbol]);
    return results.isEmpty ? null : results.first;
  }

  Future<List<StockQuote>> getQuotes(List<String> symbols) async {
    if (symbols.isEmpty) return [];
    try {
      final res = await _invoke(
        'get-schwab-quotes',
        body: {'symbols': symbols},
      );
      if (res.status != 200) return [];
      final data = res.data as Map<String, dynamic>;
      if (data.containsKey('error')) return [];
      return data.entries
          .map((e) => SchwabQuote.fromJson(
                e.key, e.value as Map<String, dynamic>)
              .toStockQuote())
          .toList();
    } catch (e) {
      if (e is FunctionException && e.status == 401) throw const SchwabReauthRequiredException();
      debugPrint('SchwabService.getQuotes error: $e');
      return [];
    }
  }

  // ── Options chain ────────────────────────────────────────────────────────────

  Future<SchwabOptionsChain?> getOptionsChain(
    String symbol, {
    String contractType = 'ALL',
    int strikeCount = 30,
    String? expirationDate,
  }) async {
    try {
      final res = await _invoke(
        'get-schwab-chains',
        body: {
          'symbol': symbol,
          'contractType': contractType,
          'strikeCount': strikeCount,
          'expirationDate': expirationDate,
        },
        timeout: const Duration(seconds: 35),
      );
      if (res.status != 200) {
        final err = (res.data as Map<String, dynamic>?)?['error'] ?? 'HTTP ${res.status}';
        throw Exception('Schwab chain error: $err');
      }
      final data = res.data as Map<String, dynamic>;
      if (data.containsKey('error')) throw Exception('Schwab chain error: ${data['error']}');
      return SchwabOptionsChain.fromJson(data);
    } catch (e) {
      if (e is FunctionException && e.status == 401) throw const SchwabReauthRequiredException();
      rethrow;
    }
  }

  // ── Ticker search ────────────────────────────────────────────────────────────

  Future<List<SchwabInstrument>> searchTicker(String query) async {
    if (query.isEmpty) return [];
    try {
      final res = await _invoke(
        'get-schwab-instruments',
        body: {'query': query},
      );
      if (res.status != 200) return [];
      final data = res.data;
      if (data is! List) return [];
      return data
          .map((e) => SchwabInstrument.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      if (e is FunctionException && e.status == 401) throw const SchwabReauthRequiredException();
      debugPrint('SchwabService.searchTicker error: $e');
      return [];
    }
  }

  // ── Fundamentals ─────────────────────────────────────────────────────────────

  Future<SchwabFundamentals?> getFundamentals(String symbol) async {
    try {
      final res = await _invoke(
        'get-schwab-instruments',
        body: {'symbol': symbol, 'projection': 'fundamental'},
      );
      if (res.status != 200) return null;
      final f = res.data as Map<String, dynamic>?;
      if (f == null || f.containsKey('error')) return null;
      return SchwabFundamentals.fromJson(f);
    } catch (e) {
      if (e is FunctionException && e.status == 401) throw const SchwabReauthRequiredException();
      debugPrint('SchwabService.getFundamentals error: $e');
      return null;
    }
  }

  // ── Earnings date ────────────────────────────────────────────────────────────

  /// Returns the next earnings date for [symbol] from Schwab fundamentals,
  /// or null if unavailable. Uses the quotes endpoint (fields=fundamental)
  /// — separate from getFundamentals which uses the instruments endpoint.
  Future<EarningsDate?> getEarningsDate(String symbol) async {
    try {
      final res = await _invoke(
        'get-schwab-quotes',
        body: {'symbols': [symbol]},
      );
      if (res.status != 200) return null;
      final data = res.data as Map<String, dynamic>?;
      if (data == null || data.containsKey('error')) return null;
      final entry = data[symbol] as Map<String, dynamic>?;
      if (entry == null) return null;
      final fund = SchwabQuote.fromJson(symbol, entry).fundamentals;
      final next = fund?.nextEarningsDate;
      final last = fund?.lastEarningsDate;
      // Return null only when Schwab has no fundamental data at all (e.g. indices).
      // When next is null but last is present the caller can show "date TBA".
      if (next == null && last == null) return null;
      return EarningsDate(
        date:             next ?? DateTime(9999),
        lastEarningsDate: last,
      );
    } catch (e) {
      if (e is FunctionException && e.status == 401) throw const SchwabReauthRequiredException();
      debugPrint('SchwabService.getEarningsDate error: $e');
      return null;
    }
  }

  // ── Movers ───────────────────────────────────────────────────────────────────

  Future<List<SchwabMover>> getMovers(
    String symbolId, {
    String sort      = 'PERCENT_CHANGE_UP',
    int    frequency = 0,
  }) async {
    try {
      final res = await _invoke(
        'get-schwab-movers',
        body: {'symbolId': symbolId, 'sort': sort, 'frequency': frequency},
      );
      if (res.status != 200) return [];
      final data = res.data as Map<String, dynamic>?;
      if (data == null || data.containsKey('error')) return [];
      final list = data['movers'] as List<dynamic>? ?? [];
      return list
          .map((e) => SchwabMover.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      if (e is FunctionException && e.status == 401) throw const SchwabReauthRequiredException();
      debugPrint('SchwabService.getMovers error: $e');
      return [];
    }
  }

  // ── Economy pulse batch ───────────────────────────────────────────────────────

  // Schwab-native symbols:
  //  /GC  = gold front-month futures
  //  /SI  = silver futures
  //  /CL  = WTI crude front-month
  //  /NG  = natural gas futures
  //  $DXY = US Dollar Index (real index, not the UUP ETF proxy)
  Future<List<StockQuote>> getEconomyQuotes() => getQuotes(
        ['SPY', 'QQQ', 'VIXY', r'$DXY', 'DXY', 'UUP', '/GC', '/SI', '/CL', '/NG', 'HYG', 'LQD', 'COPX'],
      );
}
