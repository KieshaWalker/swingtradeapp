-- =============================================================================
-- 065_hot_table_toast_compression.sql
-- =============================================================================
-- Disk-IO remediation (Phase 1, item B). vol_surface_snapshots.points and
-- iv_snapshots.gex_by_strike are large JSONB payloads rewritten in full on
-- every hourly upsert. Switching their TOAST compression from the default
-- pglz to lz4 (Postgres 14+) shrinks the physical bytes written/read per
-- rewrite at lower CPU cost than pglz.
--
-- No backfill: SET COMPRESSION only affects values written after this ALTER,
-- not existing TOAST data. Both columns are already rewritten hourly for
-- today's row, so they pick up lz4 organically within about an hour of
-- deploy. A bulk backfill would itself burn a fresh round of dead
-- tuples/WAL across the whole table — exactly what to avoid right after an
-- IO-budget incident.
-- =============================================================================

ALTER TABLE vol_surface_snapshots ALTER COLUMN points       SET COMPRESSION lz4;
ALTER TABLE iv_snapshots          ALTER COLUMN gex_by_strike SET COMPRESSION lz4;
