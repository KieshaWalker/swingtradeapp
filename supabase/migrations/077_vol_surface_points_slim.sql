-- =============================================================================
-- 077_vol_surface_points_slim.sql
-- =============================================================================
-- Disk-IO remediation (Phase 2, item D). Adds a narrow projection of
-- vol_surface_snapshots.points for the app to read, leaving `points` itself
-- untouched as the archival copy.
--
-- `select points from vol_surface_snapshots where id = $1` is the single
-- largest consumer of database time — 8m05s over 266 calls, 40.2% of total,
-- ~1.82s per call. Measured on a real row (AMD 2026-08-20, 949 points x 41
-- keys):
--
--     stored   752.8 KB
--     read     110.1 KB   strike, dte, call/put _iv, _vol, _oi
--     waste    642.7 KB   85.4%
--
-- Only 8 of VolPoint's 44 fields are read by any consumer of VolPoint
-- (vol_smile_chart, vol_skew_delta_grid, vol_heatmap, the parser and the
-- repository). The other 36 — every greek, every pricing field, the bid/ask
-- sizes, the probabilities — are parsed into the model and never touched.
--
-- They are kept anyway: the raw chain data is retained deliberately for future
-- analysis. This migration does not delete a single field. It adds a second,
-- smaller column so the read path stops paying to detoast and serialize the
-- other 85%. A projection RPC over `points` would have shrunk the wire payload
-- but not the database time, since Postgres would still detoast the full blob
-- and then do extra work on top; a separate column is what lets the hot read
-- touch ~110 KB of TOAST instead of ~752 KB.
--
-- Cost is ~74 MB of additional storage against a 507 MB table, and one
-- projection per hourly upsert (~450/day, single-digit ms each).
-- =============================================================================

alter table vol_surface_snapshots add column if not exists points_slim jsonb;
alter table vol_surface_snapshots alter column points_slim set compression lz4;

-- strict: null points in, null points_slim out. `with ordinality` preserves
-- strike/dte ordering, which the smile chart and heatmap both depend on.
create or replace function vol_surface_points_slim(p_points jsonb)
returns jsonb
language sql
immutable
strict
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'strike',   e->'strike',
        'dte',      e->'dte',
        'call_iv',  e->'call_iv',
        'put_iv',   e->'put_iv',
        'call_vol', e->'call_vol',
        'put_vol',  e->'put_vol',
        'call_oi',  e->'call_oi',
        'put_oi',   e->'put_oi'
      )
      order by ord
    ),
    '[]'::jsonb
  )
  from jsonb_array_elements(p_points) with ordinality as t(e, ord);
$$;

create or replace function vol_surface_snapshots_slim_sync()
returns trigger
language plpgsql
as $$
begin
  new.points_slim := vol_surface_points_slim(new.points);
  return new;
end;
$$;

-- `update of points` so the projection is recomputed only when the source
-- actually changes, not on every unrelated column touch.
drop trigger if exists vol_surface_snapshots_slim on vol_surface_snapshots;
create trigger vol_surface_snapshots_slim
  before insert or update of points on vol_surface_snapshots
  for each row
  execute function vol_surface_snapshots_slim_sync();
