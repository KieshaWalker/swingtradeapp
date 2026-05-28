-- Bootstrap guard: create the base table if it doesn't exist yet so that the
-- ALTER TABLE below succeeds on a fresh deploy. All columns are added
-- idempotently by this and subsequent migrations (025, 046, 050).
CREATE TABLE IF NOT EXISTS regime_snapshots (
    id        uuid  PRIMARY KEY DEFAULT gen_random_uuid(),
    ticker    text  NOT NULL,
    obs_date  date  NOT NULL,
    UNIQUE (ticker, obs_date)
);

alter table regime_snapshots
    add column if not exists vol_sma3 float,
    add column if not exists vol_sma20 float;

    
