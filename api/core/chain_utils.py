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
#
# WHY THIS EXISTS
# ---------------
# Schwab's shape is awkward in three specific ways, and every consumer would
# otherwise re-solve all three:
#   * DTE is buried in a COMPOSITE STRING KEY ("2026-01-17:150"), not a field.
#   * Strikes map to LISTS of contracts, not single contracts, so the values
#     need flattening.
#   * Calls and puts live in two SEPARATE top-level maps that must be zipped
#     back together by expiry.
# Normalizing once here means a bug in that unpacking is fixed in one place.
#
# THE OUTPUT IS A SHALLOW COPY. normalize_chain returns {**chain, ...} rather
# than mutating, so the caller's original dict is untouched — but the contract
# dicts inside are the SAME objects. Mutating a contract still affects the
# original chain; only the top-level structure is copied.
# =============================================================================


def _dte_from_key(key: str) ->Optional[int]:
    """Extract DTE from Schwab expDate key format "YYYY-MM-DD:DTE".

    Returns None for any key that does not split cleanly into a parseable
    integer after the colon, so a malformed key drops that expiration rather
    than raising and losing the entire chain.
    """
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

    THE 0DTE FLAG IS THE THING TO GET RIGHT. Same-day expiries carry enormous
    gamma and near-zero time value, so they dominate a gamma total while being
    meaningless to price or score. That is exactly why the two families of
    consumer want opposite behaviour, and why this is an explicit parameter
    rather than a global rule.

    Negative DTE (an expiration already past, which Schwab occasionally still
    returns) is excluded unconditionally — there is no reading for which an
    expired contract belongs in the surface.
    """
    call_map: dict[int, list[dict]] = {}
    put_map: dict[int, list[dict]] = {}
    date_map: dict[int, str] = {}   # dte → "YYYY-MM-DD" from the Schwab key

    # Calls and puts are unpacked by two near-identical loops rather than a
    # shared helper, keeping each side's target dict explicit.
    for key, strikes in chain.get("callExpDateMap", {}).items():
        dte = _dte_from_key(key)
        if dte is None:
            continue
        contracts: list[dict] = []
        # Schwab maps each strike to a LIST (normally one element, but the
        # shape allows more), so flatten rather than taking [0].
        for contracts_at_strike in strikes.values():
            contracts.extend(contracts_at_strike)
        call_map[dte] = contracts
        # setdefault, not assignment: the put loop below writes the same dte
        # keys, and the first writer's date wins. Both maps carry the same
        # expiration date for a given DTE, so either is correct.
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

    # UNION, not intersection — an expiry present on only one side still yields
    # an entry, with an empty list for the missing side. Consumers iterate both
    # lists, so an empty one is harmless, whereas dropping the expiry would
    # silently lose real quotes.
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

    IDEMPOTENCE HAS A SHARP EDGE: the early return checks only that
    "expirations" is present and truthy, NOT that it was built with the same
    include_zero_dte setting. A chain already normalized without 0DTE and then
    passed here with include_zero_dte=True comes back unchanged, still missing
    its 0DTE rows. Normalize once, at the entry point of a pipeline, with the
    flag that pipeline needs — do not re-normalize downstream expecting a
    different result.

    The truthiness check also means an expirations list that is present but
    EMPTY (a chain with no valid expiries) is re-parsed on every call. Cheap,
    since there is nothing to parse.
    """
    if chain.get("expirations"):
        return chain
    expirations = parse_expirations(chain, include_zero_dte=include_zero_dte)
    return {**chain, "expirations": expirations}
