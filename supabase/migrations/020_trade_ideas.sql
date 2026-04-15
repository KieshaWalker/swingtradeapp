-- =============================================================================
-- 020: trade_ideas
-- Stores trade ideas saved from the five-phase evaluation screen.
-- Ideas persist regardless of whether they passed all 5 phases, allowing
-- the user to monitor a setup until the market comes to them.
-- =============================================================================

create table if not exists trade_ideas (
  id            uuid        primary key default gen_random_uuid(),
  user_id       uuid        not null references auth.users(id) on delete cascade,
  ticker        text        not null,
  contract_type text        not null check (contract_type in ('call', 'put')),
  strike        numeric     not null,
  expiry_date   date        not null,
  quantity      int         not null default 1,
  budget        numeric     not null default 5000,
  price_target  numeric,
  notes         text,
  created_at    timestamptz not null default now()
);

alter table trade_ideas enable row level security;

create policy "Users manage own trade ideas"
  on trade_ideas
  using  (user_id = auth.uid())
  with check (user_id = auth.uid());

create index trade_ideas_user_created
  on trade_ideas (user_id, created_at desc);
