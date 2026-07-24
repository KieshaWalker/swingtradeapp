-- =============================================================================
-- 073_focus_ticker_digest
-- =============================================================================
-- One row per (ticker, obs_date) for the small hand-picked focus list
-- (jobs/focus_digest_pull.py's _FOCUS_TICKERS), assembled daily from tables
-- that already exist -- this table adds no new signal, it just answers "how
-- did today look across the names I actually trade" in one query instead of
-- five.
--
-- iv_* / gamma_regime / skew* columns are a same-day copy of that ticker's
-- iv_snapshots row (kept denormalized here so a digest row is a frozen
-- point-in-time read even if iv_snapshots gets revised intraday -- see the
-- earlier finding this session that iv_snapshots values shift as the job
-- reruns during the day).
--
-- contracts is every open position_leg AND every 'watching' watched_contract
-- on this ticker, each run through services.contract_opportunity.
-- evaluate_contract() against its own snapshot history: [{source: "position"
-- | "watch", id, strike, expiry, type, opportunity_score, grade,
-- iv_percentile, edge_percentile, insufficient_history}].
--
-- No RLS, matching iv_snapshots' own precedent (011_iv_snapshots.sql):
-- shared read/write for authenticated users, not owner-scoped -- the
-- contracts array summarizes user-owned rows, but the digest row itself is
-- a derived read-only artifact, not the source of truth for ownership.
-- =============================================================================

CREATE TABLE focus_ticker_digest (
    id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    obs_date          DATE        NOT NULL,
    ticker            TEXT        NOT NULL,
    underlying_price  NUMERIC,
    iv_rank           NUMERIC,
    iv_percentile     NUMERIC,
    iv_rating         TEXT,
    gamma_regime      TEXT,
    zero_gamma_level  NUMERIC,
    max_gex_strike    NUMERIC,
    put_call_ratio    NUMERIC,
    skew              NUMERIC,
    skew_z_score      NUMERIC,
    contracts         JSONB       NOT NULL DEFAULT '[]'::jsonb,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (ticker, obs_date)
);

CREATE INDEX idx_focus_digest_date ON focus_ticker_digest (obs_date DESC);

ALTER TABLE focus_ticker_digest ENABLE ROW LEVEL SECURITY;

CREATE POLICY "authenticated can read focus_ticker_digest"
    ON focus_ticker_digest FOR SELECT
    TO authenticated USING (true);
CREATE POLICY "authenticated can upsert focus_ticker_digest"
    ON focus_ticker_digest FOR INSERT
    TO authenticated WITH CHECK (true);
CREATE POLICY "authenticated can update focus_ticker_digest"
    ON focus_ticker_digest FOR UPDATE
    TO authenticated USING (true);
