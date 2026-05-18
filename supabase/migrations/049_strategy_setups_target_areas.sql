-- =============================================================================
-- 049: strategy_setups — add target_areas column
-- Stores the price-level targets a strategy aims to reach (ATH, 200 SMA, etc.)
-- as a text array of enum strings.  Default '{}' so existing rows are safe.
-- =============================================================================
alter table strategy_setups
  add column if not exists target_areas text[] not null default '{}';
