from __future__ import annotations

# =============================================================================
# tests/test_jobs_common.py
# =============================================================================
# Verifies that fetch_schwab_chain and fetch_schwab_closes handle error HTTP
# responses gracefully — returning None / [] instead of crashing — and that
# a successful response is parsed correctly.
# =============================================================================

import json
from unittest.mock import AsyncMock, MagicMock, patch

import httpx
import pytest

from jobs.common import fetch_schwab_chain, fetch_schwab_closes


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _mock_client(status: int, body: dict | list | None = None) -> MagicMock:
    resp = MagicMock(spec=httpx.Response)
    resp.status_code = status
    resp.json.return_value = body or {}
    client = MagicMock(spec=httpx.AsyncClient)
    client.post = AsyncMock(return_value=resp)
    return client


def _timeout_client() -> MagicMock:
    """Simulates a network timeout."""
    client = MagicMock(spec=httpx.AsyncClient)
    client.post = AsyncMock(side_effect=httpx.ReadTimeout("timeout", request=MagicMock()))
    return client


# ---------------------------------------------------------------------------
# fetch_schwab_chain
# ---------------------------------------------------------------------------

class TestFetchSchwabChain:
    @pytest.mark.asyncio
    async def test_200_returns_chain_dict(self):
        body = {"symbol": "AAPL", "expirations": []}
        client = _mock_client(200, body)
        result = await fetch_schwab_chain(client, "AAPL")
        assert result == body

    @pytest.mark.asyncio
    async def test_401_returns_none(self):
        client = _mock_client(401)
        result = await fetch_schwab_chain(client, "AAPL")
        assert result is None

    @pytest.mark.asyncio
    async def test_429_returns_none(self):
        client = _mock_client(429)
        result = await fetch_schwab_chain(client, "AAPL")
        assert result is None

    @pytest.mark.asyncio
    async def test_500_returns_none(self):
        client = _mock_client(500)
        result = await fetch_schwab_chain(client, "AAPL")
        assert result is None

    @pytest.mark.asyncio
    async def test_network_timeout_returns_none(self):
        client = _timeout_client()
        result = await fetch_schwab_chain(client, "AAPL")
        assert result is None

    @pytest.mark.asyncio
    async def test_includes_expiration_date_when_provided(self):
        body = {"symbol": "AAPL", "expirations": []}
        client = _mock_client(200, body)
        result = await fetch_schwab_chain(client, "AAPL", expiration_date="2025-01-17")
        assert result is not None
        # Confirm expiration was passed in the request body
        call_kwargs = client.post.call_args
        assert call_kwargs.kwargs["json"]["expirationDate"] == "2025-01-17"


# ---------------------------------------------------------------------------
# fetch_schwab_closes
# ---------------------------------------------------------------------------

class TestFetchSchwabCloses:
    @pytest.mark.asyncio
    async def test_200_returns_closes_and_volumes(self):
        body = {"closes": [100.0, 101.0, 102.0], "volumes": [1e6, 2e6, 1.5e6]}
        client = _mock_client(200, body)
        closes, volumes = await fetch_schwab_closes(client, "AAPL")
        assert closes == [100.0, 101.0, 102.0]
        assert volumes == [1e6, 2e6, 1.5e6]

    @pytest.mark.asyncio
    async def test_401_returns_empty(self):
        client = _mock_client(401)
        closes, volumes = await fetch_schwab_closes(client, "AAPL")
        assert closes == []
        assert volumes == []

    @pytest.mark.asyncio
    async def test_500_returns_empty(self):
        client = _mock_client(500)
        closes, volumes = await fetch_schwab_closes(client, "AAPL")
        assert closes == []
        assert volumes == []

    @pytest.mark.asyncio
    async def test_network_error_returns_empty(self):
        client = _timeout_client()
        closes, volumes = await fetch_schwab_closes(client, "AAPL")
        assert closes == []
        assert volumes == []

    @pytest.mark.asyncio
    async def test_missing_keys_returns_empty_lists(self):
        # Response 200 but body has no 'closes'/'volumes'
        client = _mock_client(200, {"data": "unexpected"})
        closes, volumes = await fetch_schwab_closes(client, "AAPL")
        assert closes == []
        assert volumes == []
