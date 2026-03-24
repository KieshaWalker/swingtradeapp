// =============================================================================
// features/ticker_profile/providers/ticker_profile_providers.dart
// =============================================================================
// Tier 1 — Raw Supabase fetchers (FutureProvider.family):
//   tickerNotesProvider(symbol)         — ticker_profile_notes rows
//   tickerSRLevelsProvider(symbol)      — ticker_support_resistance rows
//   tickerInsiderBuysProvider(symbol)   — ticker_insider_buys rows
//   tickerEarningsReactionsProvider(s)  — ticker_earnings_reactions rows
//
// Tier 2 — Derived (Provider.family, no new fetches):
//   tickerTradesProvider(symbol)        — filtered from tradesProvider
//   tickerAnalyticsProvider(symbol)     — TickerTradeAnalytics.compute()
//   activeSRLevelsProvider(symbol)      — active levels only
//
// Tier 3 — Timeline (Provider.family, merges 6 async sources):
//   tickerTimelineProvider(symbol)      — AsyncValue<List<TickerTimelineEvent>>
//
// All providers are invalidated by TickerProfileNotifier after mutations.
// =============================================================================
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth/providers/auth_provider.dart';
import '../../trades/providers/trades_provider.dart';
import '../../../services/sec/sec_providers.dart';
import '../models/ticker_profile_models.dart';

// ─── Tier 1: Raw Supabase fetchers ───────────────────────────────────────────

final tickerNotesProvider =
    FutureProvider.family<List<TickerProfileNote>, String>((ref, symbol) async {
  final client = ref.watch(supabaseClientProvider);
  final user = client.auth.currentUser;
  if (user == null) return [];
  final rows = await client
      .from('ticker_profile_notes')
      .select()
      .eq('user_id', user.id)
      .eq('ticker', symbol.toUpperCase())
      .order('created_at', ascending: false);
  return (rows as List)
      .map((e) => TickerProfileNote.fromJson(e as Map<String, dynamic>))
      .toList();
});

final tickerSRLevelsProvider =
    FutureProvider.family<List<SupportResistanceLevel>, String>(
        (ref, symbol) async {
  final client = ref.watch(supabaseClientProvider);
  final user = client.auth.currentUser;
  if (user == null) return [];
  final rows = await client
      .from('ticker_support_resistance')
      .select()
      .eq('user_id', user.id)
      .eq('ticker', symbol.toUpperCase())
      .order('noted_at', ascending: false);
  return (rows as List)
      .map((e) =>
          SupportResistanceLevel.fromJson(e as Map<String, dynamic>))
      .toList();
});

final tickerInsiderBuysProvider =
    FutureProvider.family<List<TickerInsiderBuy>, String>((ref, symbol) async {
  final client = ref.watch(supabaseClientProvider);
  final user = client.auth.currentUser;
  if (user == null) return [];
  final rows = await client
      .from('ticker_insider_buys')
      .select()
      .eq('user_id', user.id)
      .eq('ticker', symbol.toUpperCase())
      .order('filed_at', ascending: false);
  return (rows as List)
      .map((e) => TickerInsiderBuy.fromJson(e as Map<String, dynamic>))
      .toList();
});

final tickerEarningsReactionsProvider =
    FutureProvider.family<List<TickerEarningsReaction>, String>(
        (ref, symbol) async {
  final client = ref.watch(supabaseClientProvider);
  final user = client.auth.currentUser;
  if (user == null) return [];
  final rows = await client
      .from('ticker_earnings_reactions')
      .select()
      .eq('user_id', user.id)
      .eq('ticker', symbol.toUpperCase())
      .order('earnings_date', ascending: false);
  return (rows as List)
      .map((e) =>
          TickerEarningsReaction.fromJson(e as Map<String, dynamic>))
      .toList();
});

// ─── Tier 2: Derived providers ────────────────────────────────────────────────

// Trades for this ticker — derived from the global tradesProvider (client-side filter)
final tickerTradesProvider =
    Provider.family((ref, String symbol) {
  return ref.watch(tradesProvider).whenData(
        (all) => all
            .where((t) =>
                t.ticker.toUpperCase() == symbol.toUpperCase())
            .toList(),
      );
});

// Trade analytics — computed from closed trades
final tickerAnalyticsProvider =
    Provider.family<TickerTradeAnalytics, String>((ref, symbol) {
  final tradesAsync = ref.watch(tickerTradesProvider(symbol));
  return tradesAsync.whenOrNull(
        data: (trades) => TickerTradeAnalytics.compute(symbol, trades),
      ) ??
      TickerTradeAnalytics.empty(symbol);
});

// Active S/R levels only
final activeSRLevelsProvider =
    Provider.family((ref, String symbol) {
  return ref.watch(tickerSRLevelsProvider(symbol)).whenData(
        (levels) => levels.where((l) => l.isActive).toList(),
      );
});

// ─── Tier 3: Timeline assembly ────────────────────────────────────────────────

final tickerTimelineProvider =
    Provider.family<AsyncValue<List<TickerTimelineEvent>>, String>(
        (ref, symbol) {
  final tradesAsync = ref.watch(tickerTradesProvider(symbol));
  final notesAsync = ref.watch(tickerNotesProvider(symbol));
  final secAsync = ref.watch(secFilingsForTickerProvider(symbol));
  final earningsAsync = ref.watch(tickerEarningsReactionsProvider(symbol));
  final srAsync = ref.watch(tickerSRLevelsProvider(symbol));
  final insiderAsync = ref.watch(tickerInsiderBuysProvider(symbol));

  // Surface the first error encountered
  for (final a in [
    tradesAsync,
    notesAsync,
    secAsync,
    earningsAsync,
    srAsync,
    insiderAsync
  ]) {
    if (a is AsyncError) {
      return AsyncError(a.error as Object, a.stackTrace ?? StackTrace.empty);
    }
  }
  // Still loading any source → loading
  for (final a in [
    tradesAsync,
    notesAsync,
    secAsync,
    earningsAsync,
    srAsync,
    insiderAsync
  ]) {
    if (a is AsyncLoading) return const AsyncLoading();
  }

  final events = <TickerTimelineEvent>[];

  // Trades
  for (final t in tradesAsync.valueOrNull ?? []) {
    events.add(TickerTimelineEvent(
      timestamp: t.openedAt,
      type: TimelineEventType.tradeOpened,
      summary:
          'Opened ${t.strategy.label} @ \$${t.entryPrice.toStringAsFixed(2)}',
      trade: t,
    ));
    if (t.closedAt != null) {
      final pnl = t.realizedPnl;
      final sign = (pnl ?? 0) >= 0 ? '+' : '';
      events.add(TickerTimelineEvent(
        timestamp: t.closedAt!,
        type: TimelineEventType.tradeClosed,
        summary: pnl != null
            ? 'Closed ${t.strategy.label} $sign\$${pnl.toStringAsFixed(2)}'
            : 'Closed ${t.strategy.label}',
        trade: t,
      ));
    }
  }

  // Notes
  for (final n in notesAsync.valueOrNull ?? []) {
    events.add(TickerTimelineEvent(
      timestamp: n.createdAt,
      type: TimelineEventType.note,
      summary: n.body.length > 80 ? '${n.body.substring(0, 80)}…' : n.body,
      note: n,
    ));
  }

  // SEC filings
  for (final f in secAsync.valueOrNull ?? []) {
    events.add(TickerTimelineEvent(
      timestamp: f.filedAt,
      type: TimelineEventType.secFiling,
      summary: '${f.formLabel} · ${f.companyName}',
      secFiling: f,
    ));
  }

  // Earnings reactions
  for (final e in earningsAsync.valueOrNull ?? []) {
    final dir = e.direction ?? 'flat';
    final pct = e.movePct != null
        ? ' (${e.movePct!.toStringAsFixed(1)}%)'
        : '';
    events.add(TickerTimelineEvent(
      timestamp: e.earningsDate,
      type: TimelineEventType.earningsReaction,
      summary: 'Earnings $dir$pct${e.beat ? ' · beat' : ''}',
      earningsReaction: e,
    ));
  }

  // S/R levels
  for (final l in srAsync.valueOrNull ?? []) {
    events.add(TickerTimelineEvent(
      timestamp: l.notedAt,
      type: TimelineEventType.srLevelAdded,
      summary:
          '${l.levelType.name} \$${l.price.toStringAsFixed(2)}${l.label != null ? ' · ${l.label}' : ''}',
      srLevel: l,
    ));
    if (l.invalidatedAt != null) {
      events.add(TickerTimelineEvent(
        timestamp: l.invalidatedAt!,
        type: TimelineEventType.srLevelInvalidated,
        summary:
            '${l.levelType.name} \$${l.price.toStringAsFixed(2)} invalidated',
        srLevel: l,
      ));
    }
  }

  // Insider buys
  for (final b in insiderAsync.valueOrNull ?? []) {
    final val = b.totalValue != null
        ? ' (\$${(b.totalValue! / 1000).toStringAsFixed(0)}k)'
        : '';
    events.add(TickerTimelineEvent(
      timestamp: b.filedAt,
      type: TimelineEventType.insiderBuy,
      summary: '${b.insiderName} bought ${b.shares}sh$val',
      insiderBuy: b,
    ));
  }

  events.sort((a, b) => b.timestamp.compareTo(a.timestamp));
  return AsyncData(events);
});
