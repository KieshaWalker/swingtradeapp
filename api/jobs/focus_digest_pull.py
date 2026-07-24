from __future__ import annotations

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
# services.contract_opportunity.evaluate_contract(). Writes no new signal --
# this is a read-and-assemble job, not an analytics job. See
# 073_focus_ticker_digest.sql for the shape.
#
# Cron: 15 21 * * 1-5  (21:15 UTC Mon-Fri)
# =============================================================================

import logging
import uuid
from datetime import date, datetime, timezone

from core.supabase_client import get_supabase
from services.contract_opportunity import evaluate_contract

log = logging.getLogger(__name__)

_FOCUS_TICKERS = ["MRVL", "AMD", "AVGO", "MU", "SNDK", "NBIS", "ALAB", "KLAC", "INTC"]


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


async def run_focus_digest_pull() -> dict:
    now = datetime.now(timezone.utc)
    if not (20 <= now.hour < 22):
        log.info("focus_digest_pull: skipped (not near market close)")
        return {"status": "skipped_time"}

    db = get_supabase()
    today = date.today().isoformat()

    digests: list[dict] = []
    results: dict[str, str] = {}

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

    return {"status": "done", "tickers": len(_FOCUS_TICKERS), "details": results}
