-- ============================================================
-- Economy Snapshots — persists Economy Pulse data each fetch
-- Tables are global (not user-scoped); any authenticated user
-- may read/write so the shared cache stays fresh.
-- ============================================================

-- ── Economic indicator time-series ──────────────────────────
-- One row per (identifier, date); upsert on conflict.
--create table if not exists economy_indicator_snapshots (
--  identifier  text    not null,
--  date        date    not null,
--  value       numeric not null,
--  recorded_at timestamptz not null default now(),
--  primary key (identifier, date)
-- );

-- alter table economy_indicator_snapshots enable row level security;

--create policy "Authenticated users can manage economy indicators"
--on economy_indicator_snapshots for all
--to authenticated
--using (true)
--with check (true);

-- ── Treasury yield curve snapshots ──────────────────────────
--create table if not exists economy_treasury_snapshots (
  --date        date primary key,
  --year1       numeric,
  --year2       numeric,
  --year5       numeric,
  --year10      numeric,
  --year20      numeric,
  --year30      numeric,
  --recorded_at timestamptz not null default now()
-- );

--alter table economy_treasury_snapshots enable row level security;

--create policy "Authenticated users can manage treasury snapshots"
  --on economy_treasury_snapshots for all
  --to authenticated
 -- using (true)
 -- with check (true);

-- ── Market / commodity quote snapshots (daily close) ─────────
--create table if not exists economy_quote_snapshots (
  --symbol          text    not null,
  --date            date    not null,
  --price           numeric not null,
  --change_percent  numeric not null,
  --recorded_at     timestamptz not null default now(),
  --primary key (symbol, date)
-- );

--alter table economy_quote_snapshots enable row level security;

--create policy "Authenticated users can manage quote snapshots"
  --on economy_quote_snapshots for all
  --to authenticated
  --using (true)
  --with check (true);


