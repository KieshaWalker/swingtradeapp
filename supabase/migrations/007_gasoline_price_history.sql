-- ============================================================
-- 007_gasoline_price_history
-- Weekly US retail gasoline price history from EIA.
-- Source: /v2/petroleum/pri/gnd/data/
--         series EMM_EPM0_PTE_NUS_DPG (US avg, all grades, $/gal)
--
-- Table is global (not user-scoped); any authenticated user
-- may read/write so the shared cache stays fresh for everyone.
-- ============================================================

create table if not exists us_gasoline_price_history (
  date   date          primary key,
  price  numeric(6, 3) not null   -- $/gallon, e.g. 3.876
);

alter table us_gasoline_price_history enable row level security;

create policy "Authenticated users can manage gasoline price history"
  on us_gasoline_price_history for all
  to authenticated
  using (true)
  with check (true);

create index if not exists us_gasoline_price_history_date_idx
  on us_gasoline_price_history (date);
