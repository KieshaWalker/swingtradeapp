from __future__ import annotations
from typing import Optional

# =============================================================================
# backtests/mu_mfi_obv.py
# =============================================================================
# MU 2026 YTD backtest of two volume-based signals, run separately and then
# combined, each expressed as a directional options bet (long call / long
# put) rather than a stock position:
#
#   MFI    Money Flow Index(14) mean-reversion: enter when MFI crosses back
#          OUT of an oversold/overbought extreme (confirms the turn, rather
#          than catching a falling knife the moment it first crosses in).
#            cross 20 from below  -> long call
#            cross 80 from above  -> long put
#
#   OBV    On-Balance Volume trend-following: enter when cumulative OBV
#          crosses its own 20d SMA.
#            OBV crosses above its SMA -> long call
#            OBV crosses below its SMA -> long put
#
#   COMBINED  confluence: take the trade only when an MFI cross and an OBV
#          cross agree on direction within CONFLUENCE_WINDOW sessions of
#          each other (whichever fires second triggers entry).
#
# Direction-scored on the underlying (same convention as mu_composite.py):
# real option P&L pays theta decay + bid/ask spread on top of this, and MU's
# 2026 ATM IV has run 90-110%, so realized option returns on winners will be
# smaller than the underlying return shown here, and losers decay to zero
# faster than the underlying-return column implies. No historical IV surface
# exists in the DB before 2026-06-02, so a real Black-Scholes replay isn't
# possible for the full-year window.
#
# Usage: python3 backtests/mu_mfi_obv.py [data/mu_daily_2026.csv]
# =============================================================================

import csv
import sys
import statistics as st

MFI_PERIOD = 14
MFI_OVERSOLD = 20.0
MFI_OVERBOUGHT = 80.0

OBV_SMA_PERIOD = 20

HOLD = 10               # sessions held per trade (no pyramiding/overlap)
CONFLUENCE_WINDOW = 5    # sessions allowed between an MFI cross and an OBV
                         # cross for the combined variant to treat them as
                         # one confirmed signal


def load(path: str):
    rows = list(csv.DictReader(open(path)))
    dates = [r["date"] for r in rows]
    o = [float(r["open"]) for r in rows]
    h = [float(r["high"]) for r in rows]
    l = [float(r["low"]) for r in rows]
    c = [float(r["close"]) for r in rows]
    v = [float(r["volume"]) for r in rows]
    return dates, o, h, l, c, v


def compute_mfi(h, l, c, v, period=MFI_PERIOD):
    n = len(c)
    tp = [(h[i] + l[i] + c[i]) / 3 for i in range(n)]
    mf = [tp[i] * v[i] for i in range(n)]
    mfi = [None] * n
    for i in range(period, n):
        pos = sum(mf[j] for j in range(i - period + 1, i + 1) if tp[j] > tp[j - 1])
        neg = sum(mf[j] for j in range(i - period + 1, i + 1) if tp[j] < tp[j - 1])
        mfi[i] = 100.0 if neg == 0 else 100 - 100 / (1 + pos / neg)
    return mfi


def compute_obv(c, v):
    n = len(c)
    obv = [0.0] * n
    for i in range(1, n):
        if c[i] > c[i - 1]:
            obv[i] = obv[i - 1] + v[i]
        elif c[i] < c[i - 1]:
            obv[i] = obv[i - 1] - v[i]
        else:
            obv[i] = obv[i - 1]
    return obv


def sma(series, period):
    n = len(series)
    out = [None] * n
    for i in range(period - 1, n):
        out[i] = sum(series[i - period + 1:i + 1]) / period
    return out


def mfi_cross(mfi, i) -> Optional[str]:
    if mfi[i - 1] is None or mfi[i] is None:
        return None
    if mfi[i - 1] < MFI_OVERSOLD <= mfi[i]:
        return "call"
    if mfi[i - 1] > MFI_OVERBOUGHT >= mfi[i]:
        return "put"
    return None


def obv_cross(obv, obv_sma, i) -> Optional[str]:
    if obv_sma[i - 1] is None or obv_sma[i] is None:
        return None
    if obv[i - 1] <= obv_sma[i - 1] and obv[i] > obv_sma[i]:
        return "call"
    if obv[i - 1] >= obv_sma[i - 1] and obv[i] < obv_sma[i]:
        return "put"
    return None


def run(dates, c, signal_fn, start, hold=HOLD, stop=None):
    """signal_fn(i) -> 'call' | 'put' | None. Non-overlapping trades.
    stop: last index (exclusive) a NEW trade may start at; a trade's exit
    (i + hold) may still land past stop. Defaults to len(dates) - 1."""
    n = len(dates)
    stop = n - 1 if stop is None else stop
    trades = []
    equity, eq = [1.0], 1.0
    i = start
    while i < stop:
        side = signal_fn(i)
        if side is not None:
            j = min(i + hold, n - 1)
            underlying_ret = c[j] / c[i] - 1
            r = underlying_ret if side == "call" else -underlying_ret
            trades.append((dates[i], dates[j], side, r))
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
        print(f"\n{name}: no trades")
        return
    rets = [t[3] for t in trades]
    hit = sum(1 for r in rets if r > 0) / len(rets) * 100
    print(f"\n{name}")
    print(f"  trades={len(trades)}  total={eq - 1:+.1%}  avg={st.mean(rets):+.1%}  "
          f"median={st.median(rets):+.1%}  hit={hit:.0f}%  maxDD(trade-seq)={max_dd:.1%}")
    for t in trades:
        print(f"    {t[2]:5} {t[0]} -> {t[1]}  {t[3]:+.1%}")


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "data/mu_daily_2026.csv"
    dates, o, h, l, c, v = load(path)
    n = len(dates)
    print(f"MU MFI/OBV backtest — {dates[0]}..{dates[-1]} ({n} sessions), hold={HOLD}d")
    print(f"buy&hold: {c[-1] / c[0] - 1:+.1%}")

    mfi = compute_mfi(h, l, c, v)
    obv = compute_obv(c, v)
    obv_sma = sma(obv, OBV_SMA_PERIOD)
    start = max(MFI_PERIOD, OBV_SMA_PERIOD) + 1

    # ---- MFI only ----
    t, eq, dd = run(dates, c, lambda i: mfi_cross(mfi, i), start)
    report("A  MFI(14) reversal only", t, eq, dd)

    # ---- OBV only ----
    t, eq, dd = run(dates, c, lambda i: obv_cross(obv, obv_sma, i), start)
    report("B  OBV/SMA(20) crossover only", t, eq, dd)

    # ---- Combined: MFI + OBV confluence within CONFLUENCE_WINDOW sessions ----
    # Cross events are precomputed over the full series (not generated inside
    # run()'s walk), because run() skips days while a trade is open — if the
    # confluence state were tracked lazily inside the walk, a cross that
    # happens during someone else's holding period would silently vanish.
    combined = [None] * n
    last_mfi: Optional[tuple[int, str]] = None
    last_obv: Optional[tuple[int, str]] = None
    for i in range(start, n):
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

    t, eq, dd = run(dates, c, lambda i: combined[i], start)
    report(f"C  MFI + OBV confluence (within {CONFLUENCE_WINDOW}d)", t, eq, dd)


if __name__ == "__main__":
    main()
