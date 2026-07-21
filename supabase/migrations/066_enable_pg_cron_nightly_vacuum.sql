-- =============================================================================
-- 066_enable_pg_cron_nightly_vacuum.sql
-- =============================================================================
-- Disk-IO remediation (Phase 1, item C). VACUUM cannot run inside a
-- transaction block, and the Python backend only talks to Postgres through
-- PostgREST (db.table()/db.rpc()), which wraps every request — including RPC
-- calls to security definer functions — in a transaction. VACUUM is not
-- callable through that path by any means. pg_cron runs each scheduled job in
-- its own top-level connection, which is the only way to schedule VACUUM
-- inside Postgres itself. It ships pre-loaded in Supabase's Postgres image,
-- so enabling it does not require a restart.
--
-- Three separate jobs, not one combined script: pg_cron only bypasses the
-- transaction wrapper for a single bare VACUUM statement per job — a command
-- string with multiple statements would error with "VACUUM cannot run inside
-- a transaction block." Staggering them 5 minutes apart also avoids stacking
-- IO spikes at the same instant. 03:00 UTC sits comfortably inside the
-- overnight low-traffic window (market closed since 21:00 UTC, next session
-- not until 13:00 UTC).
-- =============================================================================

create extension if not exists pg_cron with schema extensions;

select cron.schedule('vacuum-vol_surface-nightly', '0 3 * * *',  $$VACUUM (ANALYZE) public.vol_surface_snapshots$$);
select cron.schedule('vacuum-iv-snapshots-nightly', '5 3 * * *',  $$VACUUM (ANALYZE) public.iv_snapshots$$);
select cron.schedule('vacuum-greek-grid-nightly',   '10 3 * * *', $$VACUUM (ANALYZE) public.greek_grid_snapshots$$);
