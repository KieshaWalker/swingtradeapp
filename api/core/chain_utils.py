from __future__ import annotations
from typing import Optional

# =============================================================================
# core/chain_utils.py
# =============================================================================
# Schwab options chain normalization utilities.
#
# Schwab's API delivers expirations as nested maps:
#   chain["callExpDateMap"] = {"YYYY-MM-DD:DTE": {strike: [contract, ...]}}
#   chain["putExpDateMap"]  = {"YYYY-MM-DD:DTE": {strike: [contract, ...]}}
#
# All backend services expect a flat normalized list on the chain dict:
#   chain["expirations"] = [{dte, calls: [...], puts: [...]}, ...]
#
# Call normalize_chain(chain) at the start of any service that consumes a
# Schwab chain — it is idempotent (no-op if "expirations" already present).
# =============================================================================


def _dte_from_key(key: str) ->Optional[int]:
    """Extract DTE from Schwab expDate key format "YYYY-MM-DD:DTE"."""
    try:
        return int(key.split(":")[1])
    except (IndexError, ValueError):
        return None


def parse_expirations(chain: dict, include_zero_dte: bool = False) -> list[dict]:
    """Convert Schwab callExpDateMap/putExpDateMap to a normalized expirations list.

    Returns: [{dte, calls: [contract, ...], puts: [contract, ...]}, ...]
    sorted ascending by DTE. dte < 0 is always excluded; dte == 0 (same-day
    expiries) is included only when include_zero_dte=True — IV/GEX analytics
    need 0DTE rows for the 0DTE gamma split, while pricing/scoring jobs that
    predate this flag keep the legacy dte > 0 behaviour.
    """
    call_map: dict[int, list[dict]] = {}
    put_map: dict[int, list[dict]] = {}
    date_map: dict[int, str] = {}   # dte → "YYYY-MM-DD" from the Schwab key

    for key, strikes in chain.get("callExpDateMap", {}).items():
        dte = _dte_from_key(key)
        if dte is None:
            continue
        contracts: list[dict] = []
        for contracts_at_strike in strikes.values():
            contracts.extend(contracts_at_strike)
        call_map[dte] = contracts
        date_map.setdefault(dte, key.split(":")[0])

    for key, strikes in chain.get("putExpDateMap", {}).items():
        dte = _dte_from_key(key)
        if dte is None:
            continue
        contracts: list[dict] = []
        for contracts_at_strike in strikes.values():
            contracts.extend(contracts_at_strike)
        put_map[dte] = contracts
        date_map.setdefault(dte, key.split(":")[0])

    all_dtes = sorted(set(call_map) | set(put_map))
    min_dte = 0 if include_zero_dte else 1
    return [
        {
            "dte":            dte,
            "expirationDate": date_map.get(dte, ""),
            "calls":          call_map.get(dte, []),
            "puts":           put_map.get(dte, []),
        }
        for dte in all_dtes
        if dte >= min_dte
    ]


def normalize_chain(chain: dict, include_zero_dte: bool = False) -> dict:
    """Ensure chain has a populated "expirations" key.

    Idempotent — if "expirations" already exists and is non-empty, returns
    the chain unchanged.  Otherwise parses callExpDateMap/putExpDateMap and
    injects the result.  Returns a shallow copy so the original is not mutated.
    """
    if chain.get("expirations"):
        return chain
    expirations = parse_expirations(chain, include_zero_dte=include_zero_dte)
    return {**chain, "expirations": expirations}
