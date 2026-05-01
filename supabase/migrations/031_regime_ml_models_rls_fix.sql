-- The original service_rw policy granted FOR ALL TO public USING (true),
-- which allowed any anon caller to read/write serialized model weights.
-- This table is written by the service_role key (bypasses RLS) and read
-- server-side only. No client policy is needed.
DROP POLICY IF EXISTS "service_rw" ON regime_ml_models;
