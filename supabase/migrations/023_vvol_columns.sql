-- Add vol-of-vol (SABR ν) analytics columns to iv_snapshots.
-- These are populated by schwab_pull.py after SABR calibration using the
-- ~30 DTE slice history from sabr_calibrations.

ALTER TABLE iv_snapshots
  ADD COLUMN IF NOT EXISTS vvol_nu         NUMERIC(8,6),
  ADD COLUMN IF NOT EXISTS vvol_rank       NUMERIC(6,2),
  ADD COLUMN IF NOT EXISTS vvol_percentile NUMERIC(6,2),
  ADD COLUMN IF NOT EXISTS vvol_rating     TEXT,
  ADD COLUMN IF NOT EXISTS vvol_trend      TEXT;

COMMENT ON COLUMN iv_snapshots.vvol_nu         IS 'SABR ν from ~30 DTE calibration slice (vol-of-vol level)';
COMMENT ON COLUMN iv_snapshots.vvol_rank       IS 'ν rank 0-100 relative to 52-week range, mirrors IV rank formula';
COMMENT ON COLUMN iv_snapshots.vvol_percentile IS 'Fraction of history days with ν below current (0-100)';
COMMENT ON COLUMN iv_snapshots.vvol_rating     IS 'cheap / fair / elevated / extreme';
COMMENT ON COLUMN iv_snapshots.vvol_trend      IS 'rising / falling / flat (last 10 days vs prior 10 days)';
