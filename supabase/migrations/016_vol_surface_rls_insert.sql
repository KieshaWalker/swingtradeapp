-- =============================================================================
-- 016_vol_surface_rls_insert.sql
--
-- The original "own snapshots" policy only had a USING clause, which covers
-- SELECT / UPDATE / DELETE but NOT INSERT.  Supabase blocks inserts when no
-- WITH CHECK clause matches.  This migration recreates the policy with both
-- clauses so authenticated users can insert their own rows.
-- =============================================================================

DROP POLICY IF EXISTS "own snapshots" ON vol_surface_snapshots;

CREATE POLICY "own snapshots" ON vol_surface_snapshots
  USING     (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);
