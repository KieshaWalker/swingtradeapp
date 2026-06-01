-- =============================================================================
-- 055_iv_snapshots_multi_window.sql
-- =============================================================================
-- Add 4-week and 26-week IVR/IVP columns to iv_snapshots.
-- Computed daily by iv_pull using the trailing 21 and 130 rows of history.
-- =============================================================================

ALTER TABLE iv_snapshots
    ADD COLUMN IF NOT EXISTS iv_rank_4w        numeric(6,2),
    ADD COLUMN IF NOT EXISTS iv_percentile_4w  numeric(6,2),
    ADD COLUMN IF NOT EXISTS iv_rank_26w       numeric(6,2),
    ADD COLUMN IF NOT EXISTS iv_percentile_26w numeric(6,2);
