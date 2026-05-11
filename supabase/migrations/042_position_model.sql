-- =============================================================================
-- 042_position_model.sql
-- User-defined positions and their legs.
-- enriched_legs is reserved for future caching of live Greek snapshots.
-- =============================================================================

CREATE TYPE leg_type AS ENUM ('call', 'put', 'underlying');

-- ── Core tables ───────────────────────────────────────────────────────────────

CREATE TABLE positions (
    id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    name       TEXT        NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE position_legs (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    position_id UUID        NOT NULL REFERENCES positions(id) ON DELETE CASCADE,
    type        leg_type    NOT NULL,
    ticker      TEXT        NOT NULL CHECK (trim(ticker) <> ''),
    strike      NUMERIC,
    expiry      DATE,
    quantity    INTEGER     NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_position_legs_position_id ON position_legs(position_id);

-- Optional: persist live Greek/price snapshots per leg
CREATE TABLE enriched_legs (
    leg_id          UUID    PRIMARY KEY REFERENCES position_legs(id) ON DELETE CASCADE,
    market_price    NUMERIC,
    bs_theo         NUMERIC,
    sabr_theo       NUMERIC,
    heston_theo     NUMERIC,
    model_theo      NUMERIC,
    contract_delta  NUMERIC,
    contract_gamma  NUMERIC,
    contract_theta  NUMERIC,
    contract_vega   NUMERIC,
    contract_rho    NUMERIC,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── updated_at trigger ────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_positions_updated_at
    BEFORE UPDATE ON positions
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER trg_enriched_legs_updated_at
    BEFORE UPDATE ON enriched_legs
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ── Row-level security ────────────────────────────────────────────────────────

ALTER TABLE positions    ENABLE ROW LEVEL SECURITY;
ALTER TABLE position_legs ENABLE ROW LEVEL SECURITY;
ALTER TABLE enriched_legs ENABLE ROW LEVEL SECURITY;

-- positions: full CRUD scoped to owner
CREATE POLICY "positions_select" ON positions
    FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "positions_insert" ON positions
    FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "positions_update" ON positions
    FOR UPDATE USING (auth.uid() = user_id);
CREATE POLICY "positions_delete" ON positions
    FOR DELETE USING (auth.uid() = user_id);

-- position_legs: inherit ownership via position_id
CREATE POLICY "position_legs_select" ON position_legs
    FOR SELECT USING (
        EXISTS (SELECT 1 FROM positions
                WHERE positions.id = position_legs.position_id
                  AND positions.user_id = auth.uid())
    );
CREATE POLICY "position_legs_insert" ON position_legs
    FOR INSERT WITH CHECK (
        EXISTS (SELECT 1 FROM positions
                WHERE positions.id = position_legs.position_id
                  AND positions.user_id = auth.uid())
    );
CREATE POLICY "position_legs_update" ON position_legs
    FOR UPDATE USING (
        EXISTS (SELECT 1 FROM positions
                WHERE positions.id = position_legs.position_id
                  AND positions.user_id = auth.uid())
    );
CREATE POLICY "position_legs_delete" ON position_legs
    FOR DELETE USING (
        EXISTS (SELECT 1 FROM positions
                WHERE positions.id = position_legs.position_id
                  AND positions.user_id = auth.uid())
    );

-- enriched_legs: inherit ownership via leg → position chain
CREATE POLICY "enriched_legs_select" ON enriched_legs
    FOR SELECT USING (
        EXISTS (SELECT 1 FROM position_legs pl
                JOIN positions p ON p.id = pl.position_id
                WHERE pl.id = enriched_legs.leg_id
                  AND p.user_id = auth.uid())
    );
CREATE POLICY "enriched_legs_insert" ON enriched_legs
    FOR INSERT WITH CHECK (
        EXISTS (SELECT 1 FROM position_legs pl
                JOIN positions p ON p.id = pl.position_id
                WHERE pl.id = enriched_legs.leg_id
                  AND p.user_id = auth.uid())
    );
CREATE POLICY "enriched_legs_update" ON enriched_legs
    FOR UPDATE USING (
        EXISTS (SELECT 1 FROM position_legs pl
                JOIN positions p ON p.id = pl.position_id
                WHERE pl.id = enriched_legs.leg_id
                  AND p.user_id = auth.uid())
    );
