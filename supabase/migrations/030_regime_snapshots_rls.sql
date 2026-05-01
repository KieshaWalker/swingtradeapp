-- RLS was enabled on regime_snapshots but no policies were defined,
-- which caused authenticated users to get zero rows on SELECT.
-- regime_snapshots is a shared ticker-level table (no user_id column),
-- so all authenticated users are allowed to read all rows.
-- Writes are done via the service_role key which bypasses RLS.

CREATE POLICY IF NOT EXISTS "authenticated_read_regime_snapshots"
  ON regime_snapshots
  FOR SELECT
  TO authenticated
  USING (true);
