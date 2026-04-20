# Swing Options Trader — Institutional-Grade Volatility Workstation

A quantitative options trading platform purpose-built for swing-horizon (multi-day to multi-week) equity options. The system synthesizes macro regime analysis, multi-model options pricing, dealer Greek exposure, and binary event risk into a single gated decision workflow — delivering the analytical depth of a proprietary volatility desk without the latency requirements of a high-frequency operation.

**Stack:** Flutter (mobile/desktop) · Python (Cloud Run) · Schwab API · Supabase (PostgreSQL + Edge Functions) · FMP · FRED/BLS/BEA/EIA · Kalshi

---

## Architecture: 5-Phase Gate System

Every trade must pass all five phases before the "Commit Trade" action is unlocked. Each phase is independently scored (PASS / WARN / FAIL) and surfaced in a blotter-style UI.

### Phase 1 — Economic (Macro Regime Gate)

*"Is the macro environment aligned with my directional bias?"*

**Data Sources:** FRED (VIX, yield curve, Fed funds), BLS (U3/U6, CPI, PPI, JOLTS), BEA (GDP, PCE, corporate profits), EIA (crude inventory, refinery utilization), Census (retail sales), Kalshi (macro event probabilities)

**Signals:**
- Composite macro score (0–100) across 7 data feeds with regime classification: Risk-On (86–100), Neutral-Bullish (71–85), Neutral (45–70), Caution (30–44), Crisis (0–29)
- VIX regime label: below 15 (buy premium) → above 30 (sell premium, defined-risk only)
- Yield curve (2s10s spread) for recession signal
- **Sector-specific overlays** keyed to ticker: oil inventory vs 5-year average for energy names; HY spreads for tech/mega-cap; Fed trajectory for rate-sensitive financials; employment + retail for consumer names

**Pass/Warn/Fail:**
| Result | Condition |
|--------|-----------|
| PASS | Macro score ≥ 55, regime ≠ crisis, sector overlay aligns with direction |
| WARN | Macro score 35–54, or regime = caution, or sector mixed |
| FAIL | Macro score < 35, regime = crisis, or sector directly contradicts direction |

---

### Phase 2 — Formula (Contract Quality Gate)

*"Is the contract itself well-structured, and what is the expected return?"*

**Composite Score (0–100)** across six components:

| Component | Weight | Optimal Zone |
|-----------|--------|--------------|
| Delta quality | 0–20 pts | `\|δ\|` ≈ 0.40 (leverage/probability balance) |
| DTE zone | 0–20 pts | 21–45 days (theta manageable, runway available) |
| Spread quality | 0–10 pts | Bid-ask < 5% of mid |
| IV score | 0–20 pts | IVP-weighted: cheap IV scores high for buyers |
| Liquidity | 0–15 pts | OI ≥ 1,000 + volume/OI turnover ratio |
| Moneyness | 0–15 pts | OTM 1–7% (directional sweet spot) |

**Regime multipliers applied post-scoring:**
- GEX multiplier (0.50–1.20): negative gamma regime → 0.50 + hard REGIME FAIL flag; deep positive gamma → 1.20
- Vanna multiplier (0.60–1.00): vanna divergence (falling gamma slope + bearish vanna) → 0.60, flags fragile rally

**Formula checks:** R:R ≥ 30% (PASS threshold), pricing edge vs theoretical value, daily theta drag as % of entry cost, unusual activity flag (vol/OI > 0.5)

**Grade mapping:** A (≥ 75) · B (≥ 55) · C (≥ 35) · D (< 35)

---

### Phase 3 — Blotter (Pricing & Portfolio Risk Gate)

*"What is this contract actually worth? Are you getting an edge? How much tail risk does this add?"*

**Three-Layer Pricing Stack:**

```
Layer 1: Black-Scholes baseline
         F = S · exp(r·T),  r = 4.33% (SOFR)
         Call = e^{-rT} [F·N(d₁) - K·N(d₂)]

Layer 2: SABR smile adjustment  (Hagan et al. 2002)
         β = 0.5 (equity CEV convention)
         ρ, ν drawn from daily surface calibration (not hardcoded)
         Captures put skew premium and OTM call discount

Layer 3: Heston first-order stochastic vol correction
         ΔV_H ≈ ρ_H·ξ·V_vanna·(1-e^{-κT})/κ  +  (ξ²/2)·V_vomma·(1-e^{-2κT})/(2κ)
         κ = 2.0  ξ = 0.50  ρ_H = -0.70

Edge (bps) = (ModelFairValue − BrokerMid) / BrokerMid × 10,000
```

**Second-order Greeks surfaced to trader:**
- **Vanna** (∂²V/∂S∂σ = −φ(d₁)·d₂/σ): delta erosion per 1% IV move — quantifies "vol crush double pain" on long calls
- **Charm** (∂Δ/∂t): daily delta decay from time alone, most dangerous 7–21 DTE
- **Volga/Vomma** (vega·d₁·d₂/σ): vega convexity; positive = benefits from large IV moves

**Expected Shortfall at 95% Confidence (ES₉₅):**
```
ES₉₅ = |Δ| · S · σ · √T · 2.063          (delta tail component)
      + ½ · |Γ| · S² · σ² · T · 1.500    (gamma convexity component)
```

| ES₉₅ | Risk Level | Action |
|------|-----------|--------|
| < $100 | Low | Full size |
| $100–$300 | Moderate | Check portfolio total |
| $300–$700 | Elevated | Reduce size or hedge |
| > $700 | High | Size down significantly |

**Portfolio delta hard gate:** `|Portfolio Δ|` > $500 blocks trade commit regardless of other scores.

**Pass/Warn/Fail:**
| Result | Condition |
|--------|-----------|
| PASS | Edge > +5 bps, ES₉₅ < $500, delta within threshold |
| WARN | Edge 0 to +5 bps, or ES₉₅ $300–$500, or delta at 80% of limit |
| FAIL | Negative edge, or portfolio delta > $500, or ES₉₅ > $700 |

---

### Phase 4 — Volatility Surface (IV Smile & Term Structure Gate)

*"Where do I stand in the IV surface? Are earnings inside my hold window?"*

**Five auto-interpreted signals:**
1. **IV level** — exact strike/DTE cell percentile within the full surface range
2. **Term structure** — near vs far ATM IV: contango (normal), flat, or backwardation (classic post-earnings IV crush setup)
3. **Smile skew** — OTM put/call IV ratio at target DTE + direction alignment check
4. **Earnings calendar** — next earnings scanned against hold window; earnings inside DTE + backwardation = FAIL (IV crush confirmation)
5. **Calendar spread shape** — 3-point term structure classification for roll strategies

---

### Phase 5 — Kalshi Event Risk (Binary Catalyst Gate)

*"Are there major binary catalysts inside my hold window?"*

**Three-tier event filter:**
- **Tier 1 (ticker-specific):** Searches event titles for stock name/ticker — earnings, CEO changes, product launches → always WARN
- **Tier 2 (macro events inside DTE):** FOMC, CPI, NFP, GDP, and other macro binary events closing before option expiry → FAIL if ≥ 65% YES probability or multiple events ≥ 50%
- **Tier 3 (catch-all):** All remaining open events shown as context

---

## Quantitative Model Inventory

| Model | File | Status | Formula / Approach |
|-------|------|--------|-------------------|
| **Black-Scholes pricing** | `black_scholes.py:37` | Production | Forward-form: `e^{-rT}[F·N(d₁) - K·N(d₂)]` |
| **Delta** (∂V/∂S) | `black_scholes.py:52` | Production | `e^{-rT}·N(d₁)` (call), `e^{-rT}·[N(d₁)-1]` (put) |
| **Gamma** (∂²V/∂S²) | `black_scholes.py:63` | Production | `e^{-rT}·φ(d₁) / (F·σ√T)` |
| **Vega** (∂V/∂σ) | `black_scholes.py:74` | Production | `F·e^{-rT}·φ(d₁)·√T` |
| **Theta** (∂V/∂t) | `black_scholes.py:85` | Production | Daily decay, annualized ÷ 365 |
| **Rho** (∂V/∂r) | `black_scholes.py:100` | Production | `K·T·e^{-rT}·N(d₂)` (call) |
| **Vanna** (∂²V/∂S∂σ) | `black_scholes.py:115` | Production | `−φ(d₁)·d₂/σ` |
| **Charm** (∂Δ/∂t) | `black_scholes.py:125` | Production | `−e^{-rT}·φ(d₁)·[2rT − d₂·σ√T] / (2σ√T)` |
| **Vomma/Volga** (∂²V/∂σ²) | `black_scholes.py:139` | Production | `vega·d₁·d₂/σ` |
| **SABR Hagan (2002)** | `sabr.py:21` | Production | ATM + non-ATM branches; z/χ(z) mapping |
| **SABR surface calibration** | `sabr_calibrator.py:65` | Production | Nelder-Mead per DTE slice; RMSE < 1.5% reliability gate |
| **Heston first-order correction** | `heston.py:15` | Production | Vanna + vomma expansion terms; κ=2.0, ξ=0.50 |
| **Fair value engine** | `fair_value_engine.py:46` | Production | BS → SABR → Heston pipeline; edge in bps |
| **IV Rank (IVR)** | `iv_analytics.py:209` | Production | `(IV − 52w_low) / (52w_high − 52w_low) × 100` |
| **IV Percentile (IVP)** | `iv_analytics.py:209` | Production | Count of history days below current IV |
| **Volatility skew** | `iv_analytics.py:340` | Production | `avg(OTM put IV) − avg(OTM call IV)`, ±1–15% wings |
| **Skew z-score** | `iv_analytics.py:237` | Production | `(skew − 52w_avg) / std_dev`; requires ≥ 5 days |
| **Gamma Exposure (GEX)** | `iv_analytics.py:388` | Production | `(call_OI·γ_call − put_OI·γ_put) × 100 × S / 1M` |
| **Vanna Exposure (VEX)** | `iv_analytics.py:104` | Production | `(call_OI·vanna − put_OI·vanna) × 100` |
| **Charm Exposure (CEX)** | `iv_analytics.py:116` | Production | `(call_OI·charm − put_OI·charm) × 100` |
| **Zero-gamma level** | `iv_analytics.py:436` | Production | Linear interpolation across GEX strike array |
| **Gamma slope** | `iv_analytics.py:459` | Production | Avg upper-half GEX vs lower-half within ±8% band |
| **IV/GEX signal** | `iv_analytics.py:488` | Production | 4-state classifier: stable\_gamma / event\_over\_pos\_gamma / classic\_short\_gamma / regime\_shift |
| **Put wall density** | `iv_analytics.py:501` | Production | Max put OI below spot / avg OI in ±5% band |
| **Realized vol (20d/60d)** | `realized_vol.py:47` | Production | `√[Σln(Pᵢ/Pᵢ₋₁)² / (n−1)] × √252` (Bessel correction) |
| **Calendar arb check** | `arb_checker.py:129` | Production | Variance must be non-decreasing: `IV²·T` monotone in T |
| **Butterfly arb check** | `arb_checker.py:168` | Production | Call convexity: `C₁ − 2C₂ + C₃ ≥ 0` across strike triplets |
| **Option scoring engine** | `option_scoring.py:52` | Production | 6-component base × GEX mult × vanna mult; regime fail cap = 35 |
| **Greek grid (5×5)** | `greek_grid_ingester.py` | Production | Median Greeks per (moneyness band × expiry bucket) cell |
| **ES₉₅** | `constants.py` (ES95\_MULT=2.063) | Partial | Formula defined, per-contract computed; portfolio aggregation pending |

---

## Institutional Edge — Value Proposition

### 1. Expected Shortfall Risk Management (ES₉₅)

Retail platforms (Robinhood, Tastyworks) surface Greeks at the contract level but provide no framework for quantifying the tail loss of a position within a portfolio context. This system computes ES₉₅ — the expected loss in the worst 5% of outcomes — for every candidate trade before entry, using a two-component model:

```
ES₉₅ = |Δ| · S · σ · √T · 2.063     ← linear price tail (delta P&L in 2σ move)
      + ½ · |Γ| · S² · σ² · T · 1.5  ← convexity component (gamma bleed)
```

The 2.063 multiplier is the theoretical ES/VaR ratio for a normally distributed loss at 95% confidence. The gamma term captures the non-linearity that makes short-dated OTM options dangerous even at small deltas.

This feeds a **hard portfolio delta gate** ($500 notional cap) that physically blocks trade entry when aggregate book exposure exceeds threshold — a risk control analogous to intraday delta limits enforced by prop desk risk management systems, without requiring a separate risk officer approval workflow.

**Differentiation from retail:** No retail brokerage platform enforces a pre-trade ES₉₅ computation or portfolio delta gate at the point of order entry. Institutional desks implement this in their OMS/RMS layer (Fidessa, Ion, Flextrade). This system replicates that gate natively in the mobile evaluation workflow.

---

### 2. Calibrated Volatility Surface Intelligence

Most retail platforms display a single IV number per contract derived from the broker's own Black-Scholes inversion. This system maintains a multi-DTE calibrated SABR surface, updated three times daily, with the following analytical layers:

**Daily SABR calibration (per ticker, per DTE slice):**
- Fits three free parameters (α, ρ, ν) to the full options chain using Nelder-Mead optimization (1,500 iterations, RMSE < 1.5% reliability gate)
- ρ (spot-vol correlation) and ν (vol-of-vol) reflect current market conditions, not hardcoded assumptions
- Persisted to database as `sabr_calibrations` for historical regime analysis

**Dealer Greek exposure surface (GEX/VEX/CEX):**
- Aggregates open interest × Greeks across all strikes within ±20% of spot
- Identifies the **zero-gamma level** (strike where dealer net gamma crosses zero) via linear interpolation — the structural price magnet used by vol arbitrage desks
- Classifies **gamma slope** (rising/falling/flat within ±8% band) as a leading indicator for intraday drift direction
- **VEX (Vanna Exposure):** quantifies how much dealer delta-hedging pressure shifts when IV moves — predicts whether a vol crush rally or vol crush sell-off is structurally supported
- **CEX (Charm Exposure):** quantifies daily delta drift from time decay alone, capturing the "OPEX charm rally" mechanic used by short-gamma desks as an expiration-week edge

**Regime classification feeding contract scoring:**
- Negative gamma regime → 0.50 score multiplier + hard REGIME FAIL flag on all contracts
- Near zero-gamma flip → 0.70 multiplier (elevated structural instability)
- Deep positive gamma (GEX > $1B) → 1.20 multiplier (structural dampening supports premium selling)
- Vanna divergence (falling gamma slope + bearish vanna regime) → 0.60 multiplier + "fragile rally" warning

This replicates the GEX/zero-gamma analysis used by volatility arbitrage desks (SpotGamma, Tier1Alpha methodology) within an integrated scoring pipeline rather than as a standalone external signal.

---

## Gap Analysis: Swing Horizon vs. Tier-1 Prop Desk

The following gaps exist relative to a full-stack institutional volatility operation. Each is assessed against the swing-horizon (multi-day/week) constraint to determine whether it represents an actionable risk or an acceptable scoping decision.

| Capability | Tier-1 Prop Desk | This System | Swing-Horizon Verdict |
|------------|-----------------|-------------|----------------------|
| **Cross-asset correlation matrix** | Full equity/rates/FX/commodity correlation surfaces updated intraday | Not implemented | **Acceptable.** Single-name equity options focus. Cross-asset correlation matters for portfolio-level delta hedging across asset classes — not required for single-leg equity swing trades |
| **Real-time order flow / L2 data** | Tick-by-tick tape, dark pool prints, options flow scanners (Unusual Whales tier) | 8-hour Schwab batch pulls | **Acceptable.** Multi-day hold horizons are insensitive to intraday order flow noise. The 8-hour cadence provides fresh Greeks, IV surface, and OI data at the decision point |
| **Deep liquidity routing / Smart Order Routing** | Co-located execution, NBBO routing, maker-taker optimization across 16 options exchanges | Schwab retail execution | **Acceptable.** This system is an analysis and decision workstation, not an execution management system. Retail execution is sufficient for single-contract to 10-contract swing trades with liquid names |
| **Tick-level microstructure / HFT** | Sub-millisecond market making, adverse selection models, queue position management | Not applicable | **By design.** The system explicitly excludes HFT. Swing horizon is defined as multi-day/week holds where microstructure noise averages out |
| **Full Heston closed-form / Monte Carlo** | Full characteristic function integration (Carr-Madan FFT), Monte Carlo with variance reduction | Heston first-order Taylor expansion | **Acceptable for swing horizon.** The SABR + Heston perturbation correction captures smile, skew, and stochastic vol to sufficient precision for edge detection in multi-day holds. Pricing errors are sub-$0.10 on typical contracts — below bid-ask noise |
| **Portfolio margin optimization** | Real-time margin efficiency (SPAN, TIMS), cross-margining across futures/options | Not implemented | **Future addition.** Currently tracks notional delta exposure; full SPAN margin modeling would improve capital efficiency for multi-leg strategies |
| **Portfolio-level VaR aggregation** | Full Greeks P&L waterfall, cross-Greek correlation adjustments, scenario P&L | Per-contract ES₉₅ computed; portfolio aggregation pending | **Active gap.** ES₉₅ is computed per trade and the portfolio delta gate is enforced, but a full portfolio VaR roll-up across all open positions is not yet implemented |
| **Vol-of-vol empirical series** | Daily vvol measurement from realized SABR ν, vol regime clustering | SABR ν calibrated per snapshot but not tracked as time series | **Minor gap.** The calibrated ν is available in `sabr_calibrations` table per date — a time-series view and percentile ranking of ν would add a vol-of-vol regime signal |
| **Greeks P&L attribution** | Daily PnL explained by Δ, Γ, V, Θ, cross-terms | Not implemented | **Relevant post-entry.** Currently tracks realized P&L against entry cost; Greek-attributed P&L waterfall would improve post-trade analysis |
| **Real-time streaming Greeks** | WebSocket-based live option chain subscriptions | Batch ingest (8h cadence), live quotes via Schwab on-demand | **Conditional.** Live Schwab quotes are pulled on-demand per ticker in the UI. The 8-hour batch cadence applies to the IV surface and GEX computations, not the display price |

---

## Data Pipeline

```
Schwab API (options chains, quotes, fundamentals)
    ↓  every 8 hours via Cloud Scheduler
Supabase Edge Functions (OAuth token management)
    ↓
Python Backend (Cloud Run)
    ├─→ Vol surface extraction       → vol_surface_snapshots
    ├─→ SABR calibration (per DTE)   → sabr_calibrations
    ├─→ IV analytics (full pipeline) → iv_snapshots
    ├─→ Greek grid aggregation       → greek_grid_snapshots
    ├─→ ATM Greek time-series        → greek_snapshots (4/7/31 DTE buckets)
    └─→ Realized vol (FMP API)       → logged

FMP API      → historical closes for RV20d/RV60d
FRED API     → VIX, yield curve, Fed funds rate
BLS API      → unemployment, CPI, PPI, JOLTS
BEA API      → GDP, PCE, corporate profits
EIA API      → crude inventory, refinery utilization
Kalshi API   → binary event probabilities (FOMC, CPI, NFP, earnings)
```

**Database:** Supabase PostgreSQL with row-level security (user-scoped analytics). 15+ tables covering trades, journal, vol surfaces, Greek time-series, macro snapshots, ticker profiles, support/resistance levels, insider buys, earnings history.

---

## Screens & Workflow (25 Views)

| Category | Screens |
|----------|---------|
| Trade lifecycle | Add trade · Trade detail · Trade log · Journal · CSV import |
| Evaluation workflow | 5-Phase Blotter · Option Decision Wizard · Validated blotters |
| Options analysis | Live options chain · Greek chart · Vol surface heatmap |
| Portfolio | Summary dashboard · 20-trade block analysis · P&L chart |
| Ticker intelligence | Ticker profile (5 tabs: overview, edge, levels, timeline, misc) · Ticker dashboard |
| Macro | Economy Pulse (7 sub-tabs: FRED, BLS, BEA, EIA, Census, Kalshi, full macro score) |
| Setup | Schwab OAuth bootstrap · Calculator |

---

## Quantitative Code Summary

| Module | Lines | Capability |
|--------|-------|-----------|
| `api/services/iv_analytics.py` | 685 | GEX/VEX/CEX surfaces, IV rank/percentile/skew, regime classification |
| `api/services/option_decision.py` | 286 | Full trade analysis: break-even, P&L, theta drag, recommendation |
| `api/services/option_scoring.py` | 273 | 0–100 scoring engine with regime multipliers |
| `api/services/greek_grid_ingester.py` | 250 | 5×5 moneyness × expiry Greek grid aggregation |
| `api/services/sabr_calibrator.py` | 210 | Multi-DTE surface calibration via Nelder-Mead |
| `api/services/arb_checker.py` | 200 | Calendar variance + butterfly convexity arbitrage detection |
| `api/services/fair_value_engine.py` | 124 | BS → SABR → Heston pricing pipeline |
| `api/services/black_scholes.py` | 229 | Full Greeks (8): δ, γ, θ, ν, ρ, vanna, charm, vomma |
| `api/services/realized_vol.py` | 136 | RV20d/RV60d with Bessel correction + percentile ranking |
| `api/jobs/schwab_pull.py` | 348 | 8-hour batch ingestion orchestrator |
| `api/core/constants.py` | 106 | All numeric constants (SABR, Heston, scoring thresholds) |
| **Total** | **~3,000** | |
