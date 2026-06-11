# =============================================================================
# routers/regime.py
# =============================================================================
# POST /regime/classify    — on-demand single-ticker classification.
# POST /regime/ml-analyze  — ML-enhanced multi-ticker analysis; 4-bucket.
# POST /regime/train       — trigger supervised training from Supabase history.
#
# Related modules:
#   api/services/regime_service.py      -> core classification logic and feature computation
#   api/services/regime_ml_service.py   -> loads the latest trained model and analyzes tickers
#   api/services/regime_ml_trainer.py   -> trains models from Supabase history and persists them
#   api/core/supabase_client.py         -> Supabase access for regime features
#
# Schema notes:
#   RegimeRequest defines the incoming payload expected by Flutter and Cloud Scheduler.
#   RegimeResponse defines the return shape used by the app and persisted outputs.
#   If any field is added or renamed here, update lib/services/python_api/python_api_client.dart
#   and any code that constructs /regime/classify or reads /regime/ml-analyze outputs.
# =============================================================================

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from typing import Any, Optional

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
    spot_to_zgl_pct:Optional[float] = None
    iv_percentile:Optional[float] = None
    sma10:Optional[float] = None
    sma50:Optional[float] = None
    vix_closes:Optional[list[float]] = None   # if provided, HMM + RSI computed here
    vix_current:Optional[float] = None
    vix_10ma:Optional[float] = None
    vix_dev_pct:Optional[float] = None
    vix_rsi:Optional[float] = None
    vol_sma3:Optional[float] = None
    vol_sma20:Optional[float] = None


class RegimeResponse(BaseModel):
    ticker:             str
    gamma_regime:       str
    iv_gex_signal:      str
    sma10:Optional[float]
    sma50:Optional[float]
    sma_crossed:Optional[bool]
    vix_current:Optional[float]
    vix_10ma:Optional[float]
    vix_dev_pct:Optional[float]
    vix_rsi:Optional[float]
    spot_to_zgl_pct:Optional[float]
    iv_percentile:Optional[float]
    hmm_state:Optional[str]
    hmm_probability:Optional[float]
    vol_sma3:Optional[float]
    vol_sma20:Optional[float]
    strategy_bias:      str
    signals:            list[str]


class RegimeFeaturesOut(BaseModel):
    spot_to_zgl_pct:Optional[float]
    spot_to_zgl_trend:Optional[float]
    ivp:Optional[float]
    ivp_trend:Optional[float]
    hmm_state:Optional[str]
    hmm_probability:Optional[float]
    sma_aligned:Optional[bool]
    vix_dev_pct:Optional[float]
    regime_duration_days:     int
    vix_term_structure_ratio:Optional[float] = None
    spot_to_vt_pct:Optional[float] = None
    breadth_proxy:Optional[float] = None
    gex_0dte_pct:Optional[float] = None
    price_roc5:Optional[float] = None


class PredictionDriverOut(BaseModel):
    feature:    str
    label:      str
    value_text: str
    push_flip:  float   # > 0 pushes toward a regime flip, < 0 anchors it


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
    last_updated:Optional[str]
    scoring_method:  str
    drivers:         list[PredictionDriverOut] = []


class MarketContextOut(BaseModel):
    spy_regime:Optional[dict[str, Any]]
    vix_state:Optional[str]
    vix_current:Optional[float]
    vix_dev_pct:Optional[float]
    vix_hmm_prob:Optional[float]
    vix_rsi:Optional[float]


class ModelMetadataOut(BaseModel):
    available:   bool
    model_type:Optional[str]
    trained_at:Optional[str]
    n_samples:   int
    n_positive:  int
    auc_roc:     float
    accuracy:    float
    precision:   float
    recall:      float
    # Live performance from reconciled predictions (regime_ml_live_metrics);
    # None/0 until reconciliation has resolved at least one prediction window.
    live_auc:Optional[float] = None
    live_hit_rate:Optional[float] = None
    live_base_rate:Optional[float] = None
    live_brier:Optional[float] = None
    live_n:           int             = 0
    live_window_days:Optional[int] = None
    live_computed_at:Optional[str] = None


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
                vix_term_structure_ratio=t.features.vix_term_structure_ratio,
                spot_to_vt_pct=t.features.spot_to_vt_pct,
                breadth_proxy=t.features.breadth_proxy,
                gex_0dte_pct=t.features.gex_0dte_pct,
                price_roc5=t.features.price_roc5,
            ),
            strategy_bias=t.strategy_bias,
            signals=t.signals,
            last_updated=t.last_updated,
            scoring_method=t.scoring_method,
            drivers=[
                PredictionDriverOut(
                    feature=d.feature,
                    label=d.label,
                    value_text=d.value_text,
                    push_flip=d.push_flip,
                )
                for d in t.drivers
            ],
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
            live_auc=m.live_auc,
            live_hit_rate=m.live_hit_rate,
            live_base_rate=m.live_base_rate,
            live_brier=m.live_brier,
            live_n=m.live_n,
            live_window_days=m.live_window_days,
            live_computed_at=m.live_computed_at,
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
            f"Model not accepted — got {result.n_samples} labeled samples. "
            f"Training needs ≥40 samples (≥200 across ~50 trading days for full "
            f"walk-forward validation) and an out-of-sample AUC ≥0.52. "
            f"Accumulate more regime history and retry."
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
    # If caller provides raw VIX closes, compute derived metrics before classification.
    # This ensures the output RegimeResponse includes the same HMM/R SI fields that
    # are stored to Supabase regime_snapshots and used by downstream analysis.
    #
    # For feature or schema changes, update these locations together:
    #   api/routers/regime.py
    #   api/services/regime_service.py
    #   api/services/regime_ml_service.py
    #   api/services/regime_ml_trainer.py
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
        vol_sma3=body.vol_sma3,
        vol_sma20=body.vol_sma20,
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
        vol_sma3=regime.vol_sma3,
        vol_sma20=regime.vol_sma20,
        strategy_bias=regime.strategy_bias.value,
        signals=regime.signals,        
    )
