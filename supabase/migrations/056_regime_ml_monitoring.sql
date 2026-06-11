-- =============================================================================
-- 056_regime_ml_monitoring.sql
-- =============================================================================
-- ML monitoring infrastructure for the regime flip model:
--
-- 1. regime_snapshots.is_final — point-in-time discipline. The hourly
--    regime_pull upserts on (ticker, obs_date), so intraday runs overwrite the
--    same row. Only the 4 PM ET close-capture run marks the row final; training
--    and supervised inference use final rows only, eliminating the
--    train (EOD snapshots) / serve (partial-day snapshots) mismatch.
--    Default TRUE so all pre-existing rows (last write of their day = EOD)
--    remain usable as training data.
--
-- 2. regime_ml_predictions — one logged prediction per ticker per day, written
--    by the close-capture regime_pull run. realized_flip is back-filled by
--    reconciliation once the 5-obs outcome window has closed.
--
-- 3. regime_ml_live_metrics — rolling out-of-sample performance computed from
--    reconciled predictions (live AUC, hit rate, base rate, Brier score).
--    One row per reconciliation run that resolved new predictions.
-- =============================================================================

ALTER TABLE regime_snapshots
    ADD COLUMN IF NOT EXISTS is_final boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN regime_snapshots.is_final IS
    'TRUE when written by the 4 PM ET close-capture run. Training and supervised inference use final rows only.';

CREATE TABLE IF NOT EXISTS regime_ml_predictions (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    ticker           text        NOT NULL,
    obs_date         date        NOT NULL,
    current_regime   text        NOT NULL,  -- regime at prediction time ("positive" | "negative")
    flip_prob        numeric(6,4) NOT NULL, -- P(regime flips within next 5 final obs)
    ml_score         numeric(6,4) NOT NULL,
    bucket           text        NOT NULL,
    scoring_method   text        NOT NULL,  -- "supervised_logistic" | "supervised_xgboost" | "heuristic"
    model_trained_at timestamptz,           -- which model made the prediction (NULL = heuristic)
    realized_flip    boolean,               -- set by reconciliation; NULL = window still open
    reconciled_at    timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now(),

    UNIQUE (ticker, obs_date)
);

ALTER TABLE regime_ml_predictions ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS idx_regime_ml_predictions_pending
    ON regime_ml_predictions (obs_date)
    WHERE reconciled_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_regime_ml_predictions_ticker_date
    ON regime_ml_predictions (ticker, obs_date DESC);

CREATE TABLE IF NOT EXISTS regime_ml_live_metrics (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    computed_at   timestamptz NOT NULL DEFAULT now(),
    window_days   int         NOT NULL,    -- rolling window the metrics cover
    n_predictions int         NOT NULL,    -- reconciled predictions in window
    n_flips       int         NOT NULL,    -- realized flips in window
    live_auc      numeric(6,4),            -- NULL when only one class realized
    hit_rate      numeric(6,4),            -- accuracy of (flip_prob >= 0.5)
    base_rate     numeric(6,4),            -- realized flip frequency
    brier         numeric(6,4),            -- mean (flip_prob - realized)^2
    by_method     jsonb,                   -- per-scoring_method breakdown
    reliability   jsonb                    -- calibration bins: predicted vs realized
);

ALTER TABLE regime_ml_live_metrics ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS idx_regime_ml_live_metrics_computed
    ON regime_ml_live_metrics (computed_at DESC);
