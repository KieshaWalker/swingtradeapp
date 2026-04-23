# =============================================================================
# services/greek_interpreter.py
# =============================================================================
# Narrative signal generation from Greek grid and chart data.
#
# interpret_greek_grid  — GreekGridSnapshot + all GreekGridPoints
# interpret_greek_chart — ATM GreekSnapshot time-series for one DTE bucket
#
# Both return an InterpretationResult dict with:
#   headline, headline_signal, today: [...], period: [...], period_obs
# =============================================================================
from __future__ import annotations

from typing import Any

# ── Signal constants ──────────────────────────────────────────────────────────

NEUTRAL  = "neutral"
BULLISH  = "bullish"
BEARISH  = "bearish"
CAUTION  = "caution"

# strike_band db values
ATM  = "atm"
OTM  = "otm"

# expiry_bucket db values
WEEKLY       = "weekly"
NEAR_MONTHLY = "near_monthly"
MONTHLY      = "monthly"
FAR_MONTHLY  = "far_monthly"
QUARTERLY    = "quarterly"


def _line(label: str, text: str, signal: str) -> dict:
    return {"label": label, "text": text, "signal": signal}


def _pct(v: float) -> str:
    return f"{v * 100:.1f}%"


def _pp(v: float) -> str:
    return f"{v * 100:.1f}pp"


def _greek_fmt(v: float) -> str:
    if abs(v) < 0.001:
        return f"{v:.2e}"
    return f"{v:.3f}"


def _build_result(
    today: list[dict],
    period: list[dict],
    n_obs: int,
) -> dict:
    if not today and not period:
        return {
            "headline":        "Not enough data — load the options chain to begin tracking.",
            "headline_signal": NEUTRAL,
            "today":           today,
            "period":          period,
            "period_obs":      n_obs,
        }

    priority_order = [CAUTION, BEARISH, BULLISH, NEUTRAL]
    top = None
    for sig in priority_order:
        for line in today:
            if line["signal"] == sig:
                top = line
                break
        if top:
            break
    if top is None:
        top = today[0]

    text_parts = top["text"].split("—")
    suffix = text_parts[-1].strip().split(".")[0] if len(text_parts) > 1 else top["text"].split(".")[0]
    headline = f"{top['label']} — {suffix}."

    return {
        "headline":        headline,
        "headline_signal": top["signal"],
        "today":           today,
        "period":          period,
        "period_obs":      n_obs,
    }


# ── Greek Grid interpreter ────────────────────────────────────────────────────

def interpret_greek_grid(
    grid_cells: list[dict[str, Any]],
) -> dict:
    """
    grid_cells: list of GreekGridPoint.toJson() maps.
      Each cell has: strike_band, expiry_bucket, obs_date,
                     iv, gamma, delta, vanna, charm, volga
    Returns an InterpretationResult dict.
    """
    today:  list[dict] = []
    period: list[dict] = []

    # Build a lookup: (strike_band, expiry_bucket) → cell (newest obs_date wins)
    cells_by_date: dict[str, list[dict]] = {}
    for row in grid_cells:
        d = row.get("obs_date", "")
        cells_by_date.setdefault(d, []).append(row)

    if not cells_by_date:
        return _build_result([], [], 0)

    latest_date = max(cells_by_date.keys())
    latest_cells = cells_by_date[latest_date]

    cell_map: dict[tuple[str, str], dict] = {
        (c["strike_band"], c["expiry_bucket"]): c for c in latest_cells
    }

    def cell(band: str, bucket: str) -> dict | None:
        return cell_map.get((band, bucket))

    # ── TODAY ──────────────────────────────────────────────────────────────────

    # 1. IV Term Structure
    short_c = cell(ATM, WEEKLY) or cell(ATM, NEAR_MONTHLY)
    long_c  = (cell(ATM, QUARTERLY) or cell(ATM, FAR_MONTHLY) or cell(ATM, MONTHLY))
    short_iv = short_c.get("iv") if short_c else None
    long_iv  = long_c.get("iv")  if long_c  else None

    if short_iv and long_iv and short_iv > 0 and long_iv > 0:
        spread = (short_iv - long_iv) * 100
        if spread > 3:
            today.append(_line(
                "IV Term Structure",
                f"Inverted — short-term IV ({_pct(short_iv)}) exceeds long-term "
                f"({_pct(long_iv)}) by {spread:.1f}pp. Near-term event premium is priced in.",
                CAUTION,
            ))
        elif spread < -3:
            today.append(_line(
                "IV Term Structure",
                f"Normal — long-term IV ({_pct(long_iv)}) > short-term "
                f"({_pct(short_iv)}). Market pricing stability near-term.",
                NEUTRAL,
            ))
        else:
            today.append(_line(
                "IV Term Structure",
                f"Flat — short ({_pct(short_iv)}) ≈ long ({_pct(long_iv)}). "
                "Uncertainty distributed evenly across expirations.",
                NEUTRAL,
            ))

    # 2. Gamma Peak
    peak_cell: dict | None = None
    peak_gamma = 0.0
    all_bands   = [ATM, OTM, "itm", "deep_itm", "deep_otm"]
    all_buckets = [WEEKLY, NEAR_MONTHLY, MONTHLY, FAR_MONTHLY, QUARTERLY]
    for band in all_bands:
        for bucket in all_buckets:
            c = cell(band, bucket)
            if c and c.get("gamma") is not None and abs(c["gamma"]) > peak_gamma:
                peak_gamma = abs(c["gamma"])
                peak_cell  = c

    if peak_cell and peak_gamma > 0:
        is_atm   = peak_cell["strike_band"] == ATM
        is_short = peak_cell["expiry_bucket"] in (WEEKLY, NEAR_MONTHLY)
        if is_atm and is_short:
            risk = "Binary outcome risk elevated — price pinned near ATM into near-term expiry."
        elif is_atm:
            risk = "Elevated delta hedging pressure on large moves from ATM."
        else:
            risk = "Off-centre concentration — less pin risk; ITM/OTM acceleration elevated."

        band_label   = peak_cell["strike_band"].replace("_", " ").title()
        bucket_label = peak_cell["expiry_bucket"].replace("_", " ").title()
        today.append(_line(
            "Gamma Peak",
            f"{band_label} · {bucket_label}  (Γ {peak_gamma:.4f}).  {risk}",
            CAUTION if is_atm and is_short else NEUTRAL,
        ))

    # 3. Skew Bias
    ref_bucket = NEAR_MONTHLY if cell(OTM, NEAR_MONTHLY) else MONTHLY
    otm_c = cell(OTM, ref_bucket)
    otm_delta = otm_c.get("delta") if otm_c else None
    if otm_delta is not None:
        if otm_delta > 0.05:
            today.append(_line(
                "Skew Bias",
                f"Call-side demand dominant — net OTM delta +{otm_delta:.2f}. "
                "Bullish positioning in out-of-the-money strikes.",
                BULLISH,
            ))
        elif otm_delta < -0.05:
            today.append(_line(
                "Skew Bias",
                f"Put-side hedging elevated — net OTM delta {otm_delta:.2f}. "
                "Bearish protection being built in OTM options.",
                BEARISH,
            ))

    # 4. Vanna
    atm_c = cell(ATM, NEAR_MONTHLY) or cell(ATM, MONTHLY)
    vanna = atm_c.get("vanna") if atm_c else None
    if vanna is not None and abs(vanna) > 0.002:
        if vanna < -0.005:
            today.append(_line(
                "Vanna",
                f"Negative ATM vanna ({vanna:.3f}) — rising IV will erode call delta. "
                "Vol expansion is a headwind for long calls.",
                CAUTION,
            ))
        elif vanna > 0.005:
            today.append(_line(
                "Vanna",
                f"Positive ATM vanna (+{vanna:.3f}) — rising IV lifts call delta. "
                "Vol expansion supports long call positions.",
                BULLISH,
            ))

    # 5. Charm (Weekly)
    weekly_c = cell(ATM, WEEKLY)
    charm = weekly_c.get("charm") if weekly_c else None
    if charm is not None and abs(charm) > 0.01:
        direction = "decaying toward" if charm < 0 else "drifting away from"
        accel     = "Expiry dynamics accelerating." if abs(charm) > 0.05 else "Normal near-expiry erosion."
        today.append(_line(
            "Charm (Weekly)",
            f"ATM weekly charm {charm:.3f} — delta {direction} ATM at "
            f"{abs(charm):.3f}/day. {accel}",
            CAUTION if abs(charm) > 0.05 else NEUTRAL,
        ))

    # ── PERIOD ─────────────────────────────────────────────────────────────────

    # ATM time-series from all dates (monthly preferred)
    atm_series = sorted(
        [c for c in grid_cells if c["strike_band"] == ATM and c["expiry_bucket"] == MONTHLY],
        key=lambda c: c["obs_date"],
    )
    if len(atm_series) < 2:
        atm_series = sorted(
            [c for c in grid_cells if c["strike_band"] == ATM and c["expiry_bucket"] in (MONTHLY, NEAR_MONTHLY)],
            key=lambda c: c["obs_date"],
        )

    all_dates = len({c["obs_date"] for c in grid_cells})

    if len(atm_series) >= 2:
        first = atm_series[0]
        last  = atm_series[-1]

        # IV trend
        first_iv = first.get("iv")
        last_iv  = last.get("iv")
        if first_iv and last_iv and first_iv > 0:
            chg = (last_iv - first_iv) / first_iv * 100
            label = "Expanding" if chg > 5 else "Compressing" if chg < -5 else "Stable"
            period.append(_line(
                "IV Trend",
                f"{label} — ATM IV {_pct(first_iv)} → {_pct(last_iv)} "
                f"({'+' if chg >= 0 else ''}{chg:.1f}%) over {all_dates} observation{'s' if all_dates != 1 else ''}.",
                CAUTION if chg > 5 else BULLISH if chg < -5 else NEUTRAL,
            ))

        # Gamma trend
        first_g = first.get("gamma")
        last_g  = last.get("gamma")
        if first_g and last_g and first_g > 0:
            chg = (last_g - first_g) / first_g * 100
            if abs(chg) > 15:
                detail = (
                    "risk density building near ATM; market accumulating near-money strikes"
                    if chg > 0 else
                    "gamma dispersing from ATM; underlying moving away from current strikes"
                )
                period.append(_line(
                    "Gamma Trend",
                    f"{'Rising' if chg > 0 else 'Falling'} {abs(chg):.0f}% — {detail}.",
                    CAUTION if chg > 0 else NEUTRAL,
                ))

        # Volga trend
        first_vg = first.get("volga")
        last_vg  = last.get("volga")
        if first_vg is not None and last_vg is not None and abs(first_vg) > 1e-6:
            chg = (abs(last_vg) - abs(first_vg)) / abs(first_vg) * 100
            if chg > 20:
                period.append(_line(
                    "Volga (Vol-of-Vol)",
                    f"Rising {chg:.0f}% — market paying more for vol convexity. "
                    "Uncertainty about the volatility regime is expanding.",
                    CAUTION,
                ))
            elif chg < -20:
                period.append(_line(
                    "Volga (Vol-of-Vol)",
                    f"Compressing {abs(chg):.0f}% — vol-of-vol declining. "
                    "Market becoming comfortable with the current vol regime.",
                    NEUTRAL,
                ))

        # Vanna structural shift
        first_vn = first.get("vanna")
        last_vn  = last.get("vanna")
        if first_vn is not None and last_vn is not None:
            if first_vn > 0.002 and last_vn < -0.002:
                period.append(_line(
                    "Vanna Shift",
                    "Flipped negative over period — IV–delta relationship reversed. "
                    "Rising vol now suppresses call delta; hedging flow is building.",
                    CAUTION,
                ))
            elif first_vn < -0.002 and last_vn > 0.002:
                period.append(_line(
                    "Vanna Shift",
                    "Flipped positive over period — rising vol now supports call delta. "
                    "Hedging flow becoming structurally supportive.",
                    BULLISH,
                ))

    return _build_result(today, period, all_dates)


# ── Greek Chart interpreter ────────────────────────────────────────────────────

def interpret_greek_chart(
    chart_history: list[dict[str, Any]],
    dte_bucket: int,
) -> dict:
    """
    chart_history: list of GreekSnapshot.toJson() maps, oldest → newest.
      Each has: call_delta, call_gamma, call_theta, call_vega, call_iv, put_iv, ...
    dte_bucket: the target DTE (4, 7, or 31)
    Returns an InterpretationResult dict.
    """
    if not chart_history:
        return {
            "headline":        "No data yet.",
            "headline_signal": NEUTRAL,
            "today":           [],
            "period":          [],
            "period_obs":      0,
        }

    today:  list[dict] = []
    period: list[dict] = []
    latest = chart_history[-1]

    # ── TODAY ──────────────────────────────────────────────────────────────────

    # 1. IV Skew
    call_iv = latest.get("call_iv")
    put_iv  = latest.get("put_iv")
    if call_iv and put_iv and call_iv > 0 and put_iv > 0:
        skew_pp = (put_iv - call_iv) * 100
        if skew_pp > 2.5:
            today.append(_line(
                "IV Skew",
                f"Put IV ({_pct(put_iv)}) > Call IV ({_pct(call_iv)}) by "
                f"{skew_pp:.1f}pp — protective put demand elevated. "
                f"Bearish hedging above normal for {dte_bucket} DTE.",
                BEARISH,
            ))
        elif skew_pp < -1.5:
            today.append(_line(
                "IV Skew",
                f"Call IV ({_pct(call_iv)}) > Put IV ({_pct(put_iv)}) by "
                f"{abs(skew_pp):.1f}pp — positive call skew unusual. "
                "May reflect takeover speculation or short-squeeze positioning.",
                CAUTION,
            ))
        else:
            today.append(_line(
                "IV Skew",
                f"Neutral — call IV ({_pct(call_iv)}) ≈ put IV ({_pct(put_iv)}). "
                f"Balanced hedging demand at {dte_bucket} DTE.",
                NEUTRAL,
            ))

    # 2. Gamma percentile
    all_gammas = sorted(s["call_gamma"] for s in chart_history if s.get("call_gamma") is not None)
    latest_gamma = latest.get("call_gamma")
    if latest_gamma is not None and all_gammas:
        rank   = sum(1 for g in all_gammas if g <= latest_gamma)
        pctile = round(rank / len(all_gammas) * 100)
        is_high = pctile >= 80
        today.append(_line(
            "Gamma",
            f"ATM call gamma at {pctile}th percentile of "
            f"{len(chart_history)}-session history ({latest_gamma:.4f}). "
            + ("Above-average risk density — strong delta hedging flows expected on large moves."
               if is_high else "Within normal range."),
            CAUTION if is_high else NEUTRAL,
        ))

    # 3. Theta / Vega efficiency
    call_theta = latest.get("call_theta")
    call_vega  = latest.get("call_vega")
    if call_theta is not None and call_vega is not None and abs(call_vega) > 0.001:
        ratio = abs(call_theta) / abs(call_vega)
        if ratio > 0.5:
            today.append(_line(
                "Theta / Vega",
                f"Ratio {ratio:.2f} — theta ({_greek_fmt(call_theta)}/day) heavy vs "
                f"vega ({_greek_fmt(call_vega)}/1% IV). Premium selling efficient at this DTE.",
                NEUTRAL,
            ))
        else:
            today.append(_line(
                "Theta / Vega",
                f"Ratio {ratio:.2f} — vega ({_greek_fmt(call_vega)}/1% IV) dominates "
                f"theta ({_greek_fmt(call_theta)}/day). Long-vol position favored over premium capture.",
                NEUTRAL,
            ))

    # 4. Delta drift
    call_delta = latest.get("call_delta")
    if call_delta is not None:
        if call_delta > 0.58:
            today.append(_line(
                "Delta",
                f"ATM call delta {call_delta:.2f} — stock has rallied above the tracked strike (now ITM). "
                "Consider rolling up to restore ATM exposure.",
                CAUTION,
            ))
        elif call_delta < 0.40:
            today.append(_line(
                "Delta",
                f"ATM call delta {call_delta:.2f} — stock has fallen below the tracked strike (now OTM). "
                "Position losing directional sensitivity.",
                BEARISH,
            ))
        else:
            today.append(_line(
                "Delta",
                f"ATM call delta {call_delta:.2f} — strike remains near fair value. Position well-centred.",
                NEUTRAL,
            ))

    # ── PERIOD ─────────────────────────────────────────────────────────────────

    if len(chart_history) >= 2:
        first = chart_history[0]
        n     = len(chart_history)

        # IV direction
        first_call_iv  = first.get("call_iv")
        latest_call_iv = latest.get("call_iv")
        if first_call_iv and latest_call_iv and first_call_iv > 0:
            chg = (latest_call_iv - first_call_iv) / first_call_iv * 100
            label = "Expanding" if chg > 8 else "Compressing" if chg < -8 else "Stable"
            period.append(_line(
                "IV Direction",
                f"{label} — call IV {_pct(first_call_iv)} → {_pct(latest_call_iv)} "
                f"({'+' if chg >= 0 else ''}{chg:.1f}%) over {n} sessions.",
                CAUTION if chg > 8 else BULLISH if chg < -8 else NEUTRAL,
            ))

        # Gamma structural change
        first_gamma  = first.get("call_gamma")
        latest_gamma = latest.get("call_gamma")
        if first_gamma and latest_gamma and first_gamma > 0:
            chg = (latest_gamma - first_gamma) / first_gamma * 100
            if abs(chg) > 20:
                detail = (
                    "increasing concentration near ATM; approaching gamma risk zone"
                    if chg > 0 else
                    "gamma dispersing; reduced binary risk at current strikes"
                )
                period.append(_line(
                    "Gamma Trend",
                    f"{'Rising' if chg > 0 else 'Falling'} {abs(chg):.0f}% — {detail}.",
                    CAUTION if chg > 0 else NEUTRAL,
                ))

        # Put/Call skew spread
        first_skew  = (first.get("put_iv",  0) or 0) - (first.get("call_iv",  0) or 0)
        latest_skew = (latest.get("put_iv", 0) or 0) - (latest.get("call_iv", 0) or 0)
        skew_change = latest_skew - first_skew
        if skew_change > 0.02:
            period.append(_line(
                "Put/Call IV Spread",
                f"Widening ({_pp(first_skew)} → {_pp(latest_skew)}) over {n} sessions — "
                "growing bearish hedging demand. Downside risk perception increasing.",
                BEARISH,
            ))
        elif skew_change < -0.02:
            period.append(_line(
                "Put/Call IV Spread",
                f"Narrowing ({_pp(first_skew)} → {_pp(latest_skew)}) over {n} sessions — "
                "downside hedging demand easing. Sentiment becoming less defensive.",
                BULLISH,
            ))

        # Delta range
        deltas = [s["call_delta"] for s in chart_history if s.get("call_delta") is not None]
        if len(deltas) >= 3:
            lo = min(deltas)
            hi = max(deltas)
            if hi - lo > 0.15:
                trended = deltas[-1] > deltas[0]
                period.append(_line(
                    "Delta Range",
                    f"Wide ({lo:.2f} – {hi:.2f}) — underlying {'rallied' if trended else 'declined'} "
                    "significantly through tracked period. Strike position shifted relative to spot.",
                    BULLISH if trended else BEARISH,
                ))
            else:
                period.append(_line(
                    "Delta Range",
                    f"Contained ({lo:.2f} – {hi:.2f}) — underlying held near the tracked strike through the period.",
                    NEUTRAL,
                ))

    return _build_result(today, period, len(chart_history))
