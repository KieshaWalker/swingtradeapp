-- ============================================================
-- Swing Options Trader — Initial Schema
-- Run this in your Supabase SQL editor or via supabase db push
-- ============================================================

-- Enable UUID extension
create extension if not exists "uuid-ossp";

-- ----------------------------------------------------------------
-- TRADES
-- ----------------------------------------------------------------
create table if not exists trades (
  id           uuid primary key default uuid_generate_v4(),
  user_id      uuid references auth.users(id) on delete cascade not null,
  ticker       text not null,
  option_type  text not null check (option_type in ('call', 'put')),
  strategy     text not null check (strategy in (
    'long_call', 'long_put',
    'bull_call_spread', 'bear_put_spread',
    'bull_put_spread', 'bear_call_spread',
    'iron_condor', 'other'
  )),
  strike       numeric(10,2) not null,
  expiration   date not null,
  dte_at_entry integer,
  contracts    integer not null default 1,
  entry_price  numeric(10,4) not null,   -- premium per share
  exit_price   numeric(10,4),
  status       text not null default 'open' check (status in ('open', 'closed', 'expired')),
  iv_rank      numeric(5,2),             -- 0–100
  delta        numeric(6,4),
  notes        text,
  opened_at    timestamptz not null default now(),
  closed_at    timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

alter table trades enable row level security;

create policy "Users can manage their own trades"
  on trades for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- Computed columns via generated columns aren't available in all PG versions,
-- so we expose P&L as a view instead.
create or replace view trade_pnl as
select
  id,
  user_id,
  ticker,
  option_type,
  strategy,
  strike,
  expiration,
  contracts,
  entry_price,
  exit_price,
  status,
  iv_rank,
  delta,
  notes,
  opened_at,
  closed_at,
  -- P&L = (exit - entry) * contracts * 100  (1 contract = 100 shares)
  case
    when exit_price is not null
    then (exit_price - entry_price) * contracts * 100
    else null
  end as realized_pnl,
  -- Cost basis
  entry_price * contracts * 100 as cost_basis
from trades;

-- ----------------------------------------------------------------
-- JOURNAL ENTRIES
-- ----------------------------------------------------------------
create table if not exists journal_entries (
  id         uuid primary key default uuid_generate_v4(),
  user_id    uuid references auth.users(id) on delete cascade not null,
  trade_id   uuid references trades(id) on delete set null,
  title      text not null,
  body       text not null,
  mood       text check (mood in ('confident', 'neutral', 'anxious', 'frustrated', 'excited')),
  tags       text[] default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table journal_entries enable row level security;

create policy "Users can manage their own journal entries"
  on journal_entries for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- ----------------------------------------------------------------
-- UPDATED_AT trigger
-- ----------------------------------------------------------------
create or replace function set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

create trigger trades_updated_at
  before update on trades
  for each row execute function set_updated_at();

create trigger journal_updated_at
  before update on journal_entries
  for each row execute function set_updated_at();
