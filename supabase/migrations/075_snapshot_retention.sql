-- =============================================================================
-- 075_snapshot_retention.sql
-- =============================================================================
-- Disk-IO remediation (Phase 2, item B). Neither of the two tables that make up
-- ~96% of this database has ever had a retention policy:
--
--     vol_surface_snapshots   421 KB/row x 3,680 rows  ~= 1,478 MB
--     iv_snapshots            335 KB/row x 2,507 rows  ~=   800 MB
--     all 48 other tables combined                     ~=   102 MB
--
-- Both grow at 50 rows/day forever. greek_grid_snapshots got
-- purge_expired_greek_grid() back in 022; these two never got an equivalent.
--
-- ── Choosing the windows ────────────────────────────────────────────────────
-- iv_snapshots is NOT free to trim. IvStorageService.getHistory() pulls 252
-- rows for IVR/IVP and IV_WINDOW_26W needs 130, so anything under ~252 trading
-- days silently degrades the IV rank that most of the app keys off. 400 days
-- leaves that window intact with room to spare. The table currently holds ~57
-- trading days, so this deletes nothing today — it is a growth guard, not a
-- purge.
--
-- vol_surface_snapshots is where the reclaimable space actually is. sabr_pull
-- and heston_pull both read only `.eq("obs_date", today)`, so nothing in the
-- backend needs history at all. The constraint is the app: VolSurfaceRepository
-- .loadAll() pages the whole table so every stored (ticker, obs_date) is
-- browsable in the Vol Surface screen. 180 days is deliberately conservative —
-- data starts 2026-04-13, so this also deletes nothing today.
--
-- Tightening vol_surface to 90 or 60 days is where real space comes back, and
-- that is a product call about how far back the surface stays browsable, not a
-- technical one. Change P_VOL_SURFACE_DAYS below when you have decided.
-- =============================================================================

create or replace function purge_old_snapshots(
  p_vol_surface_days integer default 180,
  p_iv_days          integer default 400
)
returns table (table_name text, deleted integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  n_vs integer;
  n_iv integer;
begin
  -- Guard rail first, before any deletion: never let a mistyped argument cut
  -- into the 252-row IVR window. The RAISE would roll the whole call back
  -- either way, but validating up front keeps the failure honest.
  if p_iv_days < 300 then
    raise exception
      'p_iv_days=% would break the 252-day IVR/IVP window (need >= 300)', p_iv_days;
  end if;

  delete from vol_surface_snapshots
   where obs_date < current_date - p_vol_surface_days;
  get diagnostics n_vs = row_count;

  delete from iv_snapshots
   where date < current_date - p_iv_days;
  get diagnostics n_iv = row_count;

  return query
    select 'vol_surface_snapshots'::text, n_vs
    union all
    select 'iv_snapshots'::text, n_iv;
end;
$$;

-- 02:40 UTC — inside the same overnight window 066 uses for its VACUUMs, and
-- ahead of them at 03:00/03:05 so the night's deletions get vacuumed the same
-- night rather than sitting as dead tuples until the next one.
select cron.schedule(
  'purge-old-snapshots-nightly',
  '40 2 * * *',
  $$select purge_old_snapshots()$$
);
