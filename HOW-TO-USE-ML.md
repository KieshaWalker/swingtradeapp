# Regime ML — How It Works & How to Use It

## Overview

The Current Regime tab uses a supervised machine learning pipeline to classify every
tracked ticker into one of four buckets based on where its gamma regime is headed:

| Bucket | Meaning |
|---|---|
| **Positive Gamma** | Currently positive GEX, model says stay there |
| **Trending → Positive** | Currently negative GEX, but signals improving |
| **Trending → Negative** | Currently positive GEX, but signals deteriorating |
| **Negative Gamma** | Currently negative GEX, model says stay there |

---

## Data Flow — End to End

```
regime_pull (hourly 13:18–21:18 UTC, Mon–Fri; ET session guard trims edges)
  └─► regime_snapshots table (Supabase)
        ├─ intraday runs: overwrite today's row, is_final = false
        └─ 4 PM ET close-capture run: is_final = true, then…
              ├─► log today's predictions → regime_ml_predictions
              └─► reconcile predictions ≥5 sessions old → regime_ml_live_metrics
```

```
regime_snapshots, is_final rows only (180 days)
  └─► /regime/train  (weekly, Sunday midnight UTC)
        └─► regime_ml_models table (Supabase)
              └─► loaded into API memory on startup
                    └─► used by /regime/ml-analyze to score tickers
```

`/regime/ml-analyze` runs on every app open and feeds the Current Regime screen.

### Point-in-time discipline

Intraday runs keep the screen fresh but only the close-capture row is *final*.
Training, supervised scoring, prediction logging, and reconciliation all use
final rows exclusively — so the model is trained, served, and judged on the
same end-of-day convention. Rows written before the `is_final` migration count
as final (they were each day's last write).

---

## What Gets Stored in `regime_snapshots`

Each run upserts one row per ticker per day with the gamma regime
(`positive`/`negative`), ZGL and Volatility Trigger distances, IV percentile,
HMM vol state + probability, SMA10/SMA50, VIX family metrics (level, 10-MA
deviation, RSI, VIX/VIX3M term structure, VVIX), breadth proxy, 0DTE GEX
share, 5-day price ROC, volume SMAs, and the gate signals from
`regime_service.py`.

---

## The 14 ML Features

| Feature | What it captures |
|---|---|
| `spot_to_zgl_pct` | Current ZGL distance — positive means above zero-gamma (stabilizing) |
| `spot_to_zgl_trend` | 5-obs OLS slope of ZGL distance — is spot moving toward or away from ZGL? |
| `ivp` | IV percentile — high IVP signals stress |
| `ivp_trend` | Rising IVP = stress building (bearish for positive gamma) |
| `hmm_state_num` | 0=low_vol (stable), 1=high_vol (volatile), 0.5=unknown |
| `hmm_probability` | Confidence in the HMM state |
| `sma_aligned_num` | 1=SMA10>SMA50 (bullish trend), 0=bearish, 0.5=unknown |
| `vix_dev_pct` | VIX above 10-MA signals regime stress |
| `regime_duration` | Consecutive observations in current regime — long tenure = mean-reversion pressure |
| `vix_term_structure_ratio` | VIX/VIX3M — above 1 = backwardation (near-term stress premium) |
| `spot_to_vt_pct` | Distance from the Volatility Trigger |
| `breadth_proxy` | RSP/SPY 5-day return ratio z-score — breadth confirmation/divergence |
| `gex_0dte_pct` | Share of total GEX from 0DTE options — high = structurally unstable gamma |
| `price_roc5` | 5-day price rate-of-change (%) — momentum |

The VIX HMM (2-state Gaussian on log-returns + level) fits on ~2 years of
FRED VIX closes each run for stable state identification.

---

## What the Model Predicts

The model predicts: **will this ticker's gamma regime flip within the next 5 final observations (~5 sessions)?**

- `y = 1` → flip (regime change coming)
- `y = 0` → stable (regime continues)

From the flip probability it derives:
- **ML Score** (`-1` to `+1`): positive = conviction to stay in positive gamma, negative = conviction to stay in negative gamma
- **Transition Probability**: calibrated P(flip) — see *Calibration* below
- **Confidence**: how far the prediction is from the 50/50 boundary

---

## How Training Is Evaluated

Training runs walk-forward cross-validation with **purge and embargo measured
in trading dates** (not pooled rows — all tickers of one date stay on the same
side of every fold boundary, because same-date samples share VIX/breadth
features and flip together):

- **Purge**: the last 5 dates before each test fold are dropped from training —
  their labels look forward into the test window.
- **Embargo**: the first 5 dates of each test fold are skipped — their feature
  lookback overlaps training data.
- The reported **AUC-ROC is the mean out-of-sample AUC across folds**, the
  honest leakage-free estimate.

**Acceptance gate**: a model needs OOS AUC ≥ 0.52 to be used; otherwise the
hand-tuned heuristic stays active. On daily financial data, AUC 0.52–0.58 is
the realistic band — treat anything above 0.60 with suspicion.

**Sample thresholds**: ≥40 labeled samples to train at all (early mode,
stronger regularization, single temporal split), ≥~55 distinct trading dates
(roughly 200+ samples) for full walk-forward validation.

### Calibration

`class_weight='balanced'` (LR) and `scale_pos_weight` (XGB) deliberately
distort raw `predict_proba`, so an isotonic calibrator is fitted on the pooled
out-of-sample fold predictions and stored with the model. The flip % shown in
the app is the calibrated probability — it should match realized flip
frequency, which is exactly what the live reliability tracking checks.

---

## Live Performance Monitoring

Training metrics say the model *was* good on history. The live loop measures
whether it still is:

1. **Prediction logging** — the close-capture `regime_pull` run logs every
   ticker's flip probability into `regime_ml_predictions` (one row per ticker
   per day; heuristic predictions are logged too, tagged by `scoring_method`).
2. **Reconciliation** — the same run resolves predictions whose 5-session
   window has closed: `realized_flip` = did the regime actually change?
3. **Live metrics** — rolling 60-day AUC, hit rate, realized flip rate, Brier
   score, reliability bins, and a supervised-vs-heuristic breakdown are written
   to `regime_ml_live_metrics` and shown in the **ML Intelligence** panel under
   the cyan **LIVE** row.

**How to read it**: Live AUC well below training AUC = the market has drifted
from the trained patterns — retrain or expect the heuristic fallback. Hit rate
must beat the realized flip rate baseline (always predicting "stable" already
scores `1 − flip rate`). Brier ≥ 0.25 = probabilities no better than coin-flip
guessing.

---

## Scoring Modes

### Supervised (LR or XGB) — best
Active when an accepted model exists in `regime_ml_models`. Shows `LR` or `XGB` badge on ticker chips.
- Logistic Regression: fast, interpretable, handles class imbalance with `class_weight='balanced'`
- XGBoost: gradient boosted trees, better on non-linear patterns, uses `scale_pos_weight` for imbalance

### Heuristic — fallback
Used when no model has been trained yet or the last model failed the AUC gate.
Hand-tuned weights over the same 14 features. Shows `H` badge on ticker chips.

---

## Getting Started — Step by Step

### Step 1 — Let data accumulate
The regime pull runs hourly during market sessions; one finalized row per
ticker per day is what counts. You need **≥40 labeled samples** to train at
all and **~3 months across 5+ tickers** for full walk-forward validation.

Check how many you have:
```bash
curl -s -X POST https://swing-options-api-wx52beaw5q-uc.a.run.app/regime/train \
  -H 'Content-Type: application/json' \
  -d '{"model_type":"logistic","history_days":180}' | jq '{n_samples,sufficient_data}'
```

### Step 2 — Train the model
```bash
# Logistic Regression (recommended first)
curl -s -X POST https://swing-options-api-wx52beaw5q-uc.a.run.app/regime/train \
  -H 'Content-Type: application/json' \
  -d '{"model_type":"logistic","history_days":180}' | jq .
```

Or run the weekly Cloud Scheduler job manually:
```bash
gcloud scheduler jobs run regime-train-weekly --location=us-central1 --project=options-trader-493420
```

A model is accepted at **walk-forward AUC ≥ 0.52**; 0.55+ is good for regime
prediction at this horizon.

### Step 3 — Try XGBoost
```bash
curl -s -X POST https://swing-options-api-wx52beaw5q-uc.a.run.app/regime/train \
  -H 'Content-Type: application/json' \
  -d '{"model_type":"xgboost","history_days":180}' | jq .
```

Don't pick the winner from training AUC alone — after a couple of weeks the
**live AUC by scoring method** (in `regime_ml_live_metrics.by_method`) is the
evidence-based comparison.

### Step 4 — Verify it loaded
```bash
curl -s -X POST https://swing-options-api-wx52beaw5q-uc.a.run.app/regime/ml-analyze \
  -H 'Content-Type: application/json' \
  -d '{}' | jq '.model_metadata'
```

Should return `"available": true` plus `live_*` fields once reconciliation has
resolved its first predictions (~5 sessions after deploy).

---

## Interpreting the Current Regime Screen

### Market Context strip
- **Macro** — macro score from economic indicators (FED, jobs, PMI, etc.)
- **VIX Regime** — HMM state on VIX: `Low Vol` = directional trades, `High Vol` = straddles/hedges
- **SPY Gamma** — SPY's own gamma regime (sets the market-wide tone)

### ML Intelligence panel
- Shows whether you're in supervised or heuristic mode
- If supervised: training AUC-ROC, accuracy, precision, recall, sample counts
- **LIVE row**: rolling out-of-sample AUC, hit rate, realized flip rate, Brier
- Feature legend shows all 14 dimensions

### Ticker chips
- **Ticker** + **ML Score** (green = positive conviction, red = negative)
- **Confidence bar** — distance from the 50/50 boundary
- **flip X%** — calibrated probability the regime changes within ~5 sessions
- **Badge** — `LR` (logistic), `XGB` (xgboost), or `H` (heuristic)

### "Why this prediction" (tap a ticker chip)
The detail sheet shows the top 6 **prediction drivers** — the features that
actually produced this flip probability, with the value the model saw:
- Supervised LR: exact per-feature contributions (coefficient × scaled value)
- Supervised XGB: SHAP attributions from the booster
- Heuristic: the weighted component breakdown

Bars diverge from center — **amber (right) pushes toward a regime flip, cyan
(left) anchors the current regime**. The strongest driver is also appended to
the signals list ("Top driver: …"). Use this to sanity-check the model: if a
high flip probability is driven by a feature you know is stale or weird that
day, discount the prediction.

### Reading the buckets
- **Positive Gamma**: sell premium, iron condors, short straddles work well
- **Trending → Positive**: regime recovering — light long premium or wait for confirmation
- **Trending → Negative**: regime at risk — exit short premium, hedge deltas
- **Negative Gamma**: dealers short gamma — moves accelerate; directional long premium, avoid short gamma

---

## Ongoing Maintenance

| Task | Frequency | How |
|---|---|---|
| Data collection | Automatic (hourly, market sessions) | Cloud Scheduler regime-pull |
| Prediction logging + reconciliation | Automatic (close-capture run) | inside regime-pull |
| Model retraining | Automatic (every Sunday) | Cloud Scheduler regime-train-weekly |
| Manual retrain | On demand | `curl .../regime/train` |
| Check model health | Weekly | `curl .../regime/ml-analyze \| jq .model_metadata` — compare `live_auc` vs `auc_roc` |

If live AUC degrades toward 0.5 while training AUC stays high, the market has
structurally changed since training — retrain on fresher history. If a retrain
fails the 0.52 gate, the system falls back to the heuristic automatically.

---

## Supabase Tables

| Table | Purpose |
|---|---|
| `regime_snapshots` | Feature data per ticker per day; `is_final` marks the EOD row used by ML |
| `regime_ml_models` | Trained model weights + scaler + calibration (last 5 runs kept per type) |
| `regime_ml_predictions` | Daily logged predictions; `realized_flip` back-filled by reconciliation |
| `regime_ml_live_metrics` | Rolling live AUC / hit rate / Brier / reliability bins |
