-- =============================================================================
-- 051_create_realized_vol_snapshots.sql
-- =============================================================================
-- Creates the realized_vol_snapshots table that migrations 035, 039, 040
-- assume already exists. All columns from subsequent ALTERs are included;
-- those migrations are idempotent (ADD COLUMN IF NOT EXISTS).
-- =============================================================================

CREATE TABLE IF NOT EXISTS realized_vol_snapshots (
    id            uuid             PRIMARY KEY DEFAULT gen_random_uuid(),
    symbol        text             NOT NULL,
    date          date             NOT NULL,
    rv_1d         double precision,
    rv_5d         double precision,
    rv_21d        double precision,
    rv_63d        double precision,
    persisted_at  timestamptz,

    UNIQUE (symbol, date)
);

ALTER TABLE realized_vol_snapshots ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS idx_rv_snapshots_symbol_date
    ON realized_vol_snapshots (symbol, date DESC);
