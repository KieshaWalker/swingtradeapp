// =============================================================================
// features/ticker_profile/providers/ticker_profile_providers.dart
// =============================================================================
// Data sources used in this file:
//
//   ── SUPABASE (user's own data, RLS-scoped) ──────────────────────────────
//   tickerNotesProvider          → table: ticker_profile_notes
//   tickerSRLevelsProvider       → table: ticker_support_resistance
//   tickerInsiderBuysProvider    → table: ticker_insider_buys
//   tickerEarningsReactionsProvider → table: ticker_earnings_reactions
//   tickerTradesProvider         → derived from tradesProvider (table: trades)
//
//   ── SEC EDGAR via secfilingdata.com ─────────────────────────────────────
//   secFilingsForTickerProvider  → POST /live-query-api
//                                  ticker:{symbol} AND formType:(10-K OR 10-Q OR 8-K OR 4)
//                                  feeds into Timeline tab (secFiling events)
//
//   ── KALSHI (not yet integrated) ─────────────────────────────────────────
//   TODO: add kalshiMarketProvider(symbol) → GET /markets?ticker={symbol}
//         would feed prediction market prices into the Timeline and Overview tabs
//
// Tier 1 — Raw Supabase fetchers (FutureProvider.family)
// Tier 2 — Derived (Provider.family, no new fetches)
// Tier 3 — Timeline assembly (merges all 6 sources chronologically)
//
// All providers are invalidated by TickerProfileNotifier after mutations.
// =============================================================================
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth/providers/auth_provider.dart';
import '../../trades/models/trade.dart';
import '../../trades/providers/trades_provider.dart';
import '../../../services/sec/sec_providers.dart';
import '../models/ticker_profile_models.dart';

// ─── Watched tickers ─────────────────────────────────────────────────────────
// Tickers saved via search (independent of trades table).
// Merged with trade-derived symbols in TickerDashboardScreen.

final watchedTickersProvider = FutureProvider<List<String>>((ref) async {
  final client = ref.watch(supabaseClientProvider);
  final user = client.auth.currentUser;
  if (user == null) return [];
  final rows = await client
      .from('watched_tickers')
      .select('ticker')
      .eq('user_id', user.id)
      .order('added_at', ascending: true);
  return (rows as List).map((r) => r['ticker'] as String).toList();
});

// ─── Tier 1: Raw Supabase fetchers ───────────────────────────────────────────
// All four providers below read from Supabase (user-scoped via RLS).
// None of these hit external APIs — data is entered manually by the user.

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
      .order('created_at', ascending: true);
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
      .order('noted_at', ascending: true);
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
      .order('filed_at', ascending: true);
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
      .order('earnings_date', ascending: true);
  return (rows as List)
      .map((e) =>
          TickerEarningsReaction.fromJson(e as Map<String, dynamic>))
      .toList();
});

// ─── Tier 2: Derived providers ────────────────────────────────────────────────

// Trades for this ticker — derived from the global tradesProvider (client-side filter)
final tickerTradesProvider =
    Provider.family<AsyncValue<List<Trade>>, String>((ref, symbol) {
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

  // SOURCE: Supabase — trades table (user's own trade records)
  for (final Trade t in (tradesAsync.valueOrNull ?? []).cast<Trade>()) {
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

  // SOURCE: Supabase — ticker_profile_notes table (user-entered observations)
  for (final n in notesAsync.valueOrNull ?? []) {
    events.add(TickerTimelineEvent(
      timestamp: n.createdAt,
      type: TimelineEventType.note,
      summary: n.body.length > 80 ? '${n.body.substring(0, 80)}…' : n.body,
      note: n,
    ));
  }

  // SOURCE: SEC EDGAR via secfilingdata.com — POST /live-query-api
  //         query: ticker:{symbol} AND formType:(10-K OR 10-Q OR 8-K OR 4)
  //         auth: Authorization header (SecConfig.apiKey)
  for (final f in secAsync.valueOrNull ?? []) {
    events.add(TickerTimelineEvent(
      timestamp: f.filedAt,
      type: TimelineEventType.secFiling,
      summary: '${f.formLabel} · ${f.companyName}',
      secFiling: f,
    ));
  }

  // SOURCE: Supabase — ticker_earnings_reactions table (user-logged post-earnings data)
  //         EPS estimate pre-fill comes from FMP /earnings-calendar (tickerNextEarningsProvider)
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

  // SOURCE: Supabase — ticker_support_resistance table (user-marked price levels)
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

  // SOURCE: Supabase — ticker_insider_buys table (user-curated from SEC Form 4 filings)
  //         raw Form 4 discovery comes from SEC tab (secFilingsForTickerProvider, formType:4)
  for (final b in insiderAsync.valueOrNull ?? []) {
    final val = b.totalValue != null
        ? ' (\$${(b.totalValue! / 1000).toStringAsFixed(0)}k)'
        : '';
    events.add(TickerTimelineEvent(
      timestamp: b.filedAt,
      type: TimelineEventType.insiderBuy,
      summary: '${b.insiderName} · ${b.transactionType.label} ${b.shares}sh$val',
      insiderBuy: b,
    ));
  }

  events.sort((a, b) => b.timestamp.compareTo(a.timestamp));
  return AsyncData(events);
});
