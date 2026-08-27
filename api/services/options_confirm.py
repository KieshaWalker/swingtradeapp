from __future__ import annotations

# =============================================================================
# services/options_confirm.py
# =============================================================================
# The options-confirmation leg of the swing-setup engine. Two questions, both
# answered from data the pipeline already writes nightly:
#
#   1. IS THE MOVE ALREADY PRICED?  Compare the channel's measured-move target
#      against the option-implied expected move (expected_move_snapshots).
#   2. WILL DEALERS DAMPEN OR AMPLIFY IT?  Read spot against the zero-gamma
#      level (iv_snapshots).
#
# Nothing here fetches. Both inputs are written by existing EOD jobs.
#
# ── WHY THIS IS THE FALSIFIABLE LEG ──────────────────────────────────────────
# expected_move_pull's own header states the principle: "a price target inside
# the 1σ band is what the market already expects, not an edge." That makes this
# the one confirmation check with a real null hypothesis attached. A channel
# breakout target that sits inside the 1σ cone is not a trade idea — it is the
# consensus, and you pay full price for it. Outside the cone, the option market
# is assigning the move less probability than the chart structure implies, and
# that disagreement is the entire thesis.
#
# ── THE HORIZON PROBLEM, AND HOW IT IS HANDLED ───────────────────────────────
# A measured-move target has NO inherent time horizon — it is a price, not a
# schedule. An expected move is meaningless without one, since EM scales with
# sqrt(t). Comparing them therefore requires an assumption, and hiding that
# assumption inside a single ratio would be dishonest.
#
# Two outputs are produced instead:
#
#   em_ratio_*          target_pct / em_pct at a CHOSEN horizon (monthly, ~30
#                       DTE). Kept as a CONTINUOUS descriptor only — see the
#                       warning below. Never threshold it at 1.0.
#
#   implied_days_*      the horizon-free inversion. Solving EM(t) = target for t
#                       under EM = spot·IV·sqrt(t/365) gives
#
#                           t = 365 · (target_pct/100 / IV)²
#
#                       i.e. "the market prices this move as a 1σ event N days
#                       out." No horizon has to be assumed to read it, and it is
#                       directly comparable to the DTE of the contract actually
#                       being considered. THIS IS THE HEADLINE NUMBER.
#
# ── WHY "IS IT UNDERPRICED?" WAS THE WRONG QUESTION ──────────────────────────
# The first version of this file emitted underpriced_up = em_ratio_up > 1.0,
# reading a target outside the 1σ cone as a mispricing. Measured against the
# real universe that flag came back TRUE on 100% of fitted channels, which makes
# it worthless as a filter — and it is true almost by construction: channel
# heights here run ~27% median while the 30-day cone is ~10-15%, so the ratio
# cannot be near 1. A confirmation leg that agrees with everything confirms
# nothing, the same way a volume cut at >1.0x fires on half of all bars.
#
# The failure was one of units. A measured move is a PRICE WITH NO DEADLINE; an
# expected move is a price AT A DEADLINE. Comparing them at an arbitrary 30 days
# compares different things and the answer is decided by that arbitrary choice.
#
# What replaced it is reachable_*: does the market's OWN implied vol carry price
# to the target inside _REACHABLE_DAYS? That fires on ~14% of channels rather
# than 100%, and it asks a question whose answer is not predetermined.
#
# The actionable reading of implied_days is not "cheap" or "rich" — it is WHICH
# EXPIRY THE THESIS NEEDS. A target with implied_days of 190 bought in 30-DTE
# options is a losing structure no matter how right the direction turns out to
# be, because the vol being paid for cannot travel that far in the time bought.
#
# ── GAMMA REGIME IS ABOUT PATH, NOT DIRECTION ────────────────────────────────
# Dealer gamma says nothing about which way price goes. It says how price
# TRAVELS, which is what decides whether a channel is worth fading or following:
#
#   spot ABOVE zero-gamma (positive)  dealers sell rallies / buy dips to stay
#                                     hedged -> moves are DAMPENED -> ranges
#                                     tend to hold -> fading the boundary is the
#                                     percentage play
#   spot BELOW zero-gamma (negative)  dealers hedge WITH the move -> moves are
#                                     AMPLIFIED -> breakouts tend to extend
#
# That distinction matters here more than usual. Measured over this universe,
# channel position on its own carried no reliable directional edge — pooled it
# looked like momentum, but per-ticker it split 12/16 and neither direction was
# significant. So the channel is NOT asked which way to lean; dealer positioning
# is asked whether the structure should hold at all.
#
# ── FRESHNESS IS REPORTED, NOT ASSUMED ───────────────────────────────────────
# The two inputs land at different times: expected_move_pull runs at 21:00 UTC
# (so the newest row is the prior session), while iv_snapshots is rewritten
# hourly through the day. They will routinely carry different dates, and that is
# normal rather than an error. Both source dates are returned so a caller can
# decide what is too stale instead of silently trusting a week-old cone.
# =============================================================================

import logging
from dataclasses import dataclass
from typing import Optional

log = logging.getLogger(__name__)

# Horizon used for the headline em_ratio. "monthly" is ~30 DTE in
# expected_move_snapshots, which is the rough timescale a daily-bar channel
# break resolves over. Shorter cones make almost every target look outside them;
# longer ones make almost every target look inside.
_HEADLINE_PERIOD = "monthly"

# A target beyond this many implied days is not credible at all. At some point
# "the market prices this as a 1σ event two years out" stops describing this
# market and starts describing a measured move that does not apply to it.
_MAX_CREDIBLE_DAYS = 365.0

# Horizon within which the market's own vol must reach the target for it to
# count as reachable. 90 days ~ the quarterly expiry, the longest tenor with
# reliable liquidity across this universe, and the practical outer bound for a
# swing thesis. Measured: fires on ~14% of fitted channels.
_REACHABLE_DAYS = 90.0


@dataclass
class OptionsConfirmation:
    ok:                    bool = False
    reason:                Optional[str] = None

    spot:                  Optional[float] = None
    em_date:               Optional[str] = None
    iv_date:               Optional[str] = None

    # Expected-move leg
    em_pct:                Optional[float] = None   # 1σ at the headline horizon
    em_iv:                 Optional[float] = None
    em_dte:                Optional[int] = None
    target_up_pct:         Optional[float] = None
    target_down_pct:       Optional[float] = None
    em_ratio_up:           Optional[float] = None
    em_ratio_down:         Optional[float] = None
    implied_days_up:       Optional[float] = None
    implied_days_down:     Optional[float] = None
    # True when the market's own implied vol carries price to the target within
    # _REACHABLE_DAYS. NOT "is it cheap" — see the header for why that question
    # was degenerate.
    reachable_up:          Optional[bool] = None
    reachable_down:        Optional[bool] = None

    # Dealer-positioning leg
    gamma_regime:          Optional[str] = None
    zero_gamma_level:      Optional[float] = None
    spot_to_zero_gamma_pct: Optional[float] = None
    dealer_posture:        Optional[str] = None   # dampening | amplifying
    # True when dealer hedging works WITH a breakout rather than against it.
    breakout_supported:    Optional[bool] = None


def _implied_days(target_pct: Optional[float], iv: Optional[float]) -> Optional[float]:
    """Days at which the 1σ expected move equals `target_pct`.

    Inverts EM = spot·IV·sqrt(t/365). Returns None rather than a huge number
    when IV is missing or non-positive — a zero IV would divide to infinity and
    silently produce a "never" that reads as a very strong signal.
    """
    if target_pct is None or iv is None or iv <= 0:
        return None
    frac = abs(target_pct) / 100.0
    return round(365.0 * (frac / iv) ** 2, 2)


def confirm(
    spot: Optional[float],
    breakout_target_up: Optional[float],
    breakout_target_down: Optional[float],
    em_row: Optional[dict],
    iv_row: Optional[dict],
) -> OptionsConfirmation:
    """Combine a channel's targets with the option market's own forecast.

    `em_row` is one expected_move_snapshots row at the headline period;
    `iv_row` is one iv_snapshots row. Either may be None — the legs are
    INDEPENDENT and a missing expected move must not also cost the gamma read.
    """
    c = OptionsConfirmation()
    if not spot or spot <= 0:
        c.reason = "no_spot"
        return c
    c.spot = spot

    # ── Expected-move leg ────────────────────────────────────────────────────
    if em_row:
        c.em_date = em_row.get("date")
        em_pct = em_row.get("em_pct")
        iv = em_row.get("iv")
        c.em_pct = round(float(em_pct), 4) if em_pct is not None else None
        c.em_iv = round(float(iv), 6) if iv is not None else None
        c.em_dte = em_row.get("dte")

        if breakout_target_up:
            c.target_up_pct = round((breakout_target_up / spot - 1.0) * 100.0, 4)
        if breakout_target_down:
            c.target_down_pct = round((breakout_target_down / spot - 1.0) * 100.0, 4)

        if c.em_pct and c.em_pct > 0:
            # Ratio only, never thresholded — see the header.
            if c.target_up_pct is not None:
                c.em_ratio_up = round(abs(c.target_up_pct) / c.em_pct, 4)
            if c.target_down_pct is not None:
                c.em_ratio_down = round(abs(c.target_down_pct) / c.em_pct, 4)

        c.implied_days_up = _implied_days(c.target_up_pct, c.em_iv)
        c.implied_days_down = _implied_days(c.target_down_pct, c.em_iv)

        # Reachability is decided on the horizon-free number, not on the ratio.
        # Beyond _MAX_CREDIBLE_DAYS the reading is withdrawn entirely (None
        # rather than False): "the measured move does not describe this market"
        # is a different statement from "the move is out of reach this quarter".
        if c.implied_days_up is not None:
            c.reachable_up = (None if c.implied_days_up > _MAX_CREDIBLE_DAYS
                              else c.implied_days_up <= _REACHABLE_DAYS)
        if c.implied_days_down is not None:
            c.reachable_down = (None if c.implied_days_down > _MAX_CREDIBLE_DAYS
                                else c.implied_days_down <= _REACHABLE_DAYS)

    # ── Dealer-positioning leg ───────────────────────────────────────────────
    if iv_row:
        c.iv_date = iv_row.get("date")
        c.gamma_regime = iv_row.get("gamma_regime")
        zgl = iv_row.get("zero_gamma_level")
        c.zero_gamma_level = float(zgl) if zgl is not None else None
        s2z = iv_row.get("spot_to_zero_gamma_pct")
        c.spot_to_zero_gamma_pct = float(s2z) if s2z is not None else None

        # Derived from spot vs the level rather than trusting gamma_regime
        # alone, because that column also carries "unknown". When the level is
        # missing the posture is left None instead of guessed.
        if c.zero_gamma_level and c.zero_gamma_level > 0:
            above = spot > c.zero_gamma_level
            c.dealer_posture = "dampening" if above else "amplifying"
            c.breakout_supported = not above
        elif c.gamma_regime in ("positive", "negative"):
            c.dealer_posture = "dampening" if c.gamma_regime == "positive" else "amplifying"
            c.breakout_supported = c.gamma_regime == "negative"

    c.ok = (em_row is not None) or (iv_row is not None)
    if not c.ok:
        c.reason = "no_options_data"
    return c
