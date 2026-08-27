# =============================================================================
# core/constants.py
# =============================================================================
# Single source of truth for every numeric constant carried over from Dart.
# All values verified against:
#   lib/features/blotter/services/fair_value_engine.dart
#   lib/services/vol_surface/sabr_calibrator.dart
#   lib/services/vol_surface/arb_checker.dart
#   lib/services/iv/iv_analytics_service.dart
#   lib/features/options/services/option_scoring_engine.dart
#   lib/services/math/nelder_mead.dart
# =============================================================================
#
# UNITS — the conventions these constants assume
# ----------------------------------------------
# Getting one of these wrong produces a plausible-looking number, not an error,
# so they are worth stating once here:
#   * Vols are DECIMALS (0.21 = 21%) everywhere EXCEPT raw Schwab contract
#     fields, which are percent. iv_analytics and option_scoring take the
#     percent form; everything else takes decimals.
#   * Heston theta and V0 are VARIANCES, not vols. Their bounds are therefore
#     vol², which is why a 0.5 cap means 70.7% vol and not 50%.
#   * Time is ACT/365 on CALENDAR days. Theta and charm are per calendar day.
#     Realized vol is the exception: it annualizes with 252 TRADING days
#     (RV_TRADING_DAYS_YEAR), because it is computed from daily returns.
#   * GEX totals are $ millions; VEX is $ of delta per vol point.
#
# THE RECURRING LESSON IN THIS FILE: BOUNDS MUST SCALE
# ----------------------------------------------------
# Several blocks below carry a long comment about a bound that was silently
# wrong. They are all the same failure, and it is worth recognising the shape
# before adding a new constant:
#
#   A fixed numeric bound on a parameter that is NOT scale-invariant pins the
#   fit at the boundary instead of failing. RMSE can still look acceptable,
#   because the optimizer does the best it can from the corner it is stuck in.
#
# It has bitten SABR's alpha (which scales as F^(1-beta), so a fixed ceiling
# tightens as the underlying rises), Heston's theta and V0 (variances, so their
# ceiling is vol²), and Heston's rho (clamped to negative on the assumption
# that equity skew is always negative — a regime, not an invariant).
#
# So when a fit looks poor, CHECK FOR BOUNDARY SOLUTIONS FIRST, before assuming
# the model is wrong. A parameter resting on its bound is the tell. The Heston
# bounds below were widened by measuring exactly that, not by prior belief —
# and widening was stopped at the point where further width changed no RMSE.
# =============================================================================

# ── Risk-free rate ────────────────────────────────────────────────────────────
DEFAULT_R: float = 0.0344  # ~3.44% SOFR (FairValueEngine._defaultR)

# ── SABR model defaults ────────────────────────────────────────────────────────
SABR_BETA: float = 0.5      # CEV exponent — fixed for equity (square-root CEV)
SABR_RHO: float = -0.7      # Spot-vol correlation default
SABR_NU: float = 0.40       # Vol-of-vol default

# ── SABR calibration settings ─────────────────────────────────────────────────
SABR_MIN_POINTS: int = 4          # Minimum quotes for a valid fit
SABR_MAX_IV_FILTER: float = 3.0   # Drop IVs > 300% as data errors

# SABR Nelder-Mead initial guess (rho0, nu0 from sabr_calibrator.dart)
SABR_INITIAL_RHO0: float = -0.30
SABR_INITIAL_NU0: float = 0.40

# Fallback nu seeds, tried in order only when the first fit lands on a bound
# (see calibrate_slice). Kept short — each entry costs another Nelder-Mead run.
SABR_RETRY_NU0 = (1.5, 2.5)

# nu at or below this is a collapsed fit (no vol-of-vol → pure CEV smile),
# which triggers the retry above.
SABR_NU_DEGENERATE: float = 0.01

# SABR parameter bounds for optimizer.
#
# alpha is NOT scale-invariant: alpha ≈ sigma * F^(1-beta), so with beta=0.5 a
# fixed ceiling of C caps the representable vol at C/sqrt(F) — the cap tightens
# as the underlying rises. A flat 5.0 silently limited SNDK (F≈1230) to 14% vol
# and pinned every fit on the boundary. SABR_ALPHA_BOUNDS[1] is now only a
# floor for the ceiling; calibrate_slice() raises it to
# SABR_ALPHA_MAX_MULT * alpha0 (alpha0 = the ATM-implied seed) per slice.
SABR_ALPHA_BOUNDS = (1e-6, 5.0)
SABR_ALPHA_MAX_MULT: float = 3.0
SABR_RHO_BOUNDS = (-0.999, 0.999)
SABR_NU_BOUNDS = (1e-6, 5.0)

# SABR formula guards (sabr_calibrator.dart ATM branch + chi(z) guards)
SABR_ATM_LOG_THRESHOLD: float = 1e-6
SABR_CHIZ_THRESHOLD: float = 1e-10

# SABR reliability threshold
SABR_RELIABLE_RMSE: float = 0.015  # rmse < 1.5% AND nPoints >= 5
SABR_RELIABLE_MIN_POINTS: int = 5

# ── Nelder-Mead optimizer settings (nelder_mead.dart) ─────────────────────────
NM_MAX_ITER: int = 1500
NM_FATOL: float = 1e-8   # fTol in Dart
NM_XATOL: float = 1e-7   # xTol in Dart

# ── Heston correction parameters (fair_value_engine.dart) ─────────────────────
HESTON_KAPPA: float = 2.0    # Mean-reversion speed
HESTON_XI: float = 0.50      # Vol-of-vol
HESTON_RHO: float = -0.70    # Spot-vol correlation

# ── Heston calibration bounds ─────────────────────────────────────────────────
#
# theta and V0 are VARIANCE, so their ceiling is vol² — a cap of 0.5 caps vol at
# sqrt(0.5) = 70.7%. Every name quoting above that pinned theta AND V0 at the
# ceiling, which drove xi to its own floor (vol-of-vol cannot help once the
# level is unreachable) and rho to zero: the model then collapses to Black-
# Scholes at a flat 70.7% for every strike. 4.0 admits vol up to 200%.
#
# rho's ceiling was 0.0 on the assumption that equity skew is always negative.
# That is a regime, not an invariant — single names with call-heavy demand
# calibrate to positive rho, and clamping there silently discards the skew.
# Kept symmetric: any asymmetric ceiling just relocates the pinning (a 0.5 cap
# pinned all 9 test names at exactly +0.5).
#
# Widths were set by measuring which parameters still rested on a bound, not by
# prior: kappa 15 -> 50 and xi 3 -> 5 each removed real pinning; going further
# (kappa 80, xi 6) changed no RMSE and was not adopted.
HESTON_KAPPA_BOUNDS = (0.1, 50.0)
HESTON_THETA_BOUNDS = (0.005, 4.0)   # long-run variance → vol <= 200%
HESTON_XI_BOUNDS    = (0.01, 5.0)    # vol-of-vol
HESTON_RHO_BOUNDS   = (-0.99, 0.99)
HESTON_V0_BOUNDS    = (0.005, 4.0)   # initial variance → vol <= 200%

# Calibration DTE window. One 5-parameter affine diffusion cannot fit a 1-day
# smile and a 2.4-year smile at once: SNDK quotes 198% at 1 DTE against 111% at
# 869 DTE, and spanning that forces corner solutions no bound width fixes.
# Restricting to the tradeable range took median RMSE from 3.71 to 1.87 vol
# points across the 9 test names. Sub-week expiries are additionally
# event/pin-dominated and not diffusive at all.
HESTON_MIN_DTE: int = 7
HESTON_MAX_DTE: int = 120

# A parameter this close to either end of its box is a corner solution, not a
# fit. Reported via HestonCalibResult.converged.
HESTON_BOUND_TOL: float = 0.01       # fraction of each bound's range

# ── Fair value guards ──────────────────────────────────────────────────────────
FV_SABR_VOL_MIN: float = 0.01
FV_SABR_VOL_MAX: float = 5.0
FV_SIGXT_GUARD: float = 1e-8  # σ√T < this → fallback to intrinsic

# ── Portfolio risk limits ──────────────────────────────────────────────────────
DELTA_THRESHOLD: float = 500.0   # Max |portfolio delta| in $-delta
ES95_MULT: float = 2.063         # φ(1.645)/0.05

# ── Arbitrage checker ──────────────────────────────────────────────────────────
ARB_EPSILON: float = 1e-4   # Tolerance for bid-ask noise

# ── IV analytics ──────────────────────────────────────────────────────────────
IV_OTM_MIN_PCT: float = 0.01    # 1% OTM minimum for skew wing
IV_OTM_MAX_PCT: float = 0.15    # 15% OTM maximum for skew wing
IV_MIN_DTE_PREF: int = 21       # Prefer expirations >= 21 DTE for skew
IV_GEX_WINDOW_PCT: float = 0.20 # ±20% strike range for GEX/VEX
IV_GAMMA_SLOPE_BAND_PCT: float = 0.08  # ±8% band for gamma slope
IV_GAMMA_SLOPE_THRESHOLD_PCT: float = 0.10  # 10% of max abs GEX
IV_ZERO_GAMMA_NEAR_PCT: float = 0.10  # ±10% for zero-gamma fallback
IV_PUT_WALL_BAND_PCT: float = 0.05    # ±5% for put wall density
IV_MIN_HISTORY_IVR: int = 10     # Minimum history days for IVR/IVP
IV_MIN_HISTORY_SKEW: int = 5     # Minimum history days for skew z-score
IV_WINDOW_4W: int = 21           # 4-week window (21 trading days)
IV_WINDOW_26W: int = 130         # 26-week window (130 trading days)
IV_GEX_ELEVATED_PCT: float = 67.0  # IVR >= 67 → "elevated" (top third of 52w range; matches "vol expansion" language)
IV_DEEP_LONG_GEX: float = 1000.0   # totalGex >= $1B → Deep Long Gamma (Gm=1.2)

# ── Risk-Neutral Density (Breeden-Litzenberger) ────────────────────────────
RND_STRIKE_HALF_WIDTH_PCT: float = 0.30  # ±30% of spot — SABR extrapolates stably here
RND_NUM_GRID_POINTS: int = 200           # 200-pt grid → ~0.3% spacing
RND_FD_STEP_PCT: float = 0.005          # Central-diff h = 0.5% of spot

# Only these DTE buckets are calibrated. Every consumer of the RND surface reads
# a fixed handful of slices — RndChart picks nearest 7/30/60/90, the vol-surface
# card takes the first reliable one, and vvol reads nearest-30 — but the surface
# used to calibrate SABR for *every* expiration in the chain (20+ on liquid
# names), which was ~99% of /iv/snapshot's CPU time and pushed the endpoint past
# the client's 30s timeout whenever a scheduled job shared the instance.
RND_TARGET_DTES: tuple = (7, 30, 60, 90)

# ── Realized vol ───────────────────────────────────────────────────────────────
# Price-count conventions match DB column names (rv_21d, rv_63d):
#   21 closes → 20 log-returns  (≈ 1-month HV)
#   63 closes → 62 log-returns  (≈ 1-quarter HV)
RV_PRICES_20D: int = 21
RV_PRICES_60D: int = 63
RV_MIN_HISTORY_PCT: int = 10   # Minimum history days for percentile ranking
RV_TRADING_DAYS_YEAR: int = 252

# ── Option scoring ─────────────────────────────────────────────────────────────
SCORE_GRADE_A: int = 75
SCORE_GRADE_B: int = 55
SCORE_GRADE_C: int = 35
SHORT_GAMMA_CAP: float = 35.0

# ── Greek grid bands (moneyness %) ────────────────────────────────────────────
GRID_BAND_ATM_LOWER: float = -5.0    # ±5% = ATM
GRID_BAND_ATM_UPPER: float = 5.0
GRID_BAND_NEAR_LOWER: float = -10.0  # ±5-10% = Near
GRID_BAND_NEAR_UPPER: float = 10.0
# Outside ±10% = OTM


# ── Schwab pull scheduler ──────────────────────────────────────────────────────
SCHWAB_PULL_INTERVAL_HOURS: int = 8
SABR_RECAL_INTERVAL_MINUTES: int = 30

# ── Regime classifier scope guard ─────────────────────────────────────────────
# Thresholds (1.5% ZGL proximity, VIX RSI bands, $50M delta-GEX significance)
# are calibrated for index and large-cap equity underlyings (SPY, QQQ, large-caps
# with GEX > $100M). Do not apply to small/mid-cap without recalibrating.
MIN_MEANINGFUL_TOTAL_GEX_USD: float = 100_000_000  # $100M minimum absolute GEX
