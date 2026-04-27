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

  // ── Quotes ──────────────────────────────────────────────────────────────────

  Future<StockQuote?> getQuote(String symbol) async {
    final results = await getQuotes([symbol]);
    return results.isEmpty ? null : results.first;
  }

  Future<List<StockQuote>> getQuotes(List<String> symbols) async {
    if (symbols.isEmpty) return [];
    try {
      final res = await _fn.invoke(
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
      final res = await _fn.invoke(
        'get-schwab-chains',
        body: {
          'symbol': symbol,
          'contractType': contractType,
          'strikeCount': strikeCount,
          'expirationDate': expirationDate,
        },
      );
      if (res.status != 200) return null;
      final data = res.data as Map<String, dynamic>;
      if (data.containsKey('error')) return null;
      return SchwabOptionsChain.fromJson(data);
    } catch (e) {
      if (e is FunctionException && e.status == 401) throw const SchwabReauthRequiredException();
      debugPrint('SchwabService.getOptionsChain error: $e');
      return null;
    }
  }

  // ── Ticker search ────────────────────────────────────────────────────────────

  Future<List<SchwabInstrument>> searchTicker(String query) async {
    if (query.isEmpty) return [];
    try {
      final res = await _fn.invoke(
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

  // ── Earnings date ────────────────────────────────────────────────────────────

  /// Returns the next earnings date for [symbol] from Schwab fundamentals,
  /// or null if unavailable. Uses the same quotes endpoint (fields=fundamental)
  /// — no extra network call or edge function needed.
  Future<EarningsDate?> getEarningsDate(String symbol) async {
    try {
      final res = await _fn.invoke(
        'get-schwab-quotes',
        body: {'symbols': [symbol]},
      );
      if (res.status != 200) return null;
      final data = res.data as Map<String, dynamic>?;
      if (data == null || data.containsKey('error')) return null;
      final entry = data[symbol] as Map<String, dynamic>?;
      if (entry == null) return null;
      final dt = SchwabQuote.fromJson(symbol, entry).nextEarningsDate;
      return dt == null ? null : EarningsDate(date: dt);
    } catch (e) {
      if (e is FunctionException && e.status == 401) throw const SchwabReauthRequiredException();
      debugPrint('SchwabService.getEarningsDate error: $e');
      return null;
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
