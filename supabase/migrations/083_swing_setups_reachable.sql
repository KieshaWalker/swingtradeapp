-- =============================================================================
-- 083: swing_setups — underpriced_{up,down} -> reachable_{up,down}
-- =============================================================================
-- The underpriced flag from 082 was degenerate. It was defined as
-- em_ratio > 1.0 — the measured-move target sitting outside the 30-day 1σ cone
-- — and measured against the real universe it came back TRUE on 100% of fitted
-- channels. A confirmation leg that agrees with every candidate confirms
-- nothing.
--
-- It is true almost by construction: channel heights run ~27% median here while
-- the 30-day cone is ~10-15%, so the ratio cannot land near 1. The error was one
-- of units — a measured move is a price with NO deadline, an expected move is a
-- price AT a deadline, and comparing them at an arbitrary 30 days lets that
-- arbitrary choice decide the answer.
--
-- reachable_* instead asks whether the market's OWN implied vol carries price to
-- the target within 90 days (~the quarterly expiry, the longest tenor with
-- reliable liquidity across this universe). Measured: fires on ~14% of fitted
-- channels, and NULL when implied_days exceeds 365, since "this measured move
-- does not describe this market" is a different claim from "not this quarter".
--
-- em_ratio_up / em_ratio_down are KEPT as continuous descriptors. They are still
-- informative read as a magnitude (1.48 vs 5.73 says something); they must never
-- be thresholded at 1.0 again.
--
-- Dropped rather than renamed: the old column held a value computed under the
-- degenerate definition, and carrying it forward under a new name would leave a
-- column whose meaning changes silently at a cutover date.
-- =============================================================================

alter table swing_setups
  drop column if exists underpriced_up,
  drop column if exists underpriced_down;

alter table swing_setups
  add column if not exists reachable_up   boolean,
  add column if not exists reachable_down boolean;
