-- =============================================================================
-- 052_heston_calibrations_rls_and_index.sql
-- =============================================================================
-- heston_calibrations was created without RLS (migration 029), meaning any
-- authenticated user could read all users' Heston parameters.
-- Also adds the compound index used on every provider call.
-- =============================================================================

ALTER TABLE heston_calibrations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can manage their own heston calibrations"
  ON heston_calibrations
  FOR ALL
  TO authenticated
  USING  (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

CREATE INDEX IF NOT EXISTS idx_heston_calibrations_user_ticker_date
    ON heston_calibrations (user_id, ticker, obs_date DESC);
