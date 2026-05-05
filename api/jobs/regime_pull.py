from __future__ import annotations

# =============================================================================
# jobs/regime_pull.py
# =============================================================================
# Job 7 — Read iv_snapshots + price history → regime classification → upsert regime_snapshots.
# Cron: 18 * * * 1-5  (18 min after vol_surface_pull, Mon–Fri)
#
# Reads today's iv_snapshots (written by iv_pull).
# Fetches price/volume history for SMA and ROC computation.
# Fetches VIX/VVIX/SPY/RSP for macro regime signals.
# =============================================================================

import asyncio
import logging
from datetime import date, datetime, timezone

import httpx

from core.supabase_client import get_supabase
from jobs.common import get_tickers, fetch_schwab_closes
from services.regime_service import classify_regime, compute_wilder_rsi
from services.hmm_regime import classify_vix_regime

log = logging.getLogger(__name__)


async def run_regime_pull() -> dict:
    now = datetime.now(timezone.utc)
    if now.hour >= 16:
        log.info("regime_pull: skipped (after 4 PM UTC)")
        return {"status": "after_4pm"}
    
    db = get_supabase()
    today = date.today().isoformat()
    rows = get_tickers(db)
    if not rows:
        log.warning("regime_pull: no tickers")
        return {"status": "no_tickers"}

    results: dict[str, str] = {}

    async with httpx.AsyncClient(timeout=60.0) as client:
        # Fetch macro index histories in parallel
        (
            (vix_closes, _),
            (vix3m_closes, _),
            (vvix_closes, _),
            (spy_closes, _),
            (rsp_closes, _),
        ) = await asyncio.gather(
            fetch_schwab_closes(client, "$VIX.X",   days=65),
            fetch_schwab_closes(client, "$VIX3M.X", days=5),
            fetch_schwab_closes(client, "$VVIX.X",  days=15),
            fetch_schwab_closes(client, "SPY",      days=25),
            fetch_schwab_closes(client, "RSP",      days=25),
        )

        # VIX metrics
        vix_current: float | None = None
        vix_10ma:    float | None = None
        vix_dev_pct: float | None = None
        vix_rsi:     float | None = None
        hmm_result = None
        vix_term_structure_ratio: float | None = None
        vvix_current: float | None = None
        vvix_10ma:    float | None = None
        breadth_proxy: float | None = None

        if vix_closes:
            vix_current = vix_closes[-1]
            ma10 = vix_closes[-10:] if len(vix_closes) >= 10 else []
            vix_10ma = sum(ma10) / len(ma10) if ma10 else None
            if vix_10ma and vix_10ma > 0 and vix_current is not None:
                vix_dev_pct = (vix_current - vix_10ma) / vix_10ma * 100
            vix_rsi    = compute_wilder_rsi(vix_closes)
            hmm_result = classify_vix_regime(vix_closes)

        if vix3m_closes and vix_current is not None and vix3m_closes[-1] > 0:
            vix_term_structure_ratio = vix_current / vix3m_closes[-1]

        if vvix_closes:
            vvix_current = vvix_closes[-1]
            vvix_ma = vvix_closes[-10:] if len(vvix_closes) >= 10 else vvix_closes
            vvix_10ma = sum(vvix_ma) / len(vvix_ma)

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
                mean = sum(ratios) / len(ratios)
                std  = (sum((r - mean) ** 2 for r in ratios) / len(ratios)) ** 0.5
                if std > 1e-6:
                    breadth_proxy = (ratios[-1] - mean) / std

        log.info(
            "regime_pull: vix=%.2f 10ma=%s ts_ratio=%s vvix=%s breadth_z=%s hmm=%s",
            vix_current or 0,
            f"{vix_10ma:.2f}" if vix_10ma else "—",
            f"{vix_term_structure_ratio:.3f}" if vix_term_structure_ratio else "—",
            f"{vvix_current:.1f}" if vvix_current else "—",
            f"{breadth_proxy:.2f}" if breadth_proxy else "—",
            hmm_result.state.value if hmm_result else "—",
        )

        async def _process(row: dict) -> tuple[str, str]:
            ticker  = row["ticker"]
            user_id = row["user_id"]
            try:
                # Read today's IV snapshot (written by iv_pull)
                iv_snap = (
                    db.table("iv_snapshots")
                    .select(
                        "gamma_regime,iv_gex_signal,spot_to_zero_gamma_pct,"
                        "iv_percentile,delta_gex,total_gex,"
                        "spot_to_vt_pct,gex_0dte,gex_0dte_pct,underlying_price"
                    )
                    .eq("ticker", ticker)
                    .eq("date", today)
                    .maybe_single()
                    .execute()
                )
                if iv_snap is None or not iv_snap.data:
                    log.warning("regime_pull: no iv_snapshot for ticker=%s", ticker)
                    return ticker, "no_iv_snapshot"

                iv = iv_snap.data
                spot = float(iv.get("underlying_price") or 0)

                # Price/volume history for SMA + ROC
                closes, volumes = await fetch_schwab_closes(client, ticker, days=65)
                clean_c = [c for c in closes  if c and c > 0]
                clean_v = [v for v in volumes if v and v > 0]

                sma10:     float | None = sum(clean_c[-10:]) / 10  if len(clean_c) >= 10  else None
                sma50:     float | None = sum(clean_c[-50:]) / 50  if len(clean_c) >= 50  else None
                vol_sma3:  float | None = sum(clean_v[-3:])  / 3   if len(clean_v) >= 3   else None
                vol_sma20: float | None = sum(clean_v[-20:]) / 20  if len(clean_v) >= 20  else None
                price_roc5: float | None = None
                if len(clean_c) >= 6 and clean_c[-6] > 0:
                    price_roc5 = (clean_c[-1] - clean_c[-6]) / clean_c[-6] * 100

                regime = classify_regime(
                    ticker=ticker,
                    gamma_regime=iv.get("gamma_regime"),
                    iv_gex_signal=iv.get("iv_gex_signal"),
                    spot_to_zgl_pct=iv.get("spot_to_zero_gamma_pct"),
                    iv_percentile=iv.get("iv_percentile"),
                    sma10=sma10,
                    sma50=sma50,
                    vix_current=vix_current,
                    vix_10ma=vix_10ma,
                    vix_dev_pct=vix_dev_pct,
                    vix_rsi=vix_rsi,
                    hmm_result=hmm_result,
                    vol_sma3=vol_sma3,
                    vol_sma20=vol_sma20,
                    delta_gex=iv.get("delta_gex"),
                    vix_term_structure_ratio=vix_term_structure_ratio,
                    vvix_current=vvix_current,
                    vvix_10ma=vvix_10ma,
                    spot_to_vt_pct=iv.get("spot_to_vt_pct"),
                    breadth_proxy=breadth_proxy,
                    price_roc5=price_roc5,
                    total_gex=iv.get("total_gex"),
                    gex_0dte=iv.get("gex_0dte"),
                    gex_0dte_pct=iv.get("gex_0dte_pct"),
                )
                _upsert_regime_snapshot(db, today, regime)
                log.info("regime_ok ticker=%s bias=%s", ticker, regime.strategy_bias.value)
                return ticker, "ok"
            except Exception as exc:
                log.error("regime_failed ticker=%s error=%r", ticker, exc, exc_info=True)
                return ticker, f"error:{exc!r}"

        results = dict(await asyncio.gather(*[_process(r) for r in rows]))

    return {"status": "complete", "tickers": results, "date": today}


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
            "delta_gex":                regime.delta_gex,
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
