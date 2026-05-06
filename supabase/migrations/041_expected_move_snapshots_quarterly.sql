-- Add 'quarterly' as a valid period_type in expected_move_snapshots.
-- period_type: 'daily'     — DTE closest to 1
--              'weekly'    — DTE closest to 7
--              'monthly'   — DTE closest to 30
--              'quarterly' — DTE closest to 90  (added here)
--
-- No schema change required — period_type is an unconstrained text column.
-- This migration documents the new value for clarity.

COMMENT ON COLUMN expected_move_snapshots.period_type IS
  'daily | weekly | monthly | quarterly — DTE target 1 / 7 / 30 / 90';
