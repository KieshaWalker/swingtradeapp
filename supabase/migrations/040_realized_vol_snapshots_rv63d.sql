-- Add rv_63d (63 trading days ≈ 3 calendar months) to realized_vol_snapshots.
-- Matches the 'quarterly' DTE bucket used by the term comparison feature.
-- Populated nightly by expected_move_pull and on backfill by backfill_rv.
ALTER TABLE realized_vol_snapshots
  ADD COLUMN IF NOT EXISTS rv_63d DOUBLE PRECISION;
