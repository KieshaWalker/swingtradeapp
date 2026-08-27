from __future__ import annotations

# =============================================================================
# backtests/mu_mfi_obv_windows.py
# =============================================================================
# Same MFI / OBV / combined signals as mu_mfi_obv.py, sliced into calendar
# half-year windows over the full available history (2022-01-03 onward).
#
# Indicators (MFI, OBV, OBV/SMA, and the MFI+OBV confluence state) are
# computed ONCE over the continuous full series, not reset at each window
# boundary -- a signal that fires in the first days of a window because of
# an OBV cross that happened just before the boundary is real and kept; the
# only true warm-up cost (first ~21 sessions with no signal capability) is
# paid once, at the very start of the whole series (H1 2022), not once per
# window.
#
# A window only gates which sessions may START a new trade (dates within
# [window_start, window_end]); a trade's exit can land after the window ends
# since HOLD=10 sessions can cross the boundary. That's noted per-window via
# the buy&hold figure being computed strictly within the window bounds while
# trade exits are not.
#
# Usage: python3 backtests/mu_mfi_obv_windows.py [data/mu_daily_2022_2026.csv]
# =============================================================================
#
# WHAT THIS IS FOR
# ----------------
# mu_mfi_obv.py reports one number per variant over one window, which cannot
# distinguish a real edge from a single lucky regime. Slicing the same signals
# into nine half-years asks the harder question: does the edge PERSIST? Read
# the output down the columns, not across — a variant that wins in seven of
# nine halves is a different proposition from one that wins overall because
# H2 2022 carried it.
#
# The half-years deliberately straddle regimes: the 2022 semiconductor
# drawdown, the 2023-24 AI-driven recovery, and the 2025-26 HBM cycle. A
# mean-reversion signal and a trend-following signal should not be expected to
# perform in the same halves, and the per-window blotter is where that shows.
#
# Note the buy&hold asymmetry called out above: it is measured strictly inside
# the window while trade exits may run past the boundary, so in a window ending
# on a sharp move the comparison is slightly unfair in one direction. It is
# left that way on purpose — clamping exits at the boundary would invent an
# exit rule that the strategy does not have.
#
# NOTE ON THE IMPORT: this pulls from mu_mfi_obv as a TOP-LEVEL module, not a
# package-relative one, so it must be run with backtests/ on sys.path — i.e.
# from inside the backtests/ directory, or with PYTHONPATH=backtests. Running
# `python3 backtests/mu_mfi_obv_windows.py` from the repo root works because
# Python puts the script's own directory on sys.path.
# =============================================================================

import sys

# Everything is reused verbatim from the single-window script so the two
# reports are strictly comparable: same indicator math, same entry rules, same
# position model, same output format. Only the entry gating differs.
from mu_mfi_obv import (
    CONFLUENCE_WINDOW,
    HOLD,
    MFI_PERIOD,
    OBV_SMA_PERIOD,
    compute_mfi,
    compute_obv,
    load,
    mfi_cross,
    obv_cross,
    report,
    run,
    sma,
)

# Calendar half-years. The final window is short — it ends at the last session
# in the dataset rather than 2026-12-31 — so its totals are not comparable in
# magnitude to a full half, only in sign and hit rate.
WINDOWS = [
    ("H1 2022", "2022-01-01", "2022-06-30"),
    ("H2 2022", "2022-07-01", "2022-12-31"),
    ("H1 2023", "2023-01-01", "2023-06-30"),
    ("H2 2023", "2023-07-01", "2023-12-31"),
    ("H1 2024", "2024-01-01", "2024-06-30"),
    ("H2 2024", "2024-07-01", "2024-12-31"),
    ("H1 2025", "2025-01-01", "2025-06-30"),
    ("H2 2025", "2025-07-01", "2025-12-31"),
    ("H1 2026", "2026-01-01", "2026-07-20"),
]


def window_bounds(dates, start_date, end_date):
    """Map a calendar date range onto (first_index, last_index) in `dates`.

    Compares ISO date strings directly, which sorts correctly because the
    format is zero-padded YYYY-MM-DD. Bounds are inclusive on both ends, and
    the window edges need not be trading days — the scan simply picks up the
    first and last sessions that fall inside.

    Returns (None, None) when no session falls in the range, which main()
    treats as "no data" and skips.
    """
    idxs = [i for i, d in enumerate(dates) if start_date <= d <= end_date]
    return (idxs[0], idxs[-1]) if idxs else (None, None)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "data/mu_daily_2022_2026.csv"
    dates, o, h, l, c, v = load(path)
    n = len(dates)
    print(f"MU MFI/OBV windowed backtest — {dates[0]}..{dates[-1]} ({n} sessions), hold={HOLD}d")

    # ── Indicators over the CONTINUOUS series ────────────────────────────────
    # Computed once, before any window slicing. This is the central design
    # decision of the file (see header): a window boundary is a reporting
    # device, not a market event, so an indicator must not forget its history
    # just because the calendar rolled over.
    mfi = compute_mfi(h, l, c, v)
    obv = compute_obv(c, v)
    obv_sma = sma(obv, OBV_SMA_PERIOD)
    warmup = max(MFI_PERIOD, OBV_SMA_PERIOD) + 1

    # combined confluence state, computed once over the continuous series
    # Identical logic to variant C in mu_mfi_obv.py — kept inline rather than
    # imported because that script builds it inside main(). The continuity
    # argument is doubly important here: a cross in late June pairing with one
    # in early July is a real confluence signal that per-window state would
    # destroy.
    combined = [None] * n
    last_mfi = None
    last_obv = None
    for i in range(warmup, n):
        mc = mfi_cross(mfi, i)
        oc = obv_cross(obv, obv_sma, i)
        if mc:
            last_mfi = (i, mc)
        if oc:
            last_obv = (i, oc)
        # Whichever signal fires second triggers, provided the other already
        # fired in the same direction within CONFLUENCE_WINDOW sessions.
        if mc and last_obv and last_obv[1] == mc and i - last_obv[0] <= CONFLUENCE_WINDOW:
            combined[i] = mc
        elif oc and last_mfi and last_mfi[1] == oc and i - last_mfi[0] <= CONFLUENCE_WINDOW:
            combined[i] = oc

    # ── Per-window replay ────────────────────────────────────────────────────
    for name, wstart, wend in WINDOWS:
        lo, hi = window_bounds(dates, wstart, wend)
        if lo is None:
            print(f"\n=== {name}: no data ===")
            continue
        # buy&hold is measured strictly lo..hi, unlike trade exits which may
        # run past hi. See the header note on that asymmetry.
        print(f"\n=== {name}  ({dates[lo]}..{dates[hi]}, {hi - lo + 1} sessions) "
              f"buy&hold={c[hi] / c[lo] - 1:+.1%} ===")

        # Only H1 2022 is actually clipped by `warmup`; every later window
        # starts at its own first session with indicators already warm.
        entry_start = max(lo, warmup)

        def gated(i, lo=lo, hi=hi):
            """True if session i may START a new trade in this window.

            lo and hi are bound as DEFAULT ARGUMENTS rather than captured from
            the enclosing scope on purpose. Python closures capture variables
            by reference, not by value, so a plain closure over the loop
            variables would see whatever lo/hi held at CALL time — which, for
            anything deferred, is the last window in the list. Binding them as
            defaults freezes this window's values at definition time.

            (It happens to be safe here because run() is called immediately
            below, before the loop advances. The defaults keep it correct even
            if a caller ever defers evaluation.)
            """
            return lo <= i <= hi

        # `stop=hi + 1` makes hi the last index that may open a trade; run()
        # treats stop as exclusive. The gated() check is redundant with stop on
        # the upper end but still needed on the lower end, since entry_start
        # can precede lo only in the warm-up case.
        t, eq, dd = run(dates, c, lambda i: mfi_cross(mfi, i) if gated(i) else None,
                         entry_start, stop=hi + 1)
        report("  A  MFI(14) reversal", t, eq, dd)

        t, eq, dd = run(dates, c, lambda i: obv_cross(obv, obv_sma, i) if gated(i) else None,
                         entry_start, stop=hi + 1)
        report("  B  OBV/SMA(20) crossover", t, eq, dd)

        t, eq, dd = run(dates, c, lambda i: combined[i] if gated(i) else None,
                         entry_start, stop=hi + 1)
        report(f"  C  MFI+OBV confluence ({CONFLUENCE_WINDOW}d)", t, eq, dd)


if __name__ == "__main__":
    main()
