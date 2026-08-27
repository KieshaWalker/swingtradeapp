-- =============================================================================
-- 082: swing_setups — one row per ticker per session, the screen's output
-- =============================================================================
-- Fans in the three legs of the swing-setup engine:
--   services/channel_fit.py    trendline channel from equity_bars
--   services/trend_volume.py   50/200 SMA + 30/50 volume from equity_bars
--   services/options_confirm.py expected move + dealer gamma, from the
--                              expected_move_snapshots / iv_snapshots the EOD
--                              jobs already write
--
-- THERE IS DELIBERATELY NO buy/sell/score COLUMN.
-- The obvious design is a single directional score, and it would be dishonest
-- here. Measured over this universe (48 tickers, ~6 months, walk-forward),
-- channel position carried NO reliable directional edge: pooled it looked like
-- momentum, but that was driven by two outliers, and per-ticker the split was
-- 12 momentum / 16 mean-reverting — binomial p=0.17, not significant, and
-- optimistic at that since the forward windows overlap by 9 of 10 days. A
-- column called `signal` would launder that coin flip into an instruction.
--
-- structure_quality is therefore about CLEANLINESS, not direction: how well
-- defined the structure is, how much participation confirms it, whether the
-- trend legs agree. Ranking a screen by it surfaces the most legible charts,
-- which is a claim the data supports. Which way to trade them is left to the
-- reader and to the dealer-positioning leg.
--
-- WHY THE CHANNEL LINES ARE JSONB
-- Upper and lower are each a slope/intercept plus the pivot indices they were
-- anchored on. That is chart-overlay data, read whole or not at all, never
-- filtered or aggregated in SQL — the same reasoning that keeps gex_by_strike
-- JSONB in iv_snapshots. Storing eight scalar columns instead would invite
-- someone to query one of them in isolation, where it means nothing.
--
-- channel_start_idx IS LOAD-BEARING FOR ANY CHART. The fitted lines were only
-- validated against price from that bar forward and must not be drawn before
-- it; extrapolating a trendline back past its own first anchor is not a claim
-- the fit makes. See services/channel_fit.py.
-- =============================================================================

create table if not exists swing_setups (
  ticker              text          not null,
  obs_date            date          not null,

  -- ── Channel leg ──────────────────────────────────────────────────────────
  channel_found       boolean       not null default false,
  -- Why no channel, when channel_found is false: too_few_bars, zero_atr,
  -- insufficient_pivots, no_valid_trendline, no_valid_channel_pair,
  -- inverted_channel. A populated reason is a normal outcome, not an error.
  channel_reason      text,
  channel_kind        text,          -- channel | wedge | broadening
  channel_direction   text,          -- ascending | descending | horizontal
  channel_upper       numeric(14,4),
  channel_lower       numeric(14,4),
  channel_width_pct   numeric(10,4),
  channel_position    numeric(10,4), -- 0 at lower line, 1 at upper
  channel_slope_pct   numeric(12,6),
  channel_confidence  numeric(6,4),
  channel_start_idx   smallint,
  target_up           numeric(14,4),
  target_down         numeric(14,4),
  channel_lines       jsonb,         -- {upper:{...}, lower:{...}}

  -- ── Trend leg ────────────────────────────────────────────────────────────
  sma50               numeric(14,4),
  sma200              numeric(14,4), -- NULL when under 200 bars, never a short average
  pct_to_sma50        numeric(10,4),
  pct_to_sma200       numeric(10,4),
  sma50_above_200     boolean,       -- NULL means "cannot tell", not "no"
  sma50_slope_pct     numeric(10,4),
  sma200_slope_pct    numeric(10,4),

  -- ── Volume leg ───────────────────────────────────────────────────────────
  volume              bigint,
  vol_sma30           numeric(20,4),
  vol_sma50           numeric(20,4),
  vol_ratio           numeric(10,4), -- session vs its own 30-day MEDIAN
  vol_z               numeric(10,4), -- z-score of log volume
  vol_surge           boolean,       -- vol_ratio >= 1.79 (measured p90)
  participation       text,          -- elevated | normal | light

  -- ── Options confirmation leg ─────────────────────────────────────────────
  em_pct              numeric(10,4),
  em_iv               numeric(10,6),
  em_dte              smallint,
  em_date             date,          -- EM is EOD; routinely the prior session
  em_ratio_up         numeric(10,4), -- target_up_pct / em_pct;  >1 = outside 1σ
  em_ratio_down       numeric(10,4),
  implied_days_up     numeric(10,2), -- horizon at which EM equals the target
  implied_days_down   numeric(10,2),
  underpriced_up      boolean,
  underpriced_down    boolean,
  gamma_regime        text,
  zero_gamma_level    numeric(14,4),
  spot_to_zgl_pct     numeric(10,4),
  dealer_posture      text,          -- dampening | amplifying
  breakout_supported  boolean,
  iv_date             date,

  -- ── Meta ─────────────────────────────────────────────────────────────────
  spot                numeric(14,4),
  bars_used           smallint,
  -- 0-1 cleanliness of the structure. NOT a directional signal — see header.
  structure_quality   numeric(6,4),
  computed_at         timestamptz   not null default now(),

  primary key (ticker, obs_date)
);

-- The screen reads "latest session, all tickers, best structures first".
create index if not exists swing_setups_date_quality
  on swing_setups (obs_date desc, structure_quality desc nulls last);

alter table swing_setups enable row level security;

create policy "Authenticated users can read swing setups"
  on swing_setups for select
  to authenticated
  using (true);
