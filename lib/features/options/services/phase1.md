Signal 1: VIX Level → Buy vs Sell Premium
Source: fredVixProvider → VIXCLS (most recent observation)

VIX	Regime	Signal
< 15	Fear is low	Options are cheap → prefer buying premium (long calls, debit spreads)
15–20	Normal	Balanced — either side is fairly priced
20–30	Elevated	Options are expensive → prefer selling premium (credit spreads, iron condors)
> 30	Panic	Aggressively sell premium — but only defined-risk; gamma risk is real
VIX is already flowing through MacroSubScore (component named "VIX Level", max 20 pts). We read both the raw number (for the level label) and the score.

Signal 2: Macro Regime → Directional Bias
Source: macroScoreProvider → MacroScore.regime + MacroScore.total

Regime	Score	Call/Put bias
Risk-On	86–100	Strong call bias — momentum, long calls
Neutral-Bullish	71–85	Mild call bias — bull put spreads, diagonals
Neutral	45–70	No bias — iron condors, wait for setup
Caution	30–44	Put bias — bear call spreads, protective puts
Crisis	0–29	No directional — sell premium both sides
Also surface the two weakest sub-components as "warning signs" (the ones dragging the score).

Signal 3: Supporting Indicators
These fill in the "why" behind the regime:

Yield curve (2s10s) — T10Y2Y via FRED

Positive (normal) = economic expansion → call-friendly
Negative (inverted) = recession risk → put-cautious
Deepening inversion = escalating warning
Unemployment (U3) — blsEmploymentProvider → unemploymentRateU3

Rising trend = weakening labor → bearish macro → put environment
Falling or stable = healthy → call-supportive
Fed funds rate trajectory — DFF via FRED

Rate cut cycle (falling): accommodative → bullish for risk assets → calls
Rate hike cycle (rising): tightening → risk-off → puts on rate-sensitive names
Signal 4: Sector Overlay
This is ticker-specific. The panel classifies the ticker on entry and pulls the relevant sector economy.

Oil/Energy (XOM, CVX, OXY, USO, XLE, UCO, OIH, DVN, MRO, VLO, PSX, MPC, SLB, HAL, COP, FANG):

Pull from EIA providers already in app:

eiaCrudeStocksProvider → inventory vs 5-year avg → surplus (bearish oil) or deficit (bullish)
eiaCrudeProdProvider → production trend → supply pressure
eiaRefineryUtilProvider → demand signal (high utilization = demand pulling)
Interpretation:

High inventory + high production = bearish oil stocks → favor puts or bear spreads
Low inventory + refinery utilization > 90% = tight supply = bullish → favor calls
Rate-sensitive (JPM, BAC, GS, MS, KRE, TLT, XLU, BRK):

T10Y2Y spread + DFF trajectory
Rising rates = NIM expansion for banks (bullish) but bad for TLT/utilities
Inverted curve = compression risk for banks
Consumer (AMZN, WMT, TGT, COST, HD, XRT, XLP, XLY):

blsEmploymentProvider → U3 rate + avg hourly earnings
censusRetailSalesProvider → month-over-month retail trend
Strong employment + rising wages = consumer spending healthy → calls
Tech/Mega-cap (AAPL, MSFT, GOOGL, META, NVDA, QQQ, XLK):

fredVixProvider + SPY trend sub-score + fredHyOasProvider (credit environment)
HY spreads widening = risk-off → tech sells off first
Low VIX + tight credit = tech bullish
Index/ETF (SPY, QQQ, IWM, DIA):

Use full macro score — no sector overlay needed, macro IS the story
Unknown/other: Show macro score + VIX only, skip sector overlay

Phase 1 pass/warn/fail logic

PASS  — macro score ≥ 55  AND  regime ≠ crisis  AND  sector overlay aligns with direction
WARN  — macro score 35–54  OR  regime = caution  OR  sector is mixed
FAIL  — macro score < 35  OR  regime = crisis  OR  sector overlay directly contradicts direction
         (e.g. buying calls in crisis, or buying oil calls when crude inventory is at 5-year high)
The key "contradiction" cases that flip to FAIL:

Buying calls + Caution/Crisis regime
Buying puts + Risk-On regime
Buying calls on oil stock when crude stocks above 5-year average and production trending up
Buying calls on rate-sensitive when curve is inverted and fed is hiking
What the panel shows

┌─ Phase 1: Economic ─────────────────────────── [WARN ⚠] ─┐
│                                                             │
│  VIX  22.4  ↑  Elevated — favor selling premium           │
│  ████████████░░░░░░░░  Macro Score: 48 / 100               │
│  Regime: Neutral  🟡                                        │
│                                                             │
│  Directional bias:  No clear edge — wait for setup         │
│                                                             │
│  ─── Supporting ─────────────────────────────────────────  │
│  Yield curve:  −0.12  Inverted — recession risk            │
│  Unemployment: 4.2%  Stable                                 │
│  Fed:  5.33%  Holding — no cut signal                       │
│                                                             │
│  ─── Oil Sector Overlay (XOM detected) ──────────────────  │
│  Crude stocks:  +4.2M bbl vs 5Y avg  ↑  Surplus            │
│  Production:  13.2M bbl/day  Flat                           │
│  Refinery util: 87%  Below avg                              │
│  → Sector: Bearish — avoid long calls, consider puts        │
│                                                             │
│  [View Full Macro Score →]                                  │
└─────────────────────────────────────────────────────────────┘
What's new vs what's reused
Piece	Status
VIX level + label	New — read latest from fredVixProvider, map to premium label
Macro score + regime	Reuse macroScoreProvider
Yield curve / Fed / U3	Reuse macroScoreProvider sub-components (already computed)
Oil sector overlay	New — read eiaCrudeStocksProvider, eiaCrudeProdProvider, eiaRefineryUtilProvider
Other sector overlays	New — logic layer using BLS/FRED/Census providers already loaded
Sector classification	New — static ticker→sector lookup map (short, about 60 tickers)
"View Full Macro Score" link	Reuse MacroScoreScreen push route




Phase 1 is complete. Here's what was built:

phase_result.dart — shared model for all 5 phases: PhaseStatus enum (pending/pass/warn/fail) with color and icon, PhaseResult with headline, signals list, and reviewed flag.

economic_phase_panel.dart — the full Phase 1 panel:

VIX strip — large VIX number with color (green <15, blue 15-20, amber 20-30, red >30), trend arrow vs previous day, and premium buy/sell label
Macro regime card — score progress bar, regime badge, directional bias chip (green if trade aligns with regime, red if it contradicts), top 2 regime strategies
Supporting indicators — yield curve (2s10s), U3 unemployment with trend, fed funds with 6-month trajectory (hiking/cutting/holding)
Oil sector overlay — crude stocks vs 1-year average, production trend, refinery utilization, and a verdict banner (bullish/bearish)
Sector notes for rates-sensitive, consumer, tech, and broad index tickers
Pass/warn/fail logic — detects directional contradictions (e.g. buying calls in a crisis regime, buying oil calls when crude is in surplus)
onResult callback — fires whenever computed status changes, ready to wire into the 5-phase screen lifecycle gating
