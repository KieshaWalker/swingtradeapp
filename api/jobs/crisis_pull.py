from __future__ import annotations
from typing import Optional

# =============================================================================
# jobs/crisis_pull.py
# =============================================================================
# Job — Market-level crisis-signal checklist → upsert crisis_checklist_snapshots.
# Cron: 10 21 * * 1-5  (16:10 ET close-capture, Mon-Fri; idempotent upsert)
#
# Scores the recurring pre-crisis signals calibrated on 13 historical crises
# (1873-2022; see data/crisis_checklist_2026-07-16.md for derivation):
#   structural: index-at-highs, valuation (CAPE), leverage (margin debt),
#               speculative-tier crack
#   catalysts:  Fed tightening, curve inversion, public-credit turn,
#               private-credit stress, breadth failure
#
# Sources:
#   FRED (via get-fred-data edge function): HY/IG OAS, T10Y2Y, DFF, CPI
#   Schwab closes (via get-schwab-pricehistory): SPY/RSP/IWM + BDC/manager/
#     speculative baskets
#   CAPE + margin debt have no free daily API: values are carried forward from
#     the most recent non-null row. Update them with a monthly manual upsert
#     (Shiller data / FINRA release) and the carry-forward propagates.
# =============================================================================

import asyncio
import logging
from datetime import datetime, timezone

import httpx
import pytz

from core.config import settings
from core.supabase_client import get_supabase
from jobs.common import fetch_schwab_closes, is_eod_capture_run

log = logging.getLogger(__name__)

_ET = pytz.timezone("America/New_York")

# Equal-weight baskets. BDCs hold private loans (daily market pricing of the
# quarterly-marked books); managers originate them. Spec basket = the current
# cycle's parabolic tier — revisit when the cycle rotates.
_BDC_BASKET = ["ARCC", "OBDC", "FSK", "BXSL", "MAIN"]
_MGR_BASKET = ["ARES", "OWL", "APO", "BX", "KKR"]
_SPEC_BASKET = ["MU", "SNDK"]

_LOOKBACK_DAYS = 260  # ~52 trading weeks for high-water tracking

# Polymarket event slugs snapshotted daily alongside the checklist:
# real-money forward probabilities for the Fed-policy catalyst and
# data-center regulatory risk. Read-only public Gamma API.
_POLYMARKET_SLUGS = [
    "fed-rate-hike-by",
    "fed-decision-in-september-762",
    "will-any-state-enact-a-data-center-moratorium-by-december-31-20260707003733282",
]


async def _fetch_fred_series(
    client: httpx.AsyncClient,
    series_id: str,
    limit: int = 130,
) -> list[float]:
    """Fetch a FRED series oldest→newest via the edge function."""
    try:
        resp = await client.post(
            f"{settings.edge_function_base}/get-fred-data",
            json={"series_id": series_id, "limit": str(limit)},
            headers={
                "Authorization": f"Bearer {settings.supabase_service_key}",
                "Content-Type": "application/json",
            },
            timeout=30.0,
        )
        if resp.status_code != 200:
            log.warning("fred_%s_failed status=%s", series_id, resp.status_code)
            return []
        obs = resp.json().get("observations", [])
        return [float(o["value"]) for o in reversed(obs) if o.get("value") not in (".", None, "")]
    except Exception as exc:
        log.warning("fred_%s_error error=%s", series_id, exc)
        return []


def _composite(members: list[list[float]]) -> list[float]:
    """Equal-weight composite of close series, each indexed to its first value.
    Series are right-aligned (truncated to the shortest) so 'today' lines up."""
    usable = [s for s in members if len(s) >= 21]
    if not usable:
        return []
    n = min(len(s) for s in usable)
    aligned = [s[-n:] for s in usable]
    return [
        sum(s[i] / s[0] for s in aligned) / len(aligned)
        for i in range(n)
    ]


def _off_high_pct(series: list[float]) -> Optional[float]:
    if not series:
        return None
    hi = max(series)
    return (series[-1] / hi - 1) * 100 if hi > 0 else None


def _days_since_high(series: list[float]) -> Optional[int]:
    if not series:
        return None
    hi_i = max(range(len(series)), key=lambda i: series[i])
    return len(series) - 1 - hi_i


def _chg_pct(series: list[float], sessions: int) -> Optional[float]:
    if len(series) <= sessions or series[-1 - sessions] <= 0:
        return None
    return (series[-1] / series[-1 - sessions] - 1) * 100


async def _snapshot_polymarket(client: httpx.AsyncClient, db, obs_date: str) -> int:
    """Snapshot configured Polymarket events. Failures are logged, never fatal —
    a Polymarket outage must not break the checklist write."""
    import json as _json

    rows = []
    for slug in _POLYMARKET_SLUGS:
        try:
            resp = await client.get(
                "https://gamma-api.polymarket.com/events",
                params={"slug": slug},
                timeout=20.0,
            )
            if resp.status_code != 200 or not resp.json():
                log.warning("polymarket_fetch_failed slug=%s status=%s", slug, resp.status_code)
                continue
            event = resp.json()[0]
            for m in event.get("markets", []):
                outcomes = _json.loads(m.get("outcomes") or "[]")
                prices = _json.loads(m.get("outcomePrices") or "[]")
                if "Yes" not in outcomes or len(prices) != len(outcomes):
                    continue
                yes_p = float(prices[outcomes.index("Yes")])
                rows.append({
                    "obs_date": obs_date,
                    "event_slug": slug,
                    "event_title": event.get("title"),
                    "question": m.get("question"),
                    "yes_probability": round(yes_p, 4),
                    "volume_usd": int(float(m.get("volumeNum") or 0)),
                    "closed": bool(m.get("closed")),
                })
        except Exception as exc:
            log.warning("polymarket_error slug=%s error=%r", slug, exc)
    if rows:
        try:
            db.table("prediction_market_snapshots").upsert(
                rows, on_conflict="obs_date,event_slug,question"
            ).execute()
        except Exception as exc:
            log.warning("polymarket_upsert_failed error=%r", exc)
            return 0
    return len(rows)


async def run_crisis_pull() -> dict:
    now_et = datetime.now(timezone.utc).astimezone(_ET)
    if now_et.weekday() >= 5:
        log.info("crisis_pull: skipped (weekend)")
        return {"status": "skipped", "reason": "weekend"}

    db = get_supabase()
    obs_date = now_et.date().isoformat()

    async with httpx.AsyncClient(timeout=60.0) as client:
        equity_symbols = ["SPY", "RSP", "IWM"] + _BDC_BASKET + _MGR_BASKET + _SPEC_BASKET
        fred_tasks = [
            _fetch_fred_series(client, "BAMLH0A0HYM2"),        # HY OAS, percent
            _fetch_fred_series(client, "BAMLC0A0CM"),          # IG OAS, percent
            _fetch_fred_series(client, "T10Y2Y"),              # curve, percent
            _fetch_fred_series(client, "DFF", limit=160),      # fed funds, daily
            _fetch_fred_series(client, "CPIAUCSL", limit=15),  # CPI index, monthly
            _fetch_fred_series(client, "CPILFESL", limit=15),  # core CPI, monthly
        ]
        equity_tasks = [
            fetch_schwab_closes(client, sym, days=_LOOKBACK_DAYS) for sym in equity_symbols
        ]
        results = await asyncio.gather(*fred_tasks, *equity_tasks)
        pm_rows = await _snapshot_polymarket(client, db, obs_date)

    hy_oas, ig_oas, t10y2y, dff, cpi, cpi_core = results[: len(fred_tasks)]
    closes = {
        sym: results[len(fred_tasks) + i][0] for i, sym in enumerate(equity_symbols)
    }

    spy = closes.get("SPY") or []
    if len(spy) < 30:
        log.warning("crisis_pull: SPY history unavailable; aborting")
        return {"status": "no_spy_data"}

    # --- index posture (52-week high proxy for ATH) -------------------------
    spy_off_ath = _off_high_pct(spy)
    spy_days_since_ath = _days_since_high(spy)

    # --- rates / inflation ---------------------------------------------------
    fed_funds = dff[-1] if dff else None
    # DFF is a 7-day daily series: ~90 obs ≈ one quarter
    fed_90d_chg = (dff[-1] - dff[-91]) * 100 if len(dff) >= 91 else None
    curve_bps = t10y2y[-1] * 100 if t10y2y else None
    cpi_yoy = (cpi[-1] / cpi[-13] - 1) * 100 if len(cpi) >= 13 else None
    core_yoy = (cpi_core[-1] / cpi_core[-13] - 1) * 100 if len(cpi_core) >= 13 else None

    # --- public credit -------------------------------------------------------
    hy_bps = hy_oas[-1] * 100 if hy_oas else None
    ig_bps = ig_oas[-1] * 100 if ig_oas else None
    hy_20d_chg = (hy_oas[-1] - hy_oas[-21]) * 100 if len(hy_oas) >= 21 else None

    # --- breadth: does the average stock confirm the index? ------------------
    rsp, iwm = closes.get("RSP") or [], closes.get("IWM") or []
    n_rs = min(len(rsp), len(spy))
    rsp_spy = [rsp[-n_rs:][i] / spy[-n_rs:][i] for i in range(n_rs)] if n_rs else []
    n_iw = min(len(iwm), len(spy))
    iwm_spy = [iwm[-n_iw:][i] / spy[-n_iw:][i] for i in range(n_iw)] if n_iw else []
    rsp_days_since_high = _days_since_high(rsp)
    breadth_lag = (
        rsp_days_since_high - spy_days_since_ath
        if rsp_days_since_high is not None and spy_days_since_ath is not None
        else None
    )

    # --- private credit & spec composites ------------------------------------
    bdc = _composite([closes.get(s) or [] for s in _BDC_BASKET])
    mgr = _composite([closes.get(s) or [] for s in _MGR_BASKET])
    spec = _composite([closes.get(s) or [] for s in _SPEC_BASKET])

    bdc_off_high, bdc_20d = _off_high_pct(bdc), _chg_pct(bdc, 20)
    mgr_off_high, mgr_20d = _off_high_pct(mgr), _chg_pct(mgr, 20)
    spec_off_high = _off_high_pct(spec)

    # --- carry forward monthly manual fields (CAPE, margin debt) -------------
    cape: Optional[float] = None
    margin_bn: Optional[float] = None
    margin_yoy: Optional[float] = None
    try:
        prev = (
            db.table("crisis_checklist_snapshots")
            .select("cape,margin_debt_bn,margin_debt_yoy_pct")
            .order("obs_date", desc=True)
            .limit(1)
            .execute()
        )
        if prev.data:
            cape = prev.data[0].get("cape")
            margin_bn = prev.data[0].get("margin_debt_bn")
            margin_yoy = prev.data[0].get("margin_debt_yoy_pct")
    except Exception as exc:
        log.warning("crisis_pull: carry-forward read failed: %s", exc)

    # --- verdicts -------------------------------------------------------------
    # Thresholds calibrated on the 13-crisis ledger; 'firing' = the historical
    # pre-crisis condition is present.
    def verdict(value: Optional[float], firing, partial) -> str:
        if value is None:
            return "unknown"
        if firing(value):
            return "firing"
        if partial(value):
            return "partial"
        return "clean"

    v_index = verdict(spy_off_ath, lambda v: v >= -2.0, lambda v: v >= -5.0)
    v_valuation = verdict(cape, lambda v: v >= 35.0, lambda v: v >= 30.0)
    v_leverage = verdict(margin_yoy, lambda v: v >= 25.0, lambda v: v >= 10.0)
    # spec crack only means something while the index itself is near highs
    spy_near_high = spy_off_ath is not None and spy_off_ath >= -5.0
    v_spec = (
        "unknown" if spec_off_high is None
        else "firing" if spec_off_high <= -20.0 and spy_near_high
        else "partial" if spec_off_high <= -10.0 and spy_near_high
        else "clean"
    )
    v_fed = verdict(fed_90d_chg, lambda v: v >= 50.0, lambda v: v > 0.0)
    v_curve = verdict(curve_bps, lambda v: v <= 0.0, lambda v: v <= 25.0)
    # public credit: the ledger's signal is the TURN off the tights, not the level
    v_public = (
        "unknown" if hy_bps is None
        else "firing" if hy_bps >= 400.0 or (hy_20d_chg or 0) >= 50.0
        else "partial" if (hy_20d_chg or 0) >= 25.0
        else "clean"
    )
    worst_pc_off = min(x for x in [bdc_off_high, mgr_off_high] if x is not None) if (bdc_off_high is not None or mgr_off_high is not None) else None
    v_private = (
        "unknown" if worst_pc_off is None
        else "firing" if worst_pc_off <= -15.0 and min(bdc_20d or 0, mgr_20d or 0) < 0
        else "partial" if worst_pc_off <= -15.0
        else "clean"
    )
    # breadth fails when RSP's own high is much staler than SPY's
    v_breadth = (
        "unknown" if breadth_lag is None
        else "firing" if breadth_lag >= 60
        else "partial" if breadth_lag >= 20
        else "clean"
    )

    structural = [v_index, v_valuation, v_leverage, v_spec]
    catalysts = [v_fed, v_curve, v_public, v_private, v_breadth]

    row = {
        "obs_date": obs_date,
        "spy_close": round(spy[-1], 2),
        "spy_off_ath_pct": round(spy_off_ath, 2) if spy_off_ath is not None else None,
        "spy_days_since_ath": spy_days_since_ath,
        "cape": cape,
        "margin_debt_bn": margin_bn,
        "margin_debt_yoy_pct": margin_yoy,
        "fed_funds_pct": round(fed_funds, 2) if fed_funds is not None else None,
        "fed_funds_90d_chg_bps": round(fed_90d_chg, 1) if fed_90d_chg is not None else None,
        "t10y2y_bps": round(curve_bps, 1) if curve_bps is not None else None,
        "cpi_yoy_pct": round(cpi_yoy, 2) if cpi_yoy is not None else None,
        "cpi_core_yoy_pct": round(core_yoy, 2) if core_yoy is not None else None,
        "hy_oas_bps": round(hy_bps, 1) if hy_bps is not None else None,
        "ig_oas_bps": round(ig_bps, 1) if ig_bps is not None else None,
        "hy_oas_20d_chg_bps": round(hy_20d_chg, 1) if hy_20d_chg is not None else None,
        "rsp_spy_ratio": round(rsp_spy[-1], 6) if rsp_spy else None,
        "rsp_spy_off_high_pct": round(_off_high_pct(rsp_spy), 2) if rsp_spy else None,
        "iwm_spy_ratio": round(iwm_spy[-1], 6) if iwm_spy else None,
        "iwm_spy_off_high_pct": round(_off_high_pct(iwm_spy), 2) if iwm_spy else None,
        "bdc_off_high_pct": round(bdc_off_high, 2) if bdc_off_high is not None else None,
        "bdc_20d_pct": round(bdc_20d, 2) if bdc_20d is not None else None,
        "mgr_off_high_pct": round(mgr_off_high, 2) if mgr_off_high is not None else None,
        "mgr_20d_pct": round(mgr_20d, 2) if mgr_20d is not None else None,
        "spec_off_high_pct": round(spec_off_high, 2) if spec_off_high is not None else None,
        "v_index_ath": v_index,
        "v_valuation": v_valuation,
        "v_leverage": v_leverage,
        "v_spec_tier": v_spec,
        "v_fed": v_fed,
        "v_curve": v_curve,
        "v_public_credit": v_public,
        "v_private_credit": v_private,
        "v_breadth": v_breadth,
        "structural_lit": sum(1 for v in structural if v == "firing"),
        "catalysts_firing": sum(1 for v in catalysts if v == "firing"),
        "signals": {
            "bdc_basket": _BDC_BASKET,
            "mgr_basket": _MGR_BASKET,
            "spec_basket": _SPEC_BASKET,
            "breadth_lag_sessions": breadth_lag,
            "lookback_days": _LOOKBACK_DAYS,
            "note": "ATH tracked as 52-week high; CAPE/margin carried forward from last manual upsert",
        },
        "is_final": is_eod_capture_run(),
    }

    db.table("crisis_checklist_snapshots").upsert(row, on_conflict="obs_date").execute()

    log.info(
        "crisis_pull: %s structural=%s catalysts=%s hy=%s curve=%s bdc_off=%s mgr_off=%s spec_off=%s",
        obs_date, row["structural_lit"], row["catalysts_firing"],
        row["hy_oas_bps"], row["t10y2y_bps"],
        row["bdc_off_high_pct"], row["mgr_off_high_pct"], row["spec_off_high_pct"],
    )
    return {"status": "ok", "obs_date": obs_date,
            "structural_lit": row["structural_lit"],
            "catalysts_firing": row["catalysts_firing"],
            "prediction_markets": pm_rows}
