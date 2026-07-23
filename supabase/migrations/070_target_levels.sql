-- =============================================================================
-- 070_target_levels
-- =============================================================================
-- User-entered price levels (support/resistance/all-time-high/custom) to
-- watch a ticker against. source='system' is reserved for levels the app
-- derives itself later (zero-gamma flip, GEX/OI walls from iv_snapshots) --
-- written by a future job rather than this migration, so they stay
-- self-updating instead of going stale like a user-entered price would.
-- =============================================================================

CREATE TABLE target_levels (
    id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    ticker     TEXT        NOT NULL CHECK (trim(ticker) <> ''),
    price      NUMERIC     NOT NULL,
    label      TEXT        NOT NULL,
    source     TEXT        NOT NULL DEFAULT 'user' CHECK (source IN ('user', 'system')),
    active     BOOLEAN     NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_target_levels_ticker ON target_levels (ticker) WHERE active;

ALTER TABLE target_levels ENABLE ROW LEVEL SECURITY;

CREATE POLICY "target_levels_select" ON target_levels
    FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "target_levels_insert" ON target_levels
    FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "target_levels_update" ON target_levels
    FOR UPDATE USING (auth.uid() = user_id);
CREATE POLICY "target_levels_delete" ON target_levels
    FOR DELETE USING (auth.uid() = user_id);
