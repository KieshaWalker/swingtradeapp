-- =============================================================================
-- 022_greek_grid_snapshots.sql
-- =============================================================================
-- 3-dimensional greek grid: (ticker, obs_date) × strike_band × expiry_bucket.
--
-- Each row is a band-level aggregate of all option contracts that fall in
-- a given moneyness band and DTE bucket on a given observation date.
-- Greeks are the median across all contracts in the cell; OI/volume are summed.
--
-- Axes:
--   strike_band   — moneyness relative to spot at obs time
--     deep_itm    moneyness < -15%
--     itm         -15% to -5%
--     atm         -5% to +5%
--     otm         +5% to +15%
--     deep_otm    > +15%
--
--   expiry_bucket — DTE range
--     weekly       DTE ≤ 7
--     near_monthly DTE 8–30
--     monthly      DTE 31–60
--     far_monthly  DTE 61–90
--     quarterly    DTE > 90
--
-- Cleanup: rows where expiry_date < CURRENT_DATE - 30 are pruned by
-- purge_expired_greek_grid() called from the Flutter app or pg_cron.
-- =============================================================================

create table if not exists greek_grid_snapshots (
  id               uuid    primary key default gen_random_uuid(),
  user_id          uuid    not null references auth.users (id) on delete cascade,

  -- Grid axes
  ticker           text    not null,
  obs_date         date    not null,
  strike_band      text    not null check (strike_band in
                     ('deep_itm','itm','atm','otm','deep_otm')),
  expiry_bucket    text    not null check (expiry_bucket in
                     ('weekly','near_monthly','monthly','far_monthly','quarterly')),

  -- Representative values (median strike / nearest expiry in cell)
  strike           numeric(10,2) not null,
  expiry_date      date,

  -- Aggregated greeks (median across contracts in band × bucket)
  delta            numeric(10,6),
  gamma            numeric(10,6),
  vega             numeric(10,6),
  theta            numeric(10,6),
  iv               numeric(10,6),
  vanna            numeric(10,6),
  charm            numeric(10,6),
  volga            numeric(10,6),

  -- Position metrics (summed across band × bucket)
  open_interest    integer,
  volume           integer,

  -- Spot at time of observation (for moneyness reconstruction)
  spot_at_obs      numeric(10,2) not null,

  -- Confidence indicator — how many contracts were aggregated
  contract_count   integer not null default 1,

  persisted_at     timestamptz not null default now(),

  unique (user_id, ticker, obs_date, strike_band, expiry_bucket)
);

-- All history for a ticker (primary access pattern)
create index if not exists greek_grid_ticker_obs_idx
  on greek_grid_snapshots (user_id, ticker, obs_date desc);

-- Time-series for a single cell (band × bucket) — for chart drill-down
create index if not exists greek_grid_cell_series_idx
  on greek_grid_snapshots (user_id, ticker, strike_band, expiry_bucket, obs_date asc);

-- All cells for a single snapshot date
create index if not exists greek_grid_snapshot_date_idx
  on greek_grid_snapshots (user_id, ticker, obs_date);

alter table greek_grid_snapshots enable row level security;

create policy "Users manage own greek grid snapshots"
  on greek_grid_snapshots
  for all
  using  (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- =============================================================================
-- Cleanup function
-- Deletes rows where the option has been expired for more than 30 days.
-- Returns the count of deleted rows.
-- Called from Flutter: _db.rpc('purge_expired_greek_grid', params: {'p_user_id': uid})
-- =============================================================================
create or replace function purge_expired_greek_grid(p_user_id uuid)
returns integer
language plpgsql
security definer
as $$
declare
  v_count integer;
begin
  delete from greek_grid_snapshots
  where user_id = p_user_id
    and expiry_date is not null
    and expiry_date < current_date - interval '30 days';
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
