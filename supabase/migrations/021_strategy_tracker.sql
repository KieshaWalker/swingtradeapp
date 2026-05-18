-- =============================================================================
-- 021: strategy_tracker
-- Creates strategy_setups and links trades via strategy_setup_id FK.
-- Strategy win-rate / P&L stats are derived from tagged closed trades —
-- no separate results table; outcome comes from realizedPnl on the trade.
-- =============================================================================

create table if not exists strategy_setups (
  id                  uuid        primary key default gen_random_uuid(),
  user_id             uuid        not null references auth.users(id) on delete cascade,
  name                text        not null,
  description         text,
  tags                text[]      not null default '{}',

  -- ── Preset technical entry criteria ────────────────────────────────────────
  -- [{sma: 20, position: "above"}, {sma: 200, position: "above"}]
  sma_conditions      jsonb       not null default '[]',
  sr_level_required   boolean     not null default false,
  sr_proximity_pct    numeric,
  volume_condition    text        check (volume_condition in ('above_avg','below_avg','any')),
  volume_cross_needed boolean     not null default false,
  lower_volume_needed boolean     not null default false,
  -- {operator: "lt"|"gt"|"between", value: 20} or {operator: "between", low: 15, high: 25}
  vix_condition       jsonb,
  -- {type: "sma", sma: 200, position: "above"} or {type: "area", area: "at_highs"}
  spy_condition       jsonb,

  -- ── User-defined free-form criteria ─────────────────────────────────────────
  -- [{label: "Must see hammer candle"}, {label: "First hour only"}]
  custom_criteria     jsonb       not null default '[]',

  created_at          timestamptz not null default now()
);

-- Unique strategy name per user (case-insensitive)
create unique index if not exists strategy_setups_user_name
  on strategy_setups (user_id, lower(name));

alter table strategy_setups enable row level security;

create policy "Users manage own strategies"
  on strategy_setups
  using  (user_id = auth.uid())
  with check (user_id = auth.uid());

create index if not exists strategy_setups_user_created
  on strategy_setups (user_id, created_at desc);

-- ── Link trades table to strategy setups ────────────────────────────────────
-- on delete set null: deleting a strategy keeps trades intact, just untagged
alter table trades
  add column if not exists strategy_setup_id uuid
    references strategy_setups(id) on delete set null;

create index if not exists trades_strategy_setup_idx
  on trades (strategy_setup_id)
  where strategy_setup_id is not null;
