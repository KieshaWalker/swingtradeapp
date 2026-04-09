-- =============================================================================
-- 013_trades_tp_sl.sql
-- Adds stop-loss and take-profit target columns to the trades table.
-- These are set at trade entry and drive the TP/SL proximity bar in the UI.
-- =============================================================================

ALTER TABLE trades
  ADD COLUMN IF NOT EXISTS stop_loss   NUMERIC,
  ADD COLUMN IF NOT EXISTS take_profit NUMERIC;

COMMENT ON COLUMN trades.stop_loss   IS 'User-defined stop level (option premium per share)';
COMMENT ON COLUMN trades.take_profit IS 'User-defined profit target (option premium per share)';
