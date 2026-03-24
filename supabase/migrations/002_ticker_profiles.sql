-- ============================================================
-- Swing Options Trader — Migration 002: Ticker Profiles
-- Run in Supabase SQL editor or via: supabase db push
-- ============================================================

-- ----------------------------------------------------------------
-- TICKER_PROFILE_NOTES
-- Timestamped observations on a ticker — accumulates over time.
-- ----------------------------------------------------------------
create table if not exists ticker_profile_notes (
  id         uuid primary key default uuid_generate_v4(),
  user_id    uuid references auth.users(id) on delete cascade not null,
  ticker     text not null,
  body       text not null,
  tags       text[] default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table ticker_profile_notes enable row level security;
create policy "Users own their ticker notes"
  on ticker_profile_notes for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create index idx_ticker_notes_user_ticker
  on ticker_profile_notes(user_id, ticker, created_at desc);

-- ----------------------------------------------------------------
-- TICKER_SUPPORT_RESISTANCE
-- Price levels with full lifecycle: noted_at → invalidated_at.
-- A level is active while invalidated_at IS NULL.
-- ----------------------------------------------------------------
create table if not exists ticker_support_resistance (
  id                uuid primary key default uuid_generate_v4(),
  user_id           uuid references auth.users(id) on delete cascade not null,
  ticker            text not null,
  level_type        text not null check (level_type in ('support', 'resistance')),
  price             numeric(10,2) not null,
  label             text,           -- e.g. "200MA", "Aug swing low", "gap fill"
  timeframe         text check (timeframe in ('intraday', 'daily', 'weekly', 'monthly')),
  noted_at          timestamptz not null default now(),
  invalidated_at    timestamptz,
  invalidation_note text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

alter table ticker_support_resistance enable row level security;
create policy "Users own their S/R levels"
  on ticker_support_resistance for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create index idx_ticker_sr_user_ticker
  on ticker_support_resistance(user_id, ticker, noted_at desc);

-- ----------------------------------------------------------------
-- TICKER_INSIDER_BUYS
-- Curated Form 4 buy events logged from SEC filings.
-- Not every filing is notable — user pins what matters.
-- ----------------------------------------------------------------
create table if not exists ticker_insider_buys (
  id               uuid primary key default uuid_generate_v4(),
  user_id          uuid references auth.users(id) on delete cascade not null,
  ticker           text not null,
  insider_name     text not null,
  insider_title    text,
  shares           integer not null,
  price_per_share  numeric(10,2),
  total_value      numeric(14,2),
  filed_at         date not null,
  transaction_date date,
  accession_no     text,       -- SEC EDGAR accession number
  transaction_type text not null default 'purchase'
    check (transaction_type in ('purchase', 'exercise', 'gift', 'other')),
  notes            text,
  created_at       timestamptz not null default now()
);

alter table ticker_insider_buys enable row level security;
create policy "Users own their insider buy logs"
  on ticker_insider_buys for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create index idx_ticker_insider_user_ticker
  on ticker_insider_buys(user_id, ticker, filed_at desc);

-- ----------------------------------------------------------------
-- TICKER_EARNINGS_REACTIONS
-- Post-earnings move data per quarter.
-- FMP provides EPS data; user logs the actual price reaction.
-- ----------------------------------------------------------------
create table if not exists ticker_earnings_reactions (
  id                  uuid primary key default uuid_generate_v4(),
  user_id             uuid references auth.users(id) on delete cascade not null,
  ticker              text not null,
  earnings_date       date not null,
  fiscal_period       text,           -- e.g. "Q3 2025"
  eps_actual          numeric(8,4),
  eps_estimate        numeric(8,4),
  eps_surprise_pct    numeric(6,2),
  revenue_actual      numeric(16,2),  -- in dollars
  revenue_estimate    numeric(16,2),
  price_before        numeric(10,2),
  price_after         numeric(10,2),
  move_pct            numeric(6,2),   -- stored computed: avoids recompute
  direction           text check (direction in ('up', 'down', 'flat')),
  iv_rank_before      numeric(5,2),
  iv_rank_after       numeric(5,2),
  notes               text,
  created_at          timestamptz not null default now(),
  -- one row per user per ticker per quarter
  unique (user_id, ticker, earnings_date)
);

alter table ticker_earnings_reactions enable row level security;
create policy "Users own their earnings reactions"
  on ticker_earnings_reactions for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create index idx_ticker_earnings_user_ticker
  on ticker_earnings_reactions(user_id, ticker, earnings_date desc);

-- ----------------------------------------------------------------
-- UPDATED_AT triggers for mutable tables
-- ----------------------------------------------------------------
create trigger ticker_notes_updated_at
  before update on ticker_profile_notes
  for each row execute function set_updated_at();

create trigger ticker_sr_updated_at
  before update on ticker_support_resistance
  for each row execute function set_updated_at();
