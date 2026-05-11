-- =============================================================================
-- 043_position_snapshots.sql
-- Adds entry/exit tracking to position_legs and a snapshot table for
-- capturing Greeks at entry, daily EOD, and close.
-- =============================================================================

-- ── position_legs additions ───────────────────────────────────────────────────

ALTER TABLE position_legs
    ADD COLUMN entry_price NUMERIC,
    ADD COLUMN exit_price  NUMERIC,
    ADD COLUMN status      TEXT        NOT NULL DEFAULT 'open'
                           CHECK (status IN ('open', 'closed')),
    ADD COLUMN opened_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ADD COLUMN closed_at   TIMESTAMPTZ;

-- ── position_leg_snapshots ────────────────────────────────────────────────────
-- One row per (leg, date, type).  snapshot_type:
--   'entry' — captured when the user enters the position
--   'eod'   — captured by Cloud Scheduler at market close each day
--   'exit'  — captured when the user closes the leg

CREATE TABLE position_leg_snapshots (
    id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    leg_id           UUID        NOT NULL REFERENCES position_legs(id) ON DELETE CASCADE,
    snapshot_date    DATE        NOT NULL,
    snapshot_type    TEXT        NOT NULL CHECK (snapshot_type IN ('entry', 'eod', 'exit')),
    underlying_price NUMERIC,
    market_price     NUMERIC,
    bs_theo          NUMERIC,
    sabr_theo        NUMERIC,
    heston_theo      NUMERIC,
    model_theo       NUMERIC,
    delta            NUMERIC,
    gamma            NUMERIC,
    theta            NUMERIC,
    vega             NUMERIC,
    rho              NUMERIC,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_snapshots_leg_id ON position_leg_snapshots(leg_id);

-- Prevent duplicate snapshots for the same leg/date/type
CREATE UNIQUE INDEX idx_snapshots_leg_date_type
    ON position_leg_snapshots(leg_id, snapshot_date, snapshot_type);

-- ── RLS ───────────────────────────────────────────────────────────────────────

ALTER TABLE position_leg_snapshots ENABLE ROW LEVEL SECURITY;

CREATE POLICY "snapshots_select" ON position_leg_snapshots
    FOR SELECT USING (
        EXISTS (SELECT 1 FROM position_legs pl
                JOIN positions p ON p.id = pl.position_id
                WHERE pl.id = position_leg_snapshots.leg_id
                  AND p.user_id = auth.uid())
    );

CREATE POLICY "snapshots_insert" ON position_leg_snapshots
    FOR INSERT WITH CHECK (
        EXISTS (SELECT 1 FROM position_legs pl
                JOIN positions p ON p.id = pl.position_id
                WHERE pl.id = position_leg_snapshots.leg_id
                  AND p.user_id = auth.uid())
    );

CREATE POLICY "snapshots_update" ON position_leg_snapshots
    FOR UPDATE USING (
        EXISTS (SELECT 1 FROM position_legs pl
                JOIN positions p ON p.id = pl.position_id
                WHERE pl.id = position_leg_snapshots.leg_id
                  AND p.user_id = auth.uid())
    );

CREATE POLICY "snapshots_delete" ON position_leg_snapshots
    FOR DELETE USING (
        EXISTS (SELECT 1 FROM position_legs pl
                JOIN positions p ON p.id = pl.position_id
                WHERE pl.id = position_leg_snapshots.leg_id
                  AND p.user_id = auth.uid())
    );
