-- =============================================================================
-- 085: trend_lines — user-saved, named trend lines (manual or algorithm-fitted)
-- =============================================================================
-- A trend line is stored as exactly TWO ANCHOR POINTS (a date + price on each
-- end) and nothing else. slope/intercept are derived at read time, never
-- stored, so there is no way for a saved line to drift out of sync with its
-- own two points.
--
-- MANUAL AND ALGORITHM-FITTED LINES SHARE ONE SCHEMA. The algorithm
-- (services/channel_fit.suggest_trendlines) is just a tool that proposes two
-- anchor points from a pivot pair services/channel_fit.find_pivots already
-- found; a manual line is the user supplying those same two points directly by
-- typing them in. Both are saved through the identical insert. `source`
-- records which path produced it, purely for display — it changes no logic.
--
-- `kind` decides how accuracy tracking reads the line later:
--   resistance  a break ABOVE the line (by more than the ATR tolerance) is a
--               violation — the classic overhead-supply reading
--   support     a break BELOW is a violation — the classic floor reading
--   manual      no directional violation is inferred. A hand-drawn line
--               carries no built-in expectation of which side price should
--               stay on, and guessing one would be worse than reporting
--               deviation stats without a verdict.
--
-- NO STATUS/ACCURACY COLUMNS. Whether a line is still holding is a pure
-- function of its two anchors plus the equity_bars that have printed since —
-- computed on read (POST /trend-lines/accuracy), not stored. Every new nightly
-- bar updates the answer without anything needing to run on a schedule.
-- =============================================================================

create table if not exists trend_lines (
  id             uuid        primary key default gen_random_uuid(),
  user_id        uuid        not null references auth.users(id) on delete cascade,
  ticker         text        not null,
  name           text        not null check (trim(name) <> ''),
  kind           text        not null check (kind in ('support', 'resistance', 'manual')),
  source         text        not null check (source in ('manual', 'fitted')),

  anchor1_date   date        not null,
  anchor1_price  numeric     not null,
  anchor2_date   date        not null,
  anchor2_price  numeric     not null,
  check (anchor2_date > anchor1_date),

  created_at     timestamptz not null default now()
);

create index if not exists trend_lines_user_ticker
  on trend_lines (user_id, ticker, created_at desc);

alter table trend_lines enable row level security;

-- Same four-policy "own rows" pattern as target_levels (070) and
-- ticker_support_resistance — personal planning data, not shared market data.
create policy "trend_lines_select" on trend_lines
  for select using (auth.uid() = user_id);
create policy "trend_lines_insert" on trend_lines
  for insert with check (auth.uid() = user_id);
create policy "trend_lines_update" on trend_lines
  for update using (auth.uid() = user_id);
create policy "trend_lines_delete" on trend_lines
  for delete using (auth.uid() = user_id);
