// =============================================================================
// services/regime/regime_providers.dart
// =============================================================================
// Riverpod providers for the current market regime.
//
// currentRegimeProvider(ticker)
//   — Reads the latest row from Supabase regime_snapshots for the given ticker.
//   — The Python pipeline writes this every 8 hours (schwab_pull.py).
//   — No Dart math; this is a pure read of already-computed Python output.
// =============================================================================

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'regime_models.dart';

final currentRegimeProvider =
    FutureProvider.family<CurrentRegime?, String>((ref, ticker) async {
  final supabase = Supabase.instance.client;

  final row = await supabase
      .from('regime_snapshots')
      .select()
      .eq('ticker', ticker)
      .order('obs_date', ascending: false)
      .limit(1)
      .maybeSingle();

  return row == null ? null : CurrentRegime.fromJson(row);
});
