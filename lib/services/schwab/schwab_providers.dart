// =============================================================================
// services/schwab/schwab_providers.dart
// =============================================================================
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'schwab_models.dart';
import 'schwab_reauth_provider.dart';
import 'schwab_service.dart';

final schwabServiceProvider = Provider<SchwabService>((_) => SchwabService());

// ── Quote providers ───────────────────────────────────────────────────────────

final quoteProvider = FutureProvider.family<StockQuote?, String>((ref, symbol) async {
  try {
    return await ref.watch(schwabServiceProvider).getQuote(symbol);
  } on SchwabReauthRequiredException {
    ref.read(schwabReauthNeededProvider.notifier).state = true;
    return null;
  }
});

final quotesProvider =
    FutureProvider.family<List<StockQuote>, List<String>>((ref, symbols) async {
  try {
    return await ref.watch(schwabServiceProvider).getQuotes(symbols);
  } on SchwabReauthRequiredException {
    ref.read(schwabReauthNeededProvider.notifier).state = true;
    return [];
  }
});

// ── Ticker search provider ────────────────────────────────────────────────────

final tickerSearchProvider =
    FutureProvider.family<List<SchwabInstrument>, String>((ref, query) async {
  if (query.isEmpty) return [];
  try {
    return await ref.watch(schwabServiceProvider).searchTicker(query);
  } on SchwabReauthRequiredException {
    ref.read(schwabReauthNeededProvider.notifier).state = true;
    return [];
  }
});

// ── Options chain provider ────────────────────────────────────────────────────

final schwabOptionsChainProvider =
    FutureProvider.family<SchwabOptionsChain?, OptionsChainParams>(
        (ref, params) async {
  try {
    return await ref.watch(schwabServiceProvider).getOptionsChain(
          params.symbol,
          contractType: params.contractType,
          strikeCount: params.strikeCount,
          expirationDate: params.expirationDate,
          
        );
  } on SchwabReauthRequiredException {
    ref.read(schwabReauthNeededProvider.notifier).state = true;
    return null;
  }
});

// ── Movers provider ───────────────────────────────────────────────────────────
// symbolId: $DJI | $COMPX | $SPX | NYSE | NASDAQ | OTCBB |
//           INDEX_ALL | EQUITY_ALL | OPTION_ALL | OPTION_PUT | OPTION_CALL

final moversProvider =
    FutureProvider.family<List<SchwabMover>, MoversParams>((ref, params) async {
  try {
    return await ref.watch(schwabServiceProvider).getMovers(
          params.symbolId,
          sort:      params.sort,
          frequency: params.frequency,
        );
  } on SchwabReauthRequiredException {
    ref.read(schwabReauthNeededProvider.notifier).state = true;
    return [];
  }
});

// ── Fundamentals provider ─────────────────────────────────────────────────────

final schwabFundamentalsProvider =
    FutureProvider.family<SchwabFundamentals?, String>((ref, symbol) async {
  try {
    return await ref.watch(schwabServiceProvider).getFundamentals(symbol);
  } on SchwabReauthRequiredException {
    ref.read(schwabReauthNeededProvider.notifier).state = true;
    return null;
  }
});

// ── Earnings date provider ────────────────────────────────────────────────────
// Returns the next earnings date for a symbol from Schwab fundamentals.
// null = no earnings date available (index ETF, no data, etc.)

final schwabEarningsDateProvider =
    FutureProvider.family<EarningsDate?, String>((ref, symbol) async {
  if (symbol.isEmpty) return null;
  try {
    return await ref.watch(schwabServiceProvider).getEarningsDate(symbol);
  } on SchwabReauthRequiredException {
    ref.read(schwabReauthNeededProvider.notifier).state = true;
    return null;
  }
});

class MoversParams {
  final String symbolId;
  final String sort;
  final int    frequency;

  const MoversParams({
    required this.symbolId,
    this.sort      = 'PERCENT_CHANGE_UP',
    this.frequency = 0,
  });

  @override
  bool operator ==(Object other) =>
      other is MoversParams &&
      other.symbolId  == symbolId &&
      other.sort      == sort &&
      other.frequency == frequency;

  @override
  int get hashCode => Object.hash(symbolId, sort, frequency);
}

class OptionsChainParams {
  final String symbol;
  final String contractType;
  final int strikeCount;
  final String? expirationDate;

  const OptionsChainParams({
    required this.symbol,
    this.contractType = 'ALL',
    this.strikeCount = 30,
    this.expirationDate,
  });

  @override
  bool operator ==(Object other) =>
      other is OptionsChainParams &&
      other.symbol == symbol &&
      other.contractType == contractType &&
      other.strikeCount == strikeCount &&
      other.expirationDate == expirationDate;

  @override
  int get hashCode =>
      Object.hash(symbol, contractType, strikeCount, expirationDate);
}
