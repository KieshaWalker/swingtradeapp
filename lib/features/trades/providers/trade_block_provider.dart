// =============================================================================
// features/trades/providers/trade_block_provider.dart — 20-trade block analytics
// =============================================================================
// TradeBlock (derived, never stored):
//   blockNumber  — 1-based sequential block index
//   trades       — exactly up to 20 closed trades in that block
//   wins         — count of profitable trades
//   losses       — count of unprofitable/break-even trades
//   winRate      — wins / trades.length
//   totalPnl     — sum of realizedPnl
//   isComplete   — trades.length == 20
//   edgeWarning  — isComplete && wins < 5   (below 25% win-rate floor)
//
// blockWinRateProvider:
//   Derives TradeBlock list from closedTradesProvider, sorted by closedAt ASC,
//   then chunked into sequential groups of 20.
//
// edgeErodingProvider:
//   True when the most-recent complete block has wins < 5.
//   Consumed by TradesScreen and DashboardScreen warning banners.
// =============================================================================
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/trade.dart';
import 'trades_provider.dart';

class TradeBlock {
  final int blockNumber;
  final List<Trade> trades;

  const TradeBlock({required this.blockNumber, required this.trades});

  int get wins => trades.where((t) => t.isProfitable).length;
  int get losses => trades.length - wins;
  double get winRate => trades.isEmpty ? 0 : wins / trades.length;
  double get totalPnl =>
      trades.fold(0.0, (sum, t) => sum + (t.realizedPnl ?? 0));
  bool get isComplete => trades.length == 20;
  // Edge warning: a complete block with fewer than 5 wins (< 25% win rate)
  bool get edgeWarning => isComplete && wins < 5;
}

final blockWinRateProvider = Provider<AsyncValue<List<TradeBlock>>>((ref) {
  return ref.watch(closedTradesProvider).whenData((closed) {
    final sorted = [...closed]
      ..sort((a, b) => (a.closedAt ?? a.openedAt)
          .compareTo(b.closedAt ?? b.openedAt));

    final blocks = <TradeBlock>[];
    for (var i = 0; i < sorted.length; i += 20) {
      final chunk = sorted.sublist(
        i,
        (i + 20) > sorted.length ? sorted.length : i + 20,
      );
      blocks.add(TradeBlock(blockNumber: blocks.length + 1, trades: chunk));
    }
    return blocks;
  });
});

final edgeErodingProvider = Provider<bool>((ref) {
  final blocks = ref.watch(blockWinRateProvider);
  return blocks.whenOrNull(
        data: (list) {
          final complete = list.where((b) => b.isComplete).toList();
          if (complete.isEmpty) return false;
          return complete.last.edgeWarning;
        },
      ) ??
      false;
});
