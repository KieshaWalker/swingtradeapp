-- =============================================================================
-- 045_position_snapshots_implied_vol.sql
-- Adds implied_vol column to position_leg_snapshots.
-- =============================================================================

ALTER TABLE position_leg_snapshots
    ADD COLUMN implied_vol NUMERIC;
