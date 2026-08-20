-- =============================================================================
-- 078_backfill_vol_surface_points_slim.sql
-- =============================================================================
-- Disk-IO remediation (Phase 2, item E). Populates points_slim for the ~3,730
-- rows that predate 077's trigger.
--
-- Non-destructive, unlike 076: this only writes a new column. `points` is not
-- touched, so its TOAST entries are reused rather than rewritten — the update
-- writes a new heap tuple plus the small points_slim value and leaves the
-- 752 KB blob where it is. The cost is dead heap tuples, which 066's nightly
-- VACUUM reclaims in the same window.
--
-- Batched and overnight for the same reason as 076 (065's warning about bulk
-- rewrites after an IO-budget incident). Offset two minutes from 076's schedule
-- so the two backfills interleave instead of starting together; 076 retires
-- itself after one night, this one after roughly 38 batches.
--
-- Self-terminating: unschedules itself once no rows are left.
-- =============================================================================

create or replace function backfill_vol_surface_points_slim(p_batch_size integer default 100)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer;
begin
  update vol_surface_snapshots s
     set points_slim = vol_surface_points_slim(s.points)
   where s.id in (
     select id
       from vol_surface_snapshots
      where points_slim is null
        and points is not null
      order by obs_date
      limit p_batch_size
   );

  get diagnostics n = row_count;

  if n = 0 then
    begin
      perform cron.unschedule('backfill-vol-surface-slim');
    exception when others then
      null;
    end;
  end if;

  return n;
end;
$$;

select cron.schedule(
  'backfill-vol-surface-slim',
  '2-59/5 2-5 * * *',
  $$select backfill_vol_surface_points_slim(100)$$
);
