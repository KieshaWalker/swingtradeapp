-- =============================================================================
-- 057_crisis_checklist_snapshots
-- =============================================================================
-- Daily market-level crisis-signal checklist, written by api/jobs/crisis_pull.py.
-- One global row per obs_date (not per-user, like regime_snapshots).
--
-- Each signal is scored 'clean' | 'partial' | 'firing' against thresholds
-- calibrated on 13 historical crises (1873-2022); the raw readings are stored
-- so the Flutter economy screen can chart the series and render "now vs prior
-- bubbles" comparisons. Historical bubble benchmark values are constants in
-- the Flutter layer (they never change), not rows here.
-- =============================================================================

CREATE TABLE IF NOT EXISTS crisis_checklist_snapshots (
    id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    obs_date                    date NOT NULL,

    -- index posture
    spy_close                   numeric(12,2),
    spy_off_ath_pct             numeric(8,2),
    spy_days_since_ath          integer,

    -- valuation / leverage (monthly-cadence sources; carried forward, nullable)
    cape                        numeric(8,2),
    margin_debt_bn              numeric(12,1),
    margin_debt_yoy_pct         numeric(8,1),

    -- rates / inflation
    fed_funds_pct               numeric(6,2),
    fed_funds_90d_chg_bps       numeric(8,1),
    t10y2y_bps                  numeric(8,1),
    cpi_yoy_pct                 numeric(6,2),
    cpi_core_yoy_pct            numeric(6,2),

    -- public credit
    hy_oas_bps                  numeric(8,1),
    ig_oas_bps                  numeric(8,1),
    hy_oas_20d_chg_bps          numeric(8,1),

    -- breadth (traded proxies)
    rsp_spy_ratio               numeric(10,6),
    rsp_spy_off_high_pct        numeric(8,2),
    iwm_spy_ratio               numeric(10,6),
    iwm_spy_off_high_pct        numeric(8,2),

    -- private credit (BDC + manager composites, equal-weight indexed)
    bdc_off_high_pct            numeric(8,2),
    bdc_20d_pct                 numeric(8,2),
    mgr_off_high_pct            numeric(8,2),
    mgr_20d_pct                 numeric(8,2),

    -- speculative tier (configured basket, currently the memory pair)
    spec_off_high_pct           numeric(8,2),

    -- verdicts: 'clean' | 'partial' | 'firing' | 'unknown'
    v_index_ath                 text,
    v_valuation                 text,
    v_leverage                  text,
    v_spec_tier                 text,
    v_fed                       text,
    v_curve                     text,
    v_public_credit             text,
    v_private_credit            text,
    v_breadth                   text,

    -- composites (derived server-side for convenience; UI may re-derive)
    structural_lit              smallint,
    catalysts_firing            smallint,

    -- detail payload for the UI (per-signal notes, component values)
    signals                     jsonb,

    is_final                    boolean NOT NULL DEFAULT false,
    created_at                  timestamptz NOT NULL DEFAULT now(),

    UNIQUE (obs_date)
);

ALTER TABLE crisis_checklist_snapshots ENABLE ROW LEVEL SECURITY;

-- Job writes with the service key (bypasses RLS); clients are read-only.
do $$ begin
  create policy "Authenticated read crisis checklist"
    on crisis_checklist_snapshots for select
    to authenticated
    using (true);
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Anon read crisis checklist"
    on crisis_checklist_snapshots for select
    to anon
    using (true);
exception when duplicate_object then null;
end $$;

CREATE INDEX IF NOT EXISTS idx_crisis_checklist_obs_date
    ON crisis_checklist_snapshots (obs_date DESC);
