// =============================================================================
// services/iv/realized_vol_repository.dart
// =============================================================================
// Repository layer: Supabase I/O for Realized Vol snapshots.
//
// Responsibilities:
//   • Save daily RV snapshots (upsert on symbol,date)
//   • Fetch RV history (for percentile ranking)
//   • Fetch latest snapshot per ticker
//
// Table Schema (Supabase):
//   realized_vol_snapshots (symbol, date, rv_20d, rv_60d, percentiles...)
// =============================================================================

import 'package:supabase_flutter/supabase_flutter.dart';
import 'realized_vol_models.dart';

class RealizedVolRepository {
  final SupabaseClient _db;

  RealizedVolRepository(this._db);

  /// Save (upsert) a single RV snapshot for today
  Future<void> save(RealizedVolSnapshot snapshot) async {
    try {
      await _db.from('realized_vol_snapshots').upsert([
        snapshot.toJson(),
      ], onConflict: 'symbol,date');
    } catch (e) {
      throw Exception('Failed to save RV snapshot for ${snapshot.symbol}: $e');
    }
  }

  /// Fetch full history for a ticker (sorted ascending, oldest first)
  /// [limit] default 252 (trading days in year) for 52-week history
  Future<List<RealizedVolSnapshot>> getHistory(
    String symbol, {
    int limit = 252,
  }) async {
    try {
      final rows = await _db
          .from('realized_vol_snapshots')
          .select()
          .eq('symbol', symbol)
          .order('date', ascending: true)
          .limit(limit);

      return rows.map((r) => RealizedVolSnapshot.fromJson(r)).toList();
    } catch (e) {
      // Return empty list if table doesn't exist yet (migration not applied)
      return [];
    }
  }

  /// Fetch latest RV snapshot for a ticker (most recent date)
  Future<RealizedVolSnapshot?> getLatest(String symbol) async {
    try {
      final rows = await _db
          .from('realized_vol_snapshots')
          .select()
          .eq('symbol', symbol)
          .order('date', ascending: false)
          .limit(1);

      if (rows.isEmpty) return null;
      return RealizedVolSnapshot.fromJson(rows[0]);
    } catch (e) {
      return null;
    }
  }

  /// Fetch quote history from economy_quote_snapshots (daily closes)
  /// Used as input to RealizedVolService.computeFromQuotes()
  /// [limit] default 252 for 52 weeks
  Future<List<Map<String, dynamic>>> getQuoteHistory(
    String symbol, {
    int limit = 252,
  }) async {
    try {
      final rows = await _db
          .from('economy_quote_snapshots')
          .select()
          .eq('symbol', symbol)
          .order('date', ascending: true)
          .limit(limit);

      return List<Map<String, dynamic>>.from(rows);
    } catch (e) {
      return [];
    }
  }

  /// Batch upsert multiple RV snapshots at once (for daily batch persistence)
  Future<void> saveBatch(List<RealizedVolSnapshot> snapshots) async {
    if (snapshots.isEmpty) return;

    try {
      await _db
          .from('realized_vol_snapshots')
          .upsert(
            snapshots.map((s) => s.toJson()).toList(),
            onConflict: 'symbol,date',
          );
    } catch (e) {
      throw Exception('Failed to batch-save RV snapshots: $e');
    }
  }
}
