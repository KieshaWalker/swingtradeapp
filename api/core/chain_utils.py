from __future__ import annotations

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


def _dte_from_key(key: str) -> int | None:
    """Extract DTE from Schwab expDate key format "YYYY-MM-DD:DTE"."""
    try:
        return int(key.split(":")[1])
    except (IndexError, ValueError):
        return None


def parse_expirations(chain: dict) -> list[dict]:
    """Convert Schwab callExpDateMap/putExpDateMap to a normalized expirations list.

    Returns: [{dte, calls: [contract, ...], puts: [contract, ...]}, ...]
    sorted ascending by DTE, excluding dte <= 0.
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
    return [
        {
            "dte":            dte,
            "expirationDate": date_map.get(dte, ""),
            "calls":          call_map.get(dte, []),
            "puts":           put_map.get(dte, []),
        }
        for dte in all_dtes
        if dte > 0
    ]


def normalize_chain(chain: dict) -> dict:
    """Ensure chain has a populated "expirations" key.

    Idempotent — if "expirations" already exists and is non-empty, returns
    the chain unchanged.  Otherwise parses callExpDateMap/putExpDateMap and
    injects the result.  Returns a shallow copy so the original is not mutated.
    """
    if chain.get("expirations"):
        return chain
    expirations = parse_expirations(chain)
    return {**chain, "expirations": expirations}
