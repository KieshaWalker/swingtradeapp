-- =============================================================================
-- 061_crisis_bond_etf_ratios
-- =============================================================================
-- Traded bond-market columns on the daily crisis checklist: credit-ETF ratios
-- (same-day confirmation of the FRED OAS signal, which lags a day) and TLT
-- trend (duration = the hedge instrument of the deflationary-bust regime).
-- Fetched from Schwab price history by crisis_pull alongside the equity
-- baskets; individual bonds are not retail-API-accessible, the ETFs are the
-- traded bond market.
-- =============================================================================

ALTER TABLE crisis_checklist_snapshots
    ADD COLUMN IF NOT EXISTS hyg_ief_ratio        numeric(10,6),
    ADD COLUMN IF NOT EXISTS hyg_ief_off_high_pct numeric(8,2),
    ADD COLUMN IF NOT EXISTS hyg_ief_20d_pct      numeric(8,2),
    ADD COLUMN IF NOT EXISTS lqd_ief_20d_pct      numeric(8,2),
    ADD COLUMN IF NOT EXISTS tlt_20d_pct          numeric(8,2);
