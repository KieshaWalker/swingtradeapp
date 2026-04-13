All clean. Here's what was built:

Phase 4 — Vol Surface panel (vol_surface_phase_panel.dart)

Five signals auto-interpreted from the surface:

IV Level — finds the exact strike/DTE cell, shows it as a percentile of the full surface range, and explains what that means (cheap → buy premium, 80th pct+ → IV crush risk)

Term Structure — near vs far ATM IV, produces a contango/flat/backwardation verdict with plain-language explanation. The _TermDotRow shows each DTE as a dot with the trade's target DTE highlighted.

Smile Skew — OTM put/call IV ratio at the target DTE, mapped to put-bid / symmetric / call-bid, with direction alignment check

Earnings calendar — watches tickerNextEarningsProvider. If earnings fall inside the DTE window: WARN banner + near-ATM vs OTM impact explained. If earnings + backwardation: FAIL (classic IV crush setup). If earnings outside window: informational note.

Calendar spread cycle — 3-point term shape (front/mid/back) → fully inverted, hump-shaped, or normal slope, each explaining what it means for calendar spreads

VolSurfaceScreen (vol_surface_screen.dart)

Ticker headers are now clickable → selects most recent snapshot for that ticker
Collapse/expand per ticker (chevron toggle)
Delete all for ticker (trash icon on header → confirmation dialog)
Repository and provider both gained deleteByTicker