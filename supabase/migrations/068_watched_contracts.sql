-- =============================================================================
-- 068_watched_contracts
-- =============================================================================
-- A "candidate" contract the user wants tracked before they own it — the
-- pre-entry counterpart to positions/position_legs (042_position_model.sql).
-- Deliberately a separate table rather than adding a 'watching' status onto
-- position_legs: position_legs.quantity/entry_price are NOT NULL and the
-- Flutter app + several jobs already assume every leg row is a real,
-- entered trade. Keeping watched contracts in their own table avoids
-- loosening those invariants on a live table just to support a row that
-- isn't a trade yet.
--
-- promoted_leg_id lets a watch graduate into a real position_leg on entry
-- without losing the link back to its pre-entry history.
-- =============================================================================

CREATE TABLE watched_contracts (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    ticker          TEXT        NOT NULL CHECK (trim(ticker) <> ''),
    strike          NUMERIC     NOT NULL,
    expiry          DATE        NOT NULL,
    type            TEXT        NOT NULL CHECK (type IN ('call', 'put')),
    notes           TEXT,
    status          TEXT        NOT NULL DEFAULT 'watching'
                                CHECK (status IN ('watching', 'promoted', 'dropped')),
    promoted_leg_id UUID        REFERENCES position_legs(id) ON DELETE SET NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, ticker, strike, expiry, type)
);

-- Partial index: the daily pull job only ever queries status = 'watching'.
CREATE INDEX idx_watched_contracts_watching
    ON watched_contracts (ticker) WHERE status = 'watching';

-- NOTE: 042_position_model.sql defines its own update_updated_at_column()
-- trigger function and wires it to positions/enriched_legs, but that
-- function does not actually exist in the live database (only a same-named
-- one in the `storage` schema does), and neither does the positions trigger
-- -- the live schema has drifted from that migration file. Using
-- set_updated_at() here instead, which does exist in `public` and is the
-- function actually driving updated_at elsewhere in this database (e.g.
-- iv_snapshots, 067_iv_snapshots_updated_at.sql).
CREATE TRIGGER trg_watched_contracts_updated_at
    BEFORE UPDATE ON watched_contracts
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── RLS ───────────────────────────────────────────────────────────────────────

ALTER TABLE watched_contracts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "watched_contracts_select" ON watched_contracts
    FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "watched_contracts_insert" ON watched_contracts
    FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "watched_contracts_update" ON watched_contracts
    FOR UPDATE USING (auth.uid() = user_id);
CREATE POLICY "watched_contracts_delete" ON watched_contracts
    FOR DELETE USING (auth.uid() = user_id);
