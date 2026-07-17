-- =============================================================================
-- 060_prediction_market_alerts
-- =============================================================================
-- User-defined alerts on tracked Polymarket markets. Evaluated by
-- api/jobs/crisis_pull.py after each daily snapshot (service key bypasses
-- RLS): when the YES probability crosses the threshold in the chosen
-- direction, triggered_at/triggered_probability are stamped and the app
-- surfaces the alert. One-shot: triggered alerts stay triggered until the
-- user deletes or re-arms them.
-- =============================================================================

CREATE TABLE IF NOT EXISTS prediction_market_alerts (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id               uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    event_slug            text NOT NULL,
    question              text NOT NULL,
    direction             text NOT NULL CHECK (direction IN ('above', 'below')),
    threshold             numeric(6,4) NOT NULL CHECK (threshold >= 0 AND threshold <= 1),
    active                boolean NOT NULL DEFAULT true,
    triggered_at          timestamptz,
    triggered_probability numeric(6,4),
    created_at            timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE prediction_market_alerts ENABLE ROW LEVEL SECURITY;

do $$ begin
  create policy "Users manage own prediction alerts"
    on prediction_market_alerts
    using  (user_id = auth.uid())
    with check (user_id = auth.uid());
exception when duplicate_object then null;
end $$;

CREATE INDEX IF NOT EXISTS idx_prediction_alerts_active
    ON prediction_market_alerts (active, triggered_at)
    WHERE active AND triggered_at IS NULL;
