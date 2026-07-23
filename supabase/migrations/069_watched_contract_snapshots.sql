-- =============================================================================
-- 069_watched_contract_snapshots
-- =============================================================================
-- Daily time series per watched_contracts row -- the pre-entry twin of
-- position_leg_snapshots (043_position_snapshots.sql), written by
-- api/jobs/watched_contract_pull.py. Same shape as position_leg_snapshots
-- (market price, BS/SABR/Heston/model theos, all five Greeks, IV) plus
-- open_interest and total_volume, which position_leg_snapshots didn't
-- capture until 071_position_leg_snapshots_oi_volume.sql added it there too.
--
-- One row per (watch_id, snapshot_date) -- unlike position_leg_snapshots
-- there's no entry/eod/exit distinction here since nothing has been entered
-- yet; every row is just "what this contract looked like that day."
-- =============================================================================

CREATE TABLE watched_contract_snapshots (
    id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    watch_id         UUID        NOT NULL REFERENCES watched_contracts(id) ON DELETE CASCADE,
    snapshot_date    DATE        NOT NULL,
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
    implied_vol      NUMERIC,
    open_interest    NUMERIC,
    total_volume     NUMERIC,
    dte              INTEGER,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_watched_snapshots_watch_id ON watched_contract_snapshots(watch_id);

-- One snapshot per contract per day; the pull job upserts on this.
CREATE UNIQUE INDEX idx_watched_snapshots_watch_date
    ON watched_contract_snapshots(watch_id, snapshot_date);

-- ── RLS (ownership inherited via watched_contracts.user_id) ──────────────────

ALTER TABLE watched_contract_snapshots ENABLE ROW LEVEL SECURITY;

CREATE POLICY "watched_snapshots_select" ON watched_contract_snapshots
    FOR SELECT USING (
        EXISTS (SELECT 1 FROM watched_contracts wc
                WHERE wc.id = watched_contract_snapshots.watch_id
                  AND wc.user_id = auth.uid())
    );
CREATE POLICY "watched_snapshots_insert" ON watched_contract_snapshots
    FOR INSERT WITH CHECK (
        EXISTS (SELECT 1 FROM watched_contracts wc
                WHERE wc.id = watched_contract_snapshots.watch_id
                  AND wc.user_id = auth.uid())
    );
CREATE POLICY "watched_snapshots_update" ON watched_contract_snapshots
    FOR UPDATE USING (
        EXISTS (SELECT 1 FROM watched_contracts wc
                WHERE wc.id = watched_contract_snapshots.watch_id
                  AND wc.user_id = auth.uid())
    );
CREATE POLICY "watched_snapshots_delete" ON watched_contract_snapshots
    FOR DELETE USING (
        EXISTS (SELECT 1 FROM watched_contracts wc
                WHERE wc.id = watched_contract_snapshots.watch_id
                  AND wc.user_id = auth.uid())
    );
