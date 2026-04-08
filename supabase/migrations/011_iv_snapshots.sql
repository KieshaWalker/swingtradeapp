-- =============================================================================
-- 011_iv_snapshots.sql
-- =============================================================================
-- Stores daily implied-volatility snapshots per ticker so we can compute:
--   • IV Rank  (IVR) = (current IV - 52w low) / (52w high - 52w low) × 100
--   • IV Percentile (IVP) = % of days in past 252 where IV was below today
--   • Volatility Skew   = avg OTM put IV - avg OTM call IV (25-delta wings)
--   • Gamma Exposure    = net GEX per strike (calls + puts combined)
--
-- One row per (ticker, date). Updated each time a user opens an options chain.
-- No RLS — shared read/write for all authenticated users (like economy tables).
-- =============================================================================

create table if not exists iv_snapshots (
  ticker          text        not null,
  date            date        not null,
  -- ATM composite IV (chain-level, from Schwab volatility field)
  atm_iv          numeric(8,4) not null,
  -- Skew: OTM put IV minus OTM call IV at ~25-delta wings (percentage points)
  -- Positive = puts more expensive = fear premium. Null if chain is thin.
  skew            numeric(8,4),
  -- Per-strike GEX array stored as JSONB: [{strike, gex, calls_oi, puts_oi}]
  -- GEX in $ millions (dealer perspective — positive = long gamma wall)
  gex_by_strike   jsonb,
  -- Convenience aggregate fields
  total_gex       numeric(14,2),   -- sum of all GEX values
  max_gex_strike  numeric(10,2),   -- strike with highest absolute GEX (flip point)
  put_call_ratio  numeric(6,3),    -- total put OI / total call OI
  -- Populated from chain response
  underlying_price numeric(10,2),

  primary key (ticker, date)
);

-- Fast 52-week history lookup per ticker
create index if not exists iv_snapshots_ticker_date
  on iv_snapshots (ticker, date desc);

-- Allow authenticated users to read and upsert
alter table iv_snapshots enable row level security;

create policy "authenticated can read iv_snapshots"
  on iv_snapshots for select
  to authenticated using (true);

create policy "authenticated can upsert iv_snapshots"
  on iv_snapshots for insert
  to authenticated with check (true);

create policy "authenticated can update iv_snapshots"
  on iv_snapshots for update
  to authenticated using (true);
