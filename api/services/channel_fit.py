from __future__ import annotations

# =============================================================================
# services/channel_fit.py
# =============================================================================
# Algorithmic channel fitting by TRENDLINES THROUGH SWING PIVOTS.
#
# This is the pivot-trendline construction a trader actually draws, not a
# regression channel. The distinction is the whole point:
#
#   A regression channel fits a line through the CLOSES and offsets it by k
#   standard deviations. It always succeeds, and its boundaries touch nothing in
#   particular — they are a statistical envelope, not levels anyone trades.
#
#   A trendline connects SWING PIVOTS — actual highs and lows where price turned
#   — and its boundaries are levels the market has respected before. It can also
#   legitimately FAIL to find a channel, which is information: not every chart
#   is in one, and inventing one there is how a screen manufactures false
#   positives.
#
# ── THE ALGORITHM ────────────────────────────────────────────────────────────
#   1. Find fractal swing pivots: bar i is a swing high when its high exceeds
#      every high within `strength` bars either side (and symmetrically for
#      lows).
#   2. For every PAIR of swing highs, take the line through them as a candidate
#      resistance line. Reject it if price later pierced it by more than the
#      tolerance — a line price has broken is not a boundary. Score the
#      survivors by how many pivots they touch, how much of the window they
#      span, and how tightly the touches sit.
#   3. Repeat with swing lows for support.
#   4. Search PAIRS of surviving upper/lower lines and keep the pair that forms
#      the best channel — near-parallel is a CHANNEL, converging is a WEDGE,
#      diverging is a BROADENING formation.
#
# ── WHY PAIRS, NOT TWO INDEPENDENT BESTS ─────────────────────────────────────
# Fitting the boundaries independently and stapling them together does not
# produce a channel. Each line can be individually excellent — plenty of
# touches, clean, spanning the window — while the two together diverge wildly.
# Measured on real data, the independent version classified 6 of 8 liquid names
# as "broadening" and produced a 98%-of-spot channel on MU and a $1291 target on
# a $200 AMD: arithmetically correct from two good lines, and meaningless.
#
# Parallelism is therefore part of the SCORE, not a label applied afterwards,
# and pairs that diverge past _MAX_DIVERGENCE are rejected rather than renamed.
# This mirrors how the construction is actually drawn: you fit one trendline to
# the pivots, then bring a parallel copy across to the other side.
#
# ── TOLERANCE IS IN ATR, NOT PERCENT OR CENTS ────────────────────────────────
# "Close enough to count as a touch" has to scale with the instrument's own
# volatility. A fixed 1% band is far too tight for a name that swings 4% a day
# and absurdly loose for a utility. ATR makes the fit behave the same way on
# every ticker in the universe, which is what makes scores comparable across a
# screen — the entire reason this runs over 51 symbols rather than one chart.
#
# ── PIVOTS LAG BY `strength` BARS, DELIBERATELY ──────────────────────────────
# A swing high is only confirmed once `strength` bars have printed to its RIGHT
# without exceeding it. That means the most recent `strength` bars can never be
# pivots yet, and a channel drawn today may gain a new pivot tomorrow. This is
# the honest version of what other platforms hide by repainting: we would rather
# a boundary appear a few bars late than show one that silently moves after the
# fact. Anything reading these fits must treat them as confirmed-as-of, not
# predictive.
#
# ── LINEAR PRICE, PERCENTAGE OUTPUTS ─────────────────────────────────────────
# Lines are fit in linear price space because that is what the user sees when
# drawing on a chart. Every OUTPUT that gets compared across tickers — channel
# width, distance to boundary, breakout target — is converted to a percentage of
# spot, so a $12 stock and a $900 stock are measured on the same axis. Fitting in
# log space would make long channels more principled but would no longer match
# the drawn line, which is the thing being reproduced.
# =============================================================================

import logging
import math
from dataclasses import dataclass, asdict
from typing import List, Optional, Sequence, Tuple

log = logging.getLogger(__name__)

# Bars either side that must not exceed a pivot for it to be confirmed. 3 is the
# common fractal setting on daily bars: large enough to ignore single-bar noise,
# small enough to catch the swings inside a multi-month channel.
_PIVOT_STRENGTH = 3

# A touch counts when price comes within this many ATR of the line.
_TOUCH_ATR = 0.55
# A line is VIOLATED when price pierces it by more than this many ATR. Larger
# than the touch band on purpose: wicks routinely poke through a real boundary,
# and a line invalidated by every wick would survive nowhere.
_BREAK_ATR = 1.10

# A trendline needs at least this many touches to be credible. Two is trivially
# satisfiable — any two points define a line — so three is the real minimum: the
# third touch is the first piece of evidence the line means anything.
_MIN_TOUCHES = 3

# Fraction of the window a line must span end-to-end. A line joining two pivots
# three bars apart is a local artifact, not a channel boundary.
_MIN_SPAN_FRAC = 0.35

# How much the channel's WIDTH may change across the window, as a fraction of
# its mean width, before it stops being parallel. Measured against width rather
# than against slope: dividing by mean slope blows up whenever a channel is
# near-horizontal, which made every flat channel look non-parallel.
_PARALLEL_TOL = 0.25

# Past this much width change the pair is not a formation at all, just two lines
# heading in different directions. Rejected outright rather than labelled.
_MAX_DIVERGENCE = 0.90

# A channel taller than this share of spot is not a tradeable structure over a
# daily window — it is the fit having failed. Rejected before it can emit a
# measured-move target several times the share price.
_MAX_WIDTH_PCT = 45.0

# Spot may sit somewhat outside the boundaries (a break in progress), but far
# outside means the lines no longer describe where price is.
_POS_LO, _POS_HI = -0.35, 1.35

# Candidate lines kept per side for the pair search. The best line on one side
# rarely pairs with the best on the other; keeping a shortlist is what lets a
# slightly weaker line win by forming a much better channel.
_TOP_K = 6


@dataclass
class TrendLine:
    """One fitted boundary. `slope` is price per bar; x is the bar index."""
    slope:      float
    intercept:  float
    touches:    int
    span_bars:  int
    # Mean absolute distance of touching pivots from the line, in ATR. Lower is
    # a tighter, more convincing line.
    tightness:  float
    pivot_idx:  List[int]
    # Standalone quality of this line, before any channel pairing.
    score:      float = 0.0
    # Index of the line's FIRST anchor pivot. The line is only meaningful from
    # here forward — it was validated against price on [start_idx, n) and never
    # tested before it. Extrapolating a trendline backwards past its own origin
    # is not a claim the fit makes.
    start_idx:  int = 0
    # Index of the SECOND construction pivot. Unlike pivot_idx (every bar within
    # touch tolerance, which can include bars far past the line's origin), this
    # is one of the two exact points the line was drawn through — needed to
    # recover a line's true anchors for storage, since a tolerance-band touch is
    # not the same claim as "the line passes through this point exactly".
    end_idx:    int = 0

    def value_at(self, x: float) -> float:
        return self.slope * x + self.intercept


@dataclass
class ChannelFit:
    """A fitted channel, or the reason there isn't one."""
    found:          bool
    reason:         Optional[str] = None
    kind:           Optional[str] = None   # channel | wedge | broadening
    direction:      Optional[str] = None   # ascending | descending | horizontal
    upper:          Optional[TrendLine] = None
    lower:          Optional[TrendLine] = None
    # Everything below is expressed at the MOST RECENT bar.
    upper_now:      Optional[float] = None
    lower_now:      Optional[float] = None
    width_pct:      Optional[float] = None   # channel height as % of spot
    position:       Optional[float] = None   # 0.0 at lower line, 1.0 at upper
    slope_pct_day:  Optional[float] = None   # channel drift, % of spot per bar
    # Measured move: a break of the channel classically projects its own height.
    breakout_target_up:   Optional[float] = None
    breakout_target_down: Optional[float] = None
    bars_used:      int = 0
    confidence:     Optional[float] = None   # 0-1, see _confidence()
    # First bar index on which BOTH boundaries are valid. Anything reading this
    # fit — a chart overlay, a containment check — must not draw or test the
    # channel before here; the lines were never validated against that stretch.
    start_idx:      Optional[int] = None


def _atr(highs: Sequence[float], lows: Sequence[float],
         closes: Sequence[float], period: int = 14) -> float:
    """Average true range over the last `period` bars.

    True range, not high-minus-low: the gap between yesterday's close and
    today's range is part of the move, and on gappy names ignoring it
    understates volatility badly enough to make the touch band meaningless.
    """
    trs: List[float] = []
    for i in range(1, len(highs)):
        trs.append(max(
            highs[i] - lows[i],
            abs(highs[i] - closes[i - 1]),
            abs(lows[i] - closes[i - 1]),
        ))
    if not trs:
        return 0.0
    window = trs[-period:]
    return sum(window) / len(window)


def find_pivots(highs: Sequence[float], lows: Sequence[float],
                strength: int = _PIVOT_STRENGTH) -> Tuple[List[int], List[int]]:
    """Return (swing_high_indices, swing_low_indices).

    Strict on the left, non-strict on the right. A flat double top would
    otherwise register zero pivots — with `>` on both sides neither bar wins —
    and flat tops are exactly the structure a resistance line wants to catch.
    """
    n = len(highs)
    hi: List[int] = []
    lo: List[int] = []
    for i in range(strength, n - strength):
        h, l = highs[i], lows[i]
        if (all(h > highs[j] for j in range(i - strength, i)) and
                all(h >= highs[j] for j in range(i + 1, i + strength + 1))):
            hi.append(i)
        if (all(l < lows[j] for j in range(i - strength, i)) and
                all(l <= lows[j] for j in range(i + 1, i + strength + 1))):
            lo.append(i)
    return hi, lo


def _candidate_lines(prices: Sequence[float], pivots: Sequence[int],
                     n_bars: int, atr: float, upper: bool, *,
                     touch_atr: float = _TOUCH_ATR,
                     break_atr: float = _BREAK_ATR,
                     min_touches: int = _MIN_TOUCHES,
                     min_span_frac: float = _MIN_SPAN_FRAC) -> List[TrendLine]:
    """Top _TOP_K trendlines through a set of pivots, best first.

    `upper=True` fits resistance against the highs (violated when price pierces
    ABOVE it); False fits support against the lows.

    Returns a SHORTLIST rather than a single winner because the best upper line
    and the best lower line frequently do not form the best channel — see the
    header. The pair search needs alternatives to choose from.

    The four tolerance/threshold knobs default to the module constants but are
    overridable — this is what lets suggest_trendlines() expose "how strict"
    the search is to a caller (a user's own tolerance sliders) without every
    other user of this module inheriting a different default.

    O(pivots^2 * bars). With ~10-30 pivots in a 120-bar window that is a few
    hundred thousand operations, so the search is exhaustive: the chosen line is
    genuinely the best available, not whatever a greedy pass found first.
    """
    if len(pivots) < 2 or atr <= 0:
        return []

    touch_band = touch_atr * atr
    break_band = break_atr * atr
    min_span = max(2, int(min_span_frac * n_bars))

    out: List[TrendLine] = []
    for a in range(len(pivots)):
        for b in range(a + 1, len(pivots)):
            i, j = pivots[a], pivots[b]
            if j - i < 2:
                continue
            slope = (prices[j] - prices[i]) / (j - i)
            intercept = prices[i] - slope * i

            violated = False
            touches: List[int] = []
            for k in range(i, n_bars):
                line = slope * k + intercept
                diff = prices[k] - line if upper else line - prices[k]
                if diff > break_band:
                    violated = True
                    break
                if abs(prices[k] - line) <= touch_band:
                    touches.append(k)
            if violated or len(touches) < min_touches:
                continue

            span = touches[-1] - touches[0]
            if span < min_span:
                continue

            dists = [abs(prices[k] - (slope * k + intercept)) / atr for k in touches]
            tightness = sum(dists) / len(dists)

            # Touches dominate (that is the evidence), span rewards a line that
            # governs the whole window, tightness breaks ties toward the cleaner
            # fit. Recency is deliberately NOT rewarded — a boundary respected
            # months ago and again last week is stronger than one only touched
            # recently.
            score = len(touches) * 10.0 + (span / n_bars) * 5.0 - tightness * 2.0
            out.append(TrendLine(
                slope=slope, intercept=intercept, touches=len(touches),
                span_bars=span, tightness=tightness, pivot_idx=touches,
                score=score, start_idx=i, end_idx=j,
            ))

    out.sort(key=lambda t: t.score, reverse=True)
    # Deduplicate near-identical lines so the shortlist holds genuinely distinct
    # alternatives rather than six numerical neighbours of the same line.
    kept: List[TrendLine] = []
    for cand in out:
        if all(abs(cand.slope - k.slope) > 1e-9 or
               abs(cand.intercept - k.intercept) > 1e-6 for k in kept):
            kept.append(cand)
        if len(kept) >= _TOP_K:
            break
    return kept


def _confidence(upper: TrendLine, lower: TrendLine, n_bars: int) -> float:
    """0-1 score for how much to trust the fit.

    Blends evidence (touch counts), coverage (span) and cleanliness
    (tightness). Deliberately saturating: six touches is not twice as
    trustworthy as three, so the touch term caps out rather than growing without
    limit and letting one noisy line dominate a screen ranking.
    """
    touch_term = min((upper.touches + lower.touches) / 10.0, 1.0)
    span_term = min((upper.span_bars + lower.span_bars) / (1.6 * n_bars), 1.0)
    tight_term = max(0.0, 1.0 - (upper.tightness + lower.tightness) / 2.0)
    return round(0.5 * touch_term + 0.3 * span_term + 0.2 * tight_term, 4)


def fit_channel(highs: Sequence[float], lows: Sequence[float],
                closes: Sequence[float],
                strength: int = _PIVOT_STRENGTH) -> ChannelFit:
    """Fit a channel to one OHLC window. Bars must be OLDEST FIRST.

    Returns ChannelFit(found=False, reason=...) rather than raising or inventing
    a channel. "No channel here" is a legitimate, common and useful answer.
    """
    n = len(closes)
    if n < 30:
        return ChannelFit(found=False, reason="too_few_bars", bars_used=n)

    atr = _atr(highs, lows, closes)
    if atr <= 0:
        return ChannelFit(found=False, reason="zero_atr", bars_used=n)

    hi_piv, lo_piv = find_pivots(highs, lows, strength)
    if len(hi_piv) < 2 or len(lo_piv) < 2:
        return ChannelFit(found=False, reason="insufficient_pivots", bars_used=n)

    uppers = _candidate_lines(highs, hi_piv, n, atr, upper=True)
    lowers = _candidate_lines(lows, lo_piv, n, atr, upper=False)
    if not uppers or not lowers:
        return ChannelFit(found=False, reason="no_valid_trendline", bars_used=n)

    x = n - 1
    n_bars_ = n
    spot = closes[-1]

    # ── Pair search ──────────────────────────────────────────────────────────
    # Every surviving upper against every lower (at most _TOP_K^2 = 36 pairs).
    # Parallelism enters the SCORE here rather than being labelled afterwards,
    # which is what stops two individually-good but diverging lines from being
    # reported as a channel.
    best = None
    best_score = float("-inf")
    best_meta = None
    for u in uppers:
        for l in lowers:
            # The channel exists only where BOTH lines have been validated.
            # Measuring width from bar 0 instead extrapolates each line back
            # past its own first anchor into a stretch it was never tested on,
            # which is what previously let "support" sit above price for a third
            # of the window.
            x0 = max(u.start_idx, l.start_idx)
            if (x - x0) < max(2, int(_MIN_SPAN_FRAC * n_bars_)):
                continue

            h_now = u.value_at(x) - l.value_at(x)
            h_start = u.value_at(x0) - l.value_at(x0)
            # Lines crossed at either end: a fully converged wedge, whose
            # negative width would poison every downstream percentage.
            if h_now <= 0 or h_start <= 0:
                continue

            mean_h = (h_now + h_start) / 2.0
            divergence = abs(h_now - h_start) / mean_h
            if divergence > _MAX_DIVERGENCE:
                continue

            width_pct = h_now / spot * 100.0
            if width_pct > _MAX_WIDTH_PCT:
                continue

            position = (spot - l.value_at(x)) / h_now
            if not (_POS_LO <= position <= _POS_HI):
                continue

            # Divergence is penalised hard: a parallel pair of decent lines is
            # worth more than a diverging pair of excellent ones, because only
            # the former is a channel. The width term mildly prefers tighter
            # structures, which have more usable measured-move targets.
            pair_score = (u.score + l.score
                          - divergence * 40.0
                          - max(0.0, width_pct - 20.0) * 0.4)
            if pair_score > best_score:
                best_score = pair_score
                best = (u, l)
                best_meta = (h_now, h_start, divergence, width_pct, position, x0)

    if best is None:
        return ChannelFit(found=False, reason="no_valid_channel_pair", bars_used=n)

    upper, lower = best
    h_now, h_start, divergence, width_pct, position, x0 = best_meta
    up_now, lo_now = upper.value_at(x), lower.value_at(x)

    # Classification falls out of how the width evolved across the window.
    if divergence <= _PARALLEL_TOL:
        kind = "channel"
    elif h_now < h_start:
        kind = "wedge"          # converging
    else:
        kind = "broadening"     # diverging

    avg_slope = (upper.slope + lower.slope) / 2.0
    # Horizontal band: drift is small relative to the channel's own height, so
    # the slope is noise rather than trend. Judged against height, not an
    # absolute cents-per-bar figure, so it scales across the universe. Measured
    # over the channel's OWN span (x - x0), not the whole window.
    if abs(avg_slope) * max(1, x - x0) < 0.25 * h_now:
        direction = "horizontal"
    else:
        direction = "ascending" if avg_slope > 0 else "descending"

    return ChannelFit(
        found=True,
        kind=kind,
        direction=direction,
        upper=upper,
        lower=lower,
        upper_now=round(up_now, 4),
        lower_now=round(lo_now, 4),
        width_pct=round(width_pct, 4),
        position=round(position, 4),
        slope_pct_day=round(avg_slope / spot * 100.0, 6),
        # Measured move: a break projects the channel's own height from the
        # broken boundary. The classical target, and the number the options
        # confirmation step compares against the implied expected move.
        breakout_target_up=round(up_now + h_now, 4),
        breakout_target_down=round(lo_now - h_now, 4),
        bars_used=n,
        confidence=_confidence(upper, lower, n),
        start_idx=x0,
    )


def to_dict(fit: ChannelFit) -> dict:
    """Flatten for JSONB storage; TrendLine objects become nested dicts."""
    d = asdict(fit)
    return d


# =============================================================================
# Single-line tools: SUGGEST candidates for saving, and TRACK a saved line.
# =============================================================================
# fit_channel() answers "is there a channel here" by auto-pairing one upper and
# one lower line. These two functions serve a different, narrower need: a user
# picking INDIVIDUAL support or resistance lines to save (not necessarily a
# matched pair), with their own tolerance settings, and later asking "is the
# line I saved still holding".
# =============================================================================


def suggest_trendlines(
    highs: Sequence[float], lows: Sequence[float], closes: Sequence[float], *,
    strength: int = _PIVOT_STRENGTH,
    touch_atr: float = _TOUCH_ATR,
    break_atr: float = _BREAK_ATR,
    min_touches: int = _MIN_TOUCHES,
    min_span_frac: float = _MIN_SPAN_FRAC,
) -> "tuple[List[TrendLine], List[TrendLine]]":
    """Candidate (resistance, support) trendlines for a user to choose from.

    Unlike fit_channel, this does NOT pair or classify — it returns the raw
    shortlists so a caller can offer several distinct resistance lines and
    several distinct support lines independently, matching "multiple lines can
    be added" rather than one auto-selected channel.

    Every tolerance is a caller-supplied override with the module's own
    measured defaults as a fallback, which is what lets a user's own slider
    values reach the search: touch_atr/break_atr control how close a touch or a
    violation must be (in ATR — see the module header for why ATR and not a
    fixed price band), min_touches sets the evidence bar, min_span_frac sets
    how much of the window a line must govern to count.

    Returns ([], []) rather than raising when the window is too short or too
    flat to fit anything — the module rule that "no line here" is a legitimate
    answer, not an error, applies just as much to a single-sided request as it
    does to fit_channel's paired one.
    """
    n = len(closes)
    if n < 30:
        return [], []
    atr = _atr(highs, lows, closes)
    if atr <= 0:
        return [], []
    hi_piv, lo_piv = find_pivots(highs, lows, strength)
    upper = _candidate_lines(
        highs, hi_piv, n, atr, upper=True,
        touch_atr=touch_atr, break_atr=break_atr,
        min_touches=min_touches, min_span_frac=min_span_frac,
    )
    lower = _candidate_lines(
        lows, lo_piv, n, atr, upper=False,
        touch_atr=touch_atr, break_atr=break_atr,
        min_touches=min_touches, min_span_frac=min_span_frac,
    )
    return upper, lower


@dataclass
class LineAccuracy:
    bars_checked:       int = 0
    touches:            int = 0
    violations:         int = 0
    first_violation_idx: Optional[int] = None
    max_deviation_atr:  Optional[float] = None
    # holding | broken | unverified.  None only for a 'manual' kind with no
    # directional reading requested — see track_line_accuracy.
    status:             Optional[str] = None


def track_line_accuracy(
    highs: Sequence[float], lows: Sequence[float], closes: Sequence[float],
    slope: float, intercept: float, start_idx: int, *,
    kind: Optional[str] = None,
    touch_atr: float = _TOUCH_ATR,
    break_atr: float = _BREAK_ATR,
) -> LineAccuracy:
    """How a SAVED line has held up against bars printed since it was drawn.

    This is deliberately the exact same touch/violation test _candidate_lines
    uses during fitting, just pointed at bars the line did not exist to be
    fitted against. Reusing the identical bands means a line's live track
    record is judged by the same standard that qualified it as a candidate in
    the first place, rather than a second, looser definition of "holding".

    `kind` decides which side counts as a violation, and is intentionally
    ignored for anything other than 'support' or 'resistance':
      resistance   violated when a bar's HIGH closes break_atr*ATR above the line
      support      violated when a bar's LOW closes break_atr*ATR below the line
      manual / None  no side is assumed. A hand-drawn line carries no built-in
                     expectation of which way price should stay, and guessing
                     one would be worse than reporting deviation without a
                     verdict — status is left None, not defaulted to "holding".

    `start_idx` is the bar index of the line's LATER anchor (its own end_idx,
    once mapped from a stored line's second anchor date back to a bar index) —
    tracking begins there because that is the first bar the line's author
    actually committed to a forward-looking line, not before.

    ATR is computed over the full supplied series (typically "since the anchor
    date through today"), which lets its tolerance widen or narrow as the
    market's own volatility has changed since the line was drawn, rather than
    freezing the ATR that happened to be in effect at save time.
    """
    n = len(closes)
    acc = LineAccuracy()
    if start_idx >= n - 1:
        return acc

    atr = _atr(highs, lows, closes)
    if atr <= 0:
        return acc
    touch_band = touch_atr * atr
    break_band = break_atr * atr

    touches = 0
    violations = 0
    first_violation_idx: Optional[int] = None
    max_dev = 0.0

    for k in range(start_idx, n):
        line = slope * k + intercept
        max_dev = max(max_dev, abs(closes[k] - line) / atr)

        if kind == "resistance":
            if highs[k] - line > break_band:
                violations += 1
                if first_violation_idx is None:
                    first_violation_idx = k
            elif abs(highs[k] - line) <= touch_band:
                touches += 1
        elif kind == "support":
            if line - lows[k] > break_band:
                violations += 1
                if first_violation_idx is None:
                    first_violation_idx = k
            elif abs(lows[k] - line) <= touch_band:
                touches += 1
        else:
            if abs(closes[k] - line) <= touch_band:
                touches += 1

    acc.bars_checked = n - start_idx
    acc.touches = touches
    acc.violations = violations
    acc.first_violation_idx = first_violation_idx
    acc.max_deviation_atr = round(max_dev, 4)
    if kind in ("resistance", "support"):
        acc.status = "broken" if violations > 0 else "holding"
    return acc
