# =============================================================================
# services/heston.py
# =============================================================================
# First-order Heston stochastic-vol correction (Hull & White 1987 expansion).
# Exact port of FairValueEngine._hestonCorrection() from fair_value_engine.dart.
#
#  ΔV_Heston ≈ ρ_H × ξ × V_vanna × (1 − e^{−κT}) / κ
#             + (ξ²/2) × V_vomma × (1 − e^{−2κT}) / (2κ)
# =============================================================================

import math
from core.constants import HESTON_KAPPA, HESTON_XI, HESTON_RHO


def heston_correction(
    T: float,
    vanna: float,
    vomma: float,
    kappa: float = HESTON_KAPPA,
    xi: float = HESTON_XI,
    rho_h: float = HESTON_RHO,
) -> float:
    """First-order Heston correction to BS/SABR price.

    Args:
        T: Time to expiry in years.
        vanna: BS vanna at the SABR-adjusted vol.
        vomma: BS vomma (volga) at the SABR-adjusted vol.
        kappa: Mean-reversion speed (default 2.0).
        xi: Vol-of-vol (default 0.50).
        rho_h: Spot-vol correlation (default -0.70).

    Returns:
        Price correction ΔV to add to the SABR price.
    """
    k = kappa
    a = rho_h * xi * vanna * (1 - math.exp(-k * T)) / k
    b = (xi * xi / 2) * vomma * (1 - math.exp(-2 * k * T)) / (2 * k)
    return a + b
