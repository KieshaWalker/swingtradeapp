-- =============================================================================
-- 006_trades_revamp.sql
-- Adds option-specific setup fields to the trades table, and creates the
-- trade_journal table for post-trade reflection data.
-- =============================================================================

-- ── Extend trades table ───────────────────────────────────────────────────────
ALTER TABLE trades
  ADD COLUMN IF NOT EXISTS price_range_high     numeric,
  ADD COLUMN IF NOT EXISTS price_range_low      numeric,
  ADD COLUMN IF NOT EXISTS implied_vol_entry    numeric,
  ADD COLUMN IF NOT EXISTS intraday_support     numeric,
  ADD COLUMN IF NOT EXISTS intraday_resistance  numeric,
  ADD COLUMN IF NOT EXISTS daily_breakout_level numeric,
  ADD COLUMN IF NOT EXISTS daily_breakdown_level numeric,
  ADD COLUMN IF NOT EXISTS entry_point_type     text,   -- 'atm' | 'itm' | 'otm'
  ADD COLUMN IF NOT EXISTS max_loss             numeric,
  ADD COLUMN IF NOT EXISTS implied_vol_exit     numeric,
  ADD COLUMN IF NOT EXISTS time_of_entry        text,
  ADD COLUMN IF NOT EXISTS time_of_exit         text;

-- ── trade_journal ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS trade_journal (
  id                        uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  trade_id                  uuid        NOT NULL REFERENCES trades(id) ON DELETE CASCADE,
  user_id                   uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,

  -- Reflection
  daily_trend               text,       -- 'bullish' | 'bearish' | 'sideways' | 'choppy'
  r_multiple                numeric,    -- actual R earned/lost (exitPnl / maxLoss)
  grade                     text,       -- 'a' | 'b' | 'c' | 'd' | 'f'
  tag                       text,       -- e.g. 'momentum', 'earnings_play'
  mistakes                  text,
  exited_too_soon           boolean,
  followed_stop_loss        boolean,
  meditation                boolean,
  took_breaks               boolean,
  mindset_notes             text,
  post_trade_notes          text,

  -- Research / short interest
  short_pct                 numeric,
  institutional_pct         numeric,
  shares_shorted            numeric,
  prev_month_shares_shorted numeric,
  general_news              text,

  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (trade_id)
);

ALTER TABLE trade_journal ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users manage own journal"
  ON trade_journal FOR ALL TO authenticated
  USING  (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

----create table public.trades (
 -- id uuid not null default extensions.uuid_generate_v4 (),
  ---user_id uuid not null,
 -- ticker text not null,
 -- option_type text not null,
--  strategy text not null,
--  strike numeric(10, 2) not null,
--  expiration date not null,
--  dte_at_entry integer null,
--  contracts integer not null default 1,
--  entry_price numeric(10, 4) not null,
--  exit_price numeric(10, 4) null,
--  status text not null default 'open'::text,
--  iv_rank numeric(5, 2) null,
--  delta numeric(6, 4) null,
--  notes text null,
--  opened_at timestamp with time zone not null default now(),
--  closed_at timestamp with time zone null,
--  created_at timestamp with time zone not null default now(),
 -- updated_at timestamp with time zone not null default now(),
--  price_range_high numeric null,
--  price_range_low numeric null,
---implied_vol_entry numeric null,
--intraday_support numeric null,
---intraday_resistance numeric null,
---daily_breakout_level numeric null,
----daily_breakdown_level numeric null,
---entry_point_type text null,
--max_loss numeric null,
--implied_vol_exit numeric null,
--time_of_entry text null,
--time_of_exit text null,
--stop_loss numeric null,
--take_profit numeric null,
--constraint trades_pkey primary key (id),
--constraint trades_user_id_fkey foreign KEY (user_id) references auth.users (id) on delete CASCADE,
--constraint trades_option_type_check check (
   --(
--  option_type = any (array['call'::text, 'put'::text])
-- )
-- ),
--constraint trades_status_check check (
 --(
--  status = any (
--      array['open'::text, 'closed'::text, 'expired'::text]
--   )
-- )
-- ),
--constraint trades_strategy_check check (
--(
--  strategy = any (
--   array[
         -- 'long_call'::text,
         -- 'long_put'::text,
         -- 'bull_call_spread'::text,
         -- 'bear_put_spread'::text,
         -- 'bull_put_spread'::text,
         -- 'bear_call_spread'::text,
         -- 'iron_condor'::text,
         -- 'other'::text
       -- ]
     -- )
   -- )
 -- )
--) TABLESPACE pg_default;

----create trigger trades_updated_at BEFORE
--update on trades for EACH row
--execute FUNCTION set_updated_at ();