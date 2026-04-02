// =============================================================================
// services/schwab/schwab_providers.dart
// Drop-in replacements for fmp_providers quoteProvider / quotesProvider.
// All existing widgets continue to work with zero changes.
// =============================================================================
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../fmp/fmp_models.dart';
import 'schwab_models.dart';
import 'schwab_service.dart';

final schwabServiceProvider = Provider<SchwabService>((_) => SchwabService());

// ── Drop-in quote providers (same signatures as fmp_providers) ────────────────

final quoteProvider = FutureProvider.family<StockQuote?, String>((ref, symbol) {
  return ref.watch(schwabServiceProvider).getQuote(symbol);
});

final quotesProvider =
    FutureProvider.family<List<StockQuote>, List<String>>((ref, symbols) {
  return ref.watch(schwabServiceProvider).getQuotes(symbols);
});

// ── Options chain provider ────────────────────────────────────────────────────

final schwabOptionsChainProvider =
    FutureProvider.family<SchwabOptionsChain?, OptionsChainParams>(
        (ref, params) {
  return ref.watch(schwabServiceProvider).getOptionsChain(
        params.symbol,
        contractType:   params.contractType,
        strikeCount:    params.strikeCount,
        expirationDate: params.expirationDate,
      );
});

class OptionsChainParams {
  final String  symbol;
  final String  contractType;
  final int     strikeCount;
  final String? expirationDate;

  const OptionsChainParams({
    required this.symbol,
    this.contractType  = 'ALL',
    this.strikeCount   = 10,
    this.expirationDate,
  });

  @override
  bool operator ==(Object other) =>
      other is OptionsChainParams &&
      other.symbol         == symbol &&
      other.contractType   == contractType &&
      other.strikeCount    == strikeCount &&
      other.expirationDate == expirationDate;

  @override
  int get hashCode =>
      Object.hash(symbol, contractType, strikeCount, expirationDate);
}
