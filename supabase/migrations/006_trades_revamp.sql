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
  ADD COLUMN IF NOT EXISTS entry_point_type     text;   -- 'atm' | 'itm' | 'otm'

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
