// =============================================================================
// features/trades/providers/live_marks_provider.dart
// =============================================================================
// Fetches the current mid-price for a single open trade's option contract.
//
// Strategy:
//   1. Call schwabOptionsChainProvider for the trade's ticker (ALL types,
//      strikeCount=1 — Schwab expands to include the requested expiry).
//   2. Walk the chain to find the expiration closest to trade.expiration.
//   3. Within that expiration, find the contract matching the trade's strike
//      and option type (call/put).
//   4. Return (bid + ask) / 2, or null if the contract isn't found.
//
// Calling pattern:
//   ref.watch(tradeMarkProvider(trade))
//   — Returns AsyncValue<double?>.
//   — null means no matching contract was found in the chain.
//
// Bulk refresh:
//   refreshAllMarks(openTrades, ref) iterates open trades and writes each
//   result into liveMarksProvider (the session-only StateProvider<Map>),
//   so TradesScreen can show all unrealized P&Ls with a single refresh tap.
// =============================================================================

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../services/schwab/schwab_models.dart';
import '../../../services/schwab/schwab_providers.dart';
import '../models/trade.dart';
import 'trades_provider.dart';

// ── Per-trade mark fetcher ─────────────────────────────────────────────────────

final tradeMarkProvider =
    FutureProvider.autoDispose.family<double?, Trade>((ref, trade) async {
  final chain = await ref.watch(
    schwabOptionsChainProvider(
      OptionsChainParams(
        symbol: trade.ticker,
        contractType: trade.optionType == OptionType.call ? 'CALL' : 'PUT',
        strikeCount: 20, // wide enough to include OTM/ITM positions
      ),
    ).future,
  );

  if (chain == null || chain.expirations.isEmpty) return null;

  // Find the expiration whose date best matches the trade's expiration.
  SchwabOptionsExpiration? bestExp;
  int bestDiff = 9999;
  for (final exp in chain.expirations) {
    // exp.expirationDate is "yyyy-MM-dd" or "yyyy-MM-ddTHH:mm:ss..."
    final expDateStr = exp.expirationDate.length >= 10
        ? exp.expirationDate.substring(0, 10)
        : exp.expirationDate;
    final expDate = DateTime.tryParse(expDateStr);
    if (expDate == null) continue;
    final diff = (expDate.difference(trade.expiration).inDays).abs();
    if (diff < bestDiff) {
      bestDiff = diff;
      bestExp = exp;
    }
  }

  if (bestExp == null) return null;

  // Find contract matching the trade's strike price (within $0.50 tolerance).
  final contracts =
      trade.optionType == OptionType.call ? bestExp.calls : bestExp.puts;

  SchwabOptionContract? match;
  double bestStrikeDiff = 9999;
  for (final c in contracts) {
    final diff = (c.strikePrice - trade.strike).abs();
    if (diff < bestStrikeDiff) {
      bestStrikeDiff = diff;
      match = c;
    }
  }

  // Only accept if the strike is within $1 of the target.
  if (match == null || bestStrikeDiff > 1.0) return null;
  if (match.bid <= 0 && match.ask <= 0) return match.last > 0 ? match.last : null;

  return match.midpoint;
});

// ── Bulk refresh ───────────────────────────────────────────────────────────────
// Call this from the TradesScreen refresh button to update all open-trade marks.

Future<void> refreshAllMarks(List<Trade> openTrades, WidgetRef ref) async {
  final updates = <String, double>{};
  await Future.wait(
    openTrades.map((trade) async {
      try {
        final mark = await ref.read(tradeMarkProvider(trade).future);
        if (mark != null) updates[trade.id] = mark;
      } catch (_) {
        // Skip trades where the chain lookup fails.
      }
    }),
  );
  if (updates.isNotEmpty) {
    ref.read(liveMarksProvider.notifier).update((state) => {...state, ...updates});
  }
}
