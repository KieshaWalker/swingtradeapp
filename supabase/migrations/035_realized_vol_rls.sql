-- realized_vol_snapshots has no user_id column (market-wide data keyed on
-- symbol,date). Enable RLS with read-only access for authenticated users;
-- writes are service-role only (pipeline uses service key, bypasses RLS).
ALTER TABLE realized_vol_snapshots ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated users can read RV snapshots"
  ON realized_vol_snapshots FOR SELECT
  TO authenticated
  USING (true);
