from __future__ import annotations
from typing import Optional

# =============================================================================
# services/contract_opportunity.py
# =============================================================================
# Turns a single contract's own daily snapshot history (watched_contract_
# snapshots or position_leg_snapshots rows) into a 0-100 "opportunity score":
# is THIS contract cheap right now relative to ITS OWN history, not the
# ticker's.
#
# Two independent reads, combined:
#   IV        -- this contract's implied_vol, ranked/percentiled against its
#                own trailing history. Low percentile = cheap premium to buy.
#                Same rank/percentile formula as iv_analytics._ivr_ivp() and
#                the same bucket thresholds as option_scoring.py's IVP-based
#                iv_score, just reimplemented locally rather than importing
#                a private (underscore) helper from iv_analytics across
#                module boundaries.
#   Edge      -- (model_theo - market_price) / market_price * 10_000 bps,
#                the exact convention documented in fair_value_engine.py's
#                header (positive = model thinks it's worth more than the
#                market does = underpriced). Ranked/percentiled the same
#                way; high percentile = more underpriced than usual for
#                this contract.
#
# opportunity_score halves the 100 points across the two (0-50 each) and
# reuses SCORE_GRADE_A/B/C from core.constants for the grade, so "B" means
# the same thing here as it does in option_scoring.py's point-in-time score.
#
# Needs IV_MIN_HISTORY_IVR days of snapshots before it'll produce a real
# score -- below that it returns insufficient_history=True rather than
# fabricate a percentile off too little data, mirroring how iv_analytics
# handles the same problem for ticker-level IVR/IVP.
# =============================================================================

from dataclasses import dataclass, field

from core.constants import IV_MIN_HISTORY_IVR, SCORE_GRADE_A, SCORE_GRADE_B, SCORE_GRADE_C


@dataclass
class ContractOpportunity:
    snapshot_count: int
    insufficient_history: bool

    current_iv:Optional[float] = None
    iv_rank:Optional[float] = None
    iv_percentile:Optional[float] = None

    current_edge_bps:Optional[float] = None
    edge_rank:Optional[float] = None
    edge_percentile:Optional[float] = None

    iv_score: int = 0
    edge_score: int = 0
    opportunity_score: int = 0
    grade: str = "D"
    flags: list[str] = field(default_factory=list)


def _rank_percentile(history: list[float], current: float) ->tuple[Optional[float], Optional[float]]:
    """(rank, percentile) of `current` within `history`, 0-100 each.

    rank = where current sits between history's min and max.
    percentile = % of history strictly below current (today's own value
    isn't counted against itself). Same semantics as
    iv_analytics._ivr_ivp() -- kept in sync deliberately, not coincidentally.
    """
    if len(history) < IV_MIN_HISTORY_IVR:
        return None, None
    lo, hi = min(history), max(history)
    span = hi - lo
    rank = 50.0 if span < 0.001 else max(0.0, min(100.0, (current - lo) / span * 100))
    pct = max(0.0, min(100.0, sum(1 for h in history if h < current) / len(history) * 100))
    return rank, pct


def _iv_score_from_percentile(ivp: float) -> int:
    """0-50, low IVP (cheap vol) scores highest. Same buckets as
    option_scoring.py's IVP-based iv_score, rescaled from its 0-20 max."""
    if ivp <= 20:
        return 50
    if ivp <= 40:
        return 40
    if ivp <= 60:
        return 25
    if ivp <= 80:
        return 12
    return 5


def _edge_score_from_percentile(ep: float) -> int:
    """0-50, high edge percentile (more underpriced than usual for this
    contract) scores highest -- mirror image of the IV bucket edges."""
    if ep >= 80:
        return 50
    if ep >= 60:
        return 40
    if ep >= 40:
        return 25
    if ep >= 20:
        return 12
    return 5


def _grade(total: int) -> str:
    if total >= SCORE_GRADE_A:
        return "A"
    if total >= SCORE_GRADE_B:
        return "B"
    if total >= SCORE_GRADE_C:
        return "C"
    return "D"


def evaluate_contract(snapshots: list[dict]) -> ContractOpportunity:
    """snapshots: rows shaped like watched_contract_snapshots /
    position_leg_snapshots, each with at least snapshot_date, implied_vol,
    market_price, model_theo. Order doesn't matter -- sorted internally by
    snapshot_date, and the latest row is treated as "today"."""
    rows = sorted((s for s in snapshots if s.get("snapshot_date")), key=lambda s: s["snapshot_date"])
    n = len(rows)

    if n == 0:
        return ContractOpportunity(snapshot_count=0, insufficient_history=True,
                                    flags=["No snapshot history yet"])

    latest = rows[-1]
    current_iv = latest.get("implied_vol")

    def _edge_bps(row: dict) ->Optional[float]:
        mp, mt = row.get("market_price"), row.get("model_theo")
        if not mp or mt is None:
            return None
        return (mt - mp) / mp * 10_000

    current_edge = _edge_bps(latest)

    if n < IV_MIN_HISTORY_IVR:
        return ContractOpportunity(
            snapshot_count=n, insufficient_history=True,
            current_iv=current_iv, current_edge_bps=current_edge,
            flags=[f"Only {n} day(s) of history -- need {IV_MIN_HISTORY_IVR} for a percentile-based score"],
        )

    iv_history = [r["implied_vol"] for r in rows if r.get("implied_vol") is not None]
    edge_history = [e for e in (_edge_bps(r) for r in rows) if e is not None]

    iv_rank = iv_pct = edge_rank = edge_pct = None
    iv_score = edge_score = 0
    flags: list[str] = []

    if current_iv is not None and len(iv_history) >= IV_MIN_HISTORY_IVR:
        iv_rank, iv_pct = _rank_percentile(iv_history, current_iv)
        if iv_pct is not None:
            iv_score = _iv_score_from_percentile(iv_pct)
    else:
        flags.append("IV percentile unavailable for today's row")

    if current_edge is not None and len(edge_history) >= IV_MIN_HISTORY_IVR:
        edge_rank, edge_pct = _rank_percentile(edge_history, current_edge)
        if edge_pct is not None:
            edge_score = _edge_score_from_percentile(edge_pct)
    else:
        flags.append("Edge percentile unavailable for today's row (missing market_price or model_theo)")

    total = iv_score + edge_score
    return ContractOpportunity(
        snapshot_count=n, insufficient_history=False,
        current_iv=current_iv, iv_rank=iv_rank, iv_percentile=iv_pct,
        current_edge_bps=current_edge, edge_rank=edge_rank, edge_percentile=edge_pct,
        iv_score=iv_score, edge_score=edge_score,
        opportunity_score=total, grade=_grade(total), flags=flags,
    )


# ── Level proximity ───────────────────────────────────────────────────────────

@dataclass
class NearbyLevel:
    label: str
    price: float
    source: str
    distance_pct: float


def find_nearby_level(
    underlying_price: float, levels: list[dict], tolerance_pct: float = 2.0,
) ->Optional[NearbyLevel]:
    """levels: dicts with at least price, label; source/kind optional.
    Returns the closest level within tolerance_pct, or None. Caller supplies
    both user-entered levels (target_levels rows) and any system-derived
    ones (e.g. iv_snapshots.zero_gamma_level, max_gex_strike) in the same
    list -- proximity doesn't care which kind a level is."""
    if underlying_price <= 0 or not levels:
        return None
    candidates = []
    for lvl in levels:
        price = lvl.get("price")
        if price is None or price <= 0:
            continue
        dist = abs(underlying_price - price) / underlying_price * 100
        if dist <= tolerance_pct:
            candidates.append(NearbyLevel(
                label=lvl.get("label", "level"), price=price,
                source=lvl.get("source", "user"), distance_pct=dist,
            ))
    if not candidates:
        return None
    return min(candidates, key=lambda c: c.distance_pct)


# ── Combined signal ────────────────────────────────────────────────────────────

@dataclass
class WatchSignal:
    opportunity: ContractOpportunity
    nearby_level:Optional[NearbyLevel]
    signal: bool
    reason: str


def evaluate_watch_signal(
    snapshots: list[dict],
    underlying_price:Optional[float] = None,
    levels: Optional[list[dict]] = None,
    tolerance_pct: float = 2.0,
) -> WatchSignal:
    """The combined "is this actually worth looking at" gate: cheap on its
    own history AND sitting near a level, not either alone. Grade-only
    (score is cheap) fires constantly in a trending name -- see the MFI/OBV
    backtest from this session for exactly why an unfiltered reversal-style
    trigger drowns in false positives. Requiring proximity to a real level
    is the noise filter."""
    opp = evaluate_contract(snapshots)

    if underlying_price is None and snapshots:
        latest = max((s for s in snapshots if s.get("snapshot_date")),
                     key=lambda s: s["snapshot_date"], default=None)
        underlying_price = (latest or {}).get("underlying_price")

    nearby = find_nearby_level(underlying_price, levels or [], tolerance_pct) if underlying_price else None

    if opp.insufficient_history:
        return WatchSignal(opp, nearby, False, "Insufficient history for a percentile-based score")
    if opp.grade not in ("A", "B"):
        return WatchSignal(opp, nearby, False, f"Opportunity grade {opp.grade} below threshold")
    if nearby is None:
        return WatchSignal(opp, nearby, False, "Cheap on its own history, but not near a tracked level")

    return WatchSignal(
        opp, nearby, True,
        f"Grade {opp.grade} (score {opp.opportunity_score}) and within "
        f"{nearby.distance_pct:.1f}% of {nearby.label} (${nearby.price:.2f})",
    )
