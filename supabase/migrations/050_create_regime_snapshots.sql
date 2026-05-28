-- =============================================================================
-- 050_create_regime_snapshots.sql
-- =============================================================================
-- Creates the regime_snapshots table that migrations 024, 025, 030, 046 assume
-- already exists. This CREATE TABLE should have preceded those migrations but
-- the original CREATE was never committed. All columns from subsequent ALTERs
-- are included here; the ALTER TABLE … ADD COLUMN IF NOT EXISTS in those later
-- migrations are idempotent and will simply no-op.
-- =============================================================================

CREATE TABLE IF NOT EXISTS regime_snapshots (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    ticker                  text        NOT NULL,
    obs_date                date        NOT NULL,
    gamma_regime            text,
    iv_gex_signal           text,
    sma10                   numeric(14,4),
    sma50                   numeric(14,4),
    sma_crossed             boolean,
    vix_current             numeric(8,2),
    vix_10ma                numeric(8,2),
    vix_dev_pct             numeric(8,2),
    vix_rsi                 numeric(8,2),
    vix_term_structure_ratio numeric(8,4),
    vvix_current            numeric(8,2),
    vvix_10ma               numeric(8,2),
    spot_to_zgl_pct         numeric(8,4),
    spot_to_vt_pct          numeric(8,4),
    iv_percentile           numeric(8,2),
    hmm_state               text,
    hmm_probability         numeric(8,4),
    strategy_bias           text,
    signals                 jsonb,
    vol_sma3                float,
    vol_sma20               float,
    delta_gex               numeric(14,2),
    breadth_proxy           numeric(8,4),
    gex_0dte                numeric(14,2),
    gex_0dte_pct            numeric(8,2),
    price_roc5              numeric(8,4),
    total_gex               numeric(14,2),
    created_at              timestamptz NOT NULL DEFAULT now(),

    UNIQUE (ticker, obs_date)
);

ALTER TABLE regime_snapshots ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS idx_regime_snapshots_ticker_date
    ON regime_snapshots (ticker, obs_date DESC);
