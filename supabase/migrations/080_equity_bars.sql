-- =============================================================================
-- 080: equity_bars — OHLCV price bars for the swing-setup engine
-- =============================================================================
-- The system had NO equity price bars anywhere before this table. iv_snapshots
-- carries a daily `underlying_price` (a close, nothing more) and every column
-- named "volume" elsewhere in the schema is OPTIONS volume. Channel fitting
-- needs highs and lows, moving averages need a long close series, and volume
-- surge needs share volume — none of which existed.
--
-- WHY (bar_date, bar_seq) RATHER THAN A TIMESTAMP
-- -----------------------------------------------
-- Daily bars are a calendar fact, and this repo's convention is that date
-- columns are never shifted between zones. Storing a timestamptz would force
-- every reader to pick a session-open convention and would silently drift with
-- US daylight-saving changes. bar_seq instead numbers the bars WITHIN a date:
--
--   timeframe='daily' -> always bar_seq = 0
--   timeframe='4h'    -> bar_seq 0 = 09:30-13:30 ET, bar_seq 1 = 13:30-16:00 ET
--
-- The 4h layout is pre-committed here so adding it later is an INSERT, not a
-- migration. It is two bars, not four, because US regular hours are 6.5h and do
-- not tile into 4-hour blocks; Schwab has no native 240-minute frequency, so 4h
-- bars are aggregated from 30-minute candles (8 + 5).
--
-- THIS TABLE MUST NEVER BE ADDED TO A RETENTION PURGE
-- ---------------------------------------------------
-- Schwab serves only ~48 days of intraday history. Once a 4h bar ages past that
-- window it is UNRECOVERABLE from the vendor — unlike every *_snapshots table
-- here, which can be rebuilt by re-running its job. Deleting rows from
-- equity_bars destroys history permanently. See 075_snapshot_retention.sql for
-- the tables that ARE safe to purge.
-- =============================================================================

create table if not exists equity_bars (
  ticker      text          not null,
  -- 'daily' today; '4h' reserved for the intraday layer described above.
  timeframe   text          not null check (timeframe in ('daily', '4h')),
  bar_date    date          not null,
  bar_seq     smallint      not null default 0,

  open        numeric(14,4) not null,
  high        numeric(14,4) not null,
  low         numeric(14,4) not null,
  close       numeric(14,4) not null,
  -- bigint, not integer: a heavily traded session can exceed the 2.1B int4
  -- ceiling, and an overflow here would fail the whole upsert batch.
  volume      bigint,

  ingested_at timestamptz   not null default now(),

  primary key (ticker, timeframe, bar_date, bar_seq)
);

-- Sanity constraint. A vendor glitch that returns a high below the low would
-- otherwise poison every channel fit computed from it, silently — the fit would
-- still produce lines, just wrong ones.
alter table equity_bars
  drop constraint if exists equity_bars_ohlc_sane;
alter table equity_bars
  add constraint equity_bars_ohlc_sane
  check (low <= open and low <= close and open <= high and close <= high);

-- Every read is "the last N bars for one ticker on one timeframe", walked
-- newest-first then reversed. Matches the PostgREST 1000-row cap workaround
-- used elsewhere in this codebase.
create index if not exists equity_bars_ticker_tf_date
  on equity_bars (ticker, timeframe, bar_date desc, bar_seq desc);

alter table equity_bars enable row level security;

-- Market data, not user data: readable by any authenticated user, matching the
-- expected_move_snapshots / iv_snapshots pattern. Writes come from the backend
-- job under the service role, which bypasses RLS.
create policy "Authenticated users can read equity bars"
  on equity_bars for select
  to authenticated
  using (true);
