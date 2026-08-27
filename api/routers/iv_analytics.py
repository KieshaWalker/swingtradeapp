from __future__ import annotations
from typing import Optional

# =============================================================================
# routers/iv_analytics.py
# =============================================================================
# POST /iv/analytics -> iv_analytics_endpoint
# POST /iv/snapshot  -> iv_snapshot_endpoint
#
# Schema and persistence notes:
#   IvAnalyticsRequest and IvSnapshotRequest define the request payloads used
#   by lib/services/python_api/python_api_client.dart through ivAnalytics()
#   and ivSnapshot(). If any request field changes, update the Dart client.
#
#   /iv/snapshot writes to Supabase table iv_snapshots. If the table schema or
#   persisted field set changes, update this endpoint and any Supabase helpers.
#
# Related files:
#   api/services/iv_analytics.py   -> analyse() implementation
#   api/core/supabase_client.py    -> Supabase connection
#   lib/services/python_api/python_api_client.dart -> Dart request/response mappings
#   lib/services/macro/macro_score_provider.dart  -> consumes IV analytics output indirectly
# =============================================================================
#
# WHAT THIS ROUTER PRODUCES
# -------------------------
# The single richest computation in the backend. From one option chain it
# derives four families of output:
#
#   1. IV LEVEL      — where implied vol sits versus its own history
#                      (rank/percentile over 4w, 26w and 52w windows).
#   2. SURFACE SHAPE — skew (put vs call IV) and term structure (near vs far).
#   3. DEALER FLOW   — GEX/VEX/CEX/volga: how much hedging market makers must
#                      do, and in which direction. This is the part that says
#                      whether the market is likely to be pinned or to trend.
#   4. RND           — the risk-neutral density implied by the whole surface.
#
# THE DEALER-POSITIONING IDEA
# ---------------------------
# Market makers are broadly short the options that customers buy, and they
# delta-hedge. Their aggregate GAMMA determines what that hedging does to price:
#
#   POSITIVE (long) gamma  -> dealers sell into rallies, buy into dips.
#                             Hedging DAMPENS moves; expect pinning and
#                             range-bound trade.
#   NEGATIVE (short) gamma -> dealers buy into rallies, sell into dips.
#                             Hedging AMPLIFIES moves; expect trend and
#                             volatility expansion.
#
# The ZERO-GAMMA LEVEL is the price separating the two regimes, which makes
# spot's position relative to it one of the most actionable numbers here.
#
# The two endpoints share all computation and differ only in persistence:
# /analytics is read-only; /snapshot additionally upserts into iv_snapshots.
#
# IV UNITS: chain contract IVs arrive as PERCENT (raw Schwab, 21.0 = 21%). The
# service divides by 100 internally where it needs decimals. Do not pre-convert.
# =============================================================================

from datetime import date, datetime, timedelta, timezone
from fastapi import APIRouter
from pydantic import BaseModel, Field

from services.iv_analytics import analyse
from core.supabase_client import get_supabase
from core.config import settings

router = APIRouter()


class IvAnalyticsRequest(BaseModel):
    chain: dict          # Schwab options chain JSON
    # Prior iv_snapshots rows, used ONLY for the historical rank/percentile and
    # skew z-score calculations — never recomputed from. 500 rows is ~2 years
    # of trading days, comfortably covering the 52-week window; the cap also
    # bounds the request size, since these rows are JSONB-heavy.
    #
    # The caller is responsible for fetching these correctly: PostgREST
    # silently caps responses at 1000 rows, so a "latest N" read must order
    # descending and reverse client-side rather than assume it got everything.
    history: list[dict] = Field(default_factory=list, max_length=500)
    # Defaults to DEFAULT_R inside the service when omitted. Only affects the
    # Greeks used for the exposure sums, not the reported IV levels.
    risk_free_rate:Optional[float] = None


class IvSnapshotRequest(IvAnalyticsRequest):
    # Inherits chain/history/risk_free_rate and adds the two fields needed to
    # key the persisted row. ticker is required here but absent from the
    # analytics request, because a pure computation does not need to know the
    # symbol — the chain carries everything the math uses.
    ticker: str
    # Defaults to today. Pass it explicitly when backfilling so the row lands
    # on the observation's own date rather than the run date.
    obs_date:Optional[str] = None



def _result_to_dict(result, spot: float = 0.0) -> dict:
    """Flatten the IvAnalyticsResult dataclass tree to JSON.

    `spot` is threaded in separately because several exposure figures are
    dollar-denominated and must be scaled by the underlying price at read time
    (see GexStrike.dealer_gex). It is not stored on the result object.
    """
    return {
        "ticker": result.ticker,
        # ── IV level and history ─────────────────────────────────────────────
        "current_iv": result.current_iv,
        "iv52w_high": result.iv52w_high,
        "iv52w_low": result.iv52w_low,
        # rank = position between the 52w low and high (span-based, so one
        # spike compresses everything else).
        # percentile = share of history below today (distribution-based).
        # They diverge on skewed distributions, which is why both are exposed.
        "iv_rank": result.iv_rank,
        "iv_percentile": result.iv_percentile,
        # Shorter windows catch a regime change that the 52w figure is too slow
        # to register — 4w high with 52w low is vol waking up.
        "iv_rank_4w": result.iv_rank_4w,
        "iv_percentile_4w": result.iv_percentile_4w,
        "iv_rank_26w": result.iv_rank_26w,
        "iv_percentile_26w": result.iv_percentile_26w,
        "rating": result.rating.value,   # cheap/fair/expensive/extreme/no_data
        # How many history rows were actually usable — a low count means the
        # ranks above are unreliable or null.
        "history_days": result.history_days,
        # ── Skew: the price of downside protection ───────────────────────────
        "skew": result.skew,
        "skew_avg_52w": result.skew_avg_52w,
        # Standardized skew. This is the tradeable read: skew is almost always
        # positive for equities, so the LEVEL says little and the z-score says
        # whether protection is unusually bid right now.
        "skew_z_score": result.skew_z_score,
        # Standard FX-style decomposition of the smile at the 25-delta wings:
        #   rr25 = IV(25Δ put) − IV(25Δ call)  — the TILT (directional fear)
        #   bf25 = wing average − ATM IV       — the CURVATURE (tail bid)
        # Both in vol points. Together they separate "the market fears a drop"
        # from "the market fears a big move either way".
        "skew_rr25": result.skew_rr25,
        "skew_bf25": result.skew_bf25,
        # ── Term structure: near-dated vs far-dated IV ───────────────────────
        # Normally in contango (far > near). BACKWARDATION — near above far —
        # signals an imminent event or acute stress, and is usually the
        # strongest single argument against buying near-dated premium.
        "term_structure": result.term_structure,
        "term_slope_pp": result.term_slope_pp,        # in percentage points
        "term_structure_label": result.term_structure_label,
        # ── Gamma exposure (GEX) — see header ────────────────────────────────
        "total_gex": result.total_gex,           # $M of hedging per $1 move
        "max_gex_strike": result.max_gex_strike,  # the strongest pin candidate
        "put_call_ratio": result.put_call_ratio,
        # ── Second-order exposures ───────────────────────────────────────────
        # VEX (vanna): dealer delta that appears when IV moves — the mechanism
        #   behind vol-crush rallies.
        # CEX (charm): dealer delta that appears purely from time passing —
        #   why pinning strengthens into a Friday expiry.
        # VOLGA: dealer vega sensitivity to vol itself — vol-of-vol pressure.
        #
        # SCALE BREAK: rows in iv_snapshots written BEFORE 2026-06-12 used
        # different units for total_vex/total_cex/total_volga. Across that
        # boundary only the SIGN is comparable, never the magnitude — do not
        # chart these three as a continuous series through that date.
        "total_vex": result.total_vex,
        "total_cex": result.total_cex,
        "total_volga": result.total_volga,
        "max_vex_strike": result.max_vex_strike,
        # ── Regime classification ────────────────────────────────────────────
        "gamma_regime": result.gamma_regime.value,   # positive/negative/unknown
        "vanna_regime": result.vanna_regime.value,   # direction of vol-move impact
        # The price at which aggregate dealer gamma flips sign. Spot ABOVE it =
        # long-gamma/dampened; BELOW = short-gamma/amplified. The pct field is
        # signed distance, so it doubles as "how close are we to the flip".
        "zero_gamma_level": result.zero_gamma_level,
        "spot_to_zero_gamma_pct": result.spot_to_zero_gamma_pct,
        "delta_gex": result.delta_gex,
        # Whether gamma is building or thinning as price rises — tells you
        # whether a move toward the flip accelerates or stalls.
        "gamma_slope": result.gamma_slope.value,
        # Joint read of gamma regime AND IV rank, which are far more
        # informative together: short gamma with cheap IV is the classic
        # squeeze setup; long gamma with expensive IV is an event premium.
        "iv_gex_signal": result.iv_gex_signal.value,
        # Concentration of put gamma just below spot — a dense put wall acts
        # as support while it holds, and accelerates the break when it does not.
        "put_wall_density":   result.put_wall_density,
        "underlying_price":   spot,
        # 0DTE share of total gamma. A high share means the regime is fragile:
        # most of the stabilizing gamma expires at today's close.
        "gex_0dte":           result.gex_0dte,
        "gex_0dte_pct":       result.gex_0dte_pct,
        # Lowest significant positive-GEX support above the zero-gamma level —
        # the level below which hedging flips from dampening to amplifying.
        "volatility_trigger": result.volatility_trigger,
        "spot_to_vt_pct":     result.spot_to_vt_pct,
        # ── Per-strike detail (for charts) ───────────────────────────────────
        # dealer_gex is a METHOD, not a field: it needs spot to convert open
        # interest and gamma into dollars, hence the call here.
        "gex_strikes": [
            {
                "strike": g.strike,
                "call_oi": g.call_oi,
                "put_oi": g.put_oi,
                "call_gamma": g.call_gamma,
                "put_gamma": g.put_gamma,
                "dealer_gex": g.dealer_gex(spot),
            }
            for g in result.gex_strikes
        ],
        # Raw per-strike second-order Greeks. Unlike gex_strikes these are NOT
        # aggregated into a dealer figure here — the client charts them, and
        # the totals above already carry the aggregate view.
        "second_order": [
            {
                "strike":     s.strike,
                "call_oi":    s.call_oi,
                "put_oi":     s.put_oi,
                "call_vanna": s.call_vanna,
                "put_vanna":  s.put_vanna,
                "call_charm": s.call_charm,
                "put_charm":  s.put_charm,
                "call_volga": s.call_volga,
                "put_volga":  s.put_volga,
            }
            for s in result.second_order
        ],
        # The observed smile, for plotting the raw surface alongside any fit.
        # moneyness is strike relative to spot, so curves are comparable
        # across tickers and dates.
        "skew_curve": [
            {
                "strike":    p.strike,
                "moneyness": p.moneyness,
                "call_iv":   p.call_iv,
                "put_iv":    p.put_iv,
            }
            for p in result.skew_curve
        ],
        # Vol-of-vol
        # How much IV itself moves — the empirical analogue of SABR's ν and
        # Heston's ξ. High vvol means the IV rank above is a fast-moving
        # target and premium-selling carries more mark-to-market risk.
        "vvol_nu":         result.vvol_nu,
        "vvol_rank":       result.vvol_rank,
        "vvol_percentile": result.vvol_percentile,
        "vvol_rating":     result.vvol_rating,
        "vvol_trend":      result.vvol_trend,
        # Risk-neutral density per expiry: the market-implied probability
        # distribution of the underlying at each expiration, extracted from the
        # curvature of call prices across strikes (Breeden-Litzenberger).
        "rnd": [s.to_dict() for s in result.rnd],
    }


@router.post("/analytics")
def iv_analytics_endpoint(req: IvAnalyticsRequest):
    """Compute the full IV analytics bundle. Read-only — writes nothing.

    Spot is read from the chain payload rather than taken as a parameter, so it
    is always the price the chain itself was quoted against. A chain missing
    underlyingPrice yields 0.0, which silently zeroes every dollar-denominated
    exposure — the chain must be a complete Schwab payload.
    """
    spot = float(req.chain.get("underlyingPrice", 0))
    result = analyse(req.chain, req.history, req.risk_free_rate)
    return _result_to_dict(result, spot)


@router.post("/snapshot")
def iv_snapshot_endpoint(req: IvSnapshotRequest):
    """Compute the same bundle AND persist it to iv_snapshots.

    Returns the analytics plus two extra keys: `persisted` (whether the write
    actually happened — see the staleness guard) and `date` (the row key used).
    Note the analytics are ALWAYS returned fresh; only the write is skippable.
    """
    spot = float(req.chain.get("underlyingPrice", 0))
    result = analyse(req.chain, req.history, req.risk_free_rate)
    today = req.obs_date or date.today().isoformat()
    # Slimmed-down per-strike GEX for storage: the persisted row keeps only what
    # charts need, not the full gamma detail returned to the caller.
    gex_by_strike = [
        {"strike": g.strike, "dealer_gex": g.dealer_gex(spot), "call_oi": g.call_oi, "put_oi": g.put_oi}
        for g in result.gex_strikes
    ]
    db = get_supabase()

    # Staleness guard: this endpoint fires every time any user opens a chain,
    # and iv_snapshots is a shared/global row (no user_id) — concurrent users
    # on a popular ticker would otherwise each trigger a full rewrite of the
    # same JSONB-heavy row within minutes of each other. Skip the persist step
    # (not the analytics computation) if it was written recently enough.
    #
    # This is a write-amplification guard, not a correctness lock. It is racy by
    # construction — two requests can both read a stale timestamp and both
    # write — which is harmless here because the upsert is idempotent on
    # (ticker, date) and both would be writing near-identical analytics.
    # Window is configurable via IV_SNAPSHOT_STALENESS_MINUTES (default 5).
    persisted = True
    existing = (
        db.table("iv_snapshots").select("updated_at")
        .eq("ticker", req.ticker).eq("date", today).limit(1).execute()
    )
    if existing.data:
        # Postgres returns "...Z"; fromisoformat on Python 3.9 cannot parse a
        # trailing Z, so it is rewritten to the equivalent +00:00 offset.
        last_updated = datetime.fromisoformat(existing.data[0]["updated_at"].replace("Z", "+00:00"))
        if datetime.now(timezone.utc) - last_updated < timedelta(minutes=settings.iv_snapshot_staleness_minutes):
            persisted = False

    if persisted:
        # on_conflict="ticker,date" makes this an upsert against the natural key:
        # one row per ticker per day, overwritten as the session progresses, so
        # the stored snapshot is always the most recent intraday state.
        # `date` is a DATE column — it is never timezone-shifted.
        db.table("iv_snapshots").upsert({
            "ticker": req.ticker,
            "date": today,
            "atm_iv": result.current_iv,
            "skew": result.skew,
            "gex_by_strike": gex_by_strike,
            "total_gex": result.total_gex,
            "max_gex_strike": result.max_gex_strike,
            "put_call_ratio": result.put_call_ratio,
            "underlying_price": spot,
            # Extended fields (migration 027)
            "iv_rank": result.iv_rank,
            "iv_percentile": result.iv_percentile,
            # Multi-window IVR/IVP (migration 055) — previously only written by
            # iv_pull; the live snapshot endpoint must persist them too.
            "iv_rank_4w": result.iv_rank_4w,
            "iv_percentile_4w": result.iv_percentile_4w,
            "iv_rank_26w": result.iv_rank_26w,
            "iv_percentile_26w": result.iv_percentile_26w,
            # Enums are stored as their string values, not their names, so the
            # Dart side parses stable wire strings like "bullishOnVolCrush".
            "iv_rating":             result.rating.value,
            "gamma_regime":          result.gamma_regime.value,
            "gamma_slope":           result.gamma_slope.value,
            "iv_gex_signal":         result.iv_gex_signal.value,
            "zero_gamma_level":      result.zero_gamma_level,
            "spot_to_zero_gamma_pct": result.spot_to_zero_gamma_pct,
            "delta_gex":             result.delta_gex,
            "put_wall_density":      result.put_wall_density,
            "vanna_regime":          result.vanna_regime.value,
            # SCALE BREAK — see _result_to_dict: values stored before
            # 2026-06-12 are in the old units. Any query spanning that date
            # must treat these three as sign-only.
            "total_vex": result.total_vex,
            "total_cex": result.total_cex,
            "total_volga": result.total_volga,
            "max_vex_strike": result.max_vex_strike,
            "skew_avg_52w": result.skew_avg_52w,
            "skew_z_score": result.skew_z_score,
            # `or None` stores SQL NULL rather than an empty JSONB array when
            # no RND slice could be extracted, so "no data" and "computed as
            # empty" stay distinguishable downstream.
            "rnd": [s.to_dict() for s in result.rnd] or None,
            # Institutional GEX fields (migration 029)
            "gex_0dte":           result.gex_0dte,
            "gex_0dte_pct":       result.gex_0dte_pct,
            "volatility_trigger": result.volatility_trigger,
            "spot_to_vt_pct":     result.spot_to_vt_pct,
            # Vol-of-vol (migration 028)
            "vvol_nu":         result.vvol_nu,
            "vvol_rank":       result.vvol_rank,
            "vvol_percentile": result.vvol_percentile,
            "vvol_rating":     result.vvol_rating,
            "vvol_trend":      result.vvol_trend,
        }, on_conflict="ticker,date").execute()
    return {**_result_to_dict(result, spot), "persisted": persisted, "date": today}
