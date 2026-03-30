-- ============================================================
-- 005_economy_snapshots
-- Economy Pulse + BLS / BEA / EIA / Census time-series storage
--
-- Tables are global (not user-scoped); any authenticated user
-- may read/write so the shared cache stays fresh for everyone.
-- ============================================================

-- ── Economic indicator time-series ──────────────────────────
-- One row per (identifier, date).
-- identifier values come from EconIds constants in Dart
-- (e.g. 'bls_unemployment_u3', 'bea_gdp_pct', 'eia_gasoline_price').
-- FMP-sourced indicators use the FMP series identifier string.

create table if not exists economy_indicator_snapshots (
  identifier  text    not null,
  date        date    not null,
  value       numeric not null,
  recorded_at timestamptz not null default now(),
  primary key (identifier, date)
);

alter table economy_indicator_snapshots enable row level security;

create policy "Authenticated users can manage economy indicators"
  on economy_indicator_snapshots for all
  to authenticated
  using (true)
  with check (true);

-- Index for fast range queries used by chart history reads
create index if not exists economy_indicator_snapshots_identifier_date_idx
  on economy_indicator_snapshots (identifier, date);


-- ── Treasury yield curve snapshots ──────────────────────────
-- One row per date (the full curve in a single row).

create table if not exists economy_treasury_snapshots (
  date        date primary key,
  year1       numeric,
  year2       numeric,
  year5       numeric,
  year10      numeric,
  year20      numeric,
  year30      numeric,
  recorded_at timestamptz not null default now()
);

alter table economy_treasury_snapshots enable row level security;

create policy "Authenticated users can manage treasury snapshots"
  on economy_treasury_snapshots for all
  to authenticated
  using (true)
  with check (true);


-- ── Market / commodity quote snapshots (daily) ───────────────
-- One row per (symbol, date).  Symbols match FMP tickers:
-- SPY, QQQ, VIXY, UUP, GC=F, SI=F, CL=F, NG=F

create table if not exists economy_quote_snapshots (
  symbol          text    not null,
  date            date    not null,
  price           numeric not null,
  change_percent  numeric not null,
  recorded_at     timestamptz not null default now(),
  primary key (symbol, date)
);

alter table economy_quote_snapshots enable row level security;

create policy "Authenticated users can manage quote snapshots"
  on economy_quote_snapshots for all
  to authenticated
  using (true)
  with check (true);
