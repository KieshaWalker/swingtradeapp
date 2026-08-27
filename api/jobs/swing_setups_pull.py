from __future__ import annotations

# =============================================================================
# jobs/swing_setups_pull.py
# =============================================================================
# Computes swing_setups for the watchlist universe.
# Cron: 40 21 * * 1-5  (weekdays 21:40 UTC — after equity-bars-pull at 21:30)
#
# A FAN-IN JOB. Like focus-digest-pull it fetches nothing from a vendor: it
# reads what earlier jobs wrote and assembles them. That makes its slot a HARD
# DEPENDENCY, not a preference:
#
#   21:00  expected-move-pull   -> expected_move_snapshots   (the 1σ cones)
#   21:30  equity-bars-pull     -> equity_bars               (the OHLCV bars)
#   21:40  swing-setups-pull    -> swing_setups              (this job)
#
# Run it before equity-bars-pull and every channel is fitted to yesterday's
# bars while being labelled with today's date — stale analytics that look fresh
# rather than an error.
#
# ── THE DATE OF A SETUP IS THE DATE OF ITS LAST BAR ──────────────────────────
# obs_date comes from the newest bar in equity_bars, NOT from today's calendar
# date. Those differ constantly: equity-bars-pull drops the in-progress session,
# so a run during market hours sees yesterday's bar as newest. Keying on the
# calendar would file a fit computed from Tuesday's bars under Wednesday and
# then overwrite it, silently, when the job ran again.
#
# ── WHY THE THREE LEGS ARE INDEPENDENT ───────────────────────────────────────
# A missing expected move must not cost the SMA row, and a channel that does not
# fit must not cost the volume read. Each leg is computed and stored on its own;
# a ticker with no channel still produces a row with trend, volume and gamma
# populated and channel_reason explaining the absence. "No channel here" is the
# most common single outcome (about 59% of tickers) and is information.
#
# ── STRUCTURE QUALITY IS NOT A TRADE SIGNAL ──────────────────────────────────
# See migration 082. It ranks how legible a chart is, never which way to trade
# it. Direction is left to the reader and to the dealer-positioning leg, because
# channel position on its own was measured to carry no reliable directional edge
# on this universe.
# =============================================================================

import asyncio
import logging
from datetime import datetime, timezone
from typing import Optional

from core.supabase_client import get_supabase
from jobs.common import get_tickers
from jobs.equity_bars_pull import _INDEX_SYMBOLS
from services.channel_fit import fit_channel
from services.options_confirm import confirm
from services.trend_volume import compute_trend, compute_volume

log = logging.getLogger(__name__)

# Bars fed to the channel fit. ~6 months: long enough to contain several swings,
# short enough that the structure still describes the current market. The 200
# SMA reads the full series separately, so this does not limit it.
_CHANNEL_WINDOW = 120

# Bars pulled per ticker. Covers the 200-SMA window with slack for the slope
# lookback; PostgREST caps a page at 1000 regardless.
_BAR_LIMIT = 400

_HEADLINE_PERIOD = "monthly"


def _quality(channel, trend, vol) -> Optional[float]:
    """0-1 cleanliness of the structure. NOT directional.

    Three components, each capped so no single one can dominate:
      channel confidence   how well evidenced the boundaries are
      participation        whether volume confirms the structure exists
      trend legibility     whether the moving averages agree with each other

    Returns None when there is no channel — the concept does not apply, and a
    0.0 would sort as "bad structure" rather than "no structure".
    """
    if not channel.found or channel.confidence is None:
        return None
    q = 0.6 * channel.confidence

    # Volume confirmation: elevated participation or a surge both indicate the
    # structure is being traded, not drifting on thin air.
    if vol.participation == "elevated" or vol.surge:
        q += 0.2
    elif vol.participation == "normal":
        q += 0.1

    # Trend legibility: an unambiguous 50/200 alignment is easier to act on than
    # a tangle. None (insufficient history) earns nothing rather than being
    # penalised as bearish.
    if trend.sma50_above_200 is not None:
        q += 0.2 if trend.price_above_200 == trend.sma50_above_200 else 0.1

    return round(min(q, 1.0), 4)


def _latest_map(db, table: str, cols: str, extra: Optional[dict] = None) -> dict:
    """Newest row per ticker from a snapshot table.

    Ordered DESCENDING and de-duplicated on first sight, which is the documented
    way around PostgREST's silent 1000-row cap for a "latest per key" read — an
    ascending scan would page through history and truncate before reaching now.
    """
    q = db.table(table).select(cols).order("date", desc=True).limit(1000)
    if extra:
        for k, v in extra.items():
            q = q.eq(k, v)
    rows = (q.execute()).data or []
    out: dict = {}
    for r in rows:
        out.setdefault(r["ticker"], r)
    return out


async def run() -> dict:
    """Assemble swing_setups for every ticker with bars."""
    db = get_supabase()
    # Index symbols never have bars — Schwab cannot serve index history, so
    # equity_bars_pull skips them at the source. Skipping here too keeps a
    # permanent, expected absence out of `failures`, where it would otherwise
    # appear every night and hide a real failure.
    universe = {r["ticker"] for r in get_tickers(db)}
    tickers = sorted(universe - _INDEX_SYMBOLS)
    if not tickers:
        return {"status": "skipped", "reason": "empty_universe", "tickers": 0}

    # Hoisted out of the per-ticker loop: two reads instead of 2N. Same reason
    # expected_move_pull prefetches its RV history — the supabase client is
    # synchronous and a per-ticker .execute() would serialise the whole job.
    em_map = _latest_map(
        db, "expected_move_snapshots",
        "ticker,date,period_type,spot,iv,dte,em_pct",
        {"period_type": _HEADLINE_PERIOD},
    )
    iv_map = _latest_map(
        db, "iv_snapshots",
        "ticker,date,underlying_price,gamma_regime,zero_gamma_level,spot_to_zero_gamma_pct",
    )

    written = 0
    no_channel = 0
    failures: dict = {}
    rows_out = []

    for ticker in tickers:
        try:
            bars = (
                db.table("equity_bars")
                .select("bar_date,high,low,close,volume")
                .eq("ticker", ticker).eq("timeframe", "daily")
                .order("bar_date", desc=True).limit(_BAR_LIMIT)
                .execute()
            ).data or []
        except Exception as exc:
            failures[ticker] = f"bar_read_failed: {exc!r}"[:200]
            continue

        if len(bars) < 30:
            failures[ticker] = f"insufficient_bars:{len(bars)}"
            continue

        # Descending from PostgREST; every consumer downstream assumes oldest
        # first. Reversing here rather than ordering ascending is what keeps the
        # read inside the 1000-row cap while still ending at the newest bar.
        bars.reverse()
        H = [float(b["high"]) for b in bars]
        L = [float(b["low"]) for b in bars]
        C = [float(b["close"]) for b in bars]
        V = [float(b["volume"]) for b in bars if b["volume"] is not None]
        obs_date = bars[-1]["bar_date"]
        spot = C[-1]

        ch = fit_channel(H[-_CHANNEL_WINDOW:], L[-_CHANNEL_WINDOW:], C[-_CHANNEL_WINDOW:])
        tr = compute_trend(C)
        vo = compute_volume(V)
        oc = confirm(spot, ch.breakout_target_up, ch.breakout_target_down,
                     em_map.get(ticker), iv_map.get(ticker))

        if not ch.found:
            no_channel += 1

        rows_out.append({
            "ticker": ticker, "obs_date": obs_date, "spot": spot,
            "channel_found": ch.found, "channel_reason": ch.reason,
            "channel_kind": ch.kind, "channel_direction": ch.direction,
            "channel_upper": ch.upper_now, "channel_lower": ch.lower_now,
            "channel_width_pct": ch.width_pct, "channel_position": ch.position,
            "channel_slope_pct": ch.slope_pct_day,
            "channel_confidence": ch.confidence, "channel_start_idx": ch.start_idx,
            "target_up": ch.breakout_target_up, "target_down": ch.breakout_target_down,
            "channel_lines": (
                {"upper": ch.upper.__dict__, "lower": ch.lower.__dict__}
                if ch.found else None
            ),
            "sma50": tr.sma50, "sma200": tr.sma200,
            "pct_to_sma50": tr.pct_to_sma50, "pct_to_sma200": tr.pct_to_sma200,
            "sma50_above_200": tr.sma50_above_200,
            "sma50_slope_pct": tr.sma50_slope_pct,
            "sma200_slope_pct": tr.sma200_slope_pct,
            "volume": int(vo.volume) if vo.volume else None,
            "vol_sma30": vo.vol_sma30, "vol_sma50": vo.vol_sma50,
            "vol_ratio": vo.vol_ratio, "vol_z": vo.vol_z,
            "vol_surge": vo.surge, "participation": vo.participation,
            "em_pct": oc.em_pct, "em_iv": oc.em_iv, "em_dte": oc.em_dte,
            "em_date": oc.em_date,
            "em_ratio_up": oc.em_ratio_up, "em_ratio_down": oc.em_ratio_down,
            "implied_days_up": oc.implied_days_up,
            "implied_days_down": oc.implied_days_down,
            "reachable_up": oc.reachable_up,
            "reachable_down": oc.reachable_down,
            "gamma_regime": oc.gamma_regime,
            "zero_gamma_level": oc.zero_gamma_level,
            "spot_to_zgl_pct": oc.spot_to_zero_gamma_pct,
            "dealer_posture": oc.dealer_posture,
            "breakout_supported": oc.breakout_supported,
            "iv_date": oc.iv_date,
            "bars_used": ch.bars_used,
            "structure_quality": _quality(ch, tr, vo),
            "computed_at": datetime.now(timezone.utc).isoformat(),
        })

    if rows_out:
        try:
            db.table("swing_setups").upsert(
                rows_out, on_conflict="ticker,obs_date"
            ).execute()
            written = len(rows_out)
        except Exception as exc:
            log.error("swing_setups_upsert_failed error=%r", exc)
            failures["_upsert"] = f"{exc!r}"[:300]

    log.info("swing_setups_done tickers=%d written=%d no_channel=%d failed=%d",
             len(tickers), written, no_channel, len(failures))
    return {
        "status": "ok" if written else "failed",
        "tickers": len(tickers),
        "rows_written": written,
        "no_channel": no_channel,
        "failed": len(failures),
        "failures": failures,
    }
