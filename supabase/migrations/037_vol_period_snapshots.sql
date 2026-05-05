create table if not exists vol_period_snapshots (
  id                bigserial primary key,
  ticker            text not null,
  period_type       text not null,           -- 'weekly' | 'monthly'
  period_end_date   date not null,           -- Friday (weekly) or last calendar day of month (monthly)

  -- Price
  spot_open         double precision,        -- underlying price at first day of period
  spot_close        double precision,        -- underlying price at last day of period
  price_return_pct  double precision,        -- (close - open) / open * 100

  -- ATM IV
  atm_iv_open       double precision,
  atm_iv_close      double precision,
  atm_iv_high       double precision,
  atm_iv_low        double precision,
  atm_iv_avg        double precision,
  iv_change         double precision,        -- atm_iv_close - atm_iv_open

  -- Realized vol (annualized, Bessel-corrected, √252)
  rv                double precision,        -- 5-bar for weekly, 21-bar for monthly
  iv_rv_spread      double precision,        -- atm_iv_close - rv (vol premium)

  -- Skew
  skew_avg          double precision,
  skew_close        double precision,

  -- GEX
  total_gex_avg     double precision,

  -- Rankings at period close (from iv_snapshots)
  iv_percentile     double precision,
  iv_rank           double precision,
  gamma_regime      text,

  -- Metadata
  n_days            integer,                 -- trading days with iv_snapshot data in period
  computed_at       timestamptz default now(),

  unique (ticker, period_type, period_end_date)
);

alter table vol_period_snapshots enable row level security;

create policy "Authenticated users can read vol period snapshots"
  on vol_period_snapshots for select
  to authenticated
  using (true);
