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
#
# THE THREE ENDPOINTS ARE VERY DIFFERENT ANIMALS
# ----------------------------------------------
#   /classify    STATELESS, RULE-BASED, ONE TICKER. The caller supplies every
#                input; a documented priority-ordered decision table maps them
#                to a strategy bias. No DB, no model, fully reproducible.
#   /ml-analyze  STATEFUL, LEARNED, ALL TICKERS. Takes no request body at all —
#                it reads everything from Supabase and scores each ticker's
#                probability of a regime FLIP.
#   /train       Retrains the model behind /ml-analyze and hot-reloads it.
#
# WHAT "REGIME" MEANS HERE
# ------------------------
# The dealer gamma regime from iv_analytics (see routers/iv_analytics.py):
# positive gamma = hedging dampens moves = sell premium, trade ranges;
# negative gamma = hedging amplifies moves = own convexity, avoid short vol.
# /classify says which regime you are in NOW; /ml-analyze estimates how likely
# it is to FLIP, which is the more actionable question — the dangerous moment
# is the transition, not the state.
#
# TWO SCORING PATHS, ALWAYS REPORTED
# ----------------------------------
# /ml-analyze scores with a trained supervised model when one is loaded, and
# falls back to hand-tuned feature weights when not. `scoring_method` on every
# ticker says which produced that row ("supervised_logistic" /
# "supervised_xgboost" / "heuristic"). Never read a score without it — the
# heuristic path is a reasonable prior, not a fitted model, and the two are not
# calibrated to each other.
#
# BUCKET THRESHOLDS ARE DELIBERATELY ASYMMETRIC
#   stable_positive    current=pos AND score ≥ 0.15
#   trending_negative  current=pos AND score < 0.15   (at risk)
#   trending_positive  current=neg AND score > 0.10   (recovering)
#   stable_negative    current=neg AND score ≤ 0.10
# A positive-gamma name has to score clearly well to be called stable, while a
# negative-gamma name only has to score mildly well to be called recovering.
# The bias is intentional and conservative: it is cheaper to be warned about a
# stable regime than to be reassured about a deteriorating one.
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
    """Inputs for a single stateless classification.

    Only ticker, gamma_regime and iv_gex_signal are required — every other
    field is optional, and the decision table degrades gracefully as inputs go
    missing (fewer signals fire, and the bias tends toward 'unclear'). That is
    what lets a caller with a partial picture still get an answer.
    """
    ticker:             str
    # From iv_analytics. The two primary inputs — everything else refines.
    gamma_regime:       str             # "positive" | "negative" | "unknown"
    iv_gex_signal:      str             # classicShortGamma | stableGamma | ...
    # Signed distance from spot to the zero-gamma level. Small magnitude means
    # "near the flip", which the decision table treats as its own state.
    spot_to_zgl_pct:Optional[float] = None
    iv_percentile:Optional[float] = None
    # Trend context: sma10 above sma50 is the bullish alignment used as a
    # tiebreaker when the gamma read alone is ambiguous.
    sma10:Optional[float] = None
    sma50:Optional[float] = None
    # Pass RAW VIX CLOSES and the handler derives vix_current/10ma/dev/RSI and
    # fits the HMM itself — the preferred path, since it guarantees all five
    # are computed consistently. The individual fields below are the manual
    # alternative and are IGNORED when vix_closes is supplied.
    vix_closes:Optional[list[float]] = None   # if provided, HMM + RSI computed here
    vix_current:Optional[float] = None
    vix_10ma:Optional[float] = None
    vix_dev_pct:Optional[float] = None
    vix_rsi:Optional[float] = None
    vol_sma30:Optional[float] = None
    vol_sma50:Optional[float] = None


class RegimeResponse(BaseModel):
    """Echoes every input actually used, plus the two derived outputs.

    The echo is not redundancy: this shape is persisted to regime_snapshots and
    is the training data for /regime/train, so a row has to be self-describing
    — a stored verdict is useless without the inputs that produced it.
    """
    ticker:             str
    gamma_regime:       str
    iv_gex_signal:      str
    sma10:Optional[float]
    sma50:Optional[float]
    sma_crossed:Optional[bool]   # derived: sma10 vs sma50 alignment
    vix_current:Optional[float]
    vix_10ma:Optional[float]
    vix_dev_pct:Optional[float]  # VIX vs its own 10-day mean, in percent
    vix_rsi:Optional[float]      # Wilder RSI; > 70 flags mean-reversion risk
    spot_to_zgl_pct:Optional[float]
    iv_percentile:Optional[float]
    # HMM 2-state read on the VIX series. None when hmmlearn is unavailable or
    # fewer than 30 observations were supplied — the classifier then simply
    # skips its highest-priority rule rather than failing.
    hmm_state:Optional[str]
    hmm_probability:Optional[float]
    vol_sma30:Optional[float]
    vol_sma50:Optional[float]
    # ── The verdict ──────────────────────────────────────────────────────────
    # directional_bullish / directional_bearish / straddle_only /
    # premium_sell / unclear. This is a STRATEGY SHAPE, not a direction: a
    # straddle_only verdict says own convexity, without a view on which way.
    strategy_bias:      str
    # Human-readable list of which rules fired, in priority order. The audit
    # trail for the bias above.
    signals:            list[str]


class RegimeFeaturesOut(BaseModel):
    """The ML feature vector, exposed so a prediction can be inspected.

    Note the mix of LEVELS and TRENDS (spot_to_zgl_pct vs spot_to_zgl_trend,
    ivp vs ivp_trend). Direction of travel carries information the level does
    not — approaching the flip from above is a different situation from sitting
    at the same distance while moving away.

    Any field may be None; the model handles missing features, and how many
    were available feeds the confidence score.
    """
    spot_to_zgl_pct:Optional[float]
    spot_to_zgl_trend:Optional[float]
    ivp:Optional[float]
    ivp_trend:Optional[float]
    hmm_state:Optional[str]
    hmm_probability:Optional[float]
    sma_aligned:Optional[bool]
    vix_dev_pct:Optional[float]
    # How long the current regime has persisted. Regimes that have run a long
    # time are, empirically, more likely to end.
    regime_duration_days:     int
    # VIX / VIX3M. < 1 is contango (calm); > 1 is backwardation (stress) and
    # one of the strongest single flip predictors here.
    vix_term_structure_ratio:Optional[float] = None
    spot_to_vt_pct:Optional[float] = None   # distance to the volatility trigger
    breadth_proxy:Optional[float] = None    # RSP/SPY breadth z-score
    gex_0dte_pct:Optional[float] = None     # share of gamma expiring today
    price_roc5:Optional[float] = None       # 5-day rate of change


class PredictionDriverOut(BaseModel):
    """One feature's signed contribution to this ticker's prediction.

    Turns the model from a black box into something arguable: the UI can show
    'backwardation is pushing toward a flip, long regime duration is anchoring
    it'. value_text is pre-formatted for display, so the client does no
    unit-aware formatting of its own.
    """
    feature:    str
    label:      str
    value_text: str
    push_flip:  float   # > 0 pushes toward a regime flip, < 0 anchors it


class TickerRegimeOut(BaseModel):
    ticker:          str
    current_regime:  str    # "positive" | "negative" | "unknown"
    bucket:          str    # see the asymmetric thresholds in the header
    # Directional health score. HIGHER = the current regime is holding. Sign
    # and scale differ between the supervised and heuristic paths, so compare
    # scores only within the same scoring_method.
    ml_score:        float
    # Probability the regime FLIPS, clamped to [0.01, 0.99]. From the model's
    # predict_proba when supervised; derived from ml_score when heuristic.
    transition_prob: float
    # NOT model certainty — it measures INPUT QUALITY: half from how many
    # observations were available, half from how many of the 11 features were
    # non-None. Low confidence means "we could not see much", not "the model is
    # unsure".
    confidence:      float
    features:        RegimeFeaturesOut
    strategy_bias:   str
    signals:         list[str]
    last_updated:Optional[str]
    # WHICH PATH PRODUCED THIS ROW — read it before trusting ml_score.
    scoring_method:  str
    drivers:         list[PredictionDriverOut] = []


class MarketContextOut(BaseModel):
    """Market-wide backdrop, identical across every ticker in one response.

    Per-ticker gamma is only half the picture — a name in positive gamma
    against a VIX in a high-vol HMM state is far less stable than the same
    reading in a calm tape.
    """
    spy_regime:Optional[dict[str, Any]]
    vix_state:Optional[str]
    vix_current:Optional[float]
    vix_dev_pct:Optional[float]
    vix_hmm_prob:Optional[float]
    vix_rsi:Optional[float]


class ModelMetadataOut(BaseModel):
    """Provenance and quality of the model that produced this response.

    Two tiers, and the distinction matters enormously:
      TRAINING metrics (auc_roc, accuracy, precision, recall) are measured on
        held-out data at fit time. They can look good on an overfit model.
      LIVE metrics (live_*) come from reconciled real predictions in
        regime_ml_live_metrics — actual forecasts, scored after their outcome
        was known. This is the honest read.
    """
    available:   bool   # False => every ticker fell back to the heuristic path
    model_type:Optional[str]
    trained_at:Optional[str]
    n_samples:   int
    n_positive:  int    # flips; heavily outnumbered by non-flips
    auc_roc:     float  # the acceptance metric, because classes are imbalanced
    accuracy:    float  # near-useless alone: always-predict-'no flip' scores high
    precision:   float
    recall:      float
    # Live performance from reconciled predictions (regime_ml_live_metrics);
    # None/0 until reconciliation has resolved at least one prediction window.
    live_auc:Optional[float] = None
    # ALWAYS read live_hit_rate against live_base_rate. A 70% hit rate is
    # excellent if flips occur 30% of the time and worthless if they occur 70%
    # of the time — the base rate is what makes the hit rate interpretable.
    live_hit_rate:Optional[float] = None
    live_base_rate:Optional[float] = None
    # Brier score: mean squared error of the probabilities. LOWER is better.
    # Unlike AUC it grades CALIBRATION, not just ranking — a model that ranks
    # perfectly but always says "80%" scores well on AUC and badly here.
    live_brier:Optional[float] = None
    live_n:           int             = 0   # resolved predictions; small n = noisy
    live_window_days:Optional[int] = None
    live_computed_at:Optional[str] = None


class MlAnalyzeResponse(BaseModel):
    as_of:          str
    market_context: MarketContextOut
    model_metadata: ModelMetadataOut
    tickers:        list[TickerRegimeOut]


class TrainRequest(BaseModel):
    model_type:   str = "logistic"   # "logistic" | "xgboost"
    # Training window. Longer captures more regime flips (the rare positive
    # class) but risks spanning a structurally different market. 180 days is
    # the tuned compromise.
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
    # THE FIELD THAT MATTERS: False means the model was REJECTED and the
    # previous one is still serving. A 200 does not imply a retrain happened.
    sufficient_data: bool
    message:         str   # human-readable outcome, including why it was rejected


@router.post("/ml-analyze", response_model=MlAnalyzeResponse)
def ml_analyze() -> MlAnalyzeResponse:
    """Score every tracked ticker's probability of a gamma-regime flip.

    Takes NO request body — all inputs come from Supabase, so the response is
    always "as of the latest stored pipeline output". That also means its
    freshness is bounded by the intraday jobs: run it before regime-pull has
    landed and it scores yesterday's features.

    The body is almost entirely dataclass -> Pydantic field mapping. It is
    written out longhand rather than generated so the wire schema is pinned
    here: adding a field to RegimeFeatures does NOT silently change the API
    response, it requires an edit in this file. That is the intended tradeoff —
    verbosity in exchange for the Dart client never breaking unannounced.

    Declared sync (`def`), so FastAPI runs it in a threadpool — correct, since
    analyze_all_tickers does blocking Supabase I/O and numpy work.
    """
    # Lazy import: keeps Supabase client construction off the module-import path.
    from core.supabase_client import get_supabase
    sb     = get_supabase()
    # Single call does everything: loads features, scores, buckets, annotates.
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
            # Empty for the heuristic path — per-feature attribution only comes
            # out of a fitted model.
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
        # Computed once and shared by every ticker in this response.
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

    The manual twin of /jobs/regime-train, which runs weekly on a fixed config.
    This one takes parameters, so it is the path for experimenting with
    model_type or a different history window.

    ACCEPTANCE GATE: the model is stored and loaded ONLY if train_and_store
    reports sufficient_data — ≥40 labeled samples and out-of-sample AUC ≥0.52.
    A rejected run still returns 200; the previous model keeps serving and
    `message` explains why. Shipping a model no better than a coin flip would
    be worse than keeping the heuristic fallback.

    The hot reload is PER-INSTANCE on Cloud Run: other instances pick the new
    model up when they next cold-start via main.py's lifespan hook.
    """
    from core.supabase_client import get_supabase
    from services.regime_ml_trainer import train_and_store

    # Explicit 400 rather than letting an unknown model_type reach the trainer
    # — a typo here would otherwise surface as an opaque 500 minutes later.
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
    #
    # Stateless and rule-based: no DB, no model. The verdict follows the
    # priority-ordered decision table documented at the top of
    # services/regime_service.py — VVIX spike, then HMM high-vol, then
    # proximity to the gamma flip, then the iv_gex_signal cases, then SMA
    # alignment as the tiebreaker.
    #
    # NOTE: `async def` but every call inside is synchronous, so this occupies
    # the event loop for its duration. Harmless — the work is pure arithmetic
    # plus at most one small HMM fit — but it means this handler does NOT get
    # FastAPI's automatic threadpool offload the way the sync handlers above do.
    vix_rsi = body.vix_rsi
    vix_10ma = body.vix_10ma
    vix_dev_pct = body.vix_dev_pct
    vix_current = body.vix_current
    hmm_result = None
    if body.vix_closes:
        from services.regime_service import compute_wilder_rsi
        # Strip nulls and non-positive values before any VIX arithmetic.
        closes = [c for c in body.vix_closes if c and c > 0]
        if closes:
            # These four OVERWRITE anything the caller passed explicitly —
            # raw closes are treated as the more authoritative input, and
            # deriving all of them from one series keeps them mutually
            # consistent.
            vix_current = closes[-1]
            # Short-window guard: with fewer than 10 closes the 10-day mean is
            # left None rather than computed over a partial window, so
            # vix_dev_pct stays None too and its rules simply do not fire.
            ma10 = closes[-10:] if len(closes) >= 10 else []
            vix_10ma = sum(ma10) / len(ma10) if ma10 else None
            if vix_10ma and vix_10ma > 0:
                vix_dev_pct = (vix_current - vix_10ma) / vix_10ma * 100
            vix_rsi = compute_wilder_rsi(closes)
            # Returns None when hmmlearn is not installed or there are fewer
            # than 30 observations — the classifier's highest-priority rule
            # then does not fire, and it falls through to the gamma-based rules.
            hmm_result = classify_vix_regime(closes)

    regime = classify_regime(
        ticker=body.ticker,
        gamma_regime=body.gamma_regime,
        iv_gex_signal=body.iv_gex_signal,
        spot_to_zgl_pct=body.spot_to_zgl_pct,
        iv_percentile=body.iv_percentile,
        sma10=body.sma10,
        sma50=body.sma50,
        # The locals, not body.* — these carry the values derived above when
        # vix_closes was supplied.
        vix_current=vix_current,
        vix_10ma=vix_10ma,
        vix_dev_pct=vix_dev_pct,
        vix_rsi=vix_rsi,
        hmm_result=hmm_result,
        vol_sma30=body.vol_sma30,
        vol_sma50=body.vol_sma50,
    )

    # Echo every input alongside the verdict — this shape is persisted to
    # regime_snapshots and later becomes /regime/train's training data.
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
        vol_sma30=regime.vol_sma30,
        vol_sma50=regime.vol_sma50,
        # str Enum -> its wire value, so Dart parses a stable string.
        strategy_bias=regime.strategy_bias.value,
        signals=regime.signals,
    )
