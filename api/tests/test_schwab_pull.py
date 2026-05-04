from __future__ import annotations

# =============================================================================
# tests/test_schwab_pull.py
# =============================================================================
# Tests for jobs/schwab_pull.py:
#   - Pure helper functions (no mocks needed)
#   - Upsert functions (mock Supabase DB)
#   - Full run_schwab_pull pipeline (mock httpx + Supabase)
# to run use this command: source venv/bin/activate && python -m pytest tests/test_schwab_pull.py -v 2>&1
# =============================================================================

import asyncio
import json
from unittest.mock import AsyncMock, MagicMock, patch, call

import pytest

from jobs.schwab_pull import (
    _atm_contract,
    _chain_to_vol_points,
    _pct_to_dec,
    _upsert_vol_surface,
    _upsert_sabr_calibrations,
    _upsert_greek_snapshots,
    run_schwab_pull,
)

# ---------------------------------------------------------------------------
# Fixture: minimal but realistic Schwab chain for one expiration (4 DTE)
# ---------------------------------------------------------------------------

def _make_chain(spot: float = 500.0, dte: int = 4) -> dict:
    """Build a minimal Schwab chain dict with 3 strikes around spot."""
    key = f"2026-05-08:{dte}"
    strikes = [spot - 5, spot, spot + 5]

    def _contract(strike: float, is_call: bool) -> dict:
        delta_sign = 1 if is_call else -1
        moneyness = (spot - strike) / spot
        base_delta = 0.50 + delta_sign * moneyness * 5  # rough approximation
        base_delta = max(-1.0, min(1.0, base_delta))
        return {
            "strikePrice": strike,
            "daysToExpiration": dte,
            "delta": base_delta if is_call else -abs(base_delta),
            "gamma": 0.02,
            "theta": -0.05,
            "vega": 0.10,
            "rho": 0.01,
            "impliedVolatility": 22.5,
            "volatility": 22.5,
            "openInterest": 200,
            "totalVolume": 80,
        }

    call_map = {str(s): [_contract(s, True)] for s in strikes}
    put_map  = {str(s): [_contract(s, False)] for s in strikes}

    return {
        "underlyingPrice": spot,
        "callExpDateMap": {key: call_map},
        "putExpDateMap":  {key: put_map},
    }


# ---------------------------------------------------------------------------
# Pure helper tests — no mocks
# ---------------------------------------------------------------------------

class TestPctToDec:
    def test_converts_percentage(self):
        assert _pct_to_dec(21.4) == pytest.approx(0.214)

    def test_none_returns_none(self):
        assert _pct_to_dec(None) is None

    def test_zero(self):
        assert _pct_to_dec(0) == pytest.approx(0.0)

    def test_string_number(self):
        assert _pct_to_dec("30.0") == pytest.approx(0.30)

    def test_bad_string_returns_none(self):
        assert _pct_to_dec("N/A") is None


class TestAtmContract:
    def test_picks_closest_to_50_delta(self):
        contracts = [
            {"delta": 0.80, "strikePrice": 490},
            {"delta": 0.51, "strikePrice": 500},  # closest to 0.50
            {"delta": 0.30, "strikePrice": 510},
        ]
        result = _atm_contract(contracts)
        assert result["strikePrice"] == 500

    def test_empty_list_returns_none(self):
        assert _atm_contract([]) is None

    def test_no_delta_returns_none(self):
        assert _atm_contract([{"strikePrice": 500}]) is None

    def test_zero_delta_skipped(self):
        contracts = [
            {"delta": 0, "strikePrice": 500},
            {"delta": 0.48, "strikePrice": 495},
        ]
        result = _atm_contract(contracts)
        assert result["strikePrice"] == 495


class TestChainToVolPoints:
    def test_returns_points_for_all_strikes(self):
        chain = _make_chain(spot=500.0, dte=4)
        points = _chain_to_vol_points(chain, 500.0)
        assert len(points) == 3  # 3 strikes

    def test_iv_converted_to_decimal(self):
        chain = _make_chain(spot=500.0, dte=4)
        points = _chain_to_vol_points(chain, 500.0)
        for p in points:
            if p["call_iv"] is not None:
                assert p["call_iv"] < 1.0, "IV should be decimal, not percentage"

    def test_point_fields_present(self):
        chain = _make_chain(spot=500.0, dte=4)
        points = _chain_to_vol_points(chain, 500.0)
        required = {"strike", "dte", "call_iv", "put_iv", "call_oi", "put_oi"}
        for p in points:
            assert required.issubset(p.keys())

    def test_empty_chain_returns_empty(self):
        assert _chain_to_vol_points({}, 500.0) == []

    def test_dte_attached_to_points(self):
        chain = _make_chain(spot=500.0, dte=7)
        points = _chain_to_vol_points(chain, 500.0)
        assert all(p["dte"] == 7 for p in points)


# ---------------------------------------------------------------------------
# Upsert function tests — mock Supabase DB
# ---------------------------------------------------------------------------

def _mock_db():
    """Return a mock that chains .table().upsert().execute() safely."""
    db = MagicMock()
    execute_mock = MagicMock(return_value=MagicMock(data=[]))
    db.table.return_value.upsert.return_value.execute = execute_mock
    db.table.return_value.select.return_value.eq.return_value.execute.return_value = MagicMock(data=[])
    return db, execute_mock


class TestUpsertVolSurface:
    def test_calls_upsert_with_correct_conflict_key(self):
        db, _ = _mock_db()
        chain = _make_chain(500.0)
        points = _chain_to_vol_points(chain, 500.0)
        _upsert_vol_surface(db, "SPY", "2026-05-04", 500.0, points, "user-abc")

        db.table.assert_called_with("vol_surface_snapshots")
        _, upsert_kwargs = db.table.return_value.upsert.call_args
        assert upsert_kwargs.get("on_conflict") == "user_id,ticker,obs_date"

    def test_upsert_payload_contains_spot_and_points(self):
        db, _ = _mock_db()
        chain = _make_chain(500.0)
        points = _chain_to_vol_points(chain, 500.0)
        _upsert_vol_surface(db, "SPY", "2026-05-04", 500.0, points, "user-abc")

        payload = db.table.return_value.upsert.call_args[0][0]
        assert payload["spot_price"] == 500.0
        assert payload["ticker"] == "SPY"
        assert isinstance(payload["points"], list)
        assert len(payload["points"]) == 3


class TestUpsertGreekSnapshots:
    def test_writes_one_row_per_dte_bucket(self):
        db, _ = _mock_db()
        # Track all upsert calls
        upsert_rows = []
        db.table.return_value.upsert.side_effect = lambda row, **kw: (
            upsert_rows.append(row) or db.table.return_value.upsert.return_value
        )

        chain = _make_chain(500.0, dte=4)
        # Add a 7-DTE and 31-DTE expiration so all three buckets can match
        chain["callExpDateMap"]["2026-05-11:7"] = chain["callExpDateMap"]["2026-05-08:4"]
        chain["callExpDateMap"]["2026-06-04:31"] = chain["callExpDateMap"]["2026-05-08:4"]
        chain["putExpDateMap"]["2026-05-11:7"] = chain["putExpDateMap"]["2026-05-08:4"]
        chain["putExpDateMap"]["2026-06-04:31"] = chain["putExpDateMap"]["2026-05-08:4"]

        _upsert_greek_snapshots(db, "SPY", "2026-05-04", 500.0, chain, "user-abc")

        dte_buckets = [r["dte_bucket"] for r in upsert_rows]
        assert sorted(dte_buckets) == [4, 7, 31]

    def test_conflict_key_includes_dte_bucket(self):
        db, _ = _mock_db()
        chain = _make_chain(500.0, dte=4)
        _upsert_greek_snapshots(db, "SPY", "2026-05-04", 500.0, chain, "user-abc")

        _, kw = db.table.return_value.upsert.call_args
        assert "dte_bucket" in kw.get("on_conflict", "")


# ---------------------------------------------------------------------------
# Integration smoke test — full run_schwab_pull with mocked externals
# ---------------------------------------------------------------------------

def _make_httpx_response(status: int, body: dict):
    resp = MagicMock()
    resp.status_code = status
    resp.json.return_value = body
    return resp


def _make_mock_iv_result():
    """Return a MagicMock shaped like IvAnalysisResult with safe iterable fields."""
    iv = MagicMock()
    iv.gex_strikes = []   # iterated in _upsert_iv_snapshot
    iv.rnd = []           # iterated in _upsert_iv_snapshot
    iv.gamma_regime.value = "positive"
    iv.iv_gex_signal.value = "neutral"
    iv.vanna_regime.value = "positive"
    iv.gamma_slope.value = "flat"
    iv.rating.value = "high"
    iv.spot_to_vt_pct = 0.5
    iv.gex_0dte = 0.0
    iv.gex_0dte_pct = 0.0
    return iv


def _make_mock_regime():
    regime = MagicMock()
    regime.strategy_bias.value = "neutral"
    regime.signals = []
    return regime


def _make_db_mock():
    """DB mock where all execute() calls return data=[]."""
    db = MagicMock()
    empty = MagicMock(data=[])
    # Direct: .select().execute()
    db.table.return_value.select.return_value.execute.return_value = empty
    # .select().eq().execute()
    db.table.return_value.select.return_value.eq.return_value.execute.return_value = empty
    # .select().eq().order().limit().execute()  (iv_history)
    db.table.return_value.select.return_value.eq.return_value.order.return_value.limit.return_value.execute.return_value = empty
    # upserts
    db.table.return_value.upsert.return_value.execute.return_value = MagicMock()
    return db


@pytest.mark.asyncio
async def test_run_schwab_pull_happy_path():
    """Full pipeline smoke test: one ticker, all steps should record 'ok'.

    Compute-heavy services (SABR, Heston, iv_analyse, etc.) are patched out so
    scipy never runs — this is a correctness test for the orchestration logic,
    not the numerics.
    """
    chain = _make_chain(500.0, dte=4)
    for key_suffix in ("2026-05-11:7", "2026-06-04:31"):
        chain["callExpDateMap"][key_suffix] = chain["callExpDateMap"]["2026-05-08:4"]
        chain["putExpDateMap"][key_suffix]  = chain["putExpDateMap"]["2026-05-08:4"]

    price_history = {"closes": [490.0 + i * 0.5 for i in range(65)], "volumes": [1_000_000] * 65}
    index_history = {"closes": [18.0 + i * 0.1 for i in range(65)], "volumes": []}

    def _post(url, **kwargs):
        symbol = (kwargs.get("json") or {}).get("symbol", "")
        if "get-schwab-chains" in url:
            return _make_httpx_response(200, chain)
        if "get-schwab-pricehistory" in url:
            return _make_httpx_response(200, index_history if symbol.startswith("$") or symbol in ("SPY", "RSP") else price_history)
        return _make_httpx_response(404, {})

    mock_client = AsyncMock()
    mock_client.post.side_effect = _post

    db = _make_db_mock()
    db.table.return_value.select.return_value.execute.return_value = MagicMock(
        data=[{"ticker": "SPY", "user_id": "user-abc"}]
    )

    mock_iv = _make_mock_iv_result()
    mock_regime = _make_mock_regime()

    with (
        patch("jobs.schwab_pull.get_supabase", return_value=db),
        patch("httpx.AsyncClient") as cls,
        patch("jobs.schwab_pull.calibrate_snapshot", return_value=[]),
        patch("jobs.schwab_pull.calibrate_heston", return_value=None),
        patch("jobs.schwab_pull.iv_analyse", return_value=mock_iv),
        patch("jobs.schwab_pull.grid_ingest", return_value=[]),
        patch("jobs.schwab_pull.rv_compute", return_value=MagicMock(rv20d=0.15, rv60d=0.18)),
        patch("jobs.schwab_pull.classify_regime", return_value=mock_regime),
        patch("jobs.schwab_pull.classify_vix_regime", return_value=None),
        patch("jobs.schwab_pull.compute_wilder_rsi", return_value=55.0),
    ):
        cls.return_value.__aenter__ = AsyncMock(return_value=mock_client)
        cls.return_value.__aexit__ = AsyncMock(return_value=False)
        result = await run_schwab_pull()

    assert result["status"] == "complete"
    spy_steps = result["tickers"].get("SPY", {})
    assert isinstance(spy_steps, dict), f"Expected dict of steps, got: {spy_steps}"

    for step in ("vol_surface", "iv_snapshots", "greek_snapshots", "regime_snapshots"):
        val = spy_steps.get(step, "missing")
        assert not str(val).startswith("err:"), f"Step '{step}' failed: {val}"


@pytest.mark.asyncio
async def test_run_schwab_pull_no_tickers():
    db = _make_db_mock()
    # Override to return empty watched list
    db.table.return_value.select.return_value.execute.return_value = MagicMock(data=[])

    with patch("jobs.schwab_pull.get_supabase", return_value=db):
        result = await run_schwab_pull()

    assert result == {"status": "no_tickers"}


@pytest.mark.asyncio
async def test_run_schwab_pull_chain_error():
    """If chain fetch returns non-200, ticker records chain_error_* and pipeline continues."""
    db = _make_db_mock()
    db.table.return_value.select.return_value.execute.return_value = MagicMock(
        data=[{"ticker": "AAPL", "user_id": "user-abc"}]
    )

    mock_client = AsyncMock()
    mock_client.post.return_value = _make_httpx_response(500, {})

    with (
        patch("jobs.schwab_pull.get_supabase", return_value=db),
        patch("httpx.AsyncClient") as cls,
        patch("jobs.schwab_pull.classify_vix_regime", return_value=None),
        patch("jobs.schwab_pull.compute_wilder_rsi", return_value=50.0),
    ):
        cls.return_value.__aenter__ = AsyncMock(return_value=mock_client)
        cls.return_value.__aexit__ = AsyncMock(return_value=False)
        result = await run_schwab_pull()

    assert result["status"] == "complete"
    assert str(result["tickers"].get("AAPL", "")).startswith("chain_error_")
