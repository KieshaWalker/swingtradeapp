-- =============================================================================
-- 059_prediction_market_snapshots
-- =============================================================================
-- Daily snapshots of selected Polymarket prediction markets, written by
-- api/jobs/crisis_pull.py alongside the crisis checklist. Real-money forward
-- probabilities for the events the checklist can only measure in arrears:
-- Fed policy path (the tightening catalyst) and data-center regulatory risk
-- (the buildout's 1887-ICC analog). Event slugs are configured in the job.
-- =============================================================================

CREATE TABLE IF NOT EXISTS prediction_market_snapshots (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    obs_date        date NOT NULL,
    event_slug      text NOT NULL,
    event_title     text,
    question        text NOT NULL,
    yes_probability numeric(6,4),          -- price of the YES outcome, 0..1
    volume_usd      numeric(14,0),
    closed          boolean NOT NULL DEFAULT false,
    created_at      timestamptz NOT NULL DEFAULT now(),

    UNIQUE (obs_date, event_slug, question)
);

ALTER TABLE prediction_market_snapshots ENABLE ROW LEVEL SECURITY;

do $$ begin
  create policy "Authenticated read prediction markets"
    on prediction_market_snapshots for select
    to authenticated
    using (true);
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Anon read prediction markets"
    on prediction_market_snapshots for select
    to anon
    using (true);
exception when duplicate_object then null;
end $$;

CREATE INDEX IF NOT EXISTS idx_prediction_markets_lookup
    ON prediction_market_snapshots (event_slug, obs_date DESC);
