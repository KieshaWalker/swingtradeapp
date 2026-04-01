-- ============================================================
-- 009_nat_gas_import_prices
-- Monthly US natural gas import prices (EIA, $/MMBTU).
-- Wide format: one row per year, one column per month.
-- Data pre-seeded 2000–2026 via manual INSERT.
-- ============================================================

create table if not exists us_natural_gas_import_prices (
  year  int          primary key,
  jan   numeric(5,2),
  feb   numeric(5,2),
  mar   numeric(5,2),
  apr   numeric(5,2),
  may   numeric(5,2),
  jun   numeric(5,2),
  jul   numeric(5,2),
  aug   numeric(5,2),
  sep   numeric(5,2),
  oct   numeric(5,2),
  nov   numeric(5,2),
  dec   numeric(5,2)
);

alter table us_natural_gas_import_prices enable row level security;

create policy "Authenticated users can manage nat gas import prices"
  on us_natural_gas_import_prices for all
  to authenticated
  using (true)
  with check (true);
