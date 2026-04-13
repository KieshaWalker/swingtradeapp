-- =============================================================================
-- 017_vol_surface_unique_per_ticker.sql
--
-- Bug fix: the original unique constraint was (user_id, obs_date), which means
-- importing a vol surface for a second ticker on the same observation date would
-- silently overwrite the first ticker's data.
--
-- The correct key is (user_id, ticker, obs_date) — one row per user per ticker
-- per date.
--
-- The Dart repository already uses onConflict: 'user_id,obs_date' for its
-- upsert; that reference is updated to 'user_id,ticker,obs_date' separately
-- in vol_surface_repository.dart.
-- =============================================================================

-- Drop the old constraint (named by Postgres convention on the original table)
ALTER TABLE vol_surface_snapshots
  DROP CONSTRAINT IF EXISTS vol_surface_snapshots_user_id_obs_date_key;

-- Add the corrected composite unique key
ALTER TABLE vol_surface_snapshots
  ADD CONSTRAINT vol_surface_snapshots_user_ticker_obs_date_key
  UNIQUE (user_id, ticker, obs_date);

-- Update the obs_date index to also cover ticker for fast per-ticker queries
DROP INDEX IF EXISTS vol_surface_snapshots_obs_date_idx;

CREATE INDEX vol_surface_snapshots_ticker_obs_date_idx
  ON vol_surface_snapshots (user_id, ticker, obs_date DESC);
