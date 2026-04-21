# =============================================================================
# routers/regime.py
# =============================================================================
# POST /regime/classify — on-demand regime classification.
# Same pattern as /iv/analytics (compute + return, no DB write).
# The pipeline (schwab_pull.py) runs the persisted version every 8 hours.
# =============================================================================

from fastapi import APIRouter
from pydantic import BaseModel

from services.regime_service import classify_regime, CurrentRegime, StrategyBias
from services.hmm_regime import classify_vix_regime

router = APIRouter()


class RegimeRequest(BaseModel):
    ticker:             str
    gamma_regime:       str             # "positive" | "negative" | "unknown"
    iv_gex_signal:      str             # classicShortGamma | stableGamma | ...
    spot_to_zgl_pct:    float | None = None
    iv_percentile:      float | None = None
    sma10:              float | None = None
    sma50:              float | None = None
    vix_closes:         list[float] | None = None   # if provided, HMM + RSI computed here
    vix_current:        float | None = None
    vix_10ma:           float | None = None
    vix_dev_pct:        float | None = None
    vix_rsi:            float | None = None


class RegimeResponse(BaseModel):
    ticker:             str
    gamma_regime:       str
    iv_gex_signal:      str
    sma10:              float | None
    sma50:              float | None
    sma_crossed:        bool  | None
    vix_current:        float | None
    vix_10ma:           float | None
    vix_dev_pct:        float | None
    vix_rsi:            float | None
    spot_to_zgl_pct:    float | None
    iv_percentile:      float | None
    hmm_state:          str   | None
    hmm_probability:    float | None
    strategy_bias:      str
    signals:            list[str]


@router.post("/classify", response_model=RegimeResponse)
async def classify(body: RegimeRequest) -> RegimeResponse:
    # If caller provides raw VIX closes, compute HMM + derived metrics here.
    vix_rsi = body.vix_rsi
    vix_10ma = body.vix_10ma
    vix_dev_pct = body.vix_dev_pct
    vix_current = body.vix_current
    hmm_result = None

    if body.vix_closes:
        from services.regime_service import compute_wilder_rsi
        closes = [c for c in body.vix_closes if c and c > 0]
        if closes:
            vix_current = closes[-1]
            ma10 = closes[-10:] if len(closes) >= 10 else []
            vix_10ma = sum(ma10) / len(ma10) if ma10 else None
            if vix_10ma and vix_10ma > 0:
                vix_dev_pct = (vix_current - vix_10ma) / vix_10ma * 100
            vix_rsi = compute_wilder_rsi(closes)
            hmm_result = classify_vix_regime(closes)

    regime = classify_regime(
        ticker=body.ticker,
        gamma_regime=body.gamma_regime,
        iv_gex_signal=body.iv_gex_signal,
        spot_to_zgl_pct=body.spot_to_zgl_pct,
        iv_percentile=body.iv_percentile,
        sma10=body.sma10,
        sma50=body.sma50,
        vix_current=vix_current,
        vix_10ma=vix_10ma,
        vix_dev_pct=vix_dev_pct,
        vix_rsi=vix_rsi,
        hmm_result=hmm_result,
    )

    return RegimeResponse(
        ticker=regime.ticker,
        gamma_regime=regime.gamma_regime,
        iv_gex_signal=regime.iv_gex_signal,
        sma10=regime.sma10,
        sma50=regime.sma50,
        sma_crossed=regime.sma_crossed,
        vix_current=regime.vix_current,
        vix_10ma=regime.vix_10ma,
        vix_dev_pct=regime.vix_dev_pct,
        vix_rsi=regime.vix_rsi,
        spot_to_zgl_pct=regime.spot_to_zgl_pct,
        iv_percentile=regime.iv_percentile,
        hmm_state=regime.hmm_state,
        hmm_probability=regime.hmm_probability,
        strategy_bias=regime.strategy_bias.value,
        signals=regime.signals,
    )
