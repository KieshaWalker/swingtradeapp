-- =============================================================================
-- 067_iv_snapshots_updated_at.sql
-- =============================================================================
-- Disk-IO remediation (Phase 1, item D). iv_snapshots is a shared/global table
-- (no user_id) written by the hourly iv_pull cron AND by POST /iv/snapshot
-- every time any user opens a ticker's chain — concurrent users on a popular
-- ticker each trigger a full rewrite of the same row. This column backs a
-- staleness guard in api/routers/iv_analytics.py that skips redundant
-- user-triggered rewrites within a short window.
--
-- default now() covers the first INSERT of the day; the trigger covers every
-- subsequent UPDATE from any writer, so updated_at always reflects "last
-- touched" without other write paths needing changes. Reuses the existing
-- generic set_updated_at() trigger function (001_initial_schema.sql).
-- =============================================================================

alter table iv_snapshots
  add column if not exists updated_at timestamptz not null default now();

create trigger iv_snapshots_updated_at
  before update on iv_snapshots
  for each row execute function set_updated_at();
