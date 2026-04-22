# =============================================================================
# routers/regime.py
# =============================================================================
# POST /regime/classify    — on-demand single-ticker classification.
# POST /regime/ml-analyze  — ML-enhanced multi-ticker analysis; 4-bucket.
# POST /regime/train       — trigger supervised training from Supabase history.
# =============================================================================

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from typing import Any

from services.regime_service import classify_regime, CurrentRegime, StrategyBias
from services.hmm_regime import classify_vix_regime
from services.regime_ml_service import (
    analyze_all_tickers,
    load_trained_model,
    MlAnalysisResult,
    TickerRegimeResult,
    RegimeFeatures,
    MarketContext,
    ModelMetadata,
)

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


class RegimeFeaturesOut(BaseModel):
    spot_to_zgl_pct:       float | None
    spot_to_zgl_trend:     float | None
    ivp:                   float | None
    ivp_trend:             float | None
    hmm_state:             str   | None
    hmm_probability:       float | None
    sma_aligned:           bool  | None
    vix_dev_pct:           float | None
    regime_duration_days:  int


class TickerRegimeOut(BaseModel):
    ticker:          str
    current_regime:  str
    bucket:          str
    ml_score:        float
    transition_prob: float
    confidence:      float
    features:        RegimeFeaturesOut
    strategy_bias:   str
    signals:         list[str]
    last_updated:    str | None
    scoring_method:  str


class MarketContextOut(BaseModel):
    spy_regime:   dict[str, Any] | None
    vix_state:    str | None
    vix_current:  float | None
    vix_dev_pct:  float | None
    vix_hmm_prob: float | None
    vix_rsi:      float | None


class ModelMetadataOut(BaseModel):
    available:   bool
    model_type:  str | None
    trained_at:  str | None
    n_samples:   int
    n_positive:  int
    auc_roc:     float
    accuracy:    float
    precision:   float
    recall:      float


class MlAnalyzeResponse(BaseModel):
    as_of:          str
    market_context: MarketContextOut
    model_metadata: ModelMetadataOut
    tickers:        list[TickerRegimeOut]


class TrainRequest(BaseModel):
    model_type:   str = "logistic"   # "logistic" | "xgboost"
    history_days: int = 180


class TrainResponse(BaseModel):
    model_type:      str
    trained_at:      str
    n_samples:       int
    n_positive:      int
    accuracy:        float
    auc_roc:         float
    precision:       float
    recall:          float
    sufficient_data: bool
    message:         str


@router.post("/ml-analyze", response_model=MlAnalyzeResponse)
def ml_analyze() -> MlAnalyzeResponse:
    from core.supabase_client import get_supabase
    sb     = get_supabase()
    result = analyze_all_tickers(sb)
    m      = result.model_metadata

    tickers_out = [
        TickerRegimeOut(
            ticker=t.ticker,
            current_regime=t.current_regime,
            bucket=t.bucket,
            ml_score=t.ml_score,
            transition_prob=t.transition_prob,
            confidence=t.confidence,
            features=RegimeFeaturesOut(
                spot_to_zgl_pct=t.features.spot_to_zgl_pct,
                spot_to_zgl_trend=t.features.spot_to_zgl_trend,
                ivp=t.features.ivp,
                ivp_trend=t.features.ivp_trend,
                hmm_state=t.features.hmm_state,
                hmm_probability=t.features.hmm_probability,
                sma_aligned=t.features.sma_aligned,
                vix_dev_pct=t.features.vix_dev_pct,
                regime_duration_days=t.features.regime_duration_days,
            ),
            strategy_bias=t.strategy_bias,
            signals=t.signals,
            last_updated=t.last_updated,
            scoring_method=t.scoring_method,
        )
        for t in result.tickers
    ]
    return MlAnalyzeResponse(
        as_of=result.as_of,
        market_context=MarketContextOut(
            spy_regime=result.market_context.spy_regime,
            vix_state=result.market_context.vix_state,
            vix_current=result.market_context.vix_current,
            vix_dev_pct=result.market_context.vix_dev_pct,
            vix_hmm_prob=result.market_context.vix_hmm_prob,
            vix_rsi=result.market_context.vix_rsi,
        ),
        model_metadata=ModelMetadataOut(
            available=m.available,
            model_type=m.model_type,
            trained_at=m.trained_at,
            n_samples=m.n_samples,
            n_positive=m.n_positive,
            auc_roc=m.auc_roc,
            accuracy=m.accuracy,
            precision=m.precision,
            recall=m.recall,
        ),
        tickers=tickers_out,
    )


@router.post("/train", response_model=TrainResponse)
def train_model(req: TrainRequest) -> TrainResponse:
    """Trigger supervised training from Supabase history.

    Trains on labeled regime flip data, stores the model in regime_ml_models,
    then hot-reloads it into the in-memory inference cache.
    """
    from core.supabase_client import get_supabase
    from services.regime_ml_trainer import train_and_store

    if req.model_type not in ("logistic", "xgboost"):
        raise HTTPException(status_code=400, detail="model_type must be 'logistic' or 'xgboost'")

    sb     = get_supabase()
    result = train_and_store(sb, model_type=req.model_type, history_days=req.history_days)

    if result.sufficient_data:
        # Hot-reload the newly trained model into the inference cache
        load_trained_model(sb)
        msg = (
            f"Trained {result.model_type} on {result.n_samples} samples "
            f"({result.n_positive} flips). AUC-ROC {result.auc_roc:.3f}. "
            f"Model loaded and active."
        )
    else:
        msg = (
            f"Insufficient training data — need ≥80 labeled samples, "
            f"got {result.n_samples}. Accumulate more regime history and retry."
        )

    return TrainResponse(
        model_type=result.model_type,
        trained_at=result.trained_at,
        n_samples=result.n_samples,
        n_positive=result.n_positive,
        accuracy=result.accuracy,
        auc_roc=result.auc_roc,
        precision=result.precision,
        recall=result.recall,
        sufficient_data=result.sufficient_data,
        message=msg,
    )


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
