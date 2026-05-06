-- Restructure realized_vol_snapshots RV columns to match daily/weekly/monthly timeframes.
-- Replace rv_20d / rv_60d with rv_1d (daily), rv_5d (weekly ~5d), rv_21d (monthly ~21d).
ALTER TABLE realized_vol_snapshots
  ADD COLUMN IF NOT EXISTS rv_1d  DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS rv_5d  DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS rv_21d DOUBLE PRECISION;

ALTER TABLE realized_vol_snapshots
  DROP COLUMN IF EXISTS rv_20d,
  DROP COLUMN IF EXISTS rv_60d,
  DROP COLUMN IF EXISTS rv_20d_percentile,
  DROP COLUMN IF EXISTS rv_60d_percentile;
