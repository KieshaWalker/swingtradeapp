-- =============================================================================
-- 058_sector_fundamentals
-- =============================================================================
-- Quarterly revenue & capex from SEC EDGAR XBRL for the AI-cycle universes,
-- written by api/jobs/fundamentals_pull.py (weekly poll; filings arrive on
-- their own schedule).
--   supply = semiconductor complex (MU, SNDK, NVDA, ...)
--   demand = hyperscalers (MSFT, GOOGL, AMZN, META, ORCL) whose capex lines
--            are the dollars funding the buildout
-- Values are as-reported (unit recorded; foreign filers may be non-USD).
-- Capex rows marked derived=true were computed by differencing the fiscal
-- year-to-date cash-flow series into discrete quarters.
-- =============================================================================

CREATE TABLE IF NOT EXISTS sector_fundamentals (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    ticker       text NOT NULL,
    cik          text,
    universe     text NOT NULL,             -- 'supply' | 'demand'
    metric       text NOT NULL,             -- 'revenue' | 'capex'
    period_type  text NOT NULL,             -- 'Q' | 'FY'
    period_start date,
    period_end   date NOT NULL,
    fy           integer,
    fp           text,
    value        numeric(18,0) NOT NULL,    -- as reported, in `unit`
    unit         text NOT NULL DEFAULT 'USD',
    tag_used     text,
    form         text,
    filed        date,
    derived      boolean NOT NULL DEFAULT false,
    created_at   timestamptz NOT NULL DEFAULT now(),

    UNIQUE (ticker, metric, period_type, period_end)
);

ALTER TABLE sector_fundamentals ENABLE ROW LEVEL SECURITY;

do $$ begin
  create policy "Authenticated read sector fundamentals"
    on sector_fundamentals for select
    to authenticated
    using (true);
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Anon read sector fundamentals"
    on sector_fundamentals for select
    to anon
    using (true);
exception when duplicate_object then null;
end $$;

CREATE INDEX IF NOT EXISTS idx_sector_fundamentals_lookup
    ON sector_fundamentals (metric, universe, period_end DESC);
CREATE INDEX IF NOT EXISTS idx_sector_fundamentals_ticker
    ON sector_fundamentals (ticker, metric, period_end DESC);
