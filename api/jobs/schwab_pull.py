# =============================================================================
# jobs/schwab_pull.py
# =============================================================================
# Schwab data pull pipeline — runs every 8 hours via Cloud Scheduler.
#
# Deployment:
#   - Cloud Run HTTP trigger: POST /jobs/schwab-pull
#   - Cloud Scheduler job fires every 8 hours
#   - Project: options-trader-493420 (OPTIONS TRADER)
#
# What it does for each watched ticker:
#   1. Fetch options chain from Schwab (via Supabase Edge Functions)
#   2. Parse chain → upsert vol_surface_snapshots
#   3. SABR calibration → upsert sabr_calibrations
#   4. IV analytics → upsert iv_snapshots
#   5. Greek grid aggregation → upsert greek_grid_snapshots
#   6. ATM greek snapshots (4/7/31 DTE buckets) → upsert greek_snapshots
#   7. Realized vol (from FMP) → log result
# =============================================================================

import logging
from datetime import datetime, date, timezone

import httpx

from core.config import settings
from core.supabase_client import get_supabase
from services.sabr_calibrator import calibrate_snapshot
from services.iv_analytics import analyse as iv_analyse
from services.greek_grid_ingester import ingest as grid_ingest
from services.realized_vol import compute as rv_compute

log = logging.getLogger(__name__)

# DTE targets that mirror the Flutter app's greek chart buckets
_DTE_BUCKETS = [4, 7, 31]


async def run_schwab_pull() -> dict:
    """Main entry point — called by the Cloud Scheduler HTTP trigger."""
    db = get_supabase()
    today = date.today().isoformat()
    edge_base = settings.edge_function_base
    headers = {
        "Authorization": f"Bearer {settings.supabase_service_key}",
        "Content-Type": "application/json",
    }
    fmp_key = settings.fmp_api_key

    # Fetch watched tickers + user_id (needed for user-scoped tables like greek_snapshots)
    tickers_resp = db.table("watched_tickers").select("symbol,user_id").execute()
    rows = tickers_resp.data or []
    if not rows:
        log.warning("No watched tickers found — nothing to pull")
        return {"status": "no_tickers"}

    results: dict[str, str] = {}

    async with httpx.AsyncClient(timeout=60.0) as client:
        for row in rows:
            ticker  = row["symbol"]
            user_id = row["user_id"]
            try:
                # ── Step 1: Fetch chain from Schwab via Edge Function ──────────
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

                # ── Step 2: Vol surface snapshot ──────────────────────────────
                points = _chain_to_vol_points(chain, spot)
                if points:
                    _upsert_vol_surface(db, ticker, today, spot, points, user_id)

                # ── Step 3: SABR calibration ──────────────────────────────────
                slices = calibrate_snapshot(spot=spot, points=points)
                if slices:
                    _upsert_sabr_calibrations(db, ticker, today, slices)

                # ── Step 4: IV analytics ──────────────────────────────────────
                history = _fetch_iv_history(db, ticker)
                iv_result = iv_analyse(chain, history)
                _upsert_iv_snapshot(db, ticker, today, iv_result, spot)

                # ── Step 5: Greek grid ────────────────────────────────────────
                obs_dt = datetime.now(timezone.utc)
                cells = grid_ingest(chain, obs_dt)
                if cells:
                    _upsert_greek_grid(db, ticker, today, cells, spot)

                # ── Step 6: ATM greek snapshots (greek chart time-series) ─────
                _upsert_greek_snapshots(db, ticker, today, spot, chain, user_id)

                # ── Step 7: Realized vol (FMP historical prices) ──────────────
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


# ── ATM greek snapshot ingestion ──────────────────────────────────────────────

def _upsert_greek_snapshots(
    db, ticker: str, today: str, spot: float, chain: dict, user_id: str
) -> None:
    """Write one row per DTE bucket to greek_snapshots.

    Mirrors the Dart autoIngestGreeks() logic exactly:
      - For each target DTE [4, 7, 31], select the expiration whose DTE is
        closest to the target.
      - ATM call = contract with |delta| closest to 0.50.
      - ATM put  = contract with |delta| closest to 0.50.
    """
    expirations = _parse_expirations(chain)
    if not expirations:
        return

    for target_dte in _DTE_BUCKETS:
        try:
            exp = min(expirations, key=lambda e: abs(e["dte"] - target_dte))
            calls = exp["calls"]
            puts  = exp["puts"]

            atm_call = _atm_contract(calls)
            atm_put  = _atm_contract(puts)

            row: dict = {
                "user_id":          user_id,
                "ticker":           ticker,
                "obs_date":         today,
                "dte_bucket":       target_dte,
                "underlying_price": spot,
            }

            if atm_call:
                row.update({
                    "call_strike": atm_call.get("strikePrice"),
                    "call_dte":    atm_call.get("daysToExpiration"),
                    "call_delta":  atm_call.get("delta"),
                    "call_gamma":  atm_call.get("gamma"),
                    "call_theta":  atm_call.get("theta"),
                    "call_vega":   atm_call.get("vega"),
                    "call_rho":    atm_call.get("rho"),
                    "call_iv":     _pct_to_dec(atm_call.get("volatility")),
                    "call_oi":     atm_call.get("openInterest"),
                })

            if atm_put:
                row.update({
                    "put_strike": atm_put.get("strikePrice"),
                    "put_dte":    atm_put.get("daysToExpiration"),
                    "put_delta":  atm_put.get("delta"),
                    "put_gamma":  atm_put.get("gamma"),
                    "put_theta":  atm_put.get("theta"),
                    "put_vega":   atm_put.get("vega"),
                    "put_rho":    atm_put.get("rho"),
                    "put_iv":     _pct_to_dec(atm_put.get("volatility")),
                    "put_oi":     atm_put.get("openInterest"),
                })

            db.table("greek_snapshots").upsert(
                row,
                on_conflict="user_id,ticker,obs_date,dte_bucket",
            ).execute()

        except Exception as exc:
            log.warning("greek_snapshot_failed", ticker=ticker, dte=target_dte, error=str(exc))


def _parse_expirations(chain: dict) -> list[dict]:
    """Normalize the Schwab callExpDateMap/putExpDateMap into a flat list.

    Returns: [{dte, calls: [contract, ...], puts: [contract, ...]}, ...]
    The key format is "YYYY-MM-DD:DTE" — DTE is after the colon.
    """
    call_map: dict[int, list[dict]] = {}
    put_map:  dict[int, list[dict]] = {}

    for key, strikes in chain.get("callExpDateMap", {}).items():
        dte = _dte_from_key(key)
        if dte is None:
            continue
        contracts: list[dict] = []
        for contracts_at_strike in strikes.values():
            contracts.extend(contracts_at_strike)
        call_map[dte] = contracts

    for key, strikes in chain.get("putExpDateMap", {}).items():
        dte = _dte_from_key(key)
        if dte is None:
            continue
        contracts: list[dict] = []
        for contracts_at_strike in strikes.values():
            contracts.extend(contracts_at_strike)
        put_map[dte] = contracts

    all_dtes = sorted(set(call_map) | set(put_map))
    return [
        {
            "dte":   dte,
            "calls": call_map.get(dte, []),
            "puts":  put_map.get(dte, []),
        }
        for dte in all_dtes
        if dte > 0
    ]


def _dte_from_key(key: str) -> int | None:
    """Extract DTE from Schwab expDate key format "YYYY-MM-DD:DTE"."""
    try:
        return int(key.split(":")[1])
    except (IndexError, ValueError):
        return None


def _atm_contract(contracts: list[dict]) -> dict | None:
    """Return the contract with |delta| closest to 0.50.  Falls back to
    the first contract when none have a non-zero delta."""
    if not contracts:
        return None
    with_delta = [c for c in contracts if c.get("delta") and c["delta"] != 0]
    if not with_delta:
        return contracts[0]
    return min(with_delta, key=lambda c: abs(abs(c["delta"]) - 0.50))


def _pct_to_dec(value) -> float | None:
    """Schwab delivers IV as a percentage (e.g. 21.4); convert to decimal."""
    if value is None:
        return None
    try:
        return float(value) / 100.0
    except (TypeError, ValueError):
        return None


# ── Vol surface helpers ───────────────────────────────────────────────────────

def _chain_to_vol_points(chain: dict, spot: float) -> list[dict]:
    """Convert Schwab callExpDateMap/putExpDateMap to vol surface points."""
    expirations = _parse_expirations(chain)
    points = []
    for exp in expirations:
        dte = exp["dte"]
        call_map: dict[float, float] = {}
        put_map:  dict[float, float] = {}

        for c in exp["calls"]:
            iv = c.get("volatility") or c.get("impliedVolatility") or 0
            if iv > 0:
                call_map[float(c["strikePrice"])] = float(iv) / 100

        for p in exp["puts"]:
            iv = p.get("volatility") or p.get("impliedVolatility") or 0
            if iv > 0:
                put_map[float(p["strikePrice"])] = float(iv) / 100

        for strike in sorted(set(call_map) | set(put_map)):
            points.append({
                "strike": strike,
                "dte":    dte,
                "callIv": call_map.get(strike),
                "putIv":  put_map.get(strike),
            })

    return points


# ── Supabase upserts ──────────────────────────────────────────────────────────

def _fetch_iv_history(db, ticker: str) -> list[dict]:
    resp = (
        db.table("iv_snapshots")
        .select("atm_iv,skew,total_gex,date")
        .eq("ticker", ticker)
        .order("date", desc=False)
        .limit(252)
        .execute()
    )
    return resp.data or []


def _upsert_vol_surface(
    db, ticker: str, today: str, spot: float, points: list[dict], user_id: str
) -> None:
    db.table("vol_surface_snapshots").upsert(
        {
            "user_id":    user_id,
            "ticker":     ticker,
            "obs_date":   today,
            "spot_price": spot,
            "points":     points,
        },
        on_conflict="user_id,ticker,obs_date",
    ).execute()


def _upsert_sabr_calibrations(db, ticker: str, today: str, slices) -> None:
    for s in slices:
        db.table("sabr_calibrations").upsert(
            {
                "ticker": ticker, "obs_date": today,
                "dte": s.dte, "alpha": s.alpha, "beta": s.beta,
                "rho": s.rho, "nu": s.nu, "rmse": s.rmse, "n_points": s.n_points,
            },
            on_conflict="ticker,obs_date,dte",
        ).execute()


def _upsert_iv_snapshot(db, ticker: str, today: str, iv_result, spot: float) -> None:
    gex_by_strike = [
        {"strike": g.strike, "dealer_gex": g.dealer_gex(spot),
         "call_oi": g.call_oi, "put_oi": g.put_oi}
        for g in iv_result.gex_strikes
    ]
    db.table("iv_snapshots").upsert(
        {
            "ticker": ticker, "date": today,
            "atm_iv": iv_result.current_iv, "skew": iv_result.skew,
            "gex_by_strike": gex_by_strike, "total_gex": iv_result.total_gex,
            "max_gex_strike": iv_result.max_gex_strike,
            "put_call_ratio": iv_result.put_call_ratio,
            "underlying_price": spot,
        },
        on_conflict="ticker,date",
    ).execute()


def _upsert_greek_grid(db, ticker: str, today: str, cells, spot: float) -> None:
    for cell in cells:
        db.table("greek_grid_snapshots").upsert(
            {
                "ticker": ticker, "obs_date": today,
                "strike_band": cell.strike_band.value,
                "expiry_bucket": cell.expiry_bucket.value,
                "strike": cell.strike, "delta": cell.delta, "gamma": cell.gamma,
                "vega": cell.vega, "theta": cell.theta, "iv": cell.iv,
                "vanna": cell.vanna, "charm": cell.charm, "volga": cell.volga,
                "open_interest": cell.open_interest, "volume": cell.volume,
                "contract_count": cell.contract_count, "spot_at_obs": spot,
            },
            on_conflict="ticker,obs_date,strike_band,expiry_bucket",
        ).execute()


async def _fetch_fmp_closes(
    client: httpx.AsyncClient, ticker: str, fmp_key: str, days: int = 65
) -> list[float]:
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
        closes.reverse()  # oldest → newest
        return closes
    except Exception:
        return []
