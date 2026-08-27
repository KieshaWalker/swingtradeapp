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
#
# WHY THESE TWO SIGNALS TOGETHER
# ------------------------------
# They are deliberately opposed in character, which is what makes the
# confluence variant informative rather than redundant:
#
#   MFI is MEAN-REVERTING  — it fires against the recent move, betting an
#                            exhausted extreme snaps back.
#   OBV is TREND-FOLLOWING — it fires with the move, betting accumulation or
#                            distribution continues.
#
# Two signals with opposite theories agreeing on the same direction within a
# few sessions is a much stronger statement than either alone: it means price
# reached an extreme AND volume has already begun rotating the other way.
# Variant C is the test of whether that stricter, rarer condition actually
# pays enough to justify the trades it gives up.
#
# This module is also imported as a library by mu_mfi_obv_windows.py, which
# reuses load/compute_*/(*_cross)/run/report verbatim to run the same signals
# over half-year slices. Changing a signature here changes that file too.
# =============================================================================

import csv
import sys
import statistics as st

# ── Tunables ─────────────────────────────────────────────────────────────────
MFI_PERIOD = 14          # standard MFI lookback
MFI_OVERSOLD = 20.0      # below this = washed out; a cross back up is the buy
MFI_OVERBOUGHT = 80.0    # above this = overheated; a cross back down is the sell

OBV_SMA_PERIOD = 20      # trend baseline OBV is measured against

HOLD = 10               # sessions held per trade (no pyramiding/overlap)
CONFLUENCE_WINDOW = 5    # sessions allowed between an MFI cross and an OBV
                         # cross for the combined variant to treat them as
                         # one confirmed signal


def load(path: str):
    """Read a daily OHLCV CSV into parallel per-session lists.

    Expects columns: date, open, high, low, close, volume — one row per
    session, sorted ascending by date. Everything downstream indexes by
    position and treats index-1 as "the prior session", so unsorted or
    gap-filled input would silently corrupt every indicator.

    Returns (dates, open, high, low, close, volume).
    """
    rows = list(csv.DictReader(open(path)))
    dates = [r["date"] for r in rows]
    o = [float(r["open"]) for r in rows]
    h = [float(r["high"]) for r in rows]
    l = [float(r["low"]) for r in rows]
    c = [float(r["close"]) for r in rows]
    v = [float(r["volume"]) for r in rows]
    return dates, o, h, l, c, v


def compute_mfi(h, l, c, v, period=MFI_PERIOD):
    """Money Flow Index — a volume-weighted RSI.

    Three steps:
      1. Typical price  tp = (high + low + close) / 3, a fuller picture of
         where the session actually traded than the close alone.
      2. Raw money flow mf = tp * volume, i.e. dollars that changed hands.
      3. Split the last `period` sessions' money flow by whether typical price
         rose or fell versus the prior session, then:
             MFI = 100 - 100 / (1 + pos/neg)
         which maps the positive/negative flow ratio onto 0-100.

    Sessions where tp is exactly unchanged count toward neither side — that is
    the standard definition, and it is why pos + neg does not have to equal the
    window's total flow.

    The `neg == 0` branch returns 100.0 rather than dividing by zero: no
    outflow at all in the whole window is the maximum possible reading.

    Returns a list aligned to the input with None for the first `period`
    entries, where the lookback is incomplete. Callers must treat None as
    "no reading", not as zero.
    """
    n = len(c)
    tp = [(h[i] + l[i] + c[i]) / 3 for i in range(n)]
    mf = [tp[i] * v[i] for i in range(n)]
    mfi = [None] * n
    # Start at `period` so the trailing window is full, and so the j-1 lookback
    # inside the comprehensions below never reaches a negative index.
    for i in range(period, n):
        pos = sum(mf[j] for j in range(i - period + 1, i + 1) if tp[j] > tp[j - 1])
        neg = sum(mf[j] for j in range(i - period + 1, i + 1) if tp[j] < tp[j - 1])
        mfi[i] = 100.0 if neg == 0 else 100 - 100 / (1 + pos / neg)
    return mfi


def compute_obv(c, v):
    """On-Balance Volume — a running total of volume signed by close direction.

    Add the full session's volume on an up close, subtract it on a down close,
    carry unchanged on a flat close. The idea is that volume commits before
    price does, so the OBV line turning while price has not is evidence of
    accumulation or distribution underway.

    Only the level's *direction* is meaningful. The series starts at an
    arbitrary 0.0 at index 0, so the absolute value carries no information —
    which is exactly why obv_cross() compares it against its own moving
    average rather than any fixed threshold.
    """
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
    """Trailing simple moving average, aligned to the input.

    Entry i averages the `period` values ending at i (inclusive), so it uses no
    future data. The first period-1 entries are None because the window is
    incomplete — callers must None-check rather than assume a number.
    """
    n = len(series)
    out = [None] * n
    for i in range(period - 1, n):
        out[i] = sum(series[i - period + 1:i + 1]) / period
    return out


def mfi_cross(mfi, i) -> Optional[str]:
    """Did MFI cross back OUT of an extreme on session i?

    Returns 'call', 'put', or None.

    The direction here is the mean-reversion bet: leaving oversold from below
    is the long signal, leaving overbought from above is the short signal.
    Crossing *into* an extreme is deliberately ignored — that is the falling
    knife, and requiring the exit cross is what makes this a confirmed turn.

    Reads mfi[i-1], so callers must pass i >= 1, and returns None whenever
    either reading is still in MFI's warm-up window.
    """
    if mfi[i - 1] is None or mfi[i] is None:
        return None
    # Chained comparison: strictly below the threshold yesterday, at or above
    # it today. The boundary is inclusive on today's side so a cross that lands
    # exactly on 20.0 still counts.
    if mfi[i - 1] < MFI_OVERSOLD <= mfi[i]:
        return "call"
    if mfi[i - 1] > MFI_OVERBOUGHT >= mfi[i]:
        return "put"
    return None


def obv_cross(obv, obv_sma, i) -> Optional[str]:
    """Did OBV cross its own moving average on session i?

    Returns 'call', 'put', or None. This is the trend-following signal: volume
    momentum breaking above its own baseline is the long, breaking below is the
    short.

    The <= / > asymmetry (and its mirror) is what makes this fire exactly once
    per crossing. Requiring "at or below yesterday, strictly above today" means
    a session that merely touches the average cannot count as a cross, and a
    line riding along its average cannot re-trigger every day.
    """
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
    (i + hold) may still land past stop. Defaults to len(dates) - 1.

    The generic driver shared by all three variants (and by the windowed
    script), so each variant differs only in the signal_fn passed in.

    Position model: one trade at a time, held a fixed `hold` sessions, with the
    cursor jumping to j + 1 on exit. A signal firing while a position is open
    is dropped, not queued — so the variants are not just filtered versions of
    each other, and a noisier signal genuinely occupies capital that a cleaner
    one would have used elsewhere.

    P&L convention: 'call' earns the underlying's move over the hold, 'put'
    earns its negation. This is DIRECTION ONLY — no premium, no theta, no
    spread (see the module header for why that flatters both sides).
    """
    n = len(dates)
    stop = n - 1 if stop is None else stop
    trades = []
    equity, eq = [1.0], 1.0
    i = start
    while i < stop:
        side = signal_fn(i)
        if side is not None:
            # Clamp the exit to the last available session so a signal near the
            # end of the series still resolves rather than running off the data.
            j = min(i + hold, n - 1)
            underlying_ret = c[j] / c[i] - 1
            r = underlying_ret if side == "call" else -underlying_ret
            trades.append((dates[i], dates[j], side, r))
            eq *= (1 + r)
            equity.append(eq)
            i = j + 1
        else:
            i += 1
    # Trade-sequence drawdown: one equity point per closed trade, so drawdown
    # that opened and healed inside a holding period is invisible here.
    max_dd = 0.0
    peak = equity[0]
    for e in equity:
        peak = max(peak, e)
        max_dd = min(max_dd, e / peak - 1)
    return trades, eq, max_dd


def report(name, trades, eq, max_dd):
    """Print one variant's summary line plus its full trade blotter.

    Mean and median are both shown because these samples are small; a wide gap
    between them means the variant's total rests on one or two trades.
    """
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

    # Indicators are computed once over the whole series and shared by all
    # three variants, so A, B and C see byte-identical inputs.
    mfi = compute_mfi(h, l, c, v)
    obv = compute_obv(c, v)
    obv_sma = sma(obv, OBV_SMA_PERIOD)
    # First index where BOTH indicators have a reading and a prior reading to
    # compare against: the slower of the two warm-ups, plus one for the i-1
    # lookback inside the cross functions.
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
    # Most recent cross of each type, as (index, side). These persist across
    # the whole walk; the CONFLUENCE_WINDOW age check below is what expires
    # them, so a stale cross from months ago can never pair with a new one.
    last_mfi: Optional[tuple[int, str]] = None
    last_obv: Optional[tuple[int, str]] = None
    for i in range(start, n):
        mc = mfi_cross(mfi, i)
        oc = obv_cross(obv, obv_sma, i)
        if mc:
            last_mfi = (i, mc)
        if oc:
            last_obv = (i, oc)
        # Symmetric pairing: whichever signal fires SECOND triggers the entry,
        # provided the other one already fired in the same direction within the
        # window. Note last_mfi/last_obv were just updated above, so on a
        # session where both fire, each branch sees the other's fresh cross at
        # distance 0 and the first branch wins — the two branches agree on the
        # side anyway, so the elif only ever picks the direction once.
        if mc and last_obv and last_obv[1] == mc and i - last_obv[0] <= CONFLUENCE_WINDOW:
            combined[i] = mc
        elif oc and last_mfi and last_mfi[1] == oc and i - last_mfi[0] <= CONFLUENCE_WINDOW:
            combined[i] = oc

    t, eq, dd = run(dates, c, lambda i: combined[i], start)
    report(f"C  MFI + OBV confluence (within {CONFLUENCE_WINDOW}d)", t, eq, dd)


if __name__ == "__main__":
    main()
