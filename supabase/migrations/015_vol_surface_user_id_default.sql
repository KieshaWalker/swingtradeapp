-- =============================================================================
-- 015_vol_surface_user_id_default.sql
--
-- Adds DEFAULT auth.uid() to vol_surface_snapshots.user_id so that inserts
-- from the Supabase JS client (which never sends user_id explicitly) work
-- under RLS without the caller knowing their own user ID.
-- =============================================================================

ALTER TABLE vol_surface_snapshots
  ALTER COLUMN user_id SET DEFAULT auth.uid();
