-- expected_move_snapshots: daily EOD capture of IV-implied price bands.
-- One row per (ticker, date, period_type).  Populated by a single daily job
-- that runs at 21:00 UTC (after US market close) — not the intraday pipeline.
--
-- period_type: 'daily'   — uses DTE closest to 1  (tomorrow's expiry)
--              'weekly'  — uses DTE closest to 7  (~next-Friday expiry)
--              'monthly' — uses DTE closest to 30 (~front-month expiry)
--
-- Bands use log-normal convention:
--   upper_nσ = spot × exp( n × iv × √(dte/365))
--   lower_nσ = spot × exp(-n × iv × √(dte/365))
--
-- Fixed band probabilities (log-normal, same for all timeframes):
--   ±1σ → 68.27%   ±2σ → 95.45%   ±3σ → 99.73%

create table if not exists expected_move_snapshots (
  id           bigserial primary key,
  ticker       text    not null,
  date         date    not null,
  period_type  text    not null,   -- 'daily' | 'weekly' | 'monthly'
  spot         double precision not null,
  iv           double precision,   -- ATM IV decimal used (e.g. 0.25 = 25%)
  dte          integer,            -- actual DTE of the expiry selected
  em_dollars   double precision,   -- 1σ expected move in dollars
  em_pct       double precision,   -- 1σ expected move as % of spot
  upper_1s     double precision,
  lower_1s     double precision,
  upper_2s     double precision,
  lower_2s     double precision,
  upper_3s     double precision,
  lower_3s     double precision,
  computed_at  timestamptz default now(),
  unique (ticker, date, period_type)
);

alter table expected_move_snapshots enable row level security;

create policy "Authenticated users can read expected move snapshots"
  on expected_move_snapshots for select
  to authenticated
  using (true);
