// =============================================================================
// features/swing/providers/swing_setups_provider.dart
// =============================================================================
// Reads swing_setups. Computes nothing — every analytic in the table is
// produced by jobs/swing_setups_pull.py so there is one implementation of each.
//
// READS THE LATEST SESSION, NOT "TODAY". The newest obs_date is discovered from
// the data rather than assumed from the clock. equity_bars deliberately excludes
// the in-progress session, so during market hours the newest setup row is the
// PRIOR session — asking for DateTime.now() would return an empty screen every
// weekday morning and on every market holiday.
// =============================================================================
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/swing_setup.dart';

/// Every setup row for the most recent session present in the table.
final swingSetupsProvider = FutureProvider<List<SwingSetup>>((ref) async {
  final db = Supabase.instance.client;
  if (db.auth.currentUser == null) return [];

  // Two-step rather than a join: find the newest date, then read that date.
  // A single ordered read capped at 1000 rows would silently mix sessions once
  // the table holds more than ~20 days of history.
  final latest = await db
      .from('swing_setups')
      .select('obs_date')
      .order('obs_date', ascending: false)
      .limit(1);

  final rows = latest as List;
  if (rows.isEmpty) return [];
  final obsDate = (rows.first as Map<String, dynamic>)['obs_date'] as String;

  final data = await db
      .from('swing_setups')
      .select()
      .eq('obs_date', obsDate)
      .order('structure_quality', ascending: false, nullsFirst: false);

  return (data as List)
      .map((r) => SwingSetup.fromJson(r as Map<String, dynamic>))
      .toList();
});

/// Filters the screen applies on top of the fetched session.
class SwingFilters {
  final bool channelsOnly;
  final bool surgeOnly;
  final bool reachableOnly;
  final bool breakoutSupportedOnly;

  const SwingFilters({
    this.channelsOnly = false,
    this.surgeOnly = false,
    this.reachableOnly = false,
    this.breakoutSupportedOnly = false,
  });

  SwingFilters copyWith({
    bool? channelsOnly,
    bool? surgeOnly,
    bool? reachableOnly,
    bool? breakoutSupportedOnly,
  }) =>
      SwingFilters(
        channelsOnly: channelsOnly ?? this.channelsOnly,
        surgeOnly: surgeOnly ?? this.surgeOnly,
        reachableOnly: reachableOnly ?? this.reachableOnly,
        breakoutSupportedOnly:
            breakoutSupportedOnly ?? this.breakoutSupportedOnly,
      );

  /// Each filter tests `== true`, never truthiness.
  ///
  /// The fields are tri-state: null means the leg could not be computed, and a
  /// null must FAIL an active filter rather than pass it. `!= false` would let
  /// every ticker with missing data through the exact screen meant to exclude
  /// it.
  bool matches(SwingSetup s) {
    if (channelsOnly && !s.channelFound) return false;
    if (surgeOnly && s.volSurge != true) return false;
    if (reachableOnly && s.reachableUp != true) return false;
    if (breakoutSupportedOnly && s.breakoutSupported != true) return false;
    return true;
  }

  int get activeCount => [
        channelsOnly,
        surgeOnly,
        reachableOnly,
        breakoutSupportedOnly
      ].where((e) => e).length;
}

final swingFiltersProvider =
    StateProvider<SwingFilters>((ref) => const SwingFilters());
