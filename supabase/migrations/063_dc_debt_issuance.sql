-- =============================================================================
-- 063_dc_debt_issuance  (WS4 — manual-first)
-- =============================================================================
-- Data-center debt deals logged from public sources (rating-agency presales,
-- REIT prospectuses, EMMA official statements). The metric that matters is
-- trailing-4-quarter issuance pace — this cycle's miles-of-track-per-year.
-- User-entered (per-user RLS like macro_indicators); quarterly research ritual.
-- =============================================================================

CREATE TABLE IF NOT EXISTS dc_debt_issuance (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    deal_date   date NOT NULL,
    sponsor     text NOT NULL,
    deal_name   text,
    size_mm     numeric(12,1) NOT NULL,   -- USD millions
    deal_type   text NOT NULL CHECK (deal_type IN ('abs','reit_bond','muni','private_reported','other')),
    agency      text,                      -- KBRA / Fitch / Moody's / S&P
    source_url  text,
    notes       text,
    created_at  timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE dc_debt_issuance ENABLE ROW LEVEL SECURITY;

do $$ begin
  create policy "Users manage own dc issuance rows"
    on dc_debt_issuance
    using  (user_id = auth.uid())
    with check (user_id = auth.uid());
exception when duplicate_object then null;
end $$;

CREATE INDEX IF NOT EXISTS idx_dc_issuance_date
    ON dc_debt_issuance (user_id, deal_date DESC);
