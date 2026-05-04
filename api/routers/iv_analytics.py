from __future__ import annotations

# =============================================================================
# routers/iv_analytics.py
# =============================================================================
# POST /iv/analytics -> iv_analytics_endpoint
# POST /iv/snapshot  -> iv_snapshot_endpoint
#
# Schema and persistence notes:
#   IvAnalyticsRequest and IvSnapshotRequest define the request payloads used
#   by lib/services/python_api/python_api_client.dart through ivAnalytics()
#   and ivSnapshot(). If any request field changes, update the Dart client.
#
#   /iv/snapshot writes to Supabase table iv_snapshots. If the table schema or
#   persisted field set changes, update this endpoint and any Supabase helpers.
#
# Related files:
#   api/services/iv_analytics.py   -> analyse() implementation
#   api/core/supabase_client.py    -> Supabase connection
#   lib/services/python_api/python_api_client.dart -> Dart request/response mappings
#   lib/services/macro/macro_score_provider.dart  -> consumes IV analytics output indirectly
# =============================================================================

from datetime import date
from fastapi import APIRouter
from pydantic import BaseModel

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
        "put_wall_density":   result.put_wall_density,
        "underlying_price":   spot,
        "gex_0dte":           result.gex_0dte,
        "gex_0dte_pct":       result.gex_0dte_pct,
        "volatility_trigger": result.volatility_trigger,
        "spot_to_vt_pct":     result.spot_to_vt_pct,
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
        "second_order": [
            {
                "strike":     s.strike,
                "call_oi":    s.call_oi,
                "put_oi":     s.put_oi,
                "call_vanna": s.call_vanna,
                "put_vanna":  s.put_vanna,
                "call_charm": s.call_charm,
                "put_charm":  s.put_charm,
                "call_volga": s.call_volga,
                "put_volga":  s.put_volga,
            }
            for s in result.second_order
        ],
        "skew_curve": [
            {
                "strike":    p.strike,
                "moneyness": p.moneyness,
                "call_iv":   p.call_iv,
                "put_iv":    p.put_iv,
            }
            for p in result.skew_curve
        ],
        # Vol-of-vol
        "vvol_nu":         result.vvol_nu,
        "vvol_rank":       result.vvol_rank,
        "vvol_percentile": result.vvol_percentile,
        "vvol_rating":     result.vvol_rating,
        "vvol_trend":      result.vvol_trend,
        "rnd": [s.to_dict() for s in result.rnd],
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
        # Extended fields (migration 027)
        "iv_rank": result.iv_rank,
        "iv_percentile": result.iv_percentile,
        "iv_rating":             result.rating.value,
        "gamma_regime":          result.gamma_regime.value,
        "gamma_slope":           result.gamma_slope.value,
        "iv_gex_signal":         result.iv_gex_signal.value,
        "zero_gamma_level":      result.zero_gamma_level,
        "spot_to_zero_gamma_pct": result.spot_to_zero_gamma_pct,
        "delta_gex":             result.delta_gex,
        "put_wall_density":      result.put_wall_density,
        "vanna_regime":          result.vanna_regime.value,
        "total_vex": result.total_vex,
        "total_cex": result.total_cex,
        "total_volga": result.total_volga,
        "max_vex_strike": result.max_vex_strike,
        "skew_avg_52w": result.skew_avg_52w,
        "skew_z_score": result.skew_z_score,
        "rnd": [s.to_dict() for s in result.rnd] or None,
        # Institutional GEX fields (migration 029)
        "gex_0dte":           result.gex_0dte,
        "gex_0dte_pct":       result.gex_0dte_pct,
        "volatility_trigger": result.volatility_trigger,
        "spot_to_vt_pct":     result.spot_to_vt_pct,
        # Vol-of-vol (migration 028)
        "vvol_nu":         result.vvol_nu,
        "vvol_rank":       result.vvol_rank,
        "vvol_percentile": result.vvol_percentile,
        "vvol_rating":     result.vvol_rating,
        "vvol_trend":      result.vvol_trend,
    }, on_conflict="ticker,date").execute()
    return {**_result_to_dict(result, spot), "persisted": True, "date": today}
