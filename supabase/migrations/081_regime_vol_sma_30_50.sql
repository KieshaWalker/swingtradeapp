-- =============================================================================
-- 081: regime_snapshots — replace vol_sma3/vol_sma20 with vol_sma30/vol_sma50
-- =============================================================================
-- The 3-session/20-session volume pair is replaced by 30/50. Both are still
-- computable inside the existing pipeline: regime_pull fetches 65 closes, which
-- covers a 50-bar average with slack.
--
-- WHAT CHANGES IN MEANING — this is not a rename, the numbers mean something
-- different. Measured over 9,821 observations in equity_bars, a single 10x
-- volume day moved sma3/sma20 to 2.759 (past its p99) but moves sma30/sma50 to
-- only 1.102, below that ratio's own p90 of 1.167. The new pair therefore
-- describes a SUSTAINED shift in participation over ~6 vs ~10 weeks and cannot
-- register a one-day breakout surge. Single-day surge detection now lives in
-- services/trend_volume.py, which compares the session against a 30-day median.
--
-- THE OLD COLUMNS ARE DROPPED, NOT KEPT. Historical rows hold values computed
-- on the 3/20 windows; carrying them forward under any name would leave a
-- column whose meaning silently changes at a cutover date — the same trap
-- documented for total_vex/total_cex at the 2026-06-12 scale break. New columns
-- start NULL and fill from the next regime-pull onward.
--
-- Backfill is POSSIBLE but not done here: equity_bars now holds ~252 sessions of
-- daily volume per ticker, enough to recompute both averages historically. That
-- is a separate job if the history is ever wanted.
--
-- Safe for the classifier: vol_sma3/vol_sma20 fed only
-- regime_service._append_volume_signal, an additive context signal documented as
-- "unconditional — never override bias". No strategy_bias output changes.
-- =============================================================================

alter table regime_snapshots
  add column if not exists vol_sma30 float,
  add column if not exists vol_sma50 float;

alter table regime_snapshots
  drop column if exists vol_sma3,
  drop column if exists vol_sma20;
