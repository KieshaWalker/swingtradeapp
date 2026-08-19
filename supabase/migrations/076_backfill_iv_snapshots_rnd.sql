-- =============================================================================
-- 076_backfill_iv_snapshots_rnd.sql
-- =============================================================================
-- Disk-IO remediation (Phase 2, item C). Reclaims the historical iv_snapshots
-- .rnd blobs — ~800 MB, roughly a third of the whole database.
--
-- ── Why NULL and not "keep 4 slices" ───────────────────────────────────────
-- rnd is write-only. It is upserted by iv_pull.py, schwab_pull.py and
-- /iv/snapshot, and read back by nothing:
--   - no backend select() anywhere names the column
--   - IvSnapshot (the Dart model for an iv_snapshots row) has no rnd field, so
--     even select=* parsed and discarded it
--   - the RndChart/vol-surface RND card read IvAnalysis.rnd, which comes off
--     the live POST /iv/snapshot response, never from this table
-- Trimming each historical blob down to the 4 slices 5d64892 now writes would
-- preserve data that still has no reader, for ~150 MB instead of ~800 MB. If
-- you want the history kept, stop here and say so — this is the irreversible
-- migration of the three.
--
-- NOTE: this stops the *existing* bloat. It does not stop it recurring — the
-- three writers above still persist rnd on every hourly pull, ~73 KB/row/hour
-- since 5d64892 narrowed the surface. Dropping "rnd" from those three upsert
-- dicts is the durable fix and is a three-line change.
--
-- ── Why batched, and why overnight ─────────────────────────────────────────
-- 065 warned against exactly this: a bulk rewrite right after an IO-budget
-- incident burns a fresh round of dead tuples and WAL. So it runs 200 rows at a
-- time, every 5 minutes, only between 02:00 and 05:59 UTC — market closed since
-- 21:00, next session not until 13:00, and overlapping 066's nightly VACUUMs so
-- the dead tuples get reclaimed on the same pass rather than accumulating.
-- ~2,450 eligible rows finish in about an hour, well inside one night.
--
-- The job unschedules itself when it finds nothing left to do, so it does not
-- need to be cleaned up by hand.
--
-- VACUUM makes the freed space reusable by Postgres; it does not return it to
-- the filesystem. Reported disk usage will not drop — new rows fill the space
-- instead of extending the files, which is what stops the growth curve. Only
-- VACUUM FULL (an exclusive lock on the table) or pg_repack shrinks the files.
-- =============================================================================

create or replace function backfill_iv_snapshots_rnd(p_batch_size integer default 200)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer;
begin
  with victims as (
    select ticker, date
      from iv_snapshots
     where rnd is not null
       and date < current_date      -- never touch the row being written today
     order by date
     limit p_batch_size
  )
  update iv_snapshots s
     set rnd = null
    from victims v
   where s.ticker = v.ticker
     and s.date   = v.date;

  get diagnostics n = row_count;

  if n = 0 then
    -- Nothing left. Retire the schedule; ignore the error if a concurrent run
    -- already did it, so the last two batches cannot fail each other.
    begin
      perform cron.unschedule('backfill-iv-rnd');
    exception when others then
      null;
    end;
  end if;

  return n;
end;
$$;

select cron.schedule(
  'backfill-iv-rnd',
  '*/5 2-5 * * *',
  $$select backfill_iv_snapshots_rnd(200)$$
);
