Phase 2 — Formula: Full Breakdown
What it answers
Given the specific contract (ticker + strike + expiry + call/put), five questions:

Is the contract itself well-structured? (6-component score)
Does it pass the R:R formula? (pricing edge check)
What is the theta cost? (time decay drag)
Are there hard disqualifiers? (warning flags)
What's the right position size? (budget check, contracts affordable)

The 6 Components — What Each Score Means
1. Delta Quality (0–20) — leverage sweet spot

Score	Delta	Meaning	Right move
15–20	0.30–0.50	Sweet spot — best balance of leverage vs probability	Enter as planned
8–14	0.20–0.30 or 0.50–0.70	Slightly outside ideal — still tradeable	Enter at 75% size
0–7	< 0.20 or > 0.70	Deep OTM (lottery) or deep ITM (expensive, low leverage)	Avoid or find better strike
Why 0.40 is the target: you get 40¢ of move per $1 the stock moves, without paying full intrinsic value like a deep ITM. Below 0.20 you need a violent move just to break even on delta.

2. DTE Zone (0–20) — time is the axis everything else rotates on

Score	DTE	Meaning	Right move
20	21–45	Sweet spot — theta manageable, enough runway	Full conviction entry
10–19	8–21	Theta accelerating, pin risk approaching	Reduce size 25%, need move soon
0–9	< 7	Gamma explosion zone — delta unstable, expiry risk	Avoid or trade only on same-day catalysts
0	> 90	Too much time premium, slow-moving, low leverage	Only for long-term LEAP thesis
The DTE < 7 flag is a hard warning. Within one week, gamma spikes and delta can flip from 0.40 to 0.10 in a single bad candle.

3. Spread Quality (0–15) — what you give back to the market maker

Score	Spread %	Meaning	Right move
12–15	< 5%	Tight — liquid contract	Enter at midpoint
7–11	5–20%	Manageable	Enter at midpoint, accept slight slippage
0–6	> 20%	Wide — market maker is extracting margin	Wait for better liquidity or different strike
0	> 100%	No real market	Do not trade
A 30% spread means you're already -15% the moment you enter (you'd need to sell the offer to get back to breakeven). This alone can flip a good trade into a loser.

4. Implied Volatility (0–20) — what the market thinks this stock can do

Score	IV	Meaning	Right move
20	≥ 50%	Rich premium contract	If buying: need large move. If selling: ideal target
10–19	20–50%	Normal premium range	Standard entry
0–9	< 20%	Cheap options, low-vol name	Buying is cheap but moves are small too
Critical nuance: a high IV score is neither good nor bad in isolation — it depends on whether you're buying or selling. This is why Phase 1 (VIX) comes first: VIX high → prefer selling → high IV score is ideal. VIX low → prefer buying → low IV score is fine (cheap options).

5. Open Interest (0–10) — how many other traders are in this contract

Score	OI	Meaning	Right move
10	≥ 1,000	Highly liquid — institutional participation	Full size
8	500–999	Good liquidity	Full size
5	100–499	Adequate	Reduce size by 25%
2	20–99	Thin — exit risk	Half size, plan exit before liquidity dries up
0	< 20	Illiquid	Do not trade
Low OI means when you need to exit, you may not find a buyer at fair value. You'll get filled at the bid (not midpoint), losing the spread on exit too.

6. Moneyness Match (0–15) — where you are relative to the stock price

Score	Position	Meaning	Right move
15	OTM 1–7%	Sweet spot for directional swings	Best risk/reward for trend trades
12	ATM	Best for "I expect a move but not sure how big"	Valid, but theta burns faster
7–8	Shallow ITM or OTM 7–12%	Outside sweet spot	Acceptable if strong conviction
4	Deep ITM	Low leverage, high capital	For protective use or if you want stock-like exposure
0	Deep OTM > 12%	Lottery ticket	Only on high-conviction binary events (earnings, FDA)
Formula Check (on top of the score)
This is the OptionDecisionEngine.analyze() layer — it takes the score and adds:

R:R Gate — estimatedPnl / entryCost > threshold

If your estimated P&L at target divided by your entry cost is below 30%, it's not worth the risk premium
pass: estimated return ≥ 30%
warn: estimated return 15–29%
fail: estimated return < 15% or negative
Theta drag check

If daily theta burn > 2% of entry cost → warning flag
This catches contracts where time decay is eating you alive even before the stock moves
Pricing edge

pricingEdge = theoreticalOptionValue − midpoint
Positive = contract is priced below theoretical → cheap (edge in your favor)
Negative > $0.10 = you're paying a premium over fair value → market maker extracting more
pass: edge ≥ $0.05 (cheap vs theoretical)
warn: edge −$0.10 to +$0.05
fail: edge < −$0.10 (overpriced by more than 10 cents)
Unusual activity check

vol/OI ratio > 0.5 → smart money / unusual flow → positive signal (adds to reasons)
Pass / Warn / Fail Logic

PASS   score ≥ 65  AND  estimated return ≥ 30%  AND  no hard warning flags
WARN   score 50–64  OR  return 15–29%  OR  wide spread flag  OR  DTE < 14
FAIL   score < 50  OR  negative estimated P&L  OR  no market (illiquid)  OR  deep OTM flag
Hard FAIL triggers (override score):

"No market (illiquid)" — score will be 0 anyway
"No open interest" — can't exit the trade
Direction mismatch (calling a call when thesis is bearish)
Estimated P&L ≤ 0 at stated price target
What the panel shows

┌─ Phase 2: Formula ─────────────────────────── [PASS ✓] ──┐
│                                                             │
│  AMZN  $195 CALL  21 DTE  IV 34.2%                        │
│  Grade: B+  Score: 68 / 100                                │
│  ████████████████████████░░░░░░  68%                       │
│                                                             │
│  ─── Top Components ─────────────────────────────────────  │
│  Delta Quality    18/20  Δ 0.42 — sweet spot               │
│  Moneyness        15/15  OTM 3.1% — directional ideal      │
│  DTE Zone         20/20  28 DTE — in sweet spot            │
│  Spread Quality   10/15  Spread 12% — manageable           │
│  IV               12/20  34.2% — normal range              │
│  Open Interest     8/10  OI 620 — good liquidity           │
│                                                             │
│  ─── Formula Check ──────────────────────────────────────  │
│  R:R              +42% return at $210 target               │
│  Pricing edge     +$0.08 — priced below theoretical        │
│  Theta drag       −$14/day — manageable (1.4% of cost)     │
│  Break-even       $198.45  (+1.7% from current)            │
│                                                             │
│  ─── Warnings ───────────────────────────────────────────  │
│  ⚠  Spread 12% — enter at midpoint, expect some slippage  │
│                                                             │
│  [View Full Score Sheet →]                                  │
└─────────────────────────────────────────────────────────────┘
What's new vs what's reused
Piece	Status
6-component scoring	Reuse OptionScoringEngine.score()
R:R, theta, pricing edge, break-even	Reuse OptionDecisionEngine.analyze()
Score bar chart	Reuse _ScoreBarChart from option_score_sheet.dart (or rebuild lighter)
Grade badge	Reuse _GradeBadge from option_score_sheet.dart
Hard flag detection	Reuse score.flags and result.warnings
"View Full Score Sheet →"	Reuse — open OptionScoreSheet bottom sheet
Pass/warn/fail gate	New — wrap around existing score + result
Phase 2 panel layout	New
The panel takes a SchwabOptionContract? from the parent (the 5-phase blotter screen fetches the chain and finds the matching contract by strike + expiry). If no contract yet, it shows "Enter trade details to evaluate."

Phase 2 is complete. No errors, all lints cleared.

formula_phase_panel.dart — what was built:

Data flow: watches schwabOptionsChainProvider → finds contract by expiry + closest strike → runs OptionScoringEngine + OptionDecisionEngine

Six component rows, each with:

Icon, label, score bar (score/max), color-coded by percentage
Plain-English interpretation: what the number means and what to do about it (e.g. "Δ 0.42 — directional sweet spot", "OTM 3.1% — ideal leverage/cost ratio")
Formula check section (only when priceTarget is provided):

Estimated return % at target — green ≥30%, amber 15–29%, red <15%
Pricing edge vs Schwab's theoreticalOptionValue — positive = cheap
Break-even price + % move needed
Theta drag per day + % of entry cost
Unusual activity flag if vol/OI > 0.5
Entry cost + contracts affordable at budget
Pass/warn/fail gate:

PASS — score ≥65, return ≥30%, no hard flags
WARN — score 50–64, return 15–29%, or any flag (wide spread, DTE<14)
FAIL — score <50, negative P&L, illiquid, no OI
States: loading skeleton, contract-not-found error, "enter trade details" placeholder when strike/expiry not yet set, "enter price target" note when target missing

Deep link: "View Full Score Sheet →" opens the existing OptionScoreSheet bottom sheet