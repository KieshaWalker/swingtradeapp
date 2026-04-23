-- =============================================================================
-- 025_regime_snapshots_institutional_fields.sql
-- =============================================================================
-- Adds institutional-grade context columns to regime_snapshots.
-- All populated by the 8-hour schwab_pull pipeline.
--
-- New fields:
--   delta_gex                 — day-over-day GEX change ($M)
--   vix_term_structure_ratio  — VIX / VIX3M (<1 contango, >1 backwardation)
--   vvix_current              — current VVIX level
--   spot_to_vt_pct            — (spot - VolatilityTrigger) / spot × 100
--   breadth_proxy             — RSP/SPY 5d return ratio z-score
--   gex_0dte                  — GEX from same-day expiries only ($M)
--   gex_0dte_pct              — gex_0dte / |total_gex| × 100
--   price_roc5                — 5-day price rate of change (%)
--   total_gex                 — total net dealer GEX ($M); denormalized from iv_snapshots
-- =============================================================================

ALTER TABLE regime_snapshots
  ADD COLUMN IF NOT EXISTS delta_gex                numeric(14,2),
  ADD COLUMN IF NOT EXISTS vix_term_structure_ratio numeric(8,4),
  ADD COLUMN IF NOT EXISTS vvix_current             numeric(8,2),
  ADD COLUMN IF NOT EXISTS spot_to_vt_pct           numeric(8,4),
  ADD COLUMN IF NOT EXISTS breadth_proxy            numeric(8,4),
  ADD COLUMN IF NOT EXISTS gex_0dte                 numeric(14,2),
  ADD COLUMN IF NOT EXISTS gex_0dte_pct             numeric(8,2),
  ADD COLUMN IF NOT EXISTS price_roc5               numeric(8,4),
  ADD COLUMN IF NOT EXISTS total_gex                numeric(14,2);

COMMENT ON COLUMN regime_snapshots.delta_gex                IS 'GEX_t − GEX_{t−1} day-over-day change ($M)';
COMMENT ON COLUMN regime_snapshots.vix_term_structure_ratio IS 'VIX / VIX3M; <1 = contango (vol tailwind), >1 = backwardation';
COMMENT ON COLUMN regime_snapshots.vvix_current             IS 'VVIX level at observation time; >120 with VIX<20 = early regime warning';
COMMENT ON COLUMN regime_snapshots.spot_to_vt_pct           IS '(spot − VolatilityTrigger) / spot × 100; <0 = in VT/ZGL transition corridor';
COMMENT ON COLUMN regime_snapshots.breadth_proxy            IS 'RSP/SPY 5d return ratio z-score; < −1.5 = narrow breadth divergence';
COMMENT ON COLUMN regime_snapshots.gex_0dte                 IS 'GEX contributed by same-day expiries only ($M)';
COMMENT ON COLUMN regime_snapshots.gex_0dte_pct             IS 'gex_0dte / |total_gex| × 100; high = intraday-only gamma dominates';
COMMENT ON COLUMN regime_snapshots.price_roc5               IS '5-day price rate of change (%), leading momentum indicator';
COMMENT ON COLUMN regime_snapshots.total_gex                IS 'Total net dealer GEX ($M); denormalized from iv_snapshots for regime queries';
