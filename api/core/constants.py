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

# ── Risk-free rate ────────────────────────────────────────────────────────────
DEFAULT_R: float = 0.0433  # ~4.33% SOFR (FairValueEngine._defaultR)

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

# SABR parameter bounds for optimizer
SABR_ALPHA_BOUNDS = (1e-6, 5.0)
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
IV_GEX_ELEVATED_PCT: float = 50.0  # IVP >= 50 → "elevated"
IV_DEEP_LONG_GEX: float = 1000.0   # totalGex >= $1B → Deep Long Gamma (Gm=1.2)

# ── Realized vol ───────────────────────────────────────────────────────────────
RV_WINDOW_20D: int = 20
RV_WINDOW_60D: int = 60
RV_MIN_HISTORY_PCT: int = 10   # Minimum history for percentile ranking
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
