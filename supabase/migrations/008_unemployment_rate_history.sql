-- ============================================================
-- 008_unemployment_rate_history
-- Monthly US unemployment rate (U-3) from BLS LNS14000000.
-- Pre-seeded 2016–2026; kept fresh by app BLS sync.
-- ============================================================

create table if not exists us_unemployment_rate_history (
  rate_date          date           primary key,
  unemployment_rate  numeric(3, 1)  not null
);

alter table us_unemployment_rate_history enable row level security;

create policy "Authenticated users can manage unemployment history"
  on us_unemployment_rate_history for all
  to authenticated
  using (true)
  with check (true);

create index if not exists us_unemployment_rate_history_date_idx
  on us_unemployment_rate_history (rate_date);
