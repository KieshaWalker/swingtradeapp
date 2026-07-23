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

import sys

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
    idxs = [i for i, d in enumerate(dates) if start_date <= d <= end_date]
    return (idxs[0], idxs[-1]) if idxs else (None, None)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "data/mu_daily_2022_2026.csv"
    dates, o, h, l, c, v = load(path)
    n = len(dates)
    print(f"MU MFI/OBV windowed backtest — {dates[0]}..{dates[-1]} ({n} sessions), hold={HOLD}d")

    mfi = compute_mfi(h, l, c, v)
    obv = compute_obv(c, v)
    obv_sma = sma(obv, OBV_SMA_PERIOD)
    warmup = max(MFI_PERIOD, OBV_SMA_PERIOD) + 1

    # combined confluence state, computed once over the continuous series
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
        if mc and last_obv and last_obv[1] == mc and i - last_obv[0] <= CONFLUENCE_WINDOW:
            combined[i] = mc
        elif oc and last_mfi and last_mfi[1] == oc and i - last_mfi[0] <= CONFLUENCE_WINDOW:
            combined[i] = oc

    for name, wstart, wend in WINDOWS:
        lo, hi = window_bounds(dates, wstart, wend)
        if lo is None:
            print(f"\n=== {name}: no data ===")
            continue
        print(f"\n=== {name}  ({dates[lo]}..{dates[hi]}, {hi - lo + 1} sessions) "
              f"buy&hold={c[hi] / c[lo] - 1:+.1%} ===")

        entry_start = max(lo, warmup)

        def gated(i, lo=lo, hi=hi):
            return lo <= i <= hi

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
