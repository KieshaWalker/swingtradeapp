Phase 5 — Kalshi Plan
What we have
kalshiMacroEventsProvider — List<KalshiEvent>, all open macro events with nested markets
kalshiEventsForExpirationProvider(DateTime) — already filters by close time before expiry
KalshiEvent — eventTicker, title, category, closeDateTime, leadingMarket, closesBeforeExpiration(date)
KalshiMarket — yesProbability (0.0–1.0), title, yesAsk/yesBid, volume, openInterest
kalshiLiveOddsProvider(ticker) — WebSocket stream for live probability updates
Three-tier filtering (from notes)
Tier 1 — Ticker-specific (_isTicker)

Search event.title for the stock ticker name (e.g. "NVDA", "Apple", "Amazon"). These are earnings/stock events with direct price impact.

Tier 2 — Macro within DTE window (_isMacro)

Use kalshiEventsForExpirationProvider(expiryDate) — all macro events (CPI, FOMC, NFP, etc.) closing before the option's expiry. These are binary catalysts that can spike or crush IV.

Tier 3 — Catch-all

All remaining open events: count + highest-probability event shown as context.

Pass / Warn / Fail logic
Condition	Status
No tier 1 or tier 2 events found	PASS — no binary events in window
Any tier 2 event with 40–65% YES prob	WARN — binary catalyst uncertain
Any tier 2 event with ≥65% YES prob	FAIL — high-confidence binary event during hold
Any tier 1 (ticker-specific) event found	WARN always — direct price exposure
Multiple tier 2 events ≥50%	FAIL — stacked binary risk
Per-event display card

┌─ FOMC Rate Decision ────────────────────────── Economics · closes Apr 30 ─┐
│  "Fed holds rates at 4.25-4.5% in May?"                                    │
│  ████████████░░░░░░  72%   YES ask: $0.70  No ask: $0.31  Vol: 42,418      │
│  ⚠ High confidence (72%) — binary catalyst within your 21d window          │
└────────────────────────────────────────────────────────────────────────────┘
What the panel explains
For each event:

What it is — plain English: "This is a Fed rate decision. If YES resolves (Fed holds), rate-sensitive stocks stabilize. If NO (Fed cuts/raises), sudden re-pricing across all assets."
Why it matters to your trade — based on ticker sector (oil → energy; tech → rate-sensitive; etc.)
What probability means — 40–65%: uncertain, market could go either way → avoid naked exposure; >65%: market has conviction → trades against that conviction are fighting the tape
Vol implication — high probability = event certainty priced in → limited vol expansion post-resolution; uncertain = vol spike possible if surprises
New file
lib/features/blotter/widgets/phase_panels/kalshi_phase_panel.dart

Props:

ticker — for tier 1 search
expiryDate — DateTime for kalshiEventsForExpirationProvider
isCall — for sector-specific impact interpretation
onResult(PhaseResult) — callback
Providers watched:

kalshiMacroEventsProvider — tier 1 + tier 3 base
kalshiEventsForExpirationProvider(expiryDate) — tier 2
Sections inside the panel
Status header (PASS/WARN/FAIL badge with headline)
Ticker-specific events (tier 1) — if any found
Macro events in window (tier 2) — sorted by probability desc
Summary context — tier 3 catch-all count + highest-prob event
What this means for your trade — plain interpretation
Deep link → Economy/Kalshi tab


Clean. Here's what was built:

phase_stepper.dart — horizontal 5-node progress bar

Each node is a circle colored by PhaseStatus (slate/green/amber/rose)
Status icon replaces the number once evaluated (check/warning/cancel)
Connector lines between nodes tinted by the left node's status
Labels below: Economic · Formula · Blotter · Vol Surface · Kalshi
five_phase_blotter_screen.dart — main screen

Trade form: ticker, CALL/PUT toggle, strike, expiry picker, qty, budget, optional price target
Panels only mount when all three required fields (ticker + strike + expiry) are filled
Schwab chain is watched to extract spot/IV/greeks for BlotterPhasePanel; falls back to _strike as spot when chain hasn't loaded yet
Each _PhaseTile wraps the panel in an ExpansionTile with a colored border and status chip; auto-expands on WARN/FAIL
Sticky action bar shows overall status text + "Commit Trade" button gated on all phases passing
Changing any trade field resets all 5 phase results to pending so re-evaluation is triggered automatically
Route: /blotter/evaluate?ticker=AAPL — ticker is pre-populated via query param, enabling deep-link from ticker profiles or the options chain screen.