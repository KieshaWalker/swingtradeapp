-- =============================================================================
-- 026_regime_ml_models.sql
-- =============================================================================
-- Stores serialized ML models trained by regime_ml_trainer.py.
--
-- Written by the Cloud Run API (service key) via POST /regime/train.
-- Read at startup / after training to warm the in-memory inference cache.
--
-- Columns:
--   model_type  — "logistic" | "xgboost"
--   trained_at  — UTC timestamp of training run
--   n_samples   — total labeled training rows
--   n_positive  — positive-class rows (regime flips)
--   accuracy    — hold-out accuracy (0–1)
--   auc_roc     — hold-out AUC-ROC (0–1)
--   precision   — hold-out precision (0–1)
--   recall      — hold-out recall (0–1)
--   model_json  — full serialized model + scaler params + feature names
-- =============================================================================

create table if not exists regime_ml_models (
  id          bigint      generated always as identity primary key,
  model_type  text        not null,
  trained_at  timestamptz not null default now(),
  n_samples   integer     not null default 0,
  n_positive  integer     not null default 0,
  accuracy    float8      not null default 0,
  auc_roc     float8      not null default 0,
  precision   float8      not null default 0,
  recall      float8      not null default 0,
  model_json  jsonb       not null default '{}'
);

-- load_latest_model fetches the single most-recent row by trained_at desc
create index if not exists regime_ml_models_trained_at_idx
  on regime_ml_models (trained_at desc);

-- Service key bypasses RLS; deny direct client access
alter table regime_ml_models enable row level security;
