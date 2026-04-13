Phase 3 — Blotter (Pricing): Full Breakdown
What it answers
Four questions that only a pricing model — not a score sheet — can answer:

What is this contract actually worth? (BS → SABR → Heston model stack)
Are you getting an edge, or are you paying up? (edge in bps vs broker mid)
How much can this position lose in a tail event? (ES₉₅)
What does adding this trade do to the existing book? (portfolio what-if)
The Pricing Stack — Three Layers


Layer 1: Black-Scholes (baseline)

Standard closed-form option pricing using the market's own IV
Assumes constant vol, log-normal returns
bsFairValue = what the option is worth if vol stays flat and moves are continuous
Limitation: ignores the vol smile (OTM options are priced differently than ATM)

Layer 2: SABR (smile adjustment)

Hagan et al. 2002 — stochastic alpha, beta, rho model
Calibrated to US equity vol surface: β=0.5 (square-root CEV), ρ=−0.7 (negative skew), ν=0.40 (vol-of-vol)
sabrVol = the smile-adjusted implied vol for this specific strike
sabrFairValue = BS repriced with the SABR vol — captures the skew premium on OTM puts, the cheaper OTM calls
What changes: OTM puts will price higher than BS (skew premium); OTM calls will price lower
Layer 3: Heston Correction (stochastic vol)

First-order expansion of the full Heston SV model around BS
Accounts for mean-reverting stochastic vol (vol reverts to long-run mean at speed κ=2.0)
Two terms:
ρ_H × ξ × Vanna × (1 − e^{−κT}) / κ — vol/spot correlation effect (vanna-weighted)
(ξ²/2) × Vomma × (1 − e^{−2κT}) / (2κ) — vol-of-vol convexity effect (volga-weighted)

modelFairValue = SABR + Heston correction = the most accurate internal price

What changes: adds a premium for vol mean-reversion risk, especially significant for longer DTE
Edge in Basis Points

edgeBps = (modelFairValue − brokerMid) / brokerMid × 10,000
Edge	Label	Meaning	Right move

> +20 bps	STRONG BUY	Model prices contract significantly above market	High-conviction entry

+5 to +20 bps	BUY	Model says contract is cheap vs broker	Enter — you have a pricing edge
−5 to +5 bps	FAIR	Contract is fairly priced	Proceed based on Phase 1+2; no pricing edge
−5 to −20 bps	SELL	Model says contract is expensive vs broker	Reconsider; you're paying above fair value
< −20 bps	STRONG SELL	Broker is extracting significant premium	Avoid or sell this contract instead
The nuance: edge is calculated at the current moment. Market makers reprice continuously. A +15 bps edge at entry might be +3 bps by the time your order hits if the stock moves 0.1%.

Second-Order Greeks (from the Heston correction)
These come directly out of the pricing model — not from Schwab's API — so they're already computed by the time FairValueResult is returned.

Vanna (∂²V / ∂S∂σ) — delta sensitivity to vol changes

Measures how much your delta shifts when IV moves
Negative Vanna on a long call: when IV drops, your delta falls too (double pain on IV crush)
Large |Vanna| + falling VIX = delta erosion even if stock is flat
Signal: high |Vanna| → hedge delta more aggressively or prefer lower-vega structures
Charm (∂Δ / ∂T) — delta decay per day

How much your effective delta erodes each day from time passing alone
Most dangerous in the 7-21 DTE zone where charm accelerates
A charm of −0.004 means your 0.40 delta option becomes a 0.396 delta option tomorrow even if the stock doesn't move
Signal: high |Charm| → delta hedge will need daily rebalancing; factor into theta cost
Volga / Vomma (∂²V / ∂σ²) — vol convexity

How much your vega itself changes when IV moves
Positive Volga means you benefit disproportionately from large IV moves in either direction (long vol convexity)
Signal: high Volga → position benefits from IV volatility (good for long straddles / earnings plays); the Heston correction adds this to your fair value
ES₉₅ — Expected Shortfall at 95% Confidence

ES₉₅ = |Δ| × S × σ × √T × 2.063          ← delta component (linear tail)
      + ½ |Γ| × S² × σ² × T × 1.5         ← gamma component (convexity)
Where 2.063 = φ(1.645)/0.05 is the ES₉₅ multiplier (expected loss beyond the 95th percentile, averaged over the tail).

What it means: if the next T days are a 1-in-20 bad scenario, this is your expected dollar loss (not worst case — the average of all scenarios worse than the 5th percentile).

ES₉₅	Risk level	Right move
< $100	Low	Full size
$100–$300	Moderate	Check portfolio total
$300–$700	Elevated	Reduce size or hedge
> $700	High	Size down significantly
The gamma term is critical — a short gamma position in a large move can lose far more than the linear delta predicts. ES₉₅ captures this second-order tail.

Portfolio What-If — The Four Numbers
This is what separates Phase 3 from Phase 2. Phase 2 looks at the contract in isolation. Phase 3 looks at what happens to the entire book.

Delta impact (posDelta = delta × qty × 100)

How much net directional exposure this trade adds in dollar-delta
Threshold: |portfolio delta| > $500 triggers a warning
If you're already long $400 delta and this trade adds $200, you're now outside risk limits
Vega impact (posVega = vega × qty × 100)

How much IV sensitivity this adds to the book
Large positive vega across the book means a VIX drop hurts everything simultaneously — correlated risk
No hard threshold but surfaced as a signal
ES₉₅ impact

How much this trade increases the book's tail risk
Additive: new ES₉₅ = current portfolio ES₉₅ + this position's ES₉₅
If newEs95 > 2× currentEs95: this trade more than doubles your tail risk → strong warning
Delta threshold gate

Hard rule: |newDelta| > $500 → blocks Commit
Forces trader to either reduce size or acknowledge the directional risk explicitly
Pass / Warn / Fail Logic

PASS   edgeBps > +5   AND   ES₉₅ impact < $500   AND   delta within threshold
WARN   edgeBps 0 to +5 (thin edge)
       OR  ES₉₅ impact $300–$500
       OR  delta within 80% of threshold
FAIL   edgeBps < 0 (paying above fair value)
       OR  delta threshold exceeded
       OR  ES₉₅ impact > $700
What the panel shows

┌─ Phase 3: Blotter ─────────────────────── [BUY  +14 bps] ─┐
│                                                              │
│  ─── Pricing Model Stack ──────────────────────────────── │
│  Black-Scholes     $3.42    baseline (constant vol)         │
│  SABR              $3.58    +$0.16  smile/skew adjustment    │
│  Model (Heston)    $3.71    +$0.13  stochastic vol term      │
│  Broker Mid        $3.47    ← what you're actually paying   │
│  Edge              +14 bps  BUY — model says contract cheap  │
│                                                              │
│  ─── Second-Order Greeks ─────────────────────────────── │
│  Vanna   −0.042   delta falls 4.2¢ per 1% IV drop           │
│  Charm   −0.003   delta loses 0.003 per day (time decay)    │
│  Volga   +0.021   long vol convexity — benefits from IV pop  │
│                                                              │
│  ─── Expected Shortfall (ES₉₅) ─────────────────────────  │
│  This trade   $187    delta $156 + gamma $31                 │
│  Portfolio   $423  →  $610 after adding this trade          │
│  Risk level   MODERATE — within limits                      │
│                                                              │
│  ─── Portfolio What-If ───────────────────────────────────  │
│  Delta impact  +$189    book delta $311 → $500 (⚠ limit)    │
│  Vega impact   +$42     correlated vol exposure              │
│  ES₉₅ shift   +$187    portfolio tail risk increases 44%    │
│                                                              │
│  [View Full Blotter ↗]                                       │
└──────────────────────────────────────────────────────────────┘
What's new vs what's reused
Piece	Status
FairValueEngine.compute()	Reuse directly
FairValueEngine.computeWhatIf()	Reuse directly
FairValueEngine.loadPortfolioState()	Reuse directly
FairValueResult.edgeBps, .edgeLabel, .edgeColor	Reuse
FairValueResult.vanna, .charm, .volga	Reuse
WhatIfResult	Reuse
Pricing stack display (3 rows: BS → SABR → Heston)	New
ES₉₅ breakdown (delta component + gamma component)	New
Portfolio what-if panel	New (existing blotter shows it inline; phase panel extracts it as a summary)
Pass/warn/fail gate on edge + ES₉₅	New
"View Full Blotter →" deep link	Reuse TradeBlotterScreen push route
The panel takes spot, strike, impliedVol (decimal), daysToExpiry, isCall, brokerMid, delta, gamma, vega, quantity — all of which the 5-phase blotter screen already holds from the trade form + Schwab contract lookup.

Systemic GEX (Gamma Exposure): A simple flag indicating the broader market maker positioning (Positive or Negative Gamma). If the market is in a heavy negative gamma regime, realize that realized volatility will likely exceed modeled expectations, and your stops need to be wider.

Beta-Adjusted Notional: The total dollar exposure of the trade, adjusted for the underlying asset's correlation to the broader market (SPY).