create table if not exists heston_calibrations (
  id          bigserial primary key,
  user_id     uuid not null,
  ticker      text not null,
  obs_date    date not null,
  kappa       double precision,
  theta       double precision,
  xi          double precision,
  rho         double precision,
  v0          double precision,
  rmse_iv     double precision,
  n_points    integer,
  converged   boolean,
  unique (user_id, ticker, obs_date)
);
