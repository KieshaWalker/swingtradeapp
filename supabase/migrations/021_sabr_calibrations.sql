-- =============================================================================
-- 021_sabr_calibrations.sql
-- =============================================================================
-- Stores surface-calibrated SABR parameters per (ticker, obs_date, dte).
--
-- One row per DTE slice per observation date.  Parameters (alpha, rho, nu)
-- are fit jointly to all market quotes in that slice using Nelder-Mead,
-- replacing the hardcoded ρ = -0.7 / ν = 0.40 in the single-point engine.
--
-- FairValueEngine reads the closest slice to the trade's DTE and uses the
-- calibrated rho and nu instead of hardcoded defaults.
--
-- Columns:
--   alpha     — vol level          (> 0)
--   beta      — CEV exponent       (fixed 0.5 for equity)
--   rho       — spot-vol corr      (−1 to 1)
--   nu        — vol-of-vol         (> 0)
--   rmse      — root-mean-sq IV error (decimal; 0.005 = 0.5%)
--   n_points  — market quotes used in fit
-- =============================================================================

create table if not exists sabr_calibrations (
  id           uuid         primary key default gen_random_uuid(),
  user_id      uuid         not null references auth.users (id) on delete cascade,

  ticker       text         not null,
  obs_date     date         not null,
  dte          integer      not null check (dte > 0),

  alpha        numeric(12,8) not null,
  beta         numeric(6,4)  not null default 0.5,
  rho          numeric(8,6)  not null,
  nu           numeric(12,8) not null,
  rmse         numeric(10,8),
  n_points     integer       not null default 0,

  calibrated_at timestamptz  not null default now(),

  unique (user_id, ticker, obs_date, dte)
);

-- Fetch latest calibration for a ticker (ordered by obs_date desc, dte asc)
create index if not exists sabr_cal_ticker_date_idx
  on sabr_calibrations (user_id, ticker, obs_date desc, dte asc);

-- Point-lookup: find slice closest to a target DTE on a given date
create index if not exists sabr_cal_dte_idx
  on sabr_calibrations (user_id, ticker, obs_date, dte);

alter table sabr_calibrations enable row level security;

create policy "Users manage own SABR calibrations"
  on sabr_calibrations
  for all
  using  (auth.uid() = user_id)
  with check (auth.uid() = user_id);
