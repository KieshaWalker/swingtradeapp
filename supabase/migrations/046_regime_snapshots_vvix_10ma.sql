-- =============================================================================
-- 046_regime_snapshots_vvix_10ma.sql
-- =============================================================================
-- Adds vvix_10ma to regime_snapshots.
--
-- vvix_current was added in 025 but its 10-day MA was not.
-- Both are needed for Gate 0 in regime_service.py:
--   vvix_spike = vvix_current > vvix_10ma * 1.15
-- Populated by jobs/regime_pull.py via FRED series VVIXCLS.
-- =============================================================================

ALTER TABLE regime_snapshots
  ADD COLUMN IF NOT EXISTS vvix_10ma numeric(8,2);

COMMENT ON COLUMN regime_snapshots.vvix_10ma IS '10-day MA of VVIX; spike = vvix_current > vvix_10ma * 1.15 signals hidden tail risk';
