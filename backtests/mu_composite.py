from __future__ import annotations
from typing import Optional

# =============================================================================
# backtests/mu_composite.py
# =============================================================================
# Composite MU backtest assembling every rule validated in the July-2026
# research sessions (see data/backtest_mu_meanrev_credit.md and the earnings
# replay work in data/):
#
#   LONG ENGINE   dip entry: close >= DIP% below trailing 252d high
#   CREDIT FILTER skip entries while HYG/IEF 20d change < CREDIT_RED (the
#                 state that front-ran the Apr-2025 and Jun-2026 breaks)
#   EARNINGS      hot-into-print (>= +10% over 21 sessions) -> exit at print
#   OVERLAY       close (the MU fade pattern, 2/2 in 2026); cold -> hold
#   SHORT SLEEVE  hot-into-print -> short at print close, hold 5 sessions
#                 (fade paid Mar-2026 +20%, Jun-2026 +19.6%; Dec-2025 was
#                 cold -> correctly no trade)
#
# Variants are layered so each rule's marginal contribution is visible.
# Direction-scored on the underlying: real option P&L pays theta + spread on
# top (2026 MU straddles ran ~20% of spot per cycle). One secular-bull regime.
#
# Usage: python3 backtests/mu_composite.py [data/backtest_2025_2026.csv]
# =============================================================================
#
# READING THE RESULTS
# -------------------
# Every variant runs over the same sessions and the same entry universe, so
# the delta between two adjacent variants is the marginal contribution of the
# single rule that was switched on:
#   B - A  = what the credit filter saved (it only ever REMOVES entries)
#   C - B  = what cutting a hot long at the print saved
#   D - C  = what the standalone short sleeve added
#
# Caveats that matter when reading the printout:
#   * Returns are underlying direction moves, not option P&L. A +10% move on
#     a 90-110% IV name is a good call, but a flat move is a total loss on a
#     real option and shows as 0.0% here.
#   * The sample is one secular-bull regime with ~6 earnings prints, so the
#     earnings rules rest on a handful of observations. Treat the hit rate as
#     directional evidence, not an estimate.
#   * maxDD is measured on the trade-sequence equity curve (one point per
#     closed trade), so it cannot see drawdown that happened while a position
#     was still open. It understates true peak-to-trough pain.
# =============================================================================

import csv
import sys
import statistics as st

# ── Tunables ─────────────────────────────────────────────────────────────────
# These are the values validated in the July-2026 research sessions. They are
# module-level (not CLI flags) on purpose: every variant must share them, or
# the A/B/C/D deltas stop being attributable to the single rule being toggled.

DIP_PCT = 15.0          # how far below the trailing 252d high counts as a dip
HOLD = 20               # sessions held by the long engine when nothing cuts it short
CREDIT_RED = -1.0       # HYG/IEF 20d %; below this = credit deteriorating
HOT_RUNUP = 10.0        # % gain over 21 sessions into a print = "hot"
SHORT_HOLD = 5          # sessions held by the earnings-fade short sleeve

# MU report dates inside the data window (all post-close)
# Post-close matters: the print lands AFTER the session's close price, so the
# close at an earnings index is still the pre-announcement price. That is why
# both earnings rules below transact "at the print close" — entering the short
# and exiting the long at that bar means transacting immediately before the
# news, which is the trade the research actually validated.
EARNINGS = ["2025-03-20", "2025-06-25", "2025-09-23", "2025-12-17",
            "2026-03-18", "2026-06-24"]


def load(path: str):
    """Read the backtest CSV into parallel per-session lists.

    Expects columns: date, mu, hyg, ief — one row per trading session, already
    sorted ascending by date (the walk in run_variant() indexes by position and
    assumes chronological order; it does not re-sort).

    Returns (dates, mu, ratio) where `ratio` is HYG/IEF, the credit proxy:
    high-yield corporate bonds priced against duration-matched Treasuries. When
    that ratio falls, investors are demanding more compensation to hold credit
    risk — the risk-off impulse that historically front-ran the equity breaks
    this filter is designed to dodge. It is carried as a level here and turned
    into a rate of change in credit_green().
    """
    rows = list(csv.DictReader(open(path)))
    dates = [r["date"] for r in rows]
    mu = [float(r["mu"]) for r in rows]
    ratio = [float(r["hyg"]) / float(r["ief"]) for r in rows]
    return dates, mu, ratio


def credit_green(ratio, i) -> bool:
    """Is the credit backdrop healthy enough to take a new long at index `i`?

    Measures the 20-session rate of change in HYG/IEF and compares it against
    CREDIT_RED. The *change* is used rather than the level because the level is
    dominated by the secular spread regime, while the slope is what turns ahead
    of equity drawdowns.

    Returns True during the first 20 sessions: with no lookback available the
    filter cannot form an opinion, and defaulting to True keeps it a pure veto
    (it may only ever remove entries the dip rule generated, never block the
    engine for lack of data). That makes the B - A delta a clean read on the
    filter's value.
    """
    if i < 20:
        return True
    return (ratio[i] / ratio[i - 20] - 1) * 100 >= CREDIT_RED


def hot_into(mu, i) -> Optional[bool]:
    """Was the stock 'hot' (>= HOT_RUNUP% over 21 sessions) at index i?

    This is the shared trigger behind both earnings rules: the research found
    that MU faded after prints it ran INTO, and did not after prints it went in
    cold. 21 sessions is roughly one trading month of run-up.

    Returns None (not False) when there is insufficient history, distinguishing
    "cannot tell" from "checked, not hot". Both callers use it in a boolean
    test where None is falsy, so an undecidable window correctly produces no
    earnings trade rather than a guess.
    """
    if i < 21:
        return None
    return (mu[i] / mu[i - 21] - 1) * 100 >= HOT_RUNUP


def run_variant(dates, mu, ratio, use_credit, use_earnings, use_short):
    """Walk the series once, applying whichever rules the flags enable.

    The three flags stack to produce variants A-D in main(). Every variant
    shares this one walk so the only difference between them is the rules, not
    the mechanics.

    Position model: strictly non-overlapping and always fully invested in one
    trade at a time. After a trade exits at index j the cursor jumps to j + 1,
    so a signal that fires while a position is open is never taken — it is
    skipped entirely, not queued. Equity compounds trade-on-trade.

    Returns (trades, final_equity, max_drawdown) where trades is a list of
    (entry_date, exit_date, side, return) tuples.
    """
    n = len(dates)
    # Map each earnings date to its index once, up front. Dict insertion order
    # follows EARNINGS, which is chronological — the overlay loop below relies
    # on that to find the EARLIEST qualifying print in a holding window.
    edates = {d: dates.index(d) for d in EARNINGS if d in dates}
    trades = []           # (entry_date, exit_date, side, ret)
    equity, eq = [1.0], 1.0
    # Start at 60 rather than 0 to give the trailing-high window real history.
    # max() below is clamped at 0, so an earlier start would silently compare
    # against a truncated high and manufacture dips that never happened.
    i = 60
    while i < n - 1:
        # ---- earnings-fade short sleeve (independent of long engine) ----
        # Checked FIRST, so on a session that is both an earnings date and a
        # dip the short wins and `continue` skips the long engine entirely.
        # That precedence is deliberate: the fade is the higher-conviction
        # setup, and taking both is impossible under the one-position model.
        if use_short and dates[i] in edates and hot_into(mu, i):
            j = min(i + SHORT_HOLD, n - 1)
            # Short: profit is the negated underlying move over the hold.
            r = -(mu[j] / mu[i] - 1)
            trades.append((dates[i], dates[j], "short", r))
            eq *= (1 + r)
            equity.append(eq)
            i = j + 1
            continue

        # ---- long engine ----
        # Trailing 252-session (≈1y) high, inclusive of today, then test how
        # far below it price sits.
        hi = max(mu[max(0, i - 252):i + 1])
        dip = mu[i] <= hi * (1 - DIP_PCT / 100)
        if dip and (not use_credit or credit_green(ratio, i)):
            j_target = min(i + HOLD, n - 1)
            j = j_target
            # earnings overlay: exit at print close if hot into a print
            # that falls inside the holding window
            #
            # Strict `i < ei < j_target` skips a print landing exactly on the
            # entry or the natural exit — on the entry bar there is nothing to
            # cut short, and on the exit bar the trade already closes there.
            # `break` takes the first match, i.e. the earliest print, which is
            # the one that would actually stop the trade.
            if use_earnings:
                for d, ei in edates.items():
                    if i < ei < j_target and hot_into(mu, ei):
                        j = ei
                        break
            r = mu[j] / mu[i] - 1
            trades.append((dates[i], dates[j], "long", r))
            eq *= (1 + r)
            equity.append(eq)
            i = j + 1
        else:
            i += 1

    # Max drawdown across the trade-sequence equity curve. Note this walks one
    # point per CLOSED TRADE, not per session, so it cannot see a drawdown that
    # opened and recovered inside a single holding period. It is a floor on the
    # true drawdown, not an estimate of it.
    max_dd = 0.0
    peak = equity[0]
    for e in equity:
        peak = max(peak, e)
        max_dd = min(max_dd, e / peak - 1)
    return trades, eq, max_dd


def report(name, trades, eq, max_dd):
    """Print one variant's summary line plus its full trade blotter.

    Both mean and median are shown because the sample is small enough that one
    outlier trade can carry the mean on its own; a large mean/median gap is the
    signal that the variant's edge rests on very few observations.
    """
    if not trades:
        print(f"{name}: no trades")
        return
    rets = [t[3] for t in trades]
    hit = sum(1 for r in rets if r > 0) / len(rets) * 100
    print(f"\n{name}")
    print(f"  trades={len(trades)}  total={eq - 1:+.1%}  avg={st.mean(rets):+.1%}  "
          f"median={st.median(rets):+.1%}  hit={hit:.0f}%  maxDD(trade-seq)={max_dd:.1%}")
    for t in trades:
        print(f"    {t[2]:5} {t[0]} -> {t[1]}  {t[3]:+.1%}")


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "data/backtest_2025_2026.csv"
    dates, mu, ratio = load(path)
    print(f"MU composite backtest — {dates[0]}..{dates[-1]} ({len(dates)} sessions)")
    # Buy & hold is the bar every variant has to clear. In a secular bull it is
    # a genuinely hard benchmark, and a variant that trails it is telling you
    # the rules cost more than the drawdown they avoided.
    print(f"buy&hold: {mu[-1] / mu[0] - 1:+.1%}")

    # Variants are strictly nested — each adds exactly one rule to the one
    # above — so the difference between consecutive lines isolates that rule.
    for name, uc, ue, us in [
        ("A  dip only",                       False, False, False),
        ("B  dip + credit filter",            True,  False, False),
        ("C  dip + credit + earnings overlay", True,  True,  False),
        ("D  full composite (C + fade short)", True,  True,  True),
    ]:
        trades, eq, dd = run_variant(dates, mu, ratio, uc, ue, us)
        report(name, trades, eq, dd)


if __name__ == "__main__":
    main()
