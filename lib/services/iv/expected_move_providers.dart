// =============================================================================
// services/iv/expected_move_providers.dart
// =============================================================================
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'expected_move_models.dart';
import 'expected_move_repository.dart';

final _repo = ExpectedMoveRepository();

/// Last 90 daily EOD snapshots for a ticker (ordered oldest → newest).
final expectedMoveDailyProvider =
    FutureProvider.family<List<ExpectedMoveSnapshot>, String>(
  (ref, ticker) => _repo.getHistory(ticker, periodType: 'daily', limit: 90),
);

/// Last 24 monthly EOD snapshots for a ticker (ordered oldest → newest).
final expectedMoveMonthlyProvider =
    FutureProvider.family<List<ExpectedMoveSnapshot>, String>(
  (ref, ticker) => _repo.getHistory(ticker, periodType: 'monthly', limit: 24),
);
