# Dependency Impact Map — Swing Options Trader

> **How to use:** Find the file you want to modify in the left column, then trace every downstream arrow to understand what breaks or needs updating. Each section covers one layer of the stack.

---

## Table of Contents

1. [Layer Overview](#layer-overview)
2. [Database Schema → Model Map](#database-schema--model-map)
3. [Model → Service Map](#model--service-map)
4. [Service → Provider Map](#service--provider-map)
5. [Provider → UI Consumer Map](#provider--ui-consumer-map)
6. [Full Vertical Traces (End-to-End)](#full-vertical-traces-end-to-end)
7. [Router & Navigation Map](#router--navigation-map)
8. [External API → Edge Function → Service Map](#external-api--edge-function--service-map)
9. [Pure Engines (No Provider Dependencies)](#pure-engines-no-provider-dependencies)
10. [Invalidation Chains](#invalidation-chains)
11. [Shared Type Registry](#shared-type-registry)

---

## Layer Overview

```
External APIs
    │
    ▼
Supabase Edge Functions  (Deno, auth proxy — never expose API keys to Flutter)
    │
    ▼
Service Layer            (Dart singletons — HTTP / functions.invoke())
    │
    ▼
Provider Layer           (Riverpod — FutureProvider / AsyncNotifier)
    │
    ▼
UI Layer                 (ConsumerWidget — ref.watch / ref.read)
    │
    ▼
Supabase Postgres        (tables ← written by providers/notifiers)
    │
    ▼
Economy Storage Layer    (history tables ← read back by chart providers)
```

---

## Database Schema → Model Map

Each Supabase table maps to exactly one Dart model class. Modify a migration → update the corresponding model's `fromJson` / `toJson`.

| Migration | Table | Dart Model | File |
|-----------|-------|-----------|------|
| 001 | `trades` (base cols) | `Trade` | `lib/features/trades/models/trade.dart` |
| 001 | `journal_entries` | `JournalEntry` | `lib/features/journal/models/journal_entry.dart` |
| 001 | `trade_pnl` *(view)* | computed from `Trade` | — |
| 002 | `ticker_profile_notes` | `TickerProfileNote` | `lib/features/ticker_profile/models/ticker_profile_models.dart` |
| 002 | `ticker_support_resistance` | `SupportResistanceLevel` | same |
| 002 | `ticker_insider_buys` | `TickerInsiderBuy` | same |
| 002 | `ticker_earnings_reactions` | `TickerEarningsReaction` | same |
| 003 | *(ALTER ticker_insider_buys)* | `InsiderTransactionType` enum | same |
| 004 | `watched_tickers` | `List<String>` inline | `ticker_profile_providers.dart` |
| 005 | `economy_indicator_snapshots` | `EconomicIndicatorPoint` | `lib/services/fmp/fmp_models.dart` |
| 005 | `economy_treasury_snapshots` | `TreasurySnapshot` | `lib/services/economy/economy_snapshot_models.dart` |
| 005 | `economy_quote_snapshots` | `QuoteSnapshot` | same |
| 005 | `us_gasoline_price_history` | `GasolinePricePoint` | same |
| 005 | `us_unemployment_rate_history` | `UnemploymentRatePoint` | same |
| 005 | `us_natural_gas_import_prices` | `NatGasImportPoint` | same |
| 006 | `trades` (extended cols) | `Trade` (same model, extended fields) | `lib/features/trades/models/trade.dart` |
| 006 | `trade_journal` | `TradeJournal` | `lib/features/trades/models/trade_journal.dart` |
| 007 | `us_gasoline_price_history` | `GasolinePricePoint` | `lib/services/economy/economy_snapshot_models.dart` |
| 008 | `us_unemployment_rate_history` | `UnemploymentRatePoint` | same |
| 009 | `us_natural_gas_import_prices` | `NatGasImportPoint` | same |
| 010 | `schwab_tokens` | *(server-only, no Dart model)* | `supabase/functions/_shared/schwab_auth.ts` |

### Trade Model Field Split (migration boundary)

The `Trade` model spans two migrations. `addTrade()` uses a two-step insert to handle remote DB lag:

```
Migration 001 (base — step 1 INSERT):
  id, user_id, ticker, option_type, strategy, strike, expiration,
  dte_at_entry, contracts, entry_price, exit_price, status,
  iv_rank, delta, notes, opened_at, closed_at, created_at, updated_at

Migration 006 (extended — step 2 best-effort UPDATE):
  price_range_high, price_range_low, implied_vol_entry,
  intraday_support, intraday_resistance, daily_breakout_level,
  daily_breakdown_level, entry_point_type, max_loss, time_of_entry

Set only on closeTrade():
  exit_price, status='closed', closed_at, (implied_vol_exit, time_of_exit via toJson)
```

---

## Model → Service Map

Which service reads/writes each model. Modify a model's serialization → check all services listed.

### `Trade` → `lib/features/trades/models/trade.dart`
| Operation | Service / Location |
|-----------|--------------------|
| INSERT (base) | `TradesNotifier.addTrade()` in `trades_provider.dart` |
| UPDATE (extended) | `TradesNotifier.addTrade()` best-effort block |
| UPDATE (close) | `TradesNotifier.closeTrade()` |
| DELETE | `TradesNotifier.deleteTrade()` |
| SELECT all | `tradesProvider` |
| Derived analytics | `TickerTradeAnalytics.compute()` in `ticker_profile_models.dart` |
| Block analytics | `TradeBlock` in `trade_block_provider.dart` |

### `TradeJournal` → `lib/features/trades/models/trade_journal.dart`
| Operation | Service / Location |
|-----------|--------------------|
| UPSERT | `TradeJournalNotifier.upsertJournal()` onConflict: `trade_id` |
| SELECT | `journalForTradeProvider(tradeId)` |

### `JournalEntry` → `lib/features/journal/models/journal_entry.dart`
| Operation | Service / Location |
|-----------|--------------------|
| INSERT | `JournalNotifier.addEntry()` |
| DELETE | `JournalNotifier.deleteEntry()` |
| SELECT all | `journalProvider` |

### `TickerProfileNote` / `SupportResistanceLevel` / `TickerInsiderBuy` / `TickerEarningsReaction`
→ `lib/features/ticker_profile/models/ticker_profile_models.dart`

| Operation | Service / Location |
|-----------|--------------------|
| INSERT notes | `TickerProfileNotifier.addNote()` |
| DELETE notes | `TickerProfileNotifier.deleteNote()` |
| INSERT S/R | `TickerProfileNotifier.addSRLevel()` |
| INVALIDATE S/R | `TickerProfileNotifier.invalidateSRLevel()` |
| INSERT insider | `TickerProfileNotifier.addInsiderBuy()` / `addInsiderBuys()` |
| DELETE insider | `TickerProfileNotifier.deleteInsiderBuy()` |
| UPSERT earnings | `TickerProfileNotifier.upsertEarningsReaction()` |
| DELETE earnings | `TickerProfileNotifier.deleteEarningsReaction()` |

### `StockQuote` → `lib/services/fmp/fmp_models.dart`
| Source | Service |
|--------|---------|
| Live Schwab quotes | `SchwabService.getQuote()` / `getQuotes()` via `SchwabQuote.toStockQuote()` |
| Economy batch | `SchwabService.getEconomyQuotes()` |
| Stored history | `EconomyStorageService._saveQuotes()` → `economy_quote_snapshots` |
| Historical read | `EconomyStorageService.getQuoteHistory(symbol)` → `QuoteSnapshot` |

### `SchwabOptionContract` → `lib/services/schwab/schwab_models.dart`
| Source | Consumer |
|--------|---------|
| Schwab chains API | `SchwabService.getOptionsChain()` |
| Parsed from `callExpDateMap` / `putExpDateMap` | `SchwabOptionsChain.fromJson()` |
| Scored | `OptionScoringEngine.score(contract, price)` |
| Analyzed | `OptionDecisionEngine.analyze(contract, price, input)` |

### `EconomicIndicatorPoint` → `lib/services/fmp/fmp_models.dart`
| Source | Consumer |
|--------|---------|
| FMP `/economic-indicators` | `FmpService.getEconomicIndicator()` |
| Stored to Supabase | `EconomyStorageService._saveIndicators()` |
| BLS responses | `EconomyStorageService.saveBlsResponse()` |
| BEA responses | `EconomyStorageService.saveBeaResponse()` |
| EIA responses | `EconomyStorageService.saveEiaResponse()` |
| Census responses | `EconomyStorageService.saveCensusResponse()` |
| FRED responses | `fred_providers.dart` save helpers |
| Read for charts | `EconomyStorageService.getIndicatorHistory(id)` |
| Read for macro score | `MacroScoreService` reads from Supabase directly |

### `MacroScore` / `MacroSubScore` → `lib/services/macro/macro_score_model.dart`
| Operation | Service / Location |
|-----------|--------------------|
| Computed | `MacroScoreService.computeScore()` |
| Provided | `macroScoreProvider` |
| Displayed | `MacroScoreCard` widget, `MacroScoreScreen` |

---

## Service → Provider Map

Modify a service method → check which providers call it and will be affected.

### `FmpService` → `lib/services/fmp/fmp_service.dart`

| Method | Provider | Provider File |
|--------|----------|---------------|
| `getQuote(symbol)` | `quoteProvider(symbol)` | `fmp_providers.dart` *(was FMP, now Schwab)* |
| `getQuotes(symbols)` | `quotesProvider(symbols)` | `fmp_providers.dart` *(was FMP, now Schwab)* |
| `getProfile(symbol)` | `stockProfileProvider(symbol)` | `fmp_providers.dart` |
| `getHistoricalPrices(symbol)` | `tickerHistoricalPricesProvider(symbol)` | `fmp_providers.dart` |
| `getEconomyIndicators()` | `economyPulseProvider` | `fmp_providers.dart` (indicators half) |
| `getEconomyPulse()` | `economyPulseProvider` *(legacy, still defined)* | `fmp_providers.dart` |
| `getNextEarnings(symbol)` | `tickerNextEarningsProvider(symbol)` | `fmp_providers.dart` |

### `SchwabService` → `lib/services/schwab/schwab_service.dart`

| Method | Provider | Provider File |
|--------|----------|---------------|
| `getQuote(symbol)` | `quoteProvider(symbol)` | `schwab_providers.dart` |
| `getQuotes(symbols)` | `quotesProvider(symbols)` | `schwab_providers.dart` |
| `searchTicker(query)` | `tickerSearchProvider(query)` | `schwab_providers.dart` |
| `getOptionsChain(symbol, ...)` | `schwabOptionsChainProvider(params)` | `schwab_providers.dart` |
| `getEconomyQuotes()` | `economyPulseProvider` | `fmp_providers.dart` (quotes half) |

### `EconomyStorageService` → `lib/services/economy/economy_storage_service.dart`

| Method | Provider | Provider File |
|--------|----------|---------------|
| `getIndicatorHistory(id)` | `economyIndicatorHistoryProvider(id)` | `economy_storage_providers.dart` |
| `getQuoteHistory(symbol)` | `economyQuoteHistoryProvider(symbol)` | `economy_storage_providers.dart` |
| `getTreasuryHistory()` | `economyTreasuryHistoryProvider` | `economy_storage_providers.dart` |
| `getUnemploymentHistory()` | `unemploymentRateHistoryProvider` | `economy_storage_providers.dart` |
| `getGasolinePriceHistory()` | `gasolinePriceHistoryStorageProvider` | `economy_storage_providers.dart` |
| `getNatGasImportHistory()` | `natGasImportPricesProvider` | `economy_storage_providers.dart` |

### `FredService` → `lib/services/fred/fred_service.dart`

| Method | Provider | Provider File |
|--------|----------|---------------|
| `getSeries(seriesId)` | `fredSeriesProvider(seriesId)` | `fred_providers.dart` |
| *(via fredSeriesProvider)* | `fredVixProvider` | `fred_providers.dart` |
| *(via fredSeriesProvider)* | `fredGoldProvider` | `fred_providers.dart` |
| *(via fredSeriesProvider)* | `fredSilverProvider` | `fred_providers.dart` |
| *(via fredSeriesProvider)* | `fredHyOasProvider` | `fred_providers.dart` |
| *(via fredSeriesProvider)* | `fredIgOasProvider` | `fred_providers.dart` |
| *(via fredSeriesProvider)* | `fredSpreadProvider` | `fred_providers.dart` |
| *(via fredSeriesProvider)* | `fredFedFundsProvider` | `fred_providers.dart` |

### `MacroScoreService` → `lib/services/macro/macro_score_service.dart`

| Method | Provider | Provider File |
|--------|----------|---------------|
| `computeScore()` | `macroScoreProvider` | `lib/services/macro/macro_score_provider.dart` |

**`MacroScoreService` reads directly from Supabase:**
- `economy_indicator_snapshots` — VIX, fed funds, gold, HY OAS, IG OAS, 2s10s spread
- `economy_quote_snapshots` — SPY (30-day trend), UUP (dollar)
- `economy_treasury_snapshots` — yield curve for spread calculation

---

## Provider → UI Consumer Map

Modify a provider's return type or name → update every consumer listed.

### Auth Providers → `lib/features/auth/providers/auth_provider.dart`

| Provider | Consumers |
|----------|-----------|
| `supabaseClientProvider` | Every notifier/provider that hits Supabase |
| `authStateProvider` | `routerProvider` (auth guard redirect) |
| `currentUserProvider` | `login_screen`, `signup_screen` |
| `authNotifierProvider` | `login_screen` (signIn), `signup_screen` (signUp), `summary_screen` AppBar logout |

### Trades Providers → `lib/features/trades/providers/trades_provider.dart`

| Provider | Consumers |
|----------|-----------|
| `tradesProvider` | `trades_screen`, `summary_screen`, `ticker_dashboard_screen`, `trade_block_provider`, `ticker_profile_providers` (tickerTradesProvider) |
| `openTradesProvider` | available — not directly watched (screens filter `tradesProvider`) |
| `closedTradesProvider` | `trade_block_provider` → `blockWinRateProvider` → `edgeErodingProvider` |
| `tradesNotifierProvider` | `add_trade_screen`, `trade_detail_screen`, `csv_import_screen` |

### Trade Journal Provider → `lib/features/trades/providers/trade_journal_provider.dart`

| Provider | Consumers |
|----------|-----------|
| `journalForTradeProvider(tradeId)` | `trade_detail_screen`, `trade_journal_screen` |
| `tradeJournalNotifierProvider` | `trade_journal_screen`, `csv_import_screen` |

### Trade Block Provider → `lib/features/trades/providers/trade_block_provider.dart`

| Provider | Consumers |
|----------|-----------|
| `blockWinRateProvider` | `trades_screen` (block analytics tab), `trade_blocks_screen` |
| `edgeErodingProvider` | `summary_screen` (warning banner), `trades_screen` |

### Journal Providers → `lib/features/journal/providers/journal_provider.dart`

| Provider | Consumers |
|----------|-----------|
| `journalProvider` | `journal_screen` |
| `journalNotifierProvider` | `add_journal_screen`, `journal_screen` (delete) |

### Ticker Profile Providers → `lib/features/ticker_profile/providers/`

| Provider | Consumers |
|----------|-----------|
| `watchedTickersProvider` | `ticker_dashboard_screen` |
| `tickerNotesProvider(symbol)` | `tickerTimelineProvider(symbol)` |
| `tickerSRLevelsProvider(symbol)` | `tickerTimelineProvider(symbol)`, `activeSRLevelsProvider(symbol)` |
| `tickerInsiderBuysProvider(symbol)` | `tickerTimelineProvider(symbol)` |
| `tickerEarningsReactionsProvider(symbol)` | `tickerTimelineProvider(symbol)` |
| `tickerTradesProvider(symbol)` | `tickerAnalyticsProvider(symbol)`, `tickerTimelineProvider(symbol)` |
| `tickerAnalyticsProvider(symbol)` | `ticker_profile_screen` (stats tab) |
| `activeSRLevelsProvider(symbol)` | `ticker_profile_screen` (S/R tab) |
| `tickerTimelineProvider(symbol)` | `ticker_profile_screen` (timeline tab) |
| `tickerProfileNotifierProvider` | `ticker_profile_screen` (all mutations) |

### FMP Providers → `lib/services/fmp/fmp_providers.dart`

| Provider | Consumers |
|----------|-----------|
| `quoteProvider(symbol)` | `trade_detail_screen` (live quote card), `ticker_dashboard_screen` (prices) |
| `quotesProvider(symbols)` | available — not directly watched in screens |
| `stockProfileProvider(symbol)` | available — not rendered yet |
| `tickerHistoricalPricesProvider(symbol)` | `ticker_profile_screen` (price chart tab) |
| `economyPulseProvider` | `economy_pulse_screen` (all tiles + triggers all listeners) |
| `tickerNextEarningsProvider(symbol)` | `ticker_profile_screen` (overview tab) |

### Schwab Providers → `lib/services/schwab/schwab_providers.dart`

| Provider | Consumers |
|----------|-----------|
| `quoteProvider(symbol)` | `summary_screen` (open position rows), `ticker_profile_screen` AppBar |
| `quotesProvider(symbols)` | available |
| `tickerSearchProvider(query)` | `add_trade_screen` (autocomplete), `ticker_dashboard_screen` (search dialog) |
| `schwabOptionsChainProvider(params)` | `options_chain_screen`, `option_decision_wizard` |

### Economy Storage Providers → `lib/services/economy/economy_storage_providers.dart`

| Provider | Consumers |
|----------|-----------|
| `economyStorageServiceProvider` | `economy_pulse_screen` (triggers saves), `economy_charts_tab` |
| `economyIndicatorHistoryProvider(id)` | `economy_charts_tab` (every `_IndicatorChart`) |
| `economyQuoteHistoryProvider(symbol)` | `economy_charts_tab` (every `_QuoteChart`) |
| `economyTreasuryHistoryProvider` | `economy_charts_tab` (`_TreasuryChart`) |
| `unemploymentRateHistoryProvider` | `economy_charts_tab` |
| `gasolinePriceHistoryStorageProvider` | `economy_charts_tab` |
| `natGasImportPricesProvider` | `economy_charts_tab` |

### Macro Score Provider → `lib/services/macro/macro_score_provider.dart`

| Provider | Consumers |
|----------|-----------|
| `macroScoreProvider` | `summary_screen` (`MacroScoreCard`), `macro_score_screen` |

### FRED Providers → `lib/services/fred/fred_providers.dart`

| Provider | Consumers |
|----------|-----------|
| `fredVixProvider` | `economy_pulse_screen` (ref.listen → saveFredVix) |
| `fredGoldProvider` | `economy_pulse_screen` (ref.listen → saveFredGold) |
| `fredSilverProvider` | `economy_pulse_screen` (ref.listen → saveFredSilver) |
| `fredHyOasProvider` | `economy_pulse_screen` (ref.listen → saveFredHyOas) |
| `fredIgOasProvider` | `economy_pulse_screen` (ref.listen → saveFredIgOas) |
| `fredSpreadProvider` | `economy_pulse_screen` (ref.listen → saveFredSpread) |
| `fredFedFundsProvider` | `economy_pulse_screen` (ref.listen → saveFredFedFunds) |

---

## Full Vertical Traces (End-to-End)

These traces show the complete path from user action to Supabase and back to UI.

---

### TRACE 1: Log a Trade

```
User fills AddTradeScreen form
    │
    ▼
ref.read(tradesNotifierProvider.notifier).addTrade(trade)
    │
    ├─ Step 1: INSERT into `trades` (base cols, migration 001)
    │          ← returns { id }
    │
    ├─ Step 2: UPDATE `trades` (extended cols, migration 006)
    │          best-effort, silent fail if columns absent
    │
    └─ ref.invalidate(tradesProvider)
           │
           ├─ tradesProvider re-fetches → trades_screen refreshes
           ├─ blockWinRateProvider recomputes → edgeErodingProvider updates
           ├─ tickerTradesProvider(symbol) recomputes → tickerAnalyticsProvider updates
           └─ summary_screen open-positions list refreshes
```

**Files in chain:**
`add_trade_screen.dart` → `trades_provider.dart` → `trade.dart` (toJson) → Supabase `trades` → `trades_provider.dart` (re-fetch) → `trades_screen.dart`, `summary_screen.dart`, `trade_block_provider.dart`, `ticker_profile_providers.dart`

---

### TRACE 2: View Options Chain → Score → Log Trade

```
TickerProfileScreen AppBar candlestick icon
    │
    ▼
context.push('/ticker/$symbol/chains')
    │
    ▼
OptionsChainScreen
    │
    ├─ ref.watch(schwabOptionsChainProvider(params))
    │      │
    │      └─ SchwabService.getOptionsChain(symbol)
    │             │
    │             └─ Edge Function: get-schwab-chains
    │                    │
    │                    └─ Schwab API → callExpDateMap / putExpDateMap
    │                           │
    │                           └─ SchwabOptionsChain.fromJson()
    │
    ├─ Each row: OptionScoringEngine.score(contract, underlyingPrice)
    │              → delta (20) + DTE (20) + spread% (15) + IV (20) + OI (10) + moneyness (15)
    │
    └─ Tap row → OptionScoreSheet bottom sheet (full Greeks breakdown)
           │
           └─ "Log This Trade" → context.push('/trades/add', extra: prefill)
                  │
                  └─ [see TRACE 1]

FAB "Analyze" → context.push('/ticker/$symbol/chains/wizard')
    │
    ▼
OptionDecisionWizard
    │
    ├─ ref.watch(schwabOptionsChainProvider(params))  (strikeCount: 20)
    │
    └─ User submits direction + target + budget
           │
           └─ OptionDecisionEngine.rankAll(chain, input, topN: 8)
                  │
                  ├─ Calls OptionDecisionEngine.analyze() per contract
                  │    └─ OptionScoringEngine.score() per contract
                  │
                  └─ Returns List<OptionDecisionResult> sorted:
                       Buy → Watch → Avoid, then by score desc
                       │
                       └─ "Log This Trade" on Buy cards → [TRACE 1]
```

**Files in chain:**
`ticker_profile_screen.dart` → `options_chain_screen.dart` → `schwab_providers.dart` → `schwab_service.dart` → Edge Function `get-schwab-chains` → Schwab API → `schwab_models.dart` → `option_scoring_engine.dart` → `option_score_sheet.dart` → `option_decision_wizard.dart` → `option_decision_engine.dart` → `add_trade_screen.dart` → [TRACE 1]

---

### TRACE 3: Economy Pulse → Snapshot → Chart History

```
User opens EconomyPulseScreen
    │
    ▼
ref.watch(economyPulseProvider)
    │
    ├─ SchwabService.getEconomyQuotes()           (market quotes — parallel)
    │      ['SPY','QQQ','VIXY','$DXY','/GC','/SI','/CL','/NG','HYG','LQD','COPX']
    │      Edge Function: get-schwab-quotes → Schwab API
    │
    └─ FmpService.getEconomyIndicators()          (macro indicators — parallel)
           [Treasury + Fed Funds + Unemp + NFP + Claims + CPI + GDP + Retail + Sentiment + Mortgage + Housing + Recession]
           FMP REST API
           │
           └─ Returns EconomyPulseData (merged)

EconomyPulseScreen ref.listen(economyPulseProvider, ...) fires on data:
    │
    ├─ EconomyStorageService.saveEconomyPulse(data)
    │      ├─ UPSERT economy_indicator_snapshots (11 indicators)
    │      ├─ UPSERT economy_treasury_snapshots  (yield curve)
    │      └─ UPSERT economy_quote_snapshots     (11 market quotes)
    │
    ├─ ref.listen(fredVixProvider, ...)    → saveFredVix() → UPSERT indicator_snapshots
    ├─ ref.listen(fredGoldProvider, ...)   → saveFredGold()
    ├─ ref.listen(fredHyOasProvider, ...)  → saveFredHyOas()
    ├─ ref.listen(fredIgOasProvider, ...)  → saveFredIgOas()
    ├─ ref.listen(fredSpreadProvider, ...) → saveFredSpread()
    ├─ ref.listen(fredFedFundsProvider, .)→ saveFredFedFunds()
    │
    ├─ ref.listen(blsEmploymentProvider, .) → saveBlsResponse() → UPSERT indicator_snapshots
    ├─ ref.listen(blsCpiProvider, ...)
    ├─ ref.listen(blsPpiProvider, ...)
    ├─ ref.listen(blsJoltsProvider, ...)
    │
    ├─ ref.listen(beaGdpProvider, ...)     → saveBeaResponse()
    ├─ ref.listen(beaCorePceProvider, ...)
    ├─ [5 more BEA listeners]
    │
    ├─ ref.listen(eiaGasolinePricesProvider, .) → saveEiaResponse()
    ├─ [5 more EIA listeners]
    │
    └─ ref.listen(censusRetailSalesProvider, .) → saveCensusResponse()
         [5 more Census listeners]

User switches to Charts tab (economy_charts_tab.dart):
    │
    ├─ _QuoteChart(symbol: '/GC') → ref.watch(economyQuoteHistoryProvider('/GC'))
    │      └─ EconomyStorageService.getQuoteHistory('/GC')
    │             └─ SELECT economy_quote_snapshots WHERE symbol='/GC' ORDER BY date ASC
    │
    └─ _IndicatorChart(identifier: EconIds.blsCpiAll) → ref.watch(economyIndicatorHistoryProvider(id))
           └─ EconomyStorageService.getIndicatorHistory(id)
                  └─ SELECT economy_indicator_snapshots WHERE identifier=id ORDER BY date ASC
```

**Symbol key — economy_quote_snapshots:**

| Supabase symbol | Display label | Source |
|-----------------|---------------|--------|
| `SPY` | S&P 500 | Schwab |
| `QQQ` | Nasdaq 100 | Schwab |
| `VIXY` | VIX | Schwab |
| `$DXY` | Dollar Index | Schwab |
| `/GC` | Gold | Schwab futures |
| `/SI` | Silver | Schwab futures |
| `/CL` | WTI Crude | Schwab futures |
| `/NG` | Natural Gas | Schwab futures |
| `HYG` | High Yield Bonds | Schwab |
| `LQD` | IG Bonds | Schwab |
| `COPX` | Copper Miners | Schwab |

---

### TRACE 4: Macro Score Computation

```
ref.watch(macroScoreProvider)
    │
    └─ MacroScoreService.computeScore()
           │
           ├─ _vixComponent()    → reads economy_indicator_snapshots (FredStorageIds.vix)
           │                       fallback: economy_quote_snapshots (VIXY)
           │
           ├─ _yieldCurveComponent() → reads economy_indicator_snapshots (FredStorageIds.spread2s10s)
           │                           fallback: economy_treasury_snapshots (year10 - year2)
           │
           ├─ _fedTrajectoryComponent() → reads economy_indicator_snapshots (FredStorageIds.fedFunds)
           │
           ├─ _spyTrendComponent() → reads economy_quote_snapshots (symbol='SPY')
           │                         30-day moving average
           │
           ├─ _dollarComponent()   → reads economy_quote_snapshots (symbol='UUP')
           │                         30-day trend
           │
           ├─ _hyOasComponent()    → reads economy_indicator_snapshots (FredStorageIds.hyOas)
           │                         fallback: economy_quote_snapshots (HYG)
           │
           ├─ _igOasComponent()    → reads economy_indicator_snapshots (FredStorageIds.igOas)
           │
           └─ _goldCopperComponent() → reads economy_indicator_snapshots (gold)
                                        reads economy_quote_snapshots (COPX)

Returns MacroScore { total: 0–100, regime: MacroRegime, components: [8 × MacroSubScore] }
    │
    └─ Displayed in:
           ├─ MacroScoreCard widget (embedded in summary_screen)
           └─ MacroScoreScreen (/macro route)
```

---

### TRACE 5: Ticker Profile Timeline Assembly

```
ref.watch(tickerTimelineProvider(symbol))
    │
    ├─ tickerTradesProvider(symbol)     → filters tradesProvider by ticker
    ├─ tickerNotesProvider(symbol)      → SELECT ticker_profile_notes WHERE ticker=symbol
    ├─ tickerSRLevelsProvider(symbol)   → SELECT ticker_support_resistance WHERE ticker=symbol
    ├─ tickerInsiderBuysProvider(symbol)→ SELECT ticker_insider_buys WHERE ticker=symbol
    ├─ tickerEarningsReactionsProvider(symbol) → SELECT ticker_earnings_reactions
    └─ (SEC filings from external source, if implemented)
           │
           └─ Merge all → sort by timestamp DESC → List<TickerTimelineEvent>
                  │
                  └─ ticker_profile_screen.dart (Timeline tab)
```

---

## Router & Navigation Map

```
routerProvider (watches authStateProvider)
│
├─ /                          SummaryScreen          _AppShell
├─ /login                     LoginScreen
├─ /signup                    SignupScreen
├─ /auth/callback             _AuthCallbackScreen
│
├─ /trades                    TradesScreen           _AppShell
│   ├─ /trades/add            AddTradeScreen
│   ├─ /trades/blocks         TradeBlocksScreen
│   ├─ /trades/import         CsvImportScreen
│   └─ /trades/:id            TradeDetailScreen      extra: Trade
│       └─ /trades/:id/journal TradeJournalScreen    extra: Trade
│
├─ /calculator                CalculatorScreen       _AppShell
│
├─ /journal                   JournalScreen          _AppShell
│   └─ /journal/add           AddJournalScreen
│
├─ /economy                   EconomyPulseScreen     _AppShell
│
├─ /ticker                    TickerDashboardScreen  _AppShell
│   └─ /ticker/:symbol        TickerProfileScreen    (no shell)
│       └─ /ticker/:symbol/chains    OptionsChainScreen
│           └─ /ticker/:symbol/chains/wizard   OptionDecisionWizard
│
└─ Auth guard:
   Unauthenticated → /login
   Authenticated on /login or /signup → /
   /auth/callback + authenticated → /
```

---

## External API → Edge Function → Service Map

| External API | Edge Function | Dart Service | Auth Method |
|-------------|---------------|-------------|-------------|
| Schwab MarketData | `get-schwab-quotes` | `SchwabService.getQuotes()` | Bearer token from `schwab_tokens` table |
| Schwab MarketData | `get-schwab-chains` | `SchwabService.getOptionsChain()` | same |
| Schwab MarketData | `get-schwab-instruments` | `SchwabService.searchTicker()` | same |
| Schwab OAuth | `schwab-bootstrap` | *(one-time setup)* | client_credentials |
| FRED | `get-fred-series` | `FredService.getSeries()` | FRED_API_KEY env var |
| BLS | `get-bls-series` | `BlsService.fetchSeries()` | BLS_API_KEY env var |
| BEA | `get-bea-data` | `BeaService._getNipa()` | BEA_API_KEY env var |
| EIA | `get-eia-data` | `EiaService.*()` | EIA_API_KEY env var |
| Census | `get-census-data` | `CensusService.*()` | CENSUS_API_KEY env var |
| FMP | Direct HTTP | `FmpService.*()` | `?apikey=` query param |

**Schwab token refresh flow (`_shared/schwab_auth.ts`):**
```
getValidToken()
  → reads schwab_tokens (1 row)
  → if expires_at - 5min < now:
      POST https://api.schwabapi.com/v1/oauth/token (refresh_token grant)
      → UPDATE schwab_tokens
  → returns access_token
  → if refresh fails: throws SCHWAB_REAUTH_REQUIRED (→ 401 to Flutter)
```

---

## Pure Engines (No Provider Dependencies)

These are pure Dart — no Riverpod, no Supabase, no HTTP. Safe to unit test in isolation.

### `OptionScoringEngine` → `lib/features/options/services/option_scoring_engine.dart`

```dart
static OptionScore score(SchwabOptionContract contract, double underlyingPrice)
```

| Criterion | Max Points | Logic |
|-----------|-----------|-------|
| Delta | 20 | Sweet spot 0.30–0.50 abs |
| DTE | 20 | Sweet spot 21–45 days |
| Bid-Ask Spread % | 15 | Tighter = better |
| Implied Volatility | 20 | IV vs historical range |
| Open Interest | 10 | Higher OI = more liquid |
| Moneyness | 15 | Slight OTM preferred |

**Returns:** `OptionScore { total, delta, dte, spread, iv, oi, moneyness, grade(A/B/C/D), flags[] }`

**Consumed by:** `_ContractRow` in `options_chain_screen.dart`, `OptionDecisionEngine.analyze()`

---

### `OptionDecisionEngine` → `lib/features/options/services/option_decision_engine.dart`

```dart
static OptionDecisionResult analyze(contract, underlyingPrice, input)
static List<OptionDecisionResult> rankAll({chain, input, topN})
```

**Input:** `OptionDecisionInput { direction, priceTarget, maxBudget, contracts }`

**Output:** `OptionDecisionResult` with 15+ fields:

| Field | Computation |
|-------|-------------|
| `entryCost` | `ask × contracts × 100` |
| `contractsAffordable` | `floor(maxBudget / (ask × 100))` |
| `estimatedPnl` | `delta × (target - price) × 100 × contracts` |
| `estimatedReturn` | `pnl / entryCost × 100` |
| `breakEvenPrice` | `strike ± ask` |
| `breakEvenMovePct` | `(breakEven - price) / price × 100` |
| `dailyThetaDrag` | `theta × 100 × contracts` |
| `pricingEdge` | `theoreticalOptionValue - midpoint` |
| `volOiRatio` | `totalVolume / openInterest` |
| `vegaDollarPer1PctIv` | `vega × 100 × contracts` |
| `recommendation` | `Buy` / `Watch` / `Avoid` |

**Rank order:** Buy → Watch → Avoid, then score descending.

**Consumed by:** `option_decision_wizard.dart`

---

## Invalidation Chains

When a notifier method fires, these providers are invalidated and re-fetch:

```
TradesNotifier.addTrade() / closeTrade() / deleteTrade()
    └─► ref.invalidate(tradesProvider)
            └─► trades_screen re-renders
            └─► blockWinRateProvider recomputes (watches closedTradesProvider ← tradesProvider)
                    └─► edgeErodingProvider updates
                            └─► summary_screen warning banner updates
            └─► tickerTradesProvider(symbol) recomputes (watches tradesProvider)
                    └─► tickerAnalyticsProvider(symbol) recomputes
                    └─► tickerTimelineProvider(symbol) recomputes
                            └─► ticker_profile_screen refreshes

JournalNotifier.addEntry() / deleteEntry()
    └─► ref.invalidate(journalProvider)
            └─► journal_screen re-renders

TradeJournalNotifier.upsertJournal(journal)
    └─► ref.invalidate(journalForTradeProvider(journal.tradeId))
            └─► trade_journal_screen refreshes
            └─► trade_detail_screen journal badge refreshes

TickerProfileNotifier.addNote() / deleteNote()
    └─► ref.invalidate(tickerNotesProvider(symbol))
            └─► tickerTimelineProvider(symbol) recomputes

TickerProfileNotifier.addSRLevel() / invalidateSRLevel()
    └─► ref.invalidate(tickerSRLevelsProvider(symbol))
            └─► activeSRLevelsProvider(symbol) recomputes
            └─► tickerTimelineProvider(symbol) recomputes

TickerProfileNotifier.addInsiderBuy() / deleteInsiderBuy()
    └─► ref.invalidate(tickerInsiderBuysProvider(symbol))
            └─► tickerTimelineProvider(symbol) recomputes

TickerProfileNotifier.upsertEarningsReaction() / deleteEarningsReaction()
    └─► ref.invalidate(tickerEarningsReactionsProvider(symbol))
            └─► tickerTimelineProvider(symbol) recomputes

TickerProfileNotifier.addWatchedTicker() / removeWatchedTicker()
    └─► ref.invalidate(watchedTickersProvider)
            └─► ticker_dashboard_screen refreshes
```

---

## Shared Type Registry

Types used across multiple layers. Changing any of these has the widest blast radius.

| Type | Defined In | Used In |
|------|-----------|---------|
| `StockQuote` | `fmp_models.dart` | `schwab_models.dart` (adapter), `fmp_service`, `schwab_service`, `economy_storage_service`, `macro_score_service`, every screen with live prices |
| `Trade` | `trade.dart` | `trades_provider`, `trade_journal_provider`, `trade_block_provider`, `ticker_profile_providers`, `ticker_profile_models`, every trade screen, `summary_screen` |
| `EconomyPulseData` | `fmp_models.dart` | `fmp_service.getEconomyPulse()`, `fmp_providers.economyPulseProvider`, `economy_storage_service._saveQuotes()/_saveIndicators()`, `economy_pulse_screen` |
| `EconomicIndicatorPoint` | `fmp_models.dart` | `fmp_service`, `economy_storage_service` (read/write), `macro_score_service` (reads from DB) |
| `SchwabOptionContract` | `schwab_models.dart` | `schwab_service`, `option_scoring_engine`, `option_decision_engine`, `options_chain_screen`, `option_score_sheet`, `option_decision_wizard` |
| `SchwabOptionsChain` | `schwab_models.dart` | `schwab_service`, `schwab_providers`, `options_chain_screen`, `option_decision_wizard`, `option_decision_engine` |
| `MacroScore` | `macro_score_model.dart` | `macro_score_service`, `macro_score_provider`, `macro_score_card`, `macro_score_screen`, `summary_screen` |
| `OptionsChainParams` | `schwab_providers.dart` | `schwab_providers.schwabOptionsChainProvider`, `options_chain_screen`, `option_decision_wizard` |
| `TradeBlock` | `trade_block_provider.dart` | `blockWinRateProvider`, `edgeErodingProvider`, `trades_screen`, `trade_blocks_screen`, `summary_screen` |
| `TickerTimelineEvent` | `ticker_profile_models.dart` | `tickerTimelineProvider`, `ticker_profile_screen` |
| `TreasuryRates` / `TreasurySnapshot` | `fmp_models.dart` / `economy_snapshot_models.dart` | `fmp_service`, `economy_storage_service`, `macro_score_service`, `economy_charts_tab` |

---

*Last updated: 2026-04-03*
*Coverage: 14 model files · 9 service files · 11 provider files · 14 screen files*
