-- =============================================================================
-- 044_blotter_trades.sql
-- Creates the blotter_trades table used by the five-phase blotter screen.
-- user_id defaults to auth.uid() so Flutter can insert without specifying it.
-- =============================================================================

CREATE TABLE IF NOT EXISTS blotter_trades (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id               uuid        NOT NULL DEFAULT auth.uid()
                                    REFERENCES auth.users(id) ON DELETE CASCADE,

  -- Contract identity
  symbol                text        NOT NULL,
  strike                numeric     NOT NULL,
  expiration            text        NOT NULL,
  contract_type         text        NOT NULL,   -- 'call' | 'put'
  quantity              integer     NOT NULL,
  strategy_tag          text        NOT NULL,
  notes                 text,
  status                text        NOT NULL DEFAULT 'draft',  -- 'draft' | 'committed' | 'sent'

  -- Fair value output
  broker_mid            numeric,
  bs_fair_value         numeric,
  sabr_fair_value       numeric,
  model_fair_value      numeric,
  edge_bps              numeric,
  implied_vol           numeric,
  sabr_vol              numeric,

  -- Greeks
  delta                 numeric,
  gamma                 numeric,
  theta                 numeric,
  vega                  numeric,
  rho                   numeric,
  underlying_price      numeric,

  -- Higher-order greeks
  vanna                 numeric,
  charm                 numeric,
  volga                 numeric,

  -- Portfolio risk snapshot at commit time
  portfolio_delta_before  numeric,
  portfolio_delta_after   numeric,
  portfolio_vega_before   numeric,
  portfolio_vega_after    numeric,
  es95_before             numeric,
  es95_after              numeric,

  created_at  timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE blotter_trades ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users manage own blotter trades"
  ON blotter_trades FOR ALL TO authenticated
  USING  (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);
