-- =============================================================================
-- 014_vol_surface_snapshots.sql
--
-- Persists vol surface datasets (parsed ThinkorSwim CSV snapshots) per user.
-- Each row = one observation date for one ticker.
-- The `points` JSONB column stores the raw parsed option chain:
--   [{ strike: number, dte: number, callIv: number|null, putIv: number|null }]
-- =============================================================================

create table if not exists vol_surface_snapshots (
  id          uuid        primary key default gen_random_uuid(),
  user_id     uuid        not null references auth.users (id) on delete cascade,
  ticker      text        not null,
  obs_date    date        not null,
  spot_price  numeric,
  points      jsonb       not null default '[]',
  parsed_at   timestamptz not null default now(),

  unique (user_id, obs_date)
);

-- Indexes
create index if not exists vol_surface_snapshots_user_id_idx
  on vol_surface_snapshots (user_id);

create index if not exists vol_surface_snapshots_obs_date_idx
  on vol_surface_snapshots (user_id, obs_date desc);

-- RLS
alter table vol_surface_snapshots enable row level security;

create policy "Users can read their own snapshots"
  on vol_surface_snapshots for select
  using (auth.uid() = user_id);

create policy "Users can insert their own snapshots"
  on vol_surface_snapshots for insert
  with check (auth.uid() = user_id);

create policy "Users can update their own snapshots"
  on vol_surface_snapshots for update
  using (auth.uid() = user_id);

create policy "Users can delete their own snapshots"
  on vol_surface_snapshots for delete
  using (auth.uid() = user_id);
