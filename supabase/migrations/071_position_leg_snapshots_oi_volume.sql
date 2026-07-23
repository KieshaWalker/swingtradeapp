-- =============================================================================
-- 071_position_leg_snapshots_oi_volume
-- =============================================================================
-- Adds open_interest and total_volume to position_leg_snapshots, matching
-- the same columns added on watched_contract_snapshots
-- (069_watched_contract_snapshots.sql). Schwab's chain contract already
-- carries openInterest/totalVolume -- position_eod_snapshot.py just wasn't
-- extracting them. Backfills nothing; populates going forward only.
-- =============================================================================

ALTER TABLE position_leg_snapshots
    ADD COLUMN open_interest NUMERIC,
    ADD COLUMN total_volume  NUMERIC;
