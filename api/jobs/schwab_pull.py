from __future__ import annotations

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
from core.chain_utils import parse_expirations, _dte_from_key
from services.sabr_calibrator import calibrate_snapshot
from services.iv_analytics import analyse as iv_analyse
from services.greek_grid_ingester import ingest as grid_ingest
from services.realized_vol import compute as rv_compute
from services.vvol_analytics import compute as vvol_compute
from services.regime_service import classify_regime, compute_wilder_rsi
from services.hmm_regime import classify_vix_regime

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
    tickers_resp = db.table("watched_tickers").select("ticker,user_id").execute()
    rows = tickers_resp.data or []

    # Also include tickers from open trades that aren't already watched.
    # A traded ticker needs greek grid data even if the user never added it to watched_tickers.
    trades_resp = (
        db.table("trades")
        .select("ticker,user_id")
        .eq("status", "open")
        .execute()
    )
    watched_keys = {(r["ticker"], r["user_id"]) for r in rows}
    for r in (trades_resp.data or []):
        key = (r["ticker"], r["user_id"])
        if key not in watched_keys:
            rows.append(r)
            watched_keys.add(key)

    if not rows:
        log.warning("No watched tickers found — nothing to pull")
        return {"status": "no_tickers"}

    results: dict[str, str] = {}

    async with httpx.AsyncClient(timeout=60.0) as client:
        # ── Fetch VIX + supplementary vol indexes once per pipeline run ─────────
        # All fetched once here and reused across every ticker to avoid redundant
        # API calls. FMP timeseries=65 gives 65 trading days oldest→newest.
        vix_closes: list[float] = []
        vix_current: float | None = None
        vix_10ma: float | None = None
        vix_dev_pct: float | None = None
        vix_rsi: float | None = None
        hmm_result = None
        vix_term_structure_ratio: float | None = None   # VIX / VIX3M (<1=contango, >1=backwardation)
        vvix_current: float | None = None
        vvix_10ma: float | None = None
        breadth_proxy: float | None = None              # RSP/SPY 5d return ratio z-score
        if fmp_key:
            # VIX
            vix_closes, _ = await _fetch_fmp_closes(client, "^VIX", fmp_key, days=65)
            if vix_closes:
                vix_current = vix_closes[-1]
                ma10_data = vix_closes[-10:] if len(vix_closes) >= 10 else []
                vix_10ma = sum(ma10_data) / len(ma10_data) if ma10_data else None
                if vix_10ma and vix_10ma > 0 and vix_current is not None:
                    vix_dev_pct = (vix_current - vix_10ma) / vix_10ma * 100
                vix_rsi = compute_wilder_rsi(vix_closes)
                hmm_result = classify_vix_regime(vix_closes)

            # VIX3M term structure — ratio <1 = contango (tailwind for premium selling)
            vix3m_closes, _ = await _fetch_fmp_closes(client, "^VIX3M", fmp_key, days=5)
            if vix3m_closes and vix_current is not None and vix3m_closes[-1] > 0:
                vix_term_structure_ratio = vix_current / vix3m_closes[-1]

            # VVIX — rising above 120 while VIX < 20 is an early regime-transition warning
            vvix_closes, _ = await _fetch_fmp_closes(client, "^VVIX", fmp_key, days=15)
            if vvix_closes:
                vvix_current = vvix_closes[-1]
                vvix_ma10 = vvix_closes[-10:] if len(vvix_closes) >= 10 else vvix_closes
                vvix_10ma = sum(vvix_ma10) / len(vvix_ma10)

            # Breadth proxy: RSP (equal-weight) vs SPY (cap-weight) 5d return ratio.
            # When RSP underperforms SPY the market is narrow (few mega-caps driving index).
            # z-score < -1.5 signals breadth divergence; signals are context-only (no bias override).
            spy_closes, _ = await _fetch_fmp_closes(client, "SPY", fmp_key, days=25)
            rsp_closes, _ = await _fetch_fmp_closes(client, "RSP", fmp_key, days=25)
            if len(spy_closes) >= 10 and len(rsp_closes) >= 10:
                spy_rets = [
                    (spy_closes[i] - spy_closes[i - 5]) / spy_closes[i - 5]
                    for i in range(5, len(spy_closes))
                    if spy_closes[i - 5] > 0
                ]
                rsp_rets = [
                    (rsp_closes[i] - rsp_closes[i - 5]) / rsp_closes[i - 5]
                    for i in range(5, len(rsp_closes))
                    if rsp_closes[i - 5] > 0
                ]
                n = min(len(spy_rets), len(rsp_rets))
                if n >= 5:
                    ratios = [
                        rsp_rets[i] / spy_rets[i] if abs(spy_rets[i]) > 1e-6 else 1.0
                        for i in range(n)
                    ]
                    ratio_mean = sum(ratios) / len(ratios)
                    ratio_std = (sum((r - ratio_mean) ** 2 for r in ratios) / len(ratios)) ** 0.5
                    if ratio_std > 1e-6:
                        breadth_proxy = (ratios[-1] - ratio_mean) / ratio_std

            log.info(
                "vix_computed current=%.2f 10ma=%s dev_pct=%s rsi=%s hmm=%s ts_ratio=%s vvix=%s breadth_z=%s",
                vix_current or 0,
                f"{vix_10ma:.2f}" if vix_10ma else "—",
                f"{vix_dev_pct:.1f}%" if vix_dev_pct else "—",
                f"{vix_rsi:.1f}" if vix_rsi else "—",
                hmm_result.state.value if hmm_result else "—",
                f"{vix_term_structure_ratio:.3f}" if vix_term_structure_ratio else "—",
                f"{vvix_current:.1f}" if vvix_current else "—",
                f"{breadth_proxy:.2f}" if breadth_proxy else "—",
            )

        for row in rows:
            ticker  = row["ticker"]
            user_id = row["user_id"]
            try:
                # ── Step 1: Fetch chain from Schwab via Edge Function ──────────
                chain_resp = await client.post(
                    f"{edge_base}/get-schwab-chains",
                    json={"symbol": ticker, "contractType": "ALL", "strikeCount": 40}, 
                    headers=headers,
                )
                if chain_resp.status_code != 200:
                    log.error("chain_fetch_failed ticker=%s status=%s", ticker, chain_resp.status_code)
                    results[ticker] = f"chain_error_{chain_resp.status_code}"
                    continue

                chain = chain_resp.json()
                spot = float(chain.get("underlyingPrice", 0))
                if spot <= 0:
                    log.warning("zero_spot ticker=%s", ticker)
                    results[ticker] = "zero_spot"
                    continue

                # ── Step 2: Vol surface snapshot ──────────────────────────────
                points = _chain_to_vol_points(chain, spot)
                if points:
                    _upsert_vol_surface(db, ticker, today, spot, points, user_id)

                # ── Step 3: SABR calibration ──────────────────────────────────
                slices = calibrate_snapshot(spot=spot, points=points)
                # Fetch ν history BEFORE upserting today's calibration so that
                # nu_history contains only prior observations (today excluded).
                nu_history = _fetch_nu_history(db, ticker, user_id) if slices else []
                if slices:
                    _upsert_sabr_calibrations(db, ticker, today, slices, user_id)

                # ── Step 4: IV analytics + vvol rank ─────────────────────────
                history = _fetch_iv_history(db, ticker)
                iv_result = iv_analyse(chain, history)
                vvol = None ## Compute vvol only when we have a SABR slice and history to compare against, otherwise the rank/percentile would be meaningless noise.
                if slices and nu_history:
                    atm_slice = min(slices, key=lambda s: abs(s.dte - 30))
                    vvol      = vvol_compute(atm_slice.nu, nu_history)
                _upsert_iv_snapshot(db, ticker, today, iv_result, spot, vvol)

                # ── Step 5: Greek grid ────────────────────────────────────────
                obs_date = datetime.now(timezone.utc)
                cells = grid_ingest(chain, obs_date)
                if cells:
                    _upsert_greek_grid(db, ticker, today, cells, spot, user_id)

                # ── Step 6: ATM greek snapshots (greek chart time-series) ─────
                _upsert_greek_snapshots(db, ticker, today, spot, chain, user_id)

                # ── Step 7: Realized vol (FMP historical prices) ──────────────
                closes:  list[float] = []
                volumes: list[float] = []
                if fmp_key:
                    closes, volumes = await _fetch_fmp_closes(client, ticker, fmp_key, days=65)
                    if closes:
                        rv = rv_compute(closes)
                        log.info("rv_computed ticker=%s rv20d=%s rv60d=%s", ticker, rv.rv20d, rv.rv60d)

                # ── Step 8: SMA + current regime classification ───────────────
                # SMA computed from already-fetched FMP closes (trading days).
                # Filter out zero/None values to guard against bad FMP entries.
                clean_closes  = [c for c in closes  if c and c > 0]
                clean_volumes = [v for v in volumes if v and v > 0]

                sma10: float | None = (
                    sum(clean_closes[-10:]) / 10 if len(clean_closes) >= 10 else None
                )
                sma50: float | None = (
                    sum(clean_closes[-50:]) / 50 if len(clean_closes) >= 50 else None
                )
                sma_crossed: bool | None = (
                    sma10 > sma50 if (sma10 is not None and sma50 is not None) else None
                )
                vol_sma3: float | None = (
                    sum(clean_volumes[-3:]) / 3 if len(clean_volumes) >= 3 else None
                )
                vol_sma20: float | None = (
                    sum(clean_volumes[-20:]) / 20 if len(clean_volumes) >= 20 else None
                )
                # 5-day rate of change — leading momentum indicator ahead of SMA cross
                price_roc5: float | None = None
                if len(clean_closes) >= 6 and clean_closes[-6] > 0:
                    price_roc5 = (clean_closes[-1] - clean_closes[-6]) / clean_closes[-6] * 100

                regime = classify_regime(
                    ticker=ticker,
                    gamma_regime=iv_result.gamma_regime.value,
                    iv_gex_signal=iv_result.iv_gex_signal.value,
                    spot_to_zgl_pct=iv_result.spot_to_zero_gamma_pct,
                    iv_percentile=iv_result.iv_percentile,
                    sma10=sma10,
                    sma50=sma50,
                    vix_current=vix_current,
                    vix_10ma=vix_10ma,
                    vix_dev_pct=vix_dev_pct,
                    vix_rsi=vix_rsi,
                    hmm_result=hmm_result,
                    vol_sma3=vol_sma3,
                    vol_sma20=vol_sma20,
                    delta_gex=iv_result.delta_gex,
                    vix_term_structure_ratio=vix_term_structure_ratio,
                    vvix_current=vvix_current,
                    vvix_10ma=vvix_10ma,
                    spot_to_vt_pct=iv_result.spot_to_vt_pct,
                    breadth_proxy=breadth_proxy,
                    price_roc5=price_roc5,
                    total_gex=iv_result.total_gex,
                    gex_0dte_pct=iv_result.gex_0dte_pct,
                )
                _upsert_regime_snapshot(db, today, regime)
                log.info(
                    "regime_classified ticker=%s bias=%s hmm=%s sma_cross=%s",
                    ticker, regime.strategy_bias.value,
                    regime.hmm_state, sma_crossed,
                )

                results[ticker] = "ok"
                log.info("ticker_pulled ticker=%s", ticker)

            except Exception as exc:
                log.error("ticker_pull_failed ticker=%s error=%s", ticker, exc)
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
    expirations = parse_expirations(chain)
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
                    "call_iv":     _pct_to_dec(atm_call.get("impliedVolatility")),
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
                    "put_iv":     _pct_to_dec(atm_put.get("impliedVolatility")),
                    "put_oi":     atm_put.get("openInterest"),
                })

            db.table("greek_snapshots").upsert(
                row,
                on_conflict="user_id,ticker,obs_date,dte_bucket", 
            ).execute()

        except Exception as exc:
            log.warning("greek_snapshot_failed ticker=%s dte=%s error=%s", ticker, target_dte, exc)



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
    expirations = parse_expirations(chain)
    points = []
    for exp in expirations:
        dte = exp["dte"]
        call_map: dict[float, float] = {}
        put_map:  dict[float, float] = {}

        call_oi_map:  dict[float, int] = {}
        call_vol_map: dict[float, int] = {}
        put_oi_map:   dict[float, int] = {}
        put_vol_map:  dict[float, int] = {}

        for c in exp["calls"]:
            iv = c.get("volatility") or c.get("impliedVolatility") or 0
            if iv > 0:
                s = float(c["strikePrice"])
                call_map[s]     = float(iv) / 100
                call_oi_map[s]  = c.get("openInterest") or 0
                call_vol_map[s] = c.get("totalVolume") or 0

        for p in exp["puts"]:
            iv = p.get("volatility") or p.get("impliedVolatility") or 0
            if iv > 0:
                s = float(p["strikePrice"])
                put_map[s]     = float(iv) / 100
                put_oi_map[s]  = p.get("openInterest") or 0
                put_vol_map[s] = p.get("totalVolume") or 0

        for strike in sorted(set(call_map) | set(put_map)):
            points.append({
                "strike":   strike,
                "dte":      dte,
                "call_iv":  call_map.get(strike),
                "call_oi":  call_oi_map.get(strike),
                "call_vol": call_vol_map.get(strike),
                "put_iv":   put_map.get(strike),
                "put_oi":   put_oi_map.get(strike),
                "put_vol":  put_vol_map.get(strike),
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


def _fetch_nu_history(db, ticker: str, user_id: str, dte_target: int = 30) -> list[float]:
    """Return a time-ordered series of calibrated SABR ν values for the DTE
    slice closest to dte_target.  Used to compute vvol rank/percentile.

    Call this BEFORE upserting today's calibration so the series contains
    only prior observations (today excluded).
    """
    from collections import defaultdict
    from datetime import timedelta
    cutoff = (date.today() - timedelta(days=365)).isoformat()
    resp = (
        db.table("sabr_calibrations")
        .select("obs_date,dte,nu")
        .eq("user_id", user_id)
        .eq("ticker", ticker)
        .gte("obs_date", cutoff)
        .gte("n_points", 5)
        .order("obs_date", desc=False)
        .execute()
    )
    rows = resp.data or []
    if not rows:
        return []

    by_date: dict[str, list[dict]] = defaultdict(list)
    for r in rows:
        by_date[r["obs_date"]].append(r)

    series: list[float] = []
    for obs_date in sorted(by_date):
        best = min(by_date[obs_date], key=lambda s: abs(s["dte"] - dte_target))
        if best["nu"] is not None:
            series.append(float(best["nu"]))
    return series


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


def _upsert_sabr_calibrations(db, ticker: str, today: str, slices, user_id: str) -> None:
    for s in slices:
        db.table("sabr_calibrations").upsert(
            {
                "user_id": user_id, "ticker": ticker, "obs_date": today,
                "dte": s.dte, "alpha": s.alpha, "beta": s.beta,
                "rho": s.rho, "nu": s.nu, "rmse": s.rmse, "n_points": s.n_points,
            },
            on_conflict="user_id,ticker,obs_date,dte",
        ).execute()


def _upsert_iv_snapshot(db, ticker: str, today: str, iv_result, spot: float, vvol=None) -> None:
    gex_by_strike = [
        {"strike": g.strike, "dealer_gex": g.dealer_gex(spot),
         "call_oi": g.call_oi, "put_oi": g.put_oi}
        for g in iv_result.gex_strikes
    ]
    row: dict = {
        "ticker": ticker, "date": today,
        "atm_iv": iv_result.current_iv, "skew": iv_result.skew,
        "gex_by_strike": gex_by_strike, "total_gex": iv_result.total_gex,
        "max_gex_strike": iv_result.max_gex_strike,
        "put_call_ratio": iv_result.put_call_ratio,
        "underlying_price": spot,
    }
    if vvol is not None:
        row.update({
            "vvol_nu":         vvol.nu_current,
            "vvol_rank":       vvol.vvol_rank,
            "vvol_percentile": vvol.vvol_percentile,
            "vvol_rating":     vvol.vvol_rating,
            "vvol_trend":      vvol.nu_trend,
        })
    db.table("iv_snapshots").upsert(row, on_conflict="ticker,date").execute()


def _upsert_greek_grid(db, ticker: str, today: str, cells, spot: float, user_id: str) -> None:
    for cell in cells:
        db.table("greek_grid_snapshots").upsert(
            {
                
                "user_id": user_id,
                "ticker": ticker, 
                "obs_date": today,
                "strike_band": cell.strike_band.value,
                "expiry_bucket": cell.expiry_bucket.value,
                "strike": cell.strike,
                "expiry_date": cell.expiry_date.date().isoformat() if cell.expiry_date else None,
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
                "spot_at_obs": spot,
                "contract_count": cell.contract_count,

            },
            on_conflict="user_id,ticker,obs_date,strike_band,expiry_bucket",
        ).execute()


def _upsert_regime_snapshot(db, today: str, regime) -> None:
    db.table("regime_snapshots").upsert(
        {
            "ticker":                   regime.ticker,
            "obs_date":                 today,
            "gamma_regime":             regime.gamma_regime,
            "iv_gex_signal":            regime.iv_gex_signal,
            "sma10":                    regime.sma10,
            "sma50":                    regime.sma50,
            "sma_crossed":              regime.sma_crossed,
            "vix_current":              regime.vix_current,
            "vix_10ma":                 regime.vix_10ma,
            "vix_dev_pct":              regime.vix_dev_pct,
            "vix_rsi":                  regime.vix_rsi,
            "spot_to_zgl_pct":          regime.spot_to_zgl_pct,
            "iv_percentile":            regime.iv_percentile,
            "hmm_state":                regime.hmm_state,
            "hmm_probability":          regime.hmm_probability,
            "strategy_bias":            regime.strategy_bias.value,
            "signals":                  regime.signals,


            "vol_sma3":                 regime.vol_sma3,
            "vol_sma20":                regime.vol_sma20,




            "delta_gex":                regime.delta_gex,            # New institutional-grade fields
            "vix_term_structure_ratio": regime.vix_term_structure_ratio,
            "vvix_current":             regime.vvix_current,
            "spot_to_vt_pct":           regime.spot_to_vt_pct,
            "breadth_proxy":            regime.breadth_proxy,
            "gex_0dte":                 regime.gex_0dte,
            "gex_0dte_pct":             regime.gex_0dte_pct,
            "price_roc5":               regime.price_roc5,
            "total_gex":                regime.total_gex,
        },
        on_conflict="ticker,obs_date",
    ).execute()


async def _fetch_fmp_closes(
    client: httpx.AsyncClient, ticker: str, fmp_key: str, days: int = 65
) -> tuple[list[float], list[float]]:
    """Return (closes, volumes) oldest→newest. Volumes may be empty if field absent."""
    try:
        url = (
            f"https://financialmodelingprep.com/stable/historical-price-eod/full"
            f"?symbol={ticker}&timeseries={days}&apikey={fmp_key}"
        )
        resp = await client.get(url, timeout=30.0)
        if resp.status_code != 200:
            return [], []
        data = resp.json()
        hist = data if isinstance(data, list) else data.get("historical", [])
        closes  = [float(d["close"])  for d in hist if "close"  in d]
        volumes = [float(d["volume"]) for d in hist if "volume" in d]
        closes.reverse()   # oldest → newest
        volumes.reverse()
        return closes, volumes
    except Exception:
        return [], []
