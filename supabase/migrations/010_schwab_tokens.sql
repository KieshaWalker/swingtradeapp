-- =============================================================================
-- 010_schwab_tokens.sql
-- Stores the Schwab OAuth token pair (single row, app-level, not user-scoped).
-- Only Edge Functions (service role) can read/write this table.
-- Flutter clients have zero access — no RLS policy grants client access.
-- =============================================================================

CREATE TABLE IF NOT EXISTS schwab_tokens (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  access_token  text        NOT NULL,
  refresh_token text        NOT NULL,
  expires_at    timestamptz NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- Block all direct client access — service role bypasses RLS anyway
ALTER TABLE schwab_tokens ENABLE ROW LEVEL SECURITY;

-- No policies intentionally — only service role (Edge Functions) may access
