from __future__ import annotations

# =============================================================================
# tests/test_iv_units.py
# =============================================================================
# Guards the IV unit convention (PERCENT throughout the Python backend).
# Schwab delivers impliedVolatility as PERCENT (e.g. 21.0 = 21%).
# iv_analytics.analyse() must preserve that unit for atm_iv / current_iv.
#
# The critical failure mode (pre-fix): vol_period_pull.py was dividing an
# already-decimal IV by 100 again, producing IV = 0.0021 in the DB instead
# of 0.21. These tests catch that class of bug.
# =============================================================================

import pytest

from services.iv_analytics import analyse as iv_analyse


# ---------------------------------------------------------------------------
# Minimal chain factory
# ---------------------------------------------------------------------------

def _make_chain(volatility_pct: float, spot: float = 100.0) -> dict:
    """Return a minimal Schwab chain dict with `volatility` in percent form."""
    return {
        "symbol": "TEST",
        "underlyingPrice": spot,
        "volatility": volatility_pct,
        "expirations": [],
    }


def _make_chain_from_contracts(spot: float = 100.0, iv_pct: float = 25.0) -> dict:
    """Chain where chain-level volatility=0 so ATM IV comes from contracts."""
    contract = {
        "strikePrice": spot,
        "impliedVolatility": iv_pct,
        "delta": -0.50,
        "gamma": 0.02,
        "openInterest": 1000,
        "totalVolume": 200,
    }
    return {
        "symbol": "TEST",
        "underlyingPrice": spot,
        "volatility": 0,
        "expirations": [
            {
                "dte": 30,
                "calls": [contract],
                "puts": [contract],
            }
        ],
    }


# ---------------------------------------------------------------------------
# atm_iv is in PERCENT, not decimal
# ---------------------------------------------------------------------------

class TestIvUnitConvention:
    """current_iv from iv_analyse must be in percent (e.g., ~21.0 not ~0.21)."""

    def test_chain_level_volatility_preserved_as_percent(self):
        result = iv_analyse(_make_chain(21.0), history=[])
        # Must be >1.0 (percent), not < 1.0 (decimal-after-divide)
        assert result.current_iv > 1.0, (
            f"current_iv={result.current_iv:.4f} looks like decimal; expected percent"
        )
        assert abs(result.current_iv - 21.0) < 5.0, (
            f"current_iv={result.current_iv} far from input 21.0% — possible /100 bug"
        )

    def test_high_volatility_preserved(self):
        result = iv_analyse(_make_chain(80.0), history=[])
        assert result.current_iv > 1.0
        assert abs(result.current_iv - 80.0) < 10.0

    def test_atm_iv_from_contracts_is_percent(self):
        result = iv_analyse(_make_chain_from_contracts(spot=100.0, iv_pct=30.0), history=[])
        if result.current_iv > 0:
            assert result.current_iv > 1.0, (
                f"Contract-derived current_iv={result.current_iv:.4f} looks like decimal"
            )

    def test_iv_rank_in_0_to_100(self):
        # Provide enough history (252 rows) with consistent percent-form IVs
        history = [{"atm_iv": 20.0 + i * 0.05, "date": f"2025-{(i % 12) + 1:02d}-01"}
                   for i in range(252)]
        result = iv_analyse(_make_chain(30.0), history=history)
        if result.iv_rank is not None:
            assert 0 <= result.iv_rank <= 100, (
                f"iv_rank={result.iv_rank} out of [0, 100]"
            )

    def test_iv_percentile_in_0_to_100(self):
        history = [{"atm_iv": 20.0 + i * 0.05, "date": f"2025-{(i % 12) + 1:02d}-01"}
                   for i in range(252)]
        result = iv_analyse(_make_chain(30.0), history=history)
        if result.iv_percentile is not None:
            assert 0 <= result.iv_percentile <= 100


# ---------------------------------------------------------------------------
# Rate unit handling: rates > 0.1 are treated as percent and divided
# ---------------------------------------------------------------------------

class TestRateUnitHandling:
    """Rates provided as percent (e.g. 5.0) must not blow up the analytics."""

    def test_rate_as_percent_accepted(self):
        result = iv_analyse(_make_chain(25.0), history=[], risk_free_rate=5.0)
        assert result.current_iv > 1.0

    def test_rate_as_decimal_accepted(self):
        result = iv_analyse(_make_chain(25.0), history=[], risk_free_rate=0.05)
        assert result.current_iv > 1.0

    def test_boundary_rate_0_1(self):
        # Exactly 0.1 — below threshold so treated as decimal
        result = iv_analyse(_make_chain(25.0), history=[], risk_free_rate=0.10)
        assert result.current_iv > 1.0
