from __future__ import annotations

# =============================================================================
# tests/test_option_scoring.py
# =============================================================================
# DTE scoring boundary tests — guards against the dte=7 / dte=21 discontinuity
# that was previously present when two formula branches both activated at dte=7.
# =============================================================================

import pytest

from services.option_scoring import score


# ---------------------------------------------------------------------------
# Minimal contract stub
# ---------------------------------------------------------------------------

_UNDERLYING = 100.0

def _contract(dte: int, delta: float = -0.40) -> dict:
    return {
        "daysToExpiration": dte,
        "delta": delta,
        "bid": 1.00,
        "ask": 1.10,
        "impliedVolatility": 30.0,
        "totalVolume": 500,
        "openInterest": 1000,
        "strikePrice": 100.0,
    }


# ---------------------------------------------------------------------------
# DTE score is continuous and monotone in each zone
# ---------------------------------------------------------------------------

class TestDteScoreContinuity:
    def _dte_score(self, dte: int) -> int:
        result = score(_contract(dte), _UNDERLYING)
        return result.dte_score

    def test_dte_zero_scores_zero(self):
        assert self._dte_score(0) == 0

    def test_dte_1_scores_above_zero(self):
        assert self._dte_score(1) > 0

    def test_dte_7_is_below_dte_8(self):
        # Was broken: dte=7 scored 20 (old upper branch) not ~10 (lower branch)
        score_at_7 = self._dte_score(7)
        score_at_8 = self._dte_score(8)
        assert score_at_7 < score_at_8, (
            f"dte=7 score ({score_at_7}) should be less than dte=8 score ({score_at_8})"
        )

    def test_dte_7_scores_at_most_10(self):
        assert self._dte_score(7) <= 10

    def test_dte_21_scores_20(self):
        assert self._dte_score(21) == 20

    def test_dte_45_scores_20(self):
        assert self._dte_score(45) == 20

    def test_dte_zone_7_to_21_monotone(self):
        scores = [self._dte_score(d) for d in range(7, 22)]
        assert scores == sorted(scores), f"Non-monotone in [7,21]: {scores}"

    def test_dte_zone_21_to_45_all_20(self):
        scores = [self._dte_score(d) for d in range(21, 46)]
        assert all(s == 20 for s in scores)

    def test_dte_decreasing_beyond_45(self):
        # dte=50 → round(20 - 5/45*10) = round(18.9) = 19 < 20
        assert self._dte_score(50) < 20
        assert self._dte_score(90) < self._dte_score(50)

    def test_dte_180_flag(self):
        result = score(_contract(181), _UNDERLYING)
        assert any("180" in f for f in result.flags)


# ---------------------------------------------------------------------------
# Boundary: dte=7 pin-risk flag
# ---------------------------------------------------------------------------

class TestDtePinRiskFlag:
    def test_pin_risk_flag_at_7(self):
        result = score(_contract(7), _UNDERLYING)
        assert any("pin risk" in f.lower() for f in result.flags)

    def test_no_pin_risk_flag_at_8(self):
        result = score(_contract(8), _UNDERLYING)
        assert not any("pin risk" in f.lower() for f in result.flags)

    def test_expiring_today_flag_at_0(self):
        result = score(_contract(0), _UNDERLYING)
        assert any("expir" in f.lower() for f in result.flags)
