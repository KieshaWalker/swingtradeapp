from __future__ import annotations

from datetime import date
from fastapi import APIRouter
from pydantic import BaseModel

from core.constants import DEFAULT_R
from services.iv_analytics import analyse
from core.supabase_client import get_supabase

router = APIRouter()


class IvAnalyticsRequest(BaseModel):
    chain: dict          # Schwab options chain JSON
    history: list[dict] = []
    risk_free_rate: float | None = None


class IvSnapshotRequest(IvAnalyticsRequest):
    ticker: str
    obs_date: str | None = None


def _result_to_dict(result, spot: float = 0.0) -> dict:
    return {
        "ticker": result.ticker,
        "current_iv": result.current_iv,
        "iv52w_high": result.iv52w_high,
        "iv52w_low": result.iv52w_low,
        "iv_rank": result.iv_rank,
        "iv_percentile": result.iv_percentile,
        "rating": result.rating.value,
        "history_days": result.history_days,
        "skew": result.skew,
        "skew_avg_52w": result.skew_avg_52w,
        "skew_z_score": result.skew_z_score,
        "total_gex": result.total_gex,
        "max_gex_strike": result.max_gex_strike,
        "put_call_ratio": result.put_call_ratio,
        "total_vex": result.total_vex,
        "total_cex": result.total_cex,
        "total_volga": result.total_volga,
        "max_vex_strike": result.max_vex_strike,
        "gamma_regime": result.gamma_regime.value,
        "vanna_regime": result.vanna_regime.value,
        "zero_gamma_level": result.zero_gamma_level,
        "spot_to_zero_gamma_pct": result.spot_to_zero_gamma_pct,
        "delta_gex": result.delta_gex,
        "gamma_slope": result.gamma_slope.value,
        "iv_gex_signal": result.iv_gex_signal.value,
        "put_wall_density": result.put_wall_density,
        "gex_strikes": [
            {
                "strike": g.strike,
                "call_oi": g.call_oi,
                "put_oi": g.put_oi,
                "call_gamma": g.call_gamma,
                "put_gamma": g.put_gamma,
                "dealer_gex": g.dealer_gex(spot),
            }
            for g in result.gex_strikes
        ],
    }


@router.post("/analytics")
def iv_analytics_endpoint(req: IvAnalyticsRequest):
    spot = float(req.chain.get("underlyingPrice", 0))
    result = analyse(req.chain, req.history, req.risk_free_rate)
    return _result_to_dict(result, spot)


@router.post("/snapshot")
def iv_snapshot_endpoint(req: IvSnapshotRequest):
    spot = float(req.chain.get("underlyingPrice", 0))
    result = analyse(req.chain, req.history, req.risk_free_rate)
    today = req.obs_date or date.today().isoformat()
    gex_by_strike = [
        {"strike": g.strike, "dealer_gex": g.dealer_gex(spot), "call_oi": g.call_oi, "put_oi": g.put_oi}
        for g in result.gex_strikes
    ]
    db = get_supabase()
    db.table("iv_snapshots").upsert({
        "ticker": req.ticker,
        "date": today,
        "atm_iv": result.current_iv,
        "skew": result.skew,
        "gex_by_strike": gex_by_strike,
        "total_gex": result.total_gex,
        "max_gex_strike": result.max_gex_strike,
        "put_call_ratio": result.put_call_ratio,
        "underlying_price": spot,
    }, on_conflict="ticker,date").execute()
    return {**_result_to_dict(result, spot), "persisted": True, "date": today}
