# Feature Index — Swing Options Trader

> **How to use this index:**
> When you change a file in any feature, look up that feature here to find every other file that will be affected (the "waterfall"). Cross-feature dependencies tell you which other features need review.
>
> **Layer labels used below:**
> `[UI]` Flutter screen/widget · `[MODEL]` Dart data model · `[PROVIDER]` Riverpod state · `[SVC]` Service/repository · `[API]` Python FastAPI · `[DB]` Supabase migration · `[FN]` Supabase Edge Function

---

## A

### Auth & Account Management
_Supabase auth, login, signup, session guard. All other features depend on authenticated `user_id` for RLS._

| Layer | File |
|-------|------|
| [UI] | lib/features/auth/screens/login_screen.dart |
| [UI] | lib/features/auth/screens/signup_screen.dart |
| [PROVIDER] | lib/features/auth/providers/auth_provider.dart |
| [UI] | lib/core/router.dart ← auth guard + `_AuthCallbackScreen` (PKCE) |

**Waterfall:** Changing auth flow touches every feature's RLS policy and every screen behind the auth guard. The router.dart `_AuthCallbackScreen` is the single point of PKCE token exchange — changes here break OAuth redirects for Schwab as well.

---

## B

### Blotter (5-Phase Trade Evaluation)
_Stepwise trade evaluation: Economic → Formula → Vol Surface → Greek Grid → Kalshi. Reads snapshots from four other features._

| Layer | File |
|-------|------|
| [UI] | lib/features/blotter/screens/five_phase_blotter_screen.dart |
| [UI] | lib/features/blotter/widgets/phase_stepper.dart |
| [UI] | lib/features/blotter/widgets/phase_panels/blotter_phase_panel.dart |
| [UI] | lib/features/blotter/widgets/phase_panels/economic_phase_panel.dart |
| [UI] | lib/features/blotter/widgets/phase_panels/formula_phase_panel.dart |
| [UI] | lib/features/blotter/widgets/phase_panels/vol_surface_phase_panel.dart |
| [UI] | lib/features/blotter/widgets/phase_panels/greek_grid_phase_panel.dart |
| [UI] | lib/features/blotter/widgets/phase_panels/kalshi_phase_panel.dart |
| [MODEL] | lib/features/blotter/models/blotter_models.dart |
| [MODEL] | lib/features/blotter/models/phase_result.dart |
| [SVC] | lib/features/blotter/services/fair_value_engine.dart |
| [API] | api/routers/fair_value.py |
| [API] | api/services/fair_value_engine.py |
| [DB] | supabase/migrations/012_blotter_trades.sql → `blotter_trades` |

**Waterfall — Reads from (changes to these may break phases):**
- Economy: `economy_indicator_snapshots` → economic_phase_panel
- IV: `iv_snapshots` → formula_phase_panel
- Vol Surface: `vol_surface_snapshots` → vol_surface_phase_panel
- Greek Grid: `greek_grid_snapshots` → greek_grid_phase_panel
- Kalshi: live via kalshi_providers → kalshi_phase_panel
- Regime: `regime_snapshots` → used by fair_value_engine

**Waterfall — Writes to:**
- `blotter_trades` (012)
- Result can be saved as → **Ideas** (`trade_ideas`)

---

## C

### Calculator
_Black-Scholes payoff / Greeks standalone calculator._

| Layer | File |
|-------|------|
| [UI] | lib/features/calculator/screens/calculator_screen.dart |
| [API] | api/routers/black_scholes.py |
| [API] | api/services/black_scholes.py |

**Waterfall:** The B-S service is shared with Options & Decision Engine. Changes to `api/services/black_scholes.py` affect both Calculator and the Formula phase of Blotter.

---

### Current Regime (ML)
_Machine-learning market regime classification. Ingests macro + IV data, trains and stores models, classifies current regime._

| Layer | File |
|-------|------|
| [UI] | lib/features/current_regime/screens/current_regime_screen.dart |
| [MODEL] | lib/features/current_regime/models/regime_ml_models.dart |
| [PROVIDER] | lib/features/current_regime/providers/regime_ml_provider.dart |
| [API] | api/routers/regime.py ← `/classify`, `/train`, `/ml_analyze` |
| [API] | api/services/regime_ml_service.py |
| [API] | api/services/regime_ml_trainer.py |
| [API] | api/services/regime_service.py ← heuristic fallback |
| [API] | api/services/hmm_regime.py ← HMM / VIX classification |
| [API] | api/jobs/schwab_pull.py ← periodic snapshot ingestion |
| [DB] | supabase/migrations/024_regime_snapshot.sql → `regime_snapshots` |
| [DB] | supabase/migrations/025_regime_snapshots_institutional_fields.sql |
| [DB] | supabase/migrations/026_regime_ml_models.sql → `regime_ml_models` |
| [FN] | supabase/functions/get-schwab-quotes/index.ts ← quote data |
| [FN] | supabase/functions/schwab-bootstrap/index.ts ← OAuth tokens |

**Waterfall — Reads from:**
- Economy: macro indicators as ML features
- IV: implied vol metrics as ML features
- Schwab: live quotes via `schwab_pull` job

**Waterfall — Writes to:**
- `regime_snapshots` (024) — read by Blotter phase 1 + Summary
- `regime_ml_models` (026) — storing trained model JSON

**Changing the ML feature schema** (026) requires updating `regime_ml_models.dart`, `regime_ml_service.py`, and the regime provider.
regime_ml_models - supabase
| column_name | data_type                |
| ----------- | ------------------------ |
| id          | bigint                   |
| model_type  | text                     |
| trained_at  | timestamp with time zone |
| n_samples   | integer                  |
| n_positive  | integer                  |
| accuracy    | double precision         |
| auc_roc     | double precision         |
| precision   | double precision         |
| recall      | double precision         |
| model_json  | jsonb                    |

regime_snapshots
| column_name              | data_type                |
| ------------------------ | ------------------------ |
| ticker                   | text                     |
| obs_date                 | date                     |
| gamma_regime             | text                     |
| iv_gex_signal            | text                     |
| sma10                    | double precision         |
| sma50                    | double precision         |
| sma_crossed              | boolean                  |
| vix_current              | double precision         |
| vix_10ma                 | double precision         |
| vix_dev_pct              | double precision         |
| vix_rsi                  | double precision         |
| spot_to_zgl_pct          | double precision         |
| iv_percentile            | double precision         |
| hmm_state                | text                     |
| hmm_probability          | double precision         |
| strategy_bias            | text                     |
| signals                  | ARRAY                    |
| created_at               | timestamp with time zone |
| delta_gex                | numeric                  |
| vix_term_structure_ratio | numeric                  |
| vvix_current             | numeric                  |
| spot_to_vt_pct           | numeric                  |
| breadth_proxy            | numeric                  |
| gex_0dte                 | numeric                  |
| gex_0dte_pct             | numeric                  |
| price_roc5               | numeric                  |
| total_gex                | numeric                  |
| vol_sma3                 | double precision         |
| vol_sma20                | double precision         |
---

## E

### Economy & Macro Indicators
_Aggregates BLS, BEA, EIA, Census, FRED, Kalshi data into snapshots. One of the most widely read features — changes cascade broadly._

| Layer | File |
|-------|------|
| [UI] | lib/features/economy/screens/economy_pulse_screen.dart |
| [UI] | lib/features/economy/widgets/api_tile_widgets.dart |
| [UI] | lib/features/economy/widgets/bea_tab.dart |
| [UI] | lib/features/economy/widgets/bls_tab.dart |
| [UI] | lib/features/economy/widgets/census_tab.dart |
| [UI] | lib/features/economy/widgets/eia_tab.dart |
| [UI] | lib/features/economy/widgets/fred_tab.dart |
| [UI] | lib/features/economy/widgets/kalshi_tab.dart |
| [UI] | lib/features/economy/widgets/economy_charts_tab.dart |
| [UI] | lib/features/economy/widgets/gasoline_price_history_chart.dart |
| [UI] | lib/features/economy/widgets/nat_gas_import_chart.dart |
| [UI] | lib/features/economy/widgets/unemployment_rate_chart.dart |
| [SVC] | lib/services/bls/bls_service.dart + bls_models.dart |
| [SVC] | lib/services/bea/bea_service.dart + bea_models.dart |
| [SVC] | lib/services/eia/eia_service.dart + eia_models.dart |
| [SVC] | lib/services/census/census_service.dart + census_models.dart |
| [SVC] | lib/services/fred/fred_service.dart + fred_models.dart + fred_providers.dart + fred_storage_service.dart |
| [SVC] | lib/services/kalshi/kalshi_service.dart + kalshi_models.dart + kalshi_providers.dart |
| [SVC] | lib/services/economy/economy_snapshot_models.dart |
| [SVC] | lib/services/economy/economy_storage_service.dart |
| [SVC] | lib/services/economy/economy_storage_providers.dart |
| [API] | api/routers/macro.py |
| [API] | api/services/macro_score.py |
| [FN] | supabase/functions/get-bls-data/index.ts |
| [FN] | supabase/functions/get-bea-data/index.ts |
| [FN] | supabase/functions/get-eia-data/index.ts |
| [FN] | supabase/functions/get-census-data/index.ts |
| [FN] | supabase/functions/get-fred-data/index.ts |
| [FN] | supabase/functions/get-kalshi-data/index.ts |
| [DB] | supabase/migrations/005_economy_snapshots.sql → `economy_indicator_snapshots`, `economy_treasury_snapshots`, `economy_quote_snapshots` |
| [DB] | supabase/migrations/007_gasoline_price_history.sql → `us_gasoline_price_history` |
| [DB] | supabase/migrations/008_unemployment_rate_history.sql → `us_unemployment_rate_history` |
| [DB] | supabase/migrations/009_nat_gas_import_prices.sql → `us_natural_gas_import_prices` |

**Macro Score sub-feature:**

| Layer | File |
|-------|------|
| [UI] | lib/features/macro/macro_score_screen.dart |
| [UI] | lib/features/macro/macro_score_card.dart |
| [UI] | lib/features/macro/iv_crush_tracker_screen.dart |
| [UI] | lib/features/macro/fred_sync_widget.dart |
| [SVC] | lib/services/macro/macro_score_model.dart |
| [PROVIDER] | lib/services/macro/macro_score_provider.dart |

**Waterfall — Writes to:**
- `economy_indicator_snapshots` — read by Blotter (economic phase) and Regime (ML features)

**Waterfall — Changing an edge function** (e.g. `get-bls-data`) requires matching changes to `bls_service.dart`, `bls_models.dart`, and the economy snapshot schema if fields change.


---

## G

### Greek Grid
_Greeks heatmap across strikes/DTEs. Snapshot-based; one phase of Blotter._

| Layer | File |
|-------|------|
| [UI] | lib/features/greek_grid/screens/greek_grid_screen.dart |
| [UI] | lib/features/greek_grid/widgets/greek_grid_heatmap.dart |
| [UI] | lib/features/greek_grid/widgets/greek_cell_detail_sheet.dart |
| [UI] | lib/features/greek_grid/widgets/greek_interpretation_panel.dart |
| [MODEL] | lib/features/greek_grid/models/greek_grid_models.dart |
| [PROVIDER] | lib/features/greek_grid/providers/greek_grid_providers.dart |
| [SVC] | lib/features/greek_grid/services/greek_grid_repository.dart |
| [SVC] | lib/features/greek_grid/services/greek_interpreter.dart |
| [API] | api/routers/greek_grid.py |
| [API] | api/services/greek_grid_ingester.py |
| [API] | api/services/greek_interpreter.py |
| [DB] | supabase/migrations/022_greek_grid_snapshots.sql → `greek_grid_snapshots` |

**Waterfall:** `greek_grid_snapshots` is read by Blotter phase 4. Adding new greek fields to the snapshot schema (022) requires changes to `greek_grid_models.dart`, `greek_grid_ingester.py`, and `greek_grid_phase_panel.dart`.

---

## I

### Ideas (Trade Ideas)
_AI/engine-generated trade idea records. Output of Blotter and Regime scoring._

| Layer | File |
|-------|------|
| [UI] | lib/features/ideas/screens/trade_ideas_screen.dart |
| [MODEL] | lib/features/ideas/models/trade_idea.dart |
| [PROVIDER] | lib/features/ideas/providers/trade_ideas_notifier.dart |
| [DB] | supabase/migrations/020_trade_ideas.sql → `trade_ideas` |

**Waterfall:** Ideas are written by Blotter / Regime; displayed in Ideas screen and Summary. Changing `trade_idea.dart` model requires matching change to the `trade_ideas` schema (020).

---

### IV & Volatility Analytics
_IV rank, IV history, GEX, Vanna-Charm, realized vol, skew. Core inputs to Options, Blotter, and Regime._

| Layer | File |
|-------|------|
| [UI] | lib/features/iv/screens/iv_screen.dart |
| [UI] | lib/features/iv/widgets/iv_rank_gauge.dart |
| [UI] | lib/features/iv/widgets/iv_history_chart.dart |
| [UI] | lib/features/iv/widgets/gex_chart.dart |
| [UI] | lib/features/iv/widgets/vanna_charm_chart.dart |
| [UI] | lib/features/iv/widgets/skew_chart.dart |
| [MODEL] | lib/services/iv/iv_models.dart |
| [PROVIDER] | lib/services/iv/iv_providers.dart |
| [SVC] | lib/services/iv/iv_storage_service.dart |
| [MODEL] | lib/services/iv/realized_vol_models.dart |
| [PROVIDER] | lib/services/iv/realized_vol_providers.dart |
| [SVC] | lib/services/iv/realized_vol_repository.dart |
| [API] | api/routers/iv_analytics.py |
| [API] | api/services/iv_analytics.py |
| [DB] | supabase/migrations/011_iv_snapshots.sql → `iv_snapshots` |

**Waterfall:** `iv_snapshots` is read by Blotter (formula phase) and Regime (ML features). `iv_models.dart` is one of the largest model files (~622 lines) — changes to the snapshot shape cascade to `iv_storage_service.dart`, `iv_providers.dart`, and the Blotter formula panel.

---

## J

### Journal (Trade Journal)
_Freeform trade notes and lessons. Linked to individual trades._

| Layer | File |
|-------|------|
| [UI] | lib/features/journal/screens/journal_screen.dart |
| [UI] | lib/features/journal/screens/add_journal_screen.dart |
| [MODEL] | lib/features/journal/models/journal_entry.dart |
| [PROVIDER] | lib/features/journal/providers/journal_provider.dart |
| [DB] | supabase/migrations/001_initial_schema.sql → `journal_entries` |

**Waterfall:** Linked to Trades via `trade_id` FK. Changes to the trade lifecycle (status, close) should be reflected in journal entry views.

---

## O

### Options & Decision Engine
_Live options chain display, Greeks, decision wizard, scoring engine. The hub connecting market data → analysis → trade entry._

| Layer | File |
|-------|------|
| [UI] | lib/features/options/screens/options_chain_screen.dart |
| [UI] | lib/features/options/screens/option_decision_wizard.dart |
| [UI] | lib/features/options/screens/greek_chart_screen.dart |
| [UI] | lib/features/options/widgets/option_score_sheet.dart |
| [SVC] | lib/features/options/services/option_decision_engine.dart |
| [SVC] | lib/features/options/services/option_scoring_engine.dart |
| [API] | api/routers/decision.py |
| [API] | api/routers/scoring.py |
| [API] | api/services/option_decision.py |
| [API] | api/services/option_scoring.py |
| [API] | api/services/black_scholes.py ← shared with Calculator |
| [API] | api/services/sabr.py |
| [API] | api/services/heston.py |
| [API] | api/services/vvol_analytics.py |
| [API] | api/services/charm/ ← theta decay analytics |
| [FN] | supabase/functions/get-schwab-chains/index.ts |

**Waterfall — Reads from:**
- Schwab: live chains via `get-schwab-chains`
- IV: `iv_snapshots` for IV rank context
- Vol Surface: surface data for smile context
- Regime: regime score influences decision scoring

**Waterfall — Writes to:**
- Trades: user acts on a decision → creates a Trade
- Ideas: scoring result → may save as TradeIdea

---

## S

### SABR Calibration
_SABR vol smile model fitting. Sub-feature of Vol Surface; also used by Options pricing._

| Layer | File |
|-------|------|
| [PROVIDER] | lib/features/vol_surface/providers/sabr_calibration_provider.dart |
| [API] | api/routers/sabr.py |
| [API] | api/services/sabr_calibrator.py |
| [DB] | supabase/migrations/021_sabr_calibrations.sql → `sabr_calibrations` |

**Waterfall:** SABR calibration results are consumed by Vol Surface rendering and Options pricing. Changing the SABR parameter schema (021) requires updating `sabr_calibration_provider.dart` and `sabr_calibrator.py`.

---

### Schwab Integration
_OAuth token management and market data proxy. The single source of live market data for the whole app._

| Layer | File |
|-------|------|
| [UI] | lib/features/settings/screens/schwab_bootstrap_screen.dart |
| [SVC] | lib/services/schwab/schwab_service.dart |
| [MODEL] | lib/services/schwab/schwab_models.dart |
| [PROVIDER] | lib/services/schwab/schwab_providers.dart |
| [PROVIDER] | lib/services/schwab/schwab_reauth_provider.dart |
| [FN] | supabase/functions/schwab-bootstrap/index.ts ← OAuth code exchange |
| [FN] | supabase/functions/get-schwab-chains/index.ts |
| [FN] | supabase/functions/get-schwab-quotes/index.ts |
| [FN] | supabase/functions/get-schwab-instruments/index.ts |
| [FN] | supabase/functions/_shared/schwab_auth.ts ← shared token validation |
| [DB] | supabase/migrations/010_schwab_tokens.sql → `schwab_tokens` |

**Waterfall:** Token expiry or Schwab API contract changes break: Options chains, live trade marks, Regime quote ingestion, and Ticker instrument search simultaneously. `_shared/schwab_auth.ts` is imported by every edge function — a bug here silently breaks all Schwab calls.

---

### Summary Dashboard
_Home screen. Aggregates live positions, regime, and key economic indicators._

| Layer | File |
|-------|------|
| [UI] | lib/features/summary/screens/summary_screen.dart |

**Waterfall — Reads from:** Trades (P&L), Current Regime (regime label), Economy (headline indicators), Ideas (recent ideas). No writes.

---

## T

### Ticker Profile & Watchlist
_Per-ticker dashboard: stock profile, insider (Form 4), S/R levels, earnings reactions, notes, watchlist._

| Layer | File |
|-------|------|
| [UI] | lib/features/ticker_profile/screens/ticker_dashboard_screen.dart |
| [UI] | lib/features/ticker_profile/screens/ticker_profile_screen.dart |
| [UI] | lib/features/ticker_profile/screens/ticker_profile_cards.dart |
| [UI] | lib/features/ticker_profile/screens/ticker_profile_shared_widgets.dart |
| [UI] | lib/features/ticker_profile/widgets/add_ticker_note_sheet.dart |
| [UI] | lib/features/ticker_profile/widgets/add_sr_level_sheet.dart |
| [UI] | lib/features/ticker_profile/widgets/add_earnings_reaction_sheet.dart |
| [UI] | lib/features/ticker_profile/widgets/paste_form4_sheet.dart |
| [MODEL] | lib/features/ticker_profile/models/ticker_profile_models.dart |
| [PROVIDER] | lib/features/ticker_profile/providers/ticker_profile_notifier.dart |
| [PROVIDER] | lib/features/ticker_profile/providers/ticker_profile_providers.dart |
| [SVC] | lib/services/sec/sec_service.dart + sec_models.dart + sec_providers.dart |
| [SVC] | lib/services/fmp/fmp_service.dart + fmp_models.dart + fmp_providers.dart |
| [FN] | supabase/functions/get-sec-data/index.ts |
| [FN] | supabase/functions/get-apify-data/index.ts |
| [DB] | supabase/migrations/001_initial_schema.sql → `ticker_profile_notes`, `ticker_support_resistance`, `ticker_insider_buys`, `ticker_earnings_reactions` |
| [DB] | supabase/migrations/002_ticker_profiles.sql → `ticker_profiles` |
| [DB] | supabase/migrations/003_insider_transaction_types.sql |
| [DB] | supabase/migrations/004_watched_tickers.sql → `watched_tickers` |

**Waterfall:** A ticker symbol is the shared key across Options chains, Vol Surface, Greek Grid, Trades, and Ideas. Changing the `ticker` field type or validation in `ticker_profiles` would require updates across all features that join on it.

---

### Trades & Trade Lifecycle
_Trade entry, P&L tracking, trade blocks, CSV import, live greeks on open positions._

| Layer | File |
|-------|------|
| [UI] | lib/features/trades/screens/trades_screen.dart |
| [UI] | lib/features/trades/screens/add_trade_screen.dart |
| [UI] | lib/features/trades/screens/trade_detail_screen.dart |
| [UI] | lib/features/trades/screens/trade_journal_screen.dart |
| [UI] | lib/features/trades/screens/trade_blocks_screen.dart |
| [UI] | lib/features/trades/screens/csv_import_screen.dart |
| [MODEL] | lib/features/trades/models/trade.dart |
| [MODEL] | lib/features/trades/models/trade_journal.dart |
| [PROVIDER] | lib/features/trades/providers/trades_provider.dart |
| [PROVIDER] | lib/features/trades/providers/trade_journal_provider.dart |
| [PROVIDER] | lib/features/trades/providers/trade_block_provider.dart |
| [PROVIDER] | lib/features/trades/providers/live_marks_provider.dart |
| [SVC] | lib/features/trades/services/live_greeks_service.dart |
| [DB] | supabase/migrations/001_initial_schema.sql → `trades` |
| [DB] | supabase/migrations/006_trades_revamp.sql |
| [DB] | supabase/migrations/013_trades_tp_sl.sql ← adds `take_profit`, `stop_loss` |

**Waterfall — Reads from:**
- Schwab: live marks via `live_marks_provider`
- Journal: linked journal entries
- Ticker Profile: underlying stock context

**Waterfall:** Adding a column to `trades` requires: the migration, `trade.dart`, `trades_provider.dart`, `add_trade_screen.dart`, `trade_detail_screen.dart`, and the `trade_pnl` view if it's a financial field.

---

## V

### Volatility Surface
_Vol surface snapshots from options chains: arbitrage checking, SABR calibration, heatmap, smile chart._

| Layer | File |
|-------|------|
| [UI] | lib/features/vol_surface/screens/vol_surface_screen.dart |
| [UI] | lib/features/vol_surface/widgets/vol_heatmap.dart |
| [UI] | lib/features/vol_surface/widgets/vol_smile_chart.dart |
| [UI] | lib/features/vol_surface/widgets/vol_surface_interpretation.dart |
| [UI] | lib/features/vol_surface/widgets/vol_surface_guide.dart |
| [MODEL] | lib/features/vol_surface/models/vol_surface_models.dart |
| [PROVIDER] | lib/features/vol_surface/providers/vol_surface_provider.dart |
| [PROVIDER] | lib/features/vol_surface/providers/sabr_calibration_provider.dart |
| [SVC] | lib/features/vol_surface/services/vol_surface_parser.dart |
| [SVC] | lib/features/vol_surface/services/vol_surface_repository.dart |
| [SVC] | lib/services/vol_surface/arb_checker.dart |
| [API] | api/routers/sabr.py |
| [API] | api/routers/arb.py |
| [API] | api/services/sabr_calibrator.py |
| [API] | api/services/arb_checker.py |
| [DB] | supabase/migrations/014_vol_surface_snapshots.sql → `vol_surface_snapshots` |
| [DB] | supabase/migrations/015_vol_surface_user_id_default.sql |
| [DB] | supabase/migrations/016_vol_surface_rls_insert.sql |
| [DB] | supabase/migrations/017_vol_surface_unique_per_ticker.sql |
| [DB] | supabase/migrations/018_vol_surface_points_schema_comment.sql |
| [DB] | supabase/migrations/023_vvol_columns.sql ← adds vvol columns |

**Waterfall:** `vol_surface_snapshots` is read by Blotter (phase 3). The surface `points` field is JSONB — changing its shape requires updating `vol_surface_parser.dart`, `vol_surface_models.dart`, `vol_surface_repository.dart`, and the Blotter vol surface panel.

---

## Cross-Feature Correlation Map

```
                         AUTH
                           │  (all features require user_id)
    ┌──────────────────────┼────────────────────────────────────┐
    │                      │                                    │
    ▼                      ▼                                    ▼
SCHWAB ──────► OPTIONS & DECISION ◄──── IV & VOL ◄──── ECONOMY & MACRO
  │  (chains)      │          │              │                  │
  │  (quotes)      │          └──► CALCULATOR│                  │
  │                ▼                         │                  │
  │          VOLATILITY                      │                  │
  │           SURFACE ──────────────────────►│                  │
  │              │                           │                  │
  │              ▼                           │                  │
  │         SABR CALIB                       │                  │
  │                                          │                  │
  │          GREEK GRID ◄────────────────────┘                  │
  │              │                                              │
  │              └─────────────────────────────────────────────►│
  │                                                             │
  └──► REGIME (ML) ◄───────────────────── ECONOMY & MACRO ──────┘
           │
           ▼
    ┌──────────────┐
    │   BLOTTER    │◄─── Vol Surface
    │ (5 phases)   │◄─── Greek Grid
    │              │◄─── Economy
    └──────┬───────┘◄─── IV
           │         ◄─── Kalshi (via Economy)
           ▼
         IDEAS
           │
           ▼
    SUMMARY DASHBOARD ◄─── TRADES ◄─── JOURNAL
                                 ◄─── TICKER PROFILE
```

### Correlation by Layer

| Feature | Feeds into | Fed by |
|---------|-----------|--------|
| Schwab | Options, Trades (marks), Regime (quotes) | — |
| Economy | Regime (ML features), Blotter phase 1 | FRED, BLS, BEA, EIA, Census, Kalshi edge fns |
| IV | Blotter phase 2, Regime (ML features), Options | Schwab chains |
| Vol Surface | Blotter phase 3, SABR, Options | Schwab chains |
| Greek Grid | Blotter phase 4 | Schwab chains / Options |
| Kalshi | Blotter phase 5, Economy screen | Kalshi edge fn |
| Regime | Blotter (fair value), Options scoring, Summary | Economy + IV + Schwab |
| Options | Trades, Ideas, Blotter, Vol Surface | Schwab, IV, Regime |
| Blotter | Ideas | Economy, IV, Vol Surface, Greek Grid, Regime |
| Ideas | — | Blotter, Options scoring |
| Trades | Summary, Journal | Options, Schwab (marks) |
| Ticker Profile | Options, Vol Surface, Greek Grid, Trades | FMP, SEC |

---

## Supabase Migration Timeline

| # | Migration | Table(s) Created / Altered | Read by |
|---|-----------|---------------------------|---------|
| 001 | initial_schema | `trades`, `journal_entries`, `ticker_profile_notes`, `ticker_support_resistance`, `ticker_insider_buys`, `ticker_earnings_reactions` | Trades, Journal, Ticker Profile |
| 002 | ticker_profiles | `ticker_profiles` | Ticker Profile |
| 003 | insider_transaction_types | (enum) | Ticker Profile |
| 004 | watched_tickers | `watched_tickers` | Ticker Profile |
| 005 | economy_snapshots | `economy_indicator_snapshots`, `economy_treasury_snapshots`, `economy_quote_snapshots` | Economy, Blotter, Regime |
| 006 | trades_revamp | alters `trades` schema | Trades |
| 007 | gasoline_price_history | `us_gasoline_price_history` | Economy |
| 008 | unemployment_rate_history | `us_unemployment_rate_history` | Economy |
| 009 | nat_gas_import_prices | `us_natural_gas_import_prices` | Economy |
| 010 | schwab_tokens | `schwab_tokens` | Schwab, all edge fns |
| 011 | iv_snapshots | `iv_snapshots` | IV, Blotter, Regime |
| 012 | blotter_trades | `blotter_trades` | Blotter |
| 013 | trades_tp_sl | adds `take_profit`, `stop_loss` to `trades` | Trades |
| 014 | vol_surface_snapshots | `vol_surface_snapshots` | Vol Surface, Blotter |
| 015 | vol_surface_user_id_default | alters `vol_surface_snapshots` | Vol Surface |
| 016 | vol_surface_rls_insert | RLS policy on `vol_surface_snapshots` | Vol Surface |
| 017 | vol_surface_unique_per_ticker | unique constraint | Vol Surface |
| 018 | vol_surface_points_schema_comment | doc comment | — |
| 019 | greek_snapshots | `greek_snapshots` | Greek Grid |
| 020 | trade_ideas | `trade_ideas` | Ideas |
| 021 | sabr_calibrations | `sabr_calibrations` | SABR, Vol Surface |
| 022 | greek_grid_snapshots | `greek_grid_snapshots` | Greek Grid, Blotter |
| 023 | vvol_columns | adds vvol columns to `vol_surface_snapshots` | Vol Surface |
| 024 | regime_snapshot | `regime_snapshots` | Regime, Blotter, Summary |
| 025 | regime_snapshots_institutional_fields | adds institutional fields | Regime |
| 026 | regime_ml_models | `regime_ml_models` | Regime ML |

---

_Last updated: 2026-04-24_
