# =============================================================================
# jobs/schwab_pull.py
# =============================================================================
# Schwab data pull pipeline — runs every 8 hours via Cloud Scheduler.
#
# Deployment:
#   - Cloud Function (2nd gen HTTP trigger): schwab-pull
#   - Cloud Scheduler job fires every 8 hours → POST /run
#   - Project: options-trader-493420 (OPTIONS TRADER)
#
# What it does for each watched ticker:
#   1. Fetch quotes + options chain from Schwab (via Supabase Edge Functions)
#   2. Parse chain → upsert vol_surface_snapshots
#   3. SABR calibration → upsert sabr_calibrations
#   4. IV analytics → upsert iv_snapshots
#   5. Greek grid aggregation → upsert greek_grid_snapshots
#   6. Realized vol (from FMP) → store inline in iv_snapshots
# =============================================================================

import logging
import math
from datetime import datetime, date, timezone

import httpx

from core.config import settings
from core.supabase_client import get_supabase
from services.sabr_calibrator import calibrate_snapshot
from services.iv_analytics import analyse as iv_analyse
from services.greek_grid_ingester import ingest as grid_ingest
from services.realized_vol import compute as rv_compute

log = logging.getLogger(__name__)


async def run_schwab_pull() -> dict:
    """Main entry point — called by Cloud Function HTTP handler.

    Returns dict with per-ticker status for logging.
    """
    db = get_supabase()
    today = date.today().isoformat()
    edge_base = settings.edge_function_base
    headers = {
        "Authorization": f"Bearer {settings.supabase_service_key}",
        "Content-Type": "application/json",
    }
    fmp_key = settings.fmp_api_key

    # Load watched tickers
    tickers_resp = db.table("watched_tickers").select("symbol").execute()
    tickers = [row["symbol"] for row in (tickers_resp.data or [])]
    if not tickers:
        log.warning("No watched tickers found — nothing to pull")
        return {"status": "no_tickers"}

    results: dict[str, str] = {}

    async with httpx.AsyncClient(timeout=60.0) as client:
        for ticker in tickers:
            try:
                # ── Step 1: Fetch from Schwab via Supabase Edge Functions ──────
                chain_resp = await client.post(
                    f"{edge_base}/get-schwab-chains",
                    json={"symbol": ticker, "contractType": "ALL", "strikeCount": 40},
                    headers=headers,
                )
                if chain_resp.status_code != 200:
                    log.error("chain_fetch_failed", ticker=ticker, status=chain_resp.status_code)
                    results[ticker] = f"chain_error_{chain_resp.status_code}"
                    continue

                chain = chain_resp.json()
                spot = float(chain.get("underlyingPrice", 0))
                if spot <= 0:
                    log.warning("zero_spot", ticker=ticker)
                    results[ticker] = "zero_spot"
                    continue

                # ── Step 2: Parse chain → vol surface snapshot ─────────────────
                points = _chain_to_vol_points(chain, spot)
                if points:
                    _upsert_vol_surface(db, ticker, today, spot, points)

                # ── Step 3: SABR calibration ───────────────────────────────────
                slices = calibrate_snapshot(spot=spot, points=points)
                if slices:
                    _upsert_sabr_calibrations(db, ticker, today, slices)

                # ── Step 4: IV analytics ───────────────────────────────────────
                history = _fetch_iv_history(db, ticker)
                iv_result = iv_analyse(chain, history)
                _upsert_iv_snapshot(db, ticker, today, iv_result, spot, slices)

                # ── Step 5: Greek grid ─────────────────────────────────────────
                obs_date = datetime.now(timezone.utc)
                cells = grid_ingest(chain, obs_date)
                if cells:
                    _upsert_greek_grid(db, ticker, today, cells, spot)

                # ── Step 6: Realized vol (FMP historical prices) ───────────────
                if fmp_key:
                    closes = await _fetch_fmp_closes(client, ticker, fmp_key, days=65)
                    if closes:
                        rv = rv_compute(closes)
                        log.info("rv_computed", ticker=ticker, rv20d=rv.rv20d, rv60d=rv.rv60d)

                results[ticker] = "ok"
                log.info("ticker_pulled", ticker=ticker)

            except Exception as exc:
                log.error("ticker_pull_failed", ticker=ticker, error=str(exc))
                results[ticker] = f"error: {exc}"

    return {"status": "complete", "tickers": results, "date": today}


# ── Data helpers ──────────────────────────────────────────────────────────────

def _chain_to_vol_points(chain: dict, spot: float) -> list[dict]:
    """Convert Schwab chain JSON to vol_surface_snapshots.points format."""
    points = []
    for exp in chain.get("expirations", []):
        dte = int(exp.get("dte", 0))
        if dte <= 0:
            continue

        call_map: dict[float, float] = {}
        put_map: dict[float, float] = {}

        for c in exp.get("calls", []):
            iv = float(c.get("impliedVolatility", 0))
            if iv > 0:
                call_map[float(c["strikePrice"])] = iv / 100  # convert to decimal

        for p in exp.get("puts", []):
            iv = float(p.get("impliedVolatility", 0))
            if iv > 0:
                put_map[float(p["strikePrice"])] = iv / 100

        all_strikes = sorted(set(call_map) | set(put_map))
        for strike in all_strikes:
            points.append({
                "strike": strike,
                "dte": dte,
                "callIv": call_map.get(strike),
                "putIv": put_map.get(strike),
            })

    return points


def _fetch_iv_history(db, ticker: str) -> list[dict]:
    """Fetch recent iv_snapshots for IVR/IVP computation."""
    resp = db.table("iv_snapshots")\
        .select("atm_iv, skew, total_gex, date")\
        .eq("ticker", ticker)\
        .order("date", desc=False)\
        .limit(252)\
        .execute()
    return resp.data or []


def _upsert_vol_surface(db, ticker: str, today: str, spot: float, points: list[dict]) -> None:
    db.table("vol_surface_snapshots").upsert({
        "ticker": ticker,
        "obs_date": today,
        "spot_price": spot,
        "points": points,
    }, on_conflict="ticker,obs_date").execute()


def _upsert_sabr_calibrations(db, ticker: str, today: str, slices) -> None:
    for s in slices:
        db.table("sabr_calibrations").upsert({
            "ticker": ticker,
            "obs_date": today,
            "dte": s.dte,
            "alpha": s.alpha,
            "beta": s.beta,
            "rho": s.rho,
            "nu": s.nu,
            "rmse": s.rmse,
            "n_points": s.n_points,
        }, on_conflict="ticker,obs_date,dte").execute()


def _upsert_iv_snapshot(db, ticker: str, today: str, iv_result, spot: float, slices) -> None:
    gex_by_strike = [
        {
            "strike": g.strike,
            "dealer_gex": g.dealer_gex(spot),
            "call_oi": g.call_oi,
            "put_oi": g.put_oi,
        }
        for g in iv_result.gex_strikes
    ]
    db.table("iv_snapshots").upsert({
        "ticker": ticker,
        "date": today,
        "atm_iv": iv_result.current_iv,
        "skew": iv_result.skew,
        "gex_by_strike": gex_by_strike,
        "total_gex": iv_result.total_gex,
        "max_gex_strike": iv_result.max_gex_strike,
        "put_call_ratio": iv_result.put_call_ratio,
        "underlying_price": spot,
    }, on_conflict="ticker,date").execute()


def _upsert_greek_grid(db, ticker: str, today: str, cells, spot: float) -> None:
    for cell in cells:
        db.table("greek_grid_snapshots").upsert({
            "ticker": ticker,
            "obs_date": today,
            "strike_band": cell.strike_band.value,
            "expiry_bucket": cell.expiry_bucket.value,
            "strike": cell.strike,
            "delta": cell.delta,
            "gamma": cell.gamma,
            "vega": cell.vega,
            "theta": cell.theta,
            "iv": cell.iv,
            "vanna": cell.vanna,
            "charm": cell.charm,
            "volga": cell.volga,
            "open_interest": cell.open_interest,
            "volume": cell.volume,
            "contract_count": cell.contract_count,
            "spot_at_obs": spot,
        }, on_conflict="ticker,obs_date,strike_band,expiry_bucket").execute()


async def _fetch_fmp_closes(
    client: httpx.AsyncClient,
    ticker: str,
    fmp_key: str,
    days: int = 65,
) -> list[float]:
    """Fetch historical daily closes from FMP."""
    try:
        url = (
            f"https://financialmodelingprep.com/stable/historical-price-eod/full"
            f"?symbol={ticker}&timeseries={days}&apikey={fmp_key}"
        )
        resp = await client.get(url, timeout=30.0)
        if resp.status_code != 200:
            return []
        data = resp.json()
        hist = data if isinstance(data, list) else data.get("historical", [])
        closes = [float(d["close"]) for d in hist if "close" in d]
        closes.reverse()  # oldest first
        return closes
    except Exception:
        return []
