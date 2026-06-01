-- =============================================================================
-- 054_rv_percentiles.sql
-- =============================================================================
-- Add percentile ranking columns to realized_vol_snapshots.
-- Computed daily by expected_move_pull: what fraction of historical rv_21d/rv_63d
-- values are <= today's reading (0–100).
-- =============================================================================

ALTER TABLE realized_vol_snapshots
    ADD COLUMN IF NOT EXISTS rv_21d_pct double precision,
    ADD COLUMN IF NOT EXISTS rv_63d_pct double precision;
