-- =============================================================================
-- 019_greek_snapshots.sql
--
-- Creates the greek_snapshots table used by GreekSnapshotRepository.
--
-- One row per (user_id, ticker, obs_date, dte_bucket).
-- dte_bucket is the target DTE at capture time: 4 | 7 | 31.
-- Each row stores the ATM call and ATM put greeks for that expiry bucket
-- on that calendar day, ingested automatically when the options chain loads.
--
-- RLS: users can only read/write their own rows.
-- =============================================================================

create table if not exists greek_snapshots (
  id               uuid        primary key default gen_random_uuid(),
  user_id          uuid        references auth.users not null,
  ticker           text        not null,
  obs_date         date        not null,
  dte_bucket       int         not null default 31,   -- 4 | 7 | 31
  underlying_price float8      not null,

  -- ATM Call
  call_strike      float8,
  call_dte         int,
  call_delta       float8,
  call_gamma       float8,
  call_theta       float8,
  call_vega        float8,
  call_rho         float8,
  call_iv          float8,
  call_oi          int,

  -- ATM Put
  put_strike       float8,
  put_dte          int,
  put_delta        float8,
  put_gamma        float8,
  put_theta        float8,
  put_vega         float8,
  put_rho          float8,
  put_iv           float8,
  put_oi           int,

  persisted_at     timestamptz default now(),

  unique (user_id, ticker, obs_date, dte_bucket)
);

alter table greek_snapshots enable row level security;

create policy "Users manage own greek snapshots"
  on greek_snapshots
  for all
  using (auth.uid() = user_id);
