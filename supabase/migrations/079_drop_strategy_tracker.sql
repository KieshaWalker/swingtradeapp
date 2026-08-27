-- =============================================================================
-- 079: drop strategy_tracker
-- Reverses 048 (strategy_setups + trades.strategy_setup_id) and 049
-- (target_areas).  The whole feature — screens, providers, models — was
-- scrapped on 2026-08-27; nothing reads these objects any more.
--
-- Trades are NOT affected.  The FK was `on delete set null`, so the 8 tagged
-- trades survive intact; only the tag itself is lost.  The 2 setups and the
-- 8 (trade_id, setup_id) pairs were dumped to data/strategy_tracker_backup.json
-- before this ran, in case the feature is ever revived.
-- =============================================================================

-- Drop the FK column first so the table drop needs no cascade.
-- The partial index trades_strategy_setup_idx goes with the column.
alter table trades
  drop column if exists strategy_setup_id;

-- Indexes strategy_setups_user_name / strategy_setups_user_created and the
-- "Users manage own strategies" RLS policy are dropped with the table.
drop table if exists strategy_setups;
