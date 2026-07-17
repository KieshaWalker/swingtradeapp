-- =============================================================================
-- 062_crisis_macro_expansion
-- =============================================================================
-- Household stress, bank balance sheets (H.8), and the global edge of the
-- board, written daily by crisis_pull from FRED + Schwab:
--   consumer:  credit-card & all-loan delinquency rates (quarterly, carried)
--   banks:     deposits & bank credit YoY (weekly H.8 — the March-2023 piece)
--   global:    broad dollar index, yen 20d move (carry-unwind tell: yen
--              strengthening fast = DEXJPUS falling), FXI 20d (China proxy)
-- Data-first: no verdicts until enough history exists to calibrate thresholds.
-- =============================================================================

ALTER TABLE crisis_checklist_snapshots
    ADD COLUMN IF NOT EXISTS cc_delinq_pct         numeric(6,2),
    ADD COLUMN IF NOT EXISTS loan_delinq_pct       numeric(6,2),
    ADD COLUMN IF NOT EXISTS bank_deposits_yoy_pct numeric(6,2),
    ADD COLUMN IF NOT EXISTS bank_credit_yoy_pct   numeric(6,2),
    ADD COLUMN IF NOT EXISTS dollar_idx            numeric(8,2),
    ADD COLUMN IF NOT EXISTS dollar_20d_pct        numeric(6,2),
    ADD COLUMN IF NOT EXISTS jpyusd_20d_pct        numeric(6,2),
    ADD COLUMN IF NOT EXISTS fxi_20d_pct           numeric(6,2);
