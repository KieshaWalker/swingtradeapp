-- =============================================================================
-- 036_iv_snapshots_institutional_gex_and_vvol.sql
-- =============================================================================
-- Extends iv_snapshots with institutional GEX fields (0DTE gamma breakdown,
-- volatility trigger) that were missing. These should mirror the columns in
-- regime_snapshots from migration 025, but specific to iv_snapshots.
-- =============================================================================

ALTER TABLE iv_snapshots
  ADD COLUMN IF NOT EXISTS gex_0dte           NUMERIC(14,2),
  ADD COLUMN IF NOT EXISTS gex_0dte_pct       NUMERIC(8,4),
  ADD COLUMN IF NOT EXISTS volatility_trigger NUMERIC(10,2),
  ADD COLUMN IF NOT EXISTS spot_to_vt_pct     NUMERIC(8,4);

COMMENT ON COLUMN iv_snapshots.gex_0dte           IS 'GEX contributed by same-day expiries only ($M)';
COMMENT ON COLUMN iv_snapshots.gex_0dte_pct       IS 'gex_0dte / |total_gex| × 100; high = intraday-only gamma dominates';
COMMENT ON COLUMN iv_snapshots.volatility_trigger IS 'Last meaningful positive-GEX support wall above ZGL';
COMMENT ON COLUMN iv_snapshots.spot_to_vt_pct     IS '(spot − VolatilityTrigger) / spot × 100; <0 = in VT/ZGL transition corridor';
