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
#
# THE KEY IDEA: RELATIVE TO ITSELF, NOT TO THE TICKER. option_scoring grades a
# contract against absolute standards (is the spread tight? is the delta in a
# good band?). This asks a different question entirely — is THIS contract cheap
# FOR THIS CONTRACT? A 45% IV might be the low end of one option's own range and
# the high end of another's, and only its own history can say which.
#
# That requires a stored time series, which is why this takes snapshot ROWS
# rather than a live quote. jobs/watched_contract_pull.py and
# jobs/position_eod_snapshot.py accumulate them daily.
#
# TWO INDEPENDENT LEGS, weighted equally at 0-50 each:
#   IV leg    is premium cheap for this contract?  -> LOW percentile scores high
#   EDGE leg  is it more underpriced than usual?   -> HIGH percentile scores high
# The mirror-image bucket thresholds are deliberate: the two legs measure
# opposite-signed desirability, so their scoring ladders are reversed.
#
# WHY BOTH LEGS: cheap IV alone can just mean a dead contract nobody wants.
# Positive model edge alone can just mean the model is wrong about this strike.
# Together they describe a contract that is both cheap on its own terms AND
# priced below what the models think it is worth.
#
# IT REFUSES RATHER THAN GUESSES. Below IV_MIN_HISTORY_IVR days it returns
# insufficient_history=True rather than fabricating a percentile — the same
# stance iv_analytics takes for ticker-level IVR/IVP, and the reason a
# freshly-added watch correctly scores nothing on day one.

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


# Returns BOTH measures because they disagree in an informative way: rank is
# range-based (one outlier spike compresses everything else toward zero) while
# percentile is distribution-based (an outlier barely moves it). A wide gap
# between them is itself a signal that the history contains an extreme.
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
    # A flat history has no range to place the value in, so the neutral midpoint
    # is returned rather than dividing by ~zero. Clamped to [0,100] because
    # `current` is TODAY and is not part of `history`, so it can legitimately sit
    # outside the historical range — a genuinely new extreme reads as 0 or 100.
    rank = 50.0 if span < 0.001 else max(0.0, min(100.0, (current - lo) / span * 100))
    # Strict `<`, so today is not counted against itself — the docstring's point
    # about not self-including. (services/vvol_analytics.py uses `<=` for the
    # same measure; immaterial on continuous float data where exact ties are
    # vanishingly rare, but worth knowing the two differ.)
    pct = max(0.0, min(100.0, sum(1 for h in history if h < current) / len(history) * 100))
    return rank, pct


def _iv_score_from_percentile(ivp: float) -> int:
    """0-50, low IVP (cheap vol) scores highest. Same buckets as
    option_scoring.py's IVP-based iv_score, rescaled from its 0-20 max.

    Stepped rather than continuous, and the steps are UNEVEN: the drop from 50
    to 40 across the cheapest two buckets is gentle, then it falls off a cliff
    (25, 12, 5). Cheap vol is the thesis, so the ladder is steep enough that an
    expensive contract cannot compensate through the edge leg alone.
    """
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
    contract) scores highest -- mirror image of the IV bucket edges.

    Exactly the same 50/40/25/12/5 ladder as the IV leg, with the comparison
    reversed. Keeping them structurally identical is what makes the two legs
    genuinely equal-weighted rather than merely equal-capped.
    """
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


# Note this reuses SCORE_GRADE_A/B/C from core.constants, so a "B" here means
# the same band as a "B" from option_scoring — the two scores are on different
# axes but their grades are directly comparable.
def evaluate_contract(snapshots: list[dict]) -> ContractOpportunity:
    """snapshots: rows shaped like watched_contract_snapshots /
    position_leg_snapshots, each with at least snapshot_date, implied_vol,
    market_price, model_theo. Order doesn't matter -- sorted internally by
    snapshot_date, and the latest row is treated as "today"."""
    # Rows without a snapshot_date are dropped entirely — they cannot be ordered,
    # and the latest row must be unambiguous since it is treated as "today".
    rows = sorted((s for s in snapshots if s.get("snapshot_date")), key=lambda s: s["snapshot_date"])
    n = len(rows)

    if n == 0:
        return ContractOpportunity(snapshot_count=0, insufficient_history=True,
                                    flags=["No snapshot history yet"])

    latest = rows[-1]
    current_iv = latest.get("implied_vol")

    def _edge_bps(row: dict) ->Optional[float]:
        """(model_theo - market_price)/market_price x 10,000.

        POSITIVE means the model prices it ABOVE the market — i.e. underpriced,
        cheap to buy. Same sign convention as fair_value_engine's edge_bps, so
        the two are directly comparable.

        Basis points rather than dollars so a $0.40 and a $40 contract are on
        the same scale. Note `not mp` also rejects a market_price of exactly 0,
        which is correct — the ratio would be undefined.
        """
        mp, mt = row.get("market_price"), row.get("model_theo")
        if not mp or mt is None:
            return None
        return (mt - mp) / mp * 10_000

    current_edge = _edge_bps(latest)

    # Early return still carries today's raw IV and edge, so the UI can display
    # current values while correctly reporting that no percentile-based score is
    # possible yet. Scores stay at their 0 defaults — read insufficient_history
    # before reading opportunity_score.
    if n < IV_MIN_HISTORY_IVR:
        return ContractOpportunity(
            snapshot_count=n, insufficient_history=True,
            current_iv=current_iv, current_edge_bps=current_edge,
            flags=[f"Only {n} day(s) of history -- need {IV_MIN_HISTORY_IVR} for a percentile-based score"],
        )

    # THE TWO HISTORIES ARE BUILT INDEPENDENTLY and can differ in length: a row
    # missing model_theo still contributes its IV. Each leg is then length-checked
    # separately below, so one leg can score while the other reports unavailable.
    #
    # Note both include TODAY's row (rows is the full list), unlike the ticker-level
    # helpers in iv_pull which exclude the current date. Self-inclusion pulls the
    # percentile slightly toward the middle — negligible at these history lengths.
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

    # A leg that could not be scored contributes 0, so a contract with usable IV
    # history but no model_theo caps at 50 and can never grade above a C. That is
    # intended — half the evidence is genuinely missing — but it means a low
    # grade should always be read alongside `flags`.
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
    # An empty levels list means no level can ever be near, so the combined
    # signal below can never fire. Populating `levels` is what makes the whole
    # mechanism useful.
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
    # CLOSEST wins when several levels are within tolerance — not the most
    # significant, since the function has no notion of significance. A user
    # target and a system-derived zero-gamma level compete purely on proximity.
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

    # Falls back to the underlying price on the most recent snapshot row when
    # the caller does not supply one. That value is END-OF-DAY, so pass a live
    # price explicitly for an intraday read.
    if underlying_price is None and snapshots:
        latest = max((s for s in snapshots if s.get("snapshot_date")),
                     key=lambda s: s["snapshot_date"], default=None)
        underlying_price = (latest or {}).get("underlying_price")

    nearby = find_nearby_level(underlying_price, levels or [], tolerance_pct) if underlying_price else None

    # THREE GATES IN ORDER, each returning a specific reason so a near-miss is
    # distinguishable from a non-starter. The opportunity object is returned in
    # every case, so the UI can show HOW close a contract came.
    if opp.insufficient_history:
        return WatchSignal(opp, nearby, False, "Insufficient history for a percentile-based score")
    # Grade A or B only — a C-grade contract is not worth surfacing even if it
    # happens to be sitting on a level.
    if opp.grade not in ("A", "B"):
        return WatchSignal(opp, nearby, False, f"Opportunity grade {opp.grade} below threshold")
    if nearby is None:
        return WatchSignal(opp, nearby, False, "Cheap on its own history, but not near a tracked level")

    return WatchSignal(
        opp, nearby, True,
        f"Grade {opp.grade} (score {opp.opportunity_score}) and within "
        f"{nearby.distance_pct:.1f}% of {nearby.label} (${nearby.price:.2f})",
    )
