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

import csv
import sys
import statistics as st

DIP_PCT = 15.0
HOLD = 20
CREDIT_RED = -1.0       # HYG/IEF 20d %; below this = credit deteriorating
HOT_RUNUP = 10.0        # % gain over 21 sessions into a print = "hot"
SHORT_HOLD = 5

# MU report dates inside the data window (all post-close)
EARNINGS = ["2025-03-20", "2025-06-25", "2025-09-23", "2025-12-17",
            "2026-03-18", "2026-06-24"]


def load(path: str):
    rows = list(csv.DictReader(open(path)))
    dates = [r["date"] for r in rows]
    mu = [float(r["mu"]) for r in rows]
    ratio = [float(r["hyg"]) / float(r["ief"]) for r in rows]
    return dates, mu, ratio


def credit_green(ratio, i) -> bool:
    if i < 20:
        return True
    return (ratio[i] / ratio[i - 20] - 1) * 100 >= CREDIT_RED


def hot_into(mu, i) -> Optional[bool]:
    """Was the stock 'hot' (>= HOT_RUNUP% over 21 sessions) at index i?"""
    if i < 21:
        return None
    return (mu[i] / mu[i - 21] - 1) * 100 >= HOT_RUNUP


def run_variant(dates, mu, ratio, use_credit, use_earnings, use_short):
    n = len(dates)
    edates = {d: dates.index(d) for d in EARNINGS if d in dates}
    trades = []           # (entry_date, exit_date, side, ret)
    equity, eq = [1.0], 1.0
    i = 60
    while i < n - 1:
        # ---- earnings-fade short sleeve (independent of long engine) ----
        if use_short and dates[i] in edates and hot_into(mu, i):
            j = min(i + SHORT_HOLD, n - 1)
            r = -(mu[j] / mu[i] - 1)
            trades.append((dates[i], dates[j], "short", r))
            eq *= (1 + r)
            equity.append(eq)
            i = j + 1
            continue

        # ---- long engine ----
        hi = max(mu[max(0, i - 252):i + 1])
        dip = mu[i] <= hi * (1 - DIP_PCT / 100)
        if dip and (not use_credit or credit_green(ratio, i)):
            j_target = min(i + HOLD, n - 1)
            j = j_target
            # earnings overlay: exit at print close if hot into a print
            # that falls inside the holding window
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

    max_dd = 0.0
    peak = equity[0]
    for e in equity:
        peak = max(peak, e)
        max_dd = min(max_dd, e / peak - 1)
    return trades, eq, max_dd


def report(name, trades, eq, max_dd):
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
    print(f"buy&hold: {mu[-1] / mu[0] - 1:+.1%}")

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
