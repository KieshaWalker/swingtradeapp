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
Schwab pull (every 8h)
  └─► regime_snapshots table (Supabase)
        └─► /regime/ml-analyze  (on every app open)
              └─► Current Regime screen
```

```
regime_snapshots (180 days)
  └─► /regime/train  (weekly, Sunday midnight UTC)
        └─► regime_ml_models table (Supabase)
              └─► loaded into API memory on startup
                    └─► used by /regime/ml-analyze to score tickers
```

---

## What Gets Stored in `regime_snapshots`

Every 8 hours the Schwab pull job records a snapshot per ticker with:

| Column | What it is |
|---|---|
| `ticker` | e.g. AAPL |
| `obs_date` | date of the snapshot |
| `gamma_regime` | `"positive"` or `"negative"` — current GEX side |
| `spot_to_zgl_pct` | how far spot is above/below zero-gamma level (%) |
| `iv_percentile` | IV rank 0–100 |
| `hmm_state` | `"low_vol"` or `"high_vol"` from Hidden Markov Model |
| `hmm_probability` | confidence in the HMM state |
| `sma10` / `sma50` | 10-day and 50-day moving averages |
| `vix_dev_pct` | VIX deviation from its 10-day MA |

---

## The 9 ML Features

The model is trained on these 9 features, derived from the snapshots above:

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
| `regime_duration` | How many consecutive observations in current regime — long tenure = mean-reversion pressure |

---

## What the Model Predicts

The model predicts: **will this ticker's gamma regime flip within the next 5 observations (~5 days)?**

- `y = 1` → flip (regime change coming)
- `y = 0` → stable (regime continues)

From the flip probability it derives:
- **ML Score** (`-1` to `+1`): positive = conviction to stay in positive gamma, negative = conviction to stay in negative gamma
- **Transition Probability**: raw P(flip) from `predict_proba`
- **Confidence**: how far the prediction is from the 50/50 boundary

---

## Scoring Modes

The app has two scoring modes. You can see which is active on the Current Regime screen under **ML Intelligence**.

### Supervised (LR or XGB) — best
Active when a trained model exists in `regime_ml_models`. Shows `LR` or `XGB` badge on ticker chips.
- Logistic Regression: fast, interpretable, handles class imbalance with `class_weight='balanced'`
- XGBoost: gradient boosted trees, better on non-linear patterns, uses `scale_pos_weight` for imbalance

### Heuristic — fallback
Used when no model has been trained yet (fresh install, or insufficient data).
Hand-tuned weights: ZGL level 25%, ZGL trend 20%, SMA cross 20%, HMM 15%, IVP trend 10%, VIX stress 10%.
Shows `H` badge on ticker chips.

---

## Getting Started — Step by Step

### Step 1 — Let data accumulate
The Schwab pull runs every 8 hours automatically. You need **at least 80 labeled training samples** before the model can train. A "sample" is one ticker-observation where the model can see both the features and whether a flip occurred within the next 5 obs.

Rule of thumb: **~2–3 weeks of data across ~5+ tickers** gives you enough samples.

Check how many you have:
```bash
curl -s -X POST https://swing-options-api-wx52beaw5q-uc.a.run.app/regime/train \
  -H 'Content-Type: application/json' \
  -d '{"model_type":"logistic","history_days":180}' | jq '{n_samples,sufficient_data}'
```

### Step 2 — Train the model
Once you have enough data, trigger training manually:

```bash
# Logistic Regression (recommended first)
curl -s -X POST https://swing-options-api-wx52beaw5q-uc.a.run.app/regime/train \
  -H 'Content-Type: application/json' \
  -d '{"model_type":"logistic","history_days":180}' | jq .
```

Or from the Cloud Scheduler job (runs every Sunday automatically after setup):
```bash
gcloud scheduler jobs run regime-train-weekly --location=us-central1 --project=options-trader-493420
```

A good model has **AUC-ROC > 0.65**. Above 0.75 is excellent for regime prediction.

### Step 3 — Try XGBoost
Once LR is working, try XGBoost for better non-linear pattern capture:

```bash
curl -s -X POST https://swing-options-api-wx52beaw5q-uc.a.run.app/regime/train \
  -H 'Content-Type: application/json' \
  -d '{"model_type":"xgboost","history_days":180}' | jq .
```

Compare the AUC-ROC — whichever is higher, that's the model that stays active (the latest trained model is always used).

### Step 4 — Verify it loaded
```bash
curl -s -X POST https://swing-options-api-wx52beaw5q-uc.a.run.app/regime/ml-analyze \
  -H 'Content-Type: application/json' \
  -d '{}' | jq '.model_metadata'
```

Should return `"available": true` with your AUC-ROC and training date.

---

## Interpreting the Current Regime Screen

### Market Context strip
- **Macro** — macro score from economic indicators (FED, jobs, PMI, etc.)
- **VIX Regime** — HMM state on VIX: `Low Vol` = directional trades, `High Vol` = straddles/hedges
- **SPY Gamma** — SPY's own gamma regime (sets the market-wide tone)

### ML Intelligence panel
- Shows whether you're in supervised or heuristic mode
- If supervised: AUC-ROC, accuracy, n_samples, flip event base rate
- Feature legend shows all 9 dimensions

### Ticker chips
Each chip shows:
- **Ticker** + **ML Score** (color: green = positive conviction, red = negative)
- **Confidence bar** — how certain the model is
- **flip X%** — probability this ticker's regime changes in the next ~5 days
- **Badge** — `LR` (logistic), `XGB` (xgboost), or `H` (heuristic)

### Reading the buckets
- **Positive Gamma** tickers: sell premium, iron condors, short straddles work well
- **Trending → Positive**: regime recovering — consider light long premium or wait for confirmation
- **Trending → Negative**: regime at risk — exit short premium, hedge deltas
- **Negative Gamma**: dealers are short gamma — moves accelerate; directional long premium, avoid short gamma

---

## Ongoing Maintenance

| Task | Frequency | How |
|---|---|---|
| Data collection | Automatic (every 8h) | Cloud Scheduler schwab-pull-8h |
| Model retraining | Automatic (every Sunday) | Cloud Scheduler regime-train-weekly |
| Manual retrain | On demand | `curl .../regime/train` |
| Check model health | After each retrain | `curl .../regime/ml-analyze \| jq .model_metadata` |

If AUC-ROC drops below 0.55 after a retrain, the market regime has structurally changed and the model needs more recent data — extend `history_days` or wait for more observations.

---

## Supabase Tables

| Table | Purpose |
|---|---|
| `regime_snapshots` | Raw feature data per ticker per day (training input) |
| `regime_ml_models` | Trained model weights + scaler (one row per training run) |
