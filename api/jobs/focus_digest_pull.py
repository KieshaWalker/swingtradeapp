from __future__ import annotations
from typing import Optional

# =============================================================================
# jobs/focus_digest_pull.py
# =============================================================================
# Cloud Scheduler job — run after the day's other close-capture jobs have all
# landed (position-eod-snapshot 21:05, watched-contract-pull 21:07,
# crisis-pull 21:10 UTC), so this one has fresh input to read rather than
# racing them.
#
# Assembles one row per focus ticker into focus_ticker_digest: that ticker's
# same-day iv_snapshots read, plus every open position_leg and every
# 'watching' watched_contracts row on it scored through
# services.contract_opportunity.evaluate_contract(). See
# 073_focus_ticker_digest.sql for the shape.
#
# Also runs Tier-1 Strategy A's screen-and-nominate step (long call / long
# put, cheap-vol-at-a-level): for each focus ticker whose iv_rank is in the
# existing "cheap" bucket (<25, same threshold iv_analytics.py's
# _rating_from_rank already uses) AND whose spot is within 2% of that
# ticker's zero_gamma_level, auto-nominates one contract into
# watched_contracts --
#   direction: call if spot is below the level (mean-reversion up), put if
#              above (mean-reversion down)
#   expiry:    nearest expiration with >=90 DTE
#   strike:    highest open interest among contracts in that expiration
#              with |delta| in [0.15, 0.25] -- "deep OTM" anchored to the
#              25-delta convention iv_analytics.py's skew_rr25/skew_bf25
#              already use, not an arbitrary new number
# Skips the ticker if a watch already exists in that direction (no duplicate
# nominations piling up). The contract-level opportunity score then takes
# over once watched-contract-pull has accrued enough history on it -- a
# same-day nomination will correctly show insufficient_history, same as any
# freshly-added watch.
#
# Cron: 15 21 * * 1-5  (21:15 UTC Mon-Fri)
# =============================================================================

import logging
import uuid
from datetime import date, datetime, timezone

import httpx

from core.supabase_client import get_supabase
from jobs.common import fetch_schwab_chain
from services.contract_opportunity import evaluate_contract

log = logging.getLogger(__name__)

_FOCUS_TICKERS = ["MRVL", "AMD", "AVGO", "MU", "SNDK", "NBIS", "ALAB", "KLAC", "INTC"]

_CHEAP_IV_RANK_MAX = 25.0
_LEVEL_TOLERANCE_PCT = 2.0
_NOMINATION_MIN_DTE = 90
_NOMINATION_DELTA_LO = 0.15
_NOMINATION_DELTA_HI = 0.25


def _score_contract(db, table: str, id_field: str, contract_id: str, meta: dict, source: str) -> dict:
    snaps = (
        db.table(table).select("*").eq(id_field, contract_id).execute()
    ).data or []
    opp = evaluate_contract(snaps)
    return {
        "source": source,
        "id": contract_id,
        "strike": meta.get("strike"),
        "expiry": meta.get("expiry"),
        "type": meta.get("type"),
        "opportunity_score": opp.opportunity_score,
        "grade": opp.grade,
        "iv_percentile": opp.iv_percentile,
        "edge_percentile": opp.edge_percentile,
        "insufficient_history": opp.insufficient_history,
        "snapshot_count": opp.snapshot_count,
    }


def _select_nomination(chain: dict, direction: str) -> Optional[dict]:
    """Nearest expiration with dte >= _NOMINATION_MIN_DTE; among contracts
    there with |delta| in the target band, the one with the highest OI.
    Returns None if nothing clears both filters."""
    exp_map = chain.get("callExpDateMap" if direction == "call" else "putExpDateMap") or {}

    candidates: list[tuple[str, int, list[dict]]] = []
    for exp_key, strikes in exp_map.items():
        parts = exp_key.split(":")
        if len(parts) < 2:
            continue
        exp_date = parts[0]
        try:
            dte = int(parts[1])
        except ValueError:
            continue
        if dte < _NOMINATION_MIN_DTE:
            continue
        contracts = [c for strike_list in strikes.values() for c in strike_list]
        candidates.append((exp_date, dte, contracts))

    if not candidates:
        return None
    exp_date, dte, contracts = min(candidates, key=lambda t: t[1])

    in_band = []
    for c in contracts:
        delta = c.get("delta")
        strike = c.get("strikePrice")
        if delta is None or strike is None:
            continue
        if _NOMINATION_DELTA_LO <= abs(float(delta)) <= _NOMINATION_DELTA_HI:
            in_band.append(c)
    if not in_band:
        return None

    best = max(in_band, key=lambda c: float(c.get("openInterest") or 0))
    return {
        "expiry": exp_date,
        "dte": dte,
        "strike": float(best["strikePrice"]),
        "delta": float(best["delta"]),
        "open_interest": int(best.get("openInterest") or 0),
    }


async def _maybe_nominate(
    db, client: httpx.AsyncClient, ticker: str, iv: dict,
    existing_watches: list[dict], owner_user_id: Optional[str],
) -> Optional[dict]:
    if owner_user_id is None:
        return None

    spot = iv.get("underlying_price")
    zgl = iv.get("zero_gamma_level")
    iv_rank = iv.get("iv_rank")
    if spot is None or zgl is None or iv_rank is None:
        return None
    if iv_rank > _CHEAP_IV_RANK_MAX:
        return None

    distance_pct = abs(spot - zgl) / spot * 100
    if distance_pct > _LEVEL_TOLERANCE_PCT:
        return None

    direction = "call" if spot < zgl else "put"

    if any(w.get("type") == direction for w in existing_watches):
        return None  # already watching this direction on this ticker

    chain = await fetch_schwab_chain(client, ticker, strike_count=60)
    if chain is None:
        return None
    pick = _select_nomination(chain, direction)
    if pick is None:
        return None

    watch_id = str(uuid.uuid4())
    notes = (
        f"Auto-nominated {date.today().isoformat()} (Strategy A screen): "
        f"iv_rank {iv_rank:.1f} (cheap, <{_CHEAP_IV_RANK_MAX:.0f}), spot ${spot:.2f} "
        f"within {distance_pct:.2f}% of zero-gamma level ${zgl:.2f}. "
        f"Selected {abs(pick['delta']):.2f}Δ, {pick['dte']}d to expiry, OI {pick['open_interest']}."
    )
    db.table("watched_contracts").insert({
        "id": watch_id,
        "user_id": owner_user_id,
        "ticker": ticker,
        "strike": pick["strike"],
        "expiry": pick["expiry"],
        "type": direction,
        "notes": notes,
    }).execute()
    log.info("focus_digest_pull: nominated %s %s $%.2f %s (dte=%d oi=%d)",
              ticker, direction, pick["strike"], pick["expiry"], pick["dte"], pick["open_interest"])

    return {
        "id": watch_id, "ticker": ticker, "strike": pick["strike"],
        "expiry": pick["expiry"], "type": direction,
    }


def _fetch_owner_user_id(db) -> Optional[str]:
    rows = (db.table("positions").select("user_id").limit(1).execute()).data or []
    return rows[0]["user_id"] if rows else None


async def run_focus_digest_pull() -> dict:
    now = datetime.now(timezone.utc)
    if not (20 <= now.hour < 22):
        log.info("focus_digest_pull: skipped (not near market close)")
        return {"status": "skipped_time"}

    db = get_supabase()
    today = date.today().isoformat()
    owner_user_id = _fetch_owner_user_id(db)

    digests: list[dict] = []
    results: dict[str, str] = {}
    nominations: list[dict] = []

    async with httpx.AsyncClient(timeout=60.0) as client:
        for ticker in _FOCUS_TICKERS:
            try:
                iv_rows = (
                    db.table("iv_snapshots")
                    .select("date,underlying_price,iv_rank,iv_percentile,iv_rating,"
                            "gamma_regime,zero_gamma_level,max_gex_strike,put_call_ratio,"
                            "skew,skew_z_score")
                    .eq("ticker", ticker)
                    .order("date", desc=True)
                    .limit(1)
                    .execute()
                ).data or []
                iv = iv_rows[0] if iv_rows else {}
                if iv.get("date") != today:
                    log.warning("focus_digest_pull: %s iv_snapshots stale (latest=%s)", ticker, iv.get("date"))

                contracts: list[dict] = []

                legs = (
                    db.table("position_legs")
                    .select("id,strike,expiry,type")
                    .eq("ticker", ticker).eq("status", "open").neq("type", "underlying")
                    .execute()
                ).data or []
                for leg in legs:
                    contracts.append(_score_contract(
                        db, "position_leg_snapshots", "leg_id", leg["id"], leg, "position",
                    ))

                watches = (
                    db.table("watched_contracts")
                    .select("id,strike,expiry,type")
                    .eq("ticker", ticker).eq("status", "watching")
                    .execute()
                ).data or []

                nomination = await _maybe_nominate(db, client, ticker, iv, watches, owner_user_id)
                if nomination:
                    nominations.append(nomination)
                    watches.append(nomination)

                for w in watches:
                    contracts.append(_score_contract(
                        db, "watched_contract_snapshots", "watch_id", w["id"], w, "watch",
                    ))

                digests.append({
                    "id": str(uuid.uuid4()),
                    "obs_date": today,
                    "ticker": ticker,
                    "underlying_price": iv.get("underlying_price"),
                    "iv_rank": iv.get("iv_rank"),
                    "iv_percentile": iv.get("iv_percentile"),
                    "iv_rating": iv.get("iv_rating"),
                    "gamma_regime": iv.get("gamma_regime"),
                    "zero_gamma_level": iv.get("zero_gamma_level"),
                    "max_gex_strike": iv.get("max_gex_strike"),
                    "put_call_ratio": iv.get("put_call_ratio"),
                    "skew": iv.get("skew"),
                    "skew_z_score": iv.get("skew_z_score"),
                    "contracts": contracts,
                })
                results[ticker] = "ok"

            except Exception as exc:
                log.error("focus_digest_pull: ticker=%s error=%r", ticker, exc, exc_info=True)
                results[ticker] = f"error:{exc!r}"

    if digests:
        db.table("focus_ticker_digest").upsert(
            digests, on_conflict="ticker,obs_date",
        ).execute()
        log.info("focus_digest_pull: wrote %d ticker digests", len(digests))

    return {
        "status": "done", "tickers": len(_FOCUS_TICKERS), "details": results,
        "nominations": nominations,
    }
