-- =============================================================================
-- 012_blotter_trades.sql
-- =============================================================================
-- Institutional trade blotter — staging area for options orders.
-- Lifecycle: draft → validated → committed → sent
-- One row per staged trade. Greeks, fair-value, and portfolio impact
-- are written at validation time; timestamps mark each lifecycle transition.
-- =============================================================================

create table if not exists blotter_trades (
  id                      uuid          default gen_random_uuid() primary key,

  -- ── Contract identity ────────────────────────────────────────────────────
  symbol                  text          not null,
  strike                  numeric(10,2) not null,
  expiration              date          not null,
  contract_type           text          not null check (contract_type in ('call','put')),
  quantity                int           not null,           -- positive = long, negative = short
  strategy_tag            text,
  notes                   text,

  -- ── Pricing (filled at validation) ──────────────────────────────────────
  broker_mid              numeric(10,4),
  bs_fair_value           numeric(10,4),
  sabr_fair_value         numeric(10,4),
  model_fair_value        numeric(10,4),
  edge_bps                numeric(8,2),
  implied_vol             numeric(8,4),
  sabr_vol                numeric(8,4),

  -- ── Greeks per-contract (from Schwab, filled at validation) ─────────────
  delta                   numeric(8,4),
  gamma                   numeric(8,6),
  theta                   numeric(8,4),
  vega                    numeric(8,4),
  rho                     numeric(8,4),
  vanna                   numeric(8,6),
  charm                   numeric(8,6),
  volga                   numeric(8,6),
  underlying_price        numeric(10,2),

  -- ── Portfolio impact snapshot (filled at validation) ────────────────────
  portfolio_delta_before  numeric(10,2),
  portfolio_delta_after   numeric(10,2),
  portfolio_vega_before   numeric(10,2),
  portfolio_vega_after    numeric(10,2),
  es95_before             numeric(12,2),
  es95_after              numeric(12,2),

  -- ── Lifecycle ────────────────────────────────────────────────────────────
  status                  text          not null default 'draft'
                          check (status in ('draft','validated','committed','sent')),
  validated_at            timestamptz,
  committed_at            timestamptz,
  sent_at                 timestamptz,
  created_at              timestamptz   not null default now(),
  updated_at              timestamptz   not null default now()
);

-- Indexes
create index if not exists blotter_status_created
  on blotter_trades (status, created_at desc);

create index if not exists blotter_symbol_status
  on blotter_trades (symbol, status, created_at desc);

-- RLS
alter table blotter_trades enable row level security;

create policy "authenticated can manage blotter"
  on blotter_trades for all
  to authenticated
  using (true) with check (true);
