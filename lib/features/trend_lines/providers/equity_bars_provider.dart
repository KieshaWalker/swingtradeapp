// =============================================================================
// features/trend_lines/providers/equity_bars_provider.dart
// =============================================================================
// Daily OHLC for the candlestick chart. Plain Supabase read — equity_bars is
// market data (RLS: any authenticated user, see migration 080), not user data,
// so this needs no Python round trip.
// =============================================================================
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/equity_bar.dart';

/// Full available daily history for one ticker, oldest first — the order
/// every chart and every trend-line anchor mapping in this feature assumes.
final equityBarsProvider =
    FutureProvider.family<List<EquityBar>, String>((ref, ticker) async {
  final db = Supabase.instance.client;

  // Ordered DESCENDING and reversed — the documented way around PostgREST's
  // silent 1000-row cap for "all history for one ticker", used identically in
  // jobs/equity_bars_pull.py and services/channel_fit.py callers.
  final rows = await db
      .from('equity_bars')
      .select('bar_date,open,high,low,close')
      .eq('ticker', ticker)
      .eq('timeframe', 'daily')
      .order('bar_date', ascending: false)
      .limit(1000);

  final bars = (rows as List)
      .map((r) => EquityBar.fromJson(r as Map<String, dynamic>))
      .toList();
  return bars.reversed.toList();
});
