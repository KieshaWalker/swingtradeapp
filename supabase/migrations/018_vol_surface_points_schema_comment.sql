-- =============================================================================
-- 018_vol_surface_points_schema_comment.sql
--
-- Documents the expanded `points` JSONB shape after adding volume and open
-- interest fields parsed from the ThinkorSwim "Stock and Option Quote" CSV.
--
-- Each element of `points` now follows:
--   {
--     strike:     number,
--     dte:        number,
--     call_iv:    number | null,   -- implied vol, decimal (e.g. 0.453)
--     put_iv:     number | null,
--     call_vol:   number | null,   -- call volume for this strike/expiry
--     put_vol:    number | null,
--     call_oi:    number | null,   -- call open interest
--     put_oi:     number | null
--   }
--
-- Older snapshots (before this migration) only contain strike / dte / call_iv /
-- put_iv. Missing keys are treated as null by the Dart fromJson factory.
-- No DDL changes required — JSONB is schema-flexible.
-- =============================================================================

comment on column vol_surface_snapshots.points is
  'Array of option chain data points. Shape: { strike, dte, call_iv?, put_iv?, call_vol?, put_vol?, call_oi?, put_oi? }. Rows written before 2026-04-13 omit the volume/OI keys.';
