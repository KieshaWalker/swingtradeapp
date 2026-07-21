-- =============================================================================
-- 064_hot_table_autovacuum_tuning.sql
-- =============================================================================
-- Disk-IO remediation (Phase 1, item A). vol_surface_snapshots, iv_snapshots,
-- and greek_grid_snapshots are UPSERTed in place hourly during market hours by
-- the pull pipeline. No table in this migration history has custom autovacuum
-- settings, so all of them run on Postgres defaults (20% dead-tuple threshold)
-- — too lax for hourly-churn tables, letting dead tuples/TOAST bloat pile up
-- across a full trading session between vacuum cycles.
--
-- Fixed thresholds (not just scale factors) keep the practical trigger point
-- low even as these tables grow over months — scale_factor alone drifts
-- looser as total row count climbs while the "hot" (today's) subset stays
-- roughly constant.
-- =============================================================================

ALTER TABLE vol_surface_snapshots SET (
  autovacuum_vacuum_scale_factor  = 0.02,
  autovacuum_vacuum_threshold     = 5,
  autovacuum_analyze_scale_factor = 0.02,
  autovacuum_analyze_threshold    = 5,
  toast.autovacuum_vacuum_scale_factor = 0.02,
  toast.autovacuum_vacuum_threshold    = 5
);

ALTER TABLE iv_snapshots SET (
  autovacuum_vacuum_scale_factor  = 0.02,
  autovacuum_vacuum_threshold     = 50,
  autovacuum_analyze_scale_factor = 0.02,
  autovacuum_analyze_threshold    = 50,
  toast.autovacuum_vacuum_scale_factor = 0.02,
  toast.autovacuum_vacuum_threshold    = 20
);

ALTER TABLE greek_grid_snapshots SET (
  autovacuum_vacuum_scale_factor  = 0.05,
  autovacuum_vacuum_threshold     = 20,
  autovacuum_analyze_scale_factor = 0.05,
  autovacuum_analyze_threshold    = 20
);

-- Same hourly-UPDATE shape, narrower rows, lower priority — included for
-- consistency across the rest of the pull pipeline.
ALTER TABLE sabr_calibrations   SET (autovacuum_vacuum_scale_factor = 0.05, autovacuum_analyze_scale_factor = 0.05);
ALTER TABLE heston_calibrations SET (autovacuum_vacuum_scale_factor = 0.05, autovacuum_analyze_scale_factor = 0.05);
ALTER TABLE regime_snapshots    SET (autovacuum_vacuum_scale_factor = 0.05, autovacuum_analyze_scale_factor = 0.05);
