from __future__ import annotations
from typing import Optional

# =============================================================================
# jobs/crisis_pull.py
# =============================================================================
# Job — Market-level crisis-signal checklist → upsert crisis_checklist_snapshots.
# Cron: 10 21 * * 1-5  (16:10 ET close-capture, Mon-Fri; idempotent upsert)
#
# Scores the recurring pre-crisis signals calibrated on 13 historical crises
# (1873-2022; see data/crisis_checklist_2026-07-16.md for derivation):
#   structural: index-at-highs, valuation (CAPE), leverage (margin debt),
#               speculative-tier crack
#   catalysts:  Fed tightening, curve inversion, public-credit turn,
#               private-credit stress, breadth failure
#
# Sources:
#   FRED (via get-fred-data edge function): HY/IG OAS, T10Y2Y, DFF, CPI
#   Schwab closes (via get-schwab-pricehistory): SPY/RSP/IWM + BDC/manager/
#     speculative baskets
#   CAPE + margin debt have no free daily API: values are carried forward from
#     the most recent non-null row. Update them with a monthly manual upsert
#     (Shiller data / FINRA release) and the carry-forward propagates.
# =============================================================================
#
# THE STRUCTURE / CATALYST SPLIT IS THE WHOLE IDEA, and it is what separates
# this from another market-timing score:
#
#   STRUCTURAL signals describe FRAGILITY — how far a fall would go if one
#     started. Index at highs, stretched valuation, high leverage, the
#     speculative tier already cracking. They can stay lit for YEARS. They are
#     not sell signals and must never be read as timing.
#
#   CATALYSTS describe IGNITION — something actually breaking now. Fed
#     tightening, curve inversion, credit turning, private-credit stress,
#     breadth failing.
#
# The historical pattern across the 13-crisis ledger: catalysts firing INTO a
# structurally fragile setup is what preceded a crisis. Either alone did not.
# So the two counts are stored SEPARATELY (structural_lit, catalysts_firing)
# rather than summed into one number, precisely so they cannot be conflated.
#
# THRESHOLDS ARE HISTORICALLY CALIBRATED, NOT FITTED. Every cut in the verdict
# block comes from data/crisis_checklist_2026-07-16.md — measured against what
# these series did before actual past breaks, not tuned against recent returns.
# That is why they should not be adjusted to make current readings look
# reasonable.
#
# THREE-STATE VERDICTS: "firing" / "partial" / "clean", plus "unknown" when the
# input is missing. "unknown" is deliberately distinct from "clean" — a signal
# that could not be evaluated is not a signal that passed. Neither counts toward
# the lit/firing totals.
#
# GLOBAL AND MARKET-LEVEL: one row per day for the whole market, no ticker and
# no user_id. Runs ONCE daily after the close, unlike the hourly per-ticker
# pipeline.

import asyncio
import logging
from datetime import datetime, timezone

import httpx
import pytz

from core.config import settings
from core.supabase_client import get_supabase
from jobs.common import fetch_schwab_closes, is_eod_capture_run

log = logging.getLogger(__name__)

_ET = pytz.timezone("America/New_York")

# Equal-weight baskets. BDCs hold private loans (daily market pricing of the
# quarterly-marked books); managers originate them. Spec basket = the current
# cycle's parabolic tier — revisit when the cycle rotates.
# BDCs = the vehicles HOLDING private loans. Their books are marked quarterly,
# but their shares trade daily — so the share price is the market's live opinion
# of stale marks, which is exactly the private-credit stress signal.
_BDC_BASKET = ["ARCC", "OBDC", "FSK", "BXSL", "MAIN"]
# Managers = the firms ORIGINATING those loans. They break differently from the
# holders (fee income vs credit losses), so both are tracked and the WORSE of
# the two drives the verdict.
_MGR_BASKET = ["ARES", "OWL", "APO", "BX", "KKR"]
# The current cycle's parabolic tier. Cycle-specific by nature — the comment
# above is a standing instruction to revisit this when leadership rotates.
_SPEC_BASKET = ["MU", "SNDK"]

# ~52 trading weeks. The "all-time high" in this file is really a 52-WEEK high
# (see the `note` written into signals), which is a deliberate simplification:
# it needs no separate ATH data source, and a genuine crisis setup involves an
# index at or near its 52-week high anyway.
_LOOKBACK_DAYS = 260  # ~52 trading weeks for high-water tracking

# Polymarket event slugs snapshotted daily alongside the checklist:
# real-money forward probabilities for the Fed-policy catalyst, data-center
# regulatory risk, and the Iran conflict. Read-only public Gamma API.
#
# Multi-tranche "by <date>" events expand to one row per date tranche, so the
# slug count and the row count differ sharply — the list below writes ~107
# rows/day. Tranches whose date has passed keep reporting with closed=true;
# that is intentional, it preserves the resolution in history.
#
# Slugs are dated and event-specific: when an event resolves and Polymarket
# opens a successor, the old slug returns an empty list and _snapshot_polymarket
# logs polymarket_fetch_failed and moves on. Dead slugs are noise, not an
# outage — prune them here when that shows up in the logs.
_POLYMARKET_SLUGS = [
    # ── Macro / Fed policy ────────────────────────────────────────────────
    "fed-rate-hike-by",
    "fed-decision-in-september-762",
    "will-any-state-enact-a-data-center-moratorium-by-december-31-20260707003733282",
    "how-high-will-10-year-treasury-yield-go-before-2027",

    # ── Iran: conflict state & escalation ─────────────────────────────────
    "will-the-us-invade-iran-before-2027",
    "israel-x-iran-ceasefire-continues-throughptptpt-20260716224448963",
    "us-x-iran-effective-ceasfire-byptptpt-2-week-pause-20260715194822042",
    "iran-full-airspace-closure-byptptpt-20260625195253028",
    "iran-leadership-change-by",

    # ── Iran: diplomacy & deal terms ──────────────────────────────────────
    # Deal odds price well above stockpile-surrender odds; the spread between
    # these two is the market's read on how partial any settlement would be.
    "us-iran-final-nuclear-deal-by-20260621201254412",
    "iran-agrees-to-surrender-enriched-uranium-stockpile-by",
    "next-round-of-us-iran-peace-talks-byptptpt-20260623022722982",
    "iran-announces-withdrawal-from-mou-negotiations-byptptpt-20260622191732319",
    "us-iran-60-day-negotiation-period-extended-20260624044855448",

    # ── Iran: Hormuz (the oil transmission channel) ───────────────────────
    # Thin books — read these for direction, not for calibrated probability.
    "iran-charges-hormuz-fees-byptptpt-20260625175035466",
    "us-iran-hormuz-agreement-byptptpt-20260803235957575",
    "iran-oman-hormuz-management-agreement-byptptpt-20260804222725871",
]


async def _fetch_fred_series(
    client: httpx.AsyncClient,
    series_id: str,
    limit: int = 130,
) -> list[float]:
    """Fetch a FRED series oldest→newest via the edge function.

    Near-duplicate of the helper in jobs/regime_pull.py, differing only in the
    default limit. Kept local rather than shared because the two jobs pull very
    different series at very different frequencies.

    FRED returns most-recent-first, so the list is reversed; "." holiday
    placeholders are dropped rather than parsed. Returns [] on failure — every
    caller below degrades that to a null field rather than aborting.

    IMPORTANT ON FREQUENCY: the series pulled here are daily, weekly, monthly
    AND quarterly, so an index like [-13] means "13 observations back", which is
    13 months for CPI but 13 days for DFF. Every lookback below is sized to its
    own series frequency — see the individual comments.
    """
    try:
        resp = await client.post(
            f"{settings.edge_function_base}/get-fred-data",
            json={"series_id": series_id, "limit": str(limit)},
            headers={
                "Authorization": f"Bearer {settings.supabase_service_key}",
                "Content-Type": "application/json",
            },
            timeout=30.0,
        )
        if resp.status_code != 200:
            log.warning("fred_%s_failed status=%s", series_id, resp.status_code)
            return []
        obs = resp.json().get("observations", [])
        return [float(o["value"]) for o in reversed(obs) if o.get("value") not in (".", None, "")]
    except Exception as exc:
        log.warning("fred_%s_error error=%s", series_id, exc)
        return []


def _composite(members: list[list[float]]) -> list[float]:
    """Equal-weight composite of close series, each indexed to its first value.
    Series are right-aligned (truncated to the shortest) so 'today' lines up.

    Two normalizations, both necessary:

    INDEXING each member to its own first value (s[i]/s[0]) makes an
    equal-weight basket rather than a price-weighted one. Without it a $200
    stock would dominate a $20 stock in the average, and the composite would
    track the expensive member instead of the group.

    RIGHT-ALIGNING (s[-n:]) matters because members can have different history
    lengths — a recent IPO, or a symbol Schwab returned less data for. Aligning
    on the END guarantees index i means the same session in every member. Naive
    left-alignment would compare last Tuesday in one name against last Friday in
    another.

    Members with fewer than 21 closes are dropped as too short to contribute.
    Returns [] when nothing qualifies, which the callers turn into null fields
    and an "unknown" verdict.

    Note s[0] here is the first value of the ALIGNED slice, so the composite is
    indexed to the start of the common window, not to each member's own history.
    """
    usable = [s for s in members if len(s) >= 21]
    if not usable:
        return []
    n = min(len(s) for s in usable)
    aligned = [s[-n:] for s in usable]
    return [
        sum(s[i] / s[0] for s in aligned) / len(aligned)
        for i in range(n)
    ]


def _off_high_pct(series: list[float]) -> Optional[float]:
    """How far below its own window high the series currently sits, in percent.

    Always <= 0 (the max includes the last value, so a series at its high
    returns exactly 0.0). The primary drawdown measure throughout this file.
    """
    if not series:
        return None
    hi = max(series)
    return (series[-1] / hi - 1) * 100 if hi > 0 else None


def _days_since_high(series: list[float]) -> Optional[int]:
    """Sessions elapsed since the window high. 0 means the high is today.

    The TIME dimension that _off_high_pct misses, and the basis for the breadth
    signal: comparing how stale RSP's high is against how stale SPY's is
    detects a narrowing rally even when neither has fallen much.

    max() over indices returns the FIRST occurrence on ties, so a repeated high
    reports the earliest one — a conservative choice that makes the lag look
    slightly older rather than fresher.
    """
    if not series:
        return None
    hi_i = max(range(len(series)), key=lambda i: series[i])
    return len(series) - 1 - hi_i


def _chg_pct(series: list[float], sessions: int) -> Optional[float]:
    """Percent change over the last `sessions` observations.

    Returns None rather than a partial reading when the series is too short, and
    guards a non-positive denominator. Note `sessions` counts OBSERVATIONS, so on
    a weekly series 20 means 20 weeks.
    """
    if len(series) <= sessions or series[-1 - sessions] <= 0:
        return None
    return (series[-1] / series[-1 - sessions] - 1) * 100


async def _snapshot_polymarket(client: httpx.AsyncClient, db, obs_date: str) -> int:
    """Snapshot configured Polymarket events. Failures are logged, never fatal —
    a Polymarket outage must not break the checklist write.

    WHY PREDICTION MARKETS SIT IN A CRISIS CHECKLIST: every other signal here is
    BACKWARD-looking — what prices have already done. These are real-money
    FORWARD probabilities on the specific events that would be the catalyst.
    They are the only leading input in the file.

    Fetched SEQUENTIALLY, not concurrently. Polite to a free public API, and
    latency is irrelevant on a once-daily job.

    The `outcomes`/`outcomePrices` fields arrive as JSON-encoded STRINGS inside
    the JSON response, hence the inner json.loads. Markets without a "Yes"
    outcome, or with a length mismatch between outcomes and prices, are skipped
    rather than guessed at.

    Every failure mode is contained: a dead slug logs and continues, an upsert
    failure returns 0, and the caller writes the checklist row regardless.
    Alerts are evaluated only after a successful upsert.
    """
    import json as _json

    rows = []
    for slug in _POLYMARKET_SLUGS:
        try:
            resp = await client.get(
                "https://gamma-api.polymarket.com/events",
                params={"slug": slug},
                timeout=20.0,
            )
            if resp.status_code != 200 or not resp.json():
                log.warning("polymarket_fetch_failed slug=%s status=%s", slug, resp.status_code)
                continue
            event = resp.json()[0]
            for m in event.get("markets", []):
                outcomes = _json.loads(m.get("outcomes") or "[]")
                prices = _json.loads(m.get("outcomePrices") or "[]")
                if "Yes" not in outcomes or len(prices) != len(outcomes):
                    continue
                yes_p = float(prices[outcomes.index("Yes")])
                rows.append({
                    "obs_date": obs_date,
                    "event_slug": slug,
                    "event_title": event.get("title"),
                    "question": m.get("question"),
                    "yes_probability": round(yes_p, 4),
                    "volume_usd": int(float(m.get("volumeNum") or 0)),
                    "closed": bool(m.get("closed")),
                })
        except Exception as exc:
            log.warning("polymarket_error slug=%s error=%r", slug, exc)
    if rows:
        try:
            db.table("prediction_market_snapshots").upsert(
                rows, on_conflict="obs_date,event_slug,question"
            ).execute()
        except Exception as exc:
            log.warning("polymarket_upsert_failed error=%r", exc)
            return 0
        _evaluate_alerts(db, rows)
    return len(rows)


def _evaluate_alerts(db, snapshot_rows: list) -> None:
    """Stamp user alerts whose threshold the latest snapshot crossed.
    Runs with the service key (bypasses RLS) across all users; one-shot.

    ONE-SHOT is enforced by the `triggered_at IS NULL` filter: once an alert
    fires it is stamped and never selected again, so a probability hovering at
    its threshold cannot re-fire daily. Re-arming means clearing triggered_at.

    RLS BYPASS IS INTENTIONAL HERE — unlike the read paths, which push per-user
    queries to the client precisely to avoid this. A scheduled job has no user
    context to act under, and it only ever stamps an alert row the user created,
    matched on the exact (event_slug, question) pair they chose. It never
    exposes one user's data to another.

    The whole body is wrapped: alert evaluation is a convenience feature and
    must not cost the snapshot that was already written.
    """
    from datetime import datetime, timezone as _tz

    try:
        alerts = (
            db.table("prediction_market_alerts")
            .select("id,event_slug,question,direction,threshold")
            .eq("active", True)
            .is_("triggered_at", "null")
            .execute()
        ).data or []
        if not alerts:
            return
        latest = {
            (r["event_slug"], r["question"]): r["yes_probability"]
            for r in snapshot_rows
            if r.get("yes_probability") is not None
        }
        fired = 0
        for a in alerts:
            p = latest.get((a["event_slug"], a["question"]))
            if p is None:
                continue
            crossed = (
                p >= float(a["threshold"])
                if a["direction"] == "above"
                else p <= float(a["threshold"])
            )
            if crossed:
                db.table("prediction_market_alerts").update({
                    "triggered_at": datetime.now(_tz.utc).isoformat(),
                    "triggered_probability": p,
                }).eq("id", a["id"]).execute()
                fired += 1
        if fired:
            log.info("crisis_pull: prediction alerts fired=%d", fired)
    except Exception as exc:
        log.warning("alert_evaluation_failed error=%r", exc)


async def run_crisis_pull() -> dict:
    """Score the crisis checklist for today and write one market-level row."""
    now_et = datetime.now(timezone.utc).astimezone(_ET)
    # Weekend check only — NOT market_session_guard(), which would reject this
    # job outright since it runs after the close. ET is used so obs_date matches
    # the trading session rather than the UTC date, which has already rolled
    # over in the evening.
    if now_et.weekday() >= 5:
        log.info("crisis_pull: skipped (weekend)")
        return {"status": "skipped", "reason": "weekend"}

    db = get_supabase()
    obs_date = now_et.date().isoformat()

    async with httpx.AsyncClient(timeout=60.0) as client:
        equity_symbols = (
            ["SPY", "RSP", "IWM", "HYG", "LQD", "IEF", "TLT", "FXI"]
            + _BDC_BASKET + _MGR_BASKET + _SPEC_BASKET
        )
        fred_tasks = [
            _fetch_fred_series(client, "BAMLH0A0HYM2"),        # HY OAS, percent
            _fetch_fred_series(client, "BAMLC0A0CM"),          # IG OAS, percent
            _fetch_fred_series(client, "T10Y2Y"),              # curve, percent
            _fetch_fred_series(client, "DFF", limit=160),      # fed funds, daily
            _fetch_fred_series(client, "CPIAUCSL", limit=15),  # CPI index, monthly
            _fetch_fred_series(client, "CPILFESL", limit=15),  # core CPI, monthly
            _fetch_fred_series(client, "DRCCLACBS", limit=8),  # cc delinquency, quarterly
            _fetch_fred_series(client, "DRALACBS", limit=8),   # all-loan delinquency, quarterly
            _fetch_fred_series(client, "DPSACBW027SBOG", limit=60),  # deposits, weekly H.8
            _fetch_fred_series(client, "TOTBKCR", limit=60),   # bank credit, weekly H.8
            _fetch_fred_series(client, "DTWEXBGS", limit=130), # broad dollar, daily
            _fetch_fred_series(client, "DEXJPUS", limit=130),  # yen per USD, daily
        ]
        equity_tasks = [
            fetch_schwab_closes(client, sym, days=_LOOKBACK_DAYS) for sym in equity_symbols
        ]
        # All FRED and equity fetches issued together — around 30 concurrent
        # requests across two independent upstreams, with no semaphore. Safe
        # because it runs once daily and the two APIs are separate.
        results = await asyncio.gather(*fred_tasks, *equity_tasks)
        pm_rows = await _snapshot_polymarket(client, db, obs_date)

    (hy_oas, ig_oas, t10y2y, dff, cpi, cpi_core,
     cc_delinq, loan_delinq, deposits, bank_credit, dollar, jpyusd) = results[: len(fred_tasks)]
    closes = {
        sym: results[len(fred_tasks) + i][0] for i, sym in enumerate(equity_symbols)
    }

    # HARD ABORT ON SPY. Every structural verdict is anchored to the index —
    # off-ATH, days-since-ATH, the breadth ratios, and the gate on the
    # speculative-tier signal all need it. A row written without SPY would carry
    # "unknown" through most of the checklist while looking like a real
    # observation.
    spy = closes.get("SPY") or []
    if len(spy) < 30:
        log.warning("crisis_pull: SPY history unavailable; aborting")
        return {"status": "no_spy_data"}

    # --- index posture (52-week high proxy for ATH) -------------------------
    spy_off_ath = _off_high_pct(spy)
    spy_days_since_ath = _days_since_high(spy)

    # --- rates / inflation ---------------------------------------------------
    fed_funds = dff[-1] if dff else None
    # DFF is a 7-day daily series: ~90 obs ≈ one quarter
    # x100 converts FRED's percent to BASIS POINTS, the unit the threshold uses.
    # DFF is published every calendar day (weekends carry forward), so 91
    # observations really is ~3 months here — unlike the trading-day series
    # elsewhere in this file.
    fed_90d_chg = (dff[-1] - dff[-91]) * 100 if len(dff) >= 91 else None
    curve_bps = t10y2y[-1] * 100 if t10y2y else None
    # CPI is MONTHLY, so [-13] is 12 months back — a true year-over-year rate.
    cpi_yoy = (cpi[-1] / cpi[-13] - 1) * 100 if len(cpi) >= 13 else None
    core_yoy = (cpi_core[-1] / cpi_core[-13] - 1) * 100 if len(cpi_core) >= 13 else None

    # --- public credit -------------------------------------------------------
    hy_bps = hy_oas[-1] * 100 if hy_oas else None
    ig_bps = ig_oas[-1] * 100 if ig_oas else None
    # The CHANGE matters more than the level here — see the v_public verdict.
    # Credit spreads grind tighter for years and then turn; the turn is the
    # signal, and by the time the level is alarming the move is over.
    hy_20d_chg = (hy_oas[-1] - hy_oas[-21]) * 100 if len(hy_oas) >= 21 else None

    # --- breadth: does the average stock confirm the index? ------------------
    rsp, iwm = closes.get("RSP") or [], closes.get("IWM") or []
    n_rs = min(len(rsp), len(spy))
    rsp_spy = [rsp[-n_rs:][i] / spy[-n_rs:][i] for i in range(n_rs)] if n_rs else []
    n_iw = min(len(iwm), len(spy))
    iwm_spy = [iwm[-n_iw:][i] / spy[-n_iw:][i] for i in range(n_iw)] if n_iw else []
    # BREADTH LAG: how much staler the equal-weight high is than the
    # cap-weighted one. A large positive lag means SPY keeps making highs while
    # the average stock stopped participating weeks ago — the classic narrowing
    # rally that precedes a top.
    rsp_days_since_high = _days_since_high(rsp)
    breadth_lag = (
        rsp_days_since_high - spy_days_since_ath
        if rsp_days_since_high is not None and spy_days_since_ath is not None
        else None
    )

    # --- household, banks (H.8 weekly), global edge --------------------------
    # Carry-unwind tell: DEXJPUS is yen-per-dollar, so a sharply NEGATIVE 20d
    # change means the yen is strengthening fast (Aug-2024 signature).
    # H.8 is WEEKLY, so [-53] is 52 weeks back — year-over-year, matching the
    # monthly CPI treatment above but on a different observation spacing.
    deposits_yoy = (
        (deposits[-1] / deposits[-53] - 1) * 100 if len(deposits) >= 53 else None
    )
    bank_credit_yoy = (
        (bank_credit[-1] / bank_credit[-53] - 1) * 100 if len(bank_credit) >= 53 else None
    )
    fxi = closes.get("FXI") or []

    # --- traded bond market: credit-ETF ratios + duration trend --------------
    # Same-day confirmation of the (1-day-lagged) FRED OAS signal: the ratios
    # turning down is the traded market smelling credit stress before the
    # published spread moves. TLT trend = health of the deflationary-bust hedge.
    # Both ratios divide a CREDIT ETF by a duration-matched TREASURY ETF, which
    # strips out the interest-rate move and isolates the credit-risk component.
    # HYG/IEF is high-yield, LQD/IEF investment-grade. This is the same credit
    # proxy the MU backtests in backtests/ found front-ran the 2025 and 2026
    # equity breaks.
    def _ratio_series(a: str, b: str) -> list[float]:
        sa, sb = closes.get(a) or [], closes.get(b) or []
        n = min(len(sa), len(sb))
        return [sa[-n:][i] / sb[-n:][i] for i in range(n) if sb[-n:][i] > 0]

    hyg_ief = _ratio_series("HYG", "IEF")
    lqd_ief = _ratio_series("LQD", "IEF")
    tlt = closes.get("TLT") or []

    # --- private credit & spec composites ------------------------------------
    bdc = _composite([closes.get(s) or [] for s in _BDC_BASKET])
    mgr = _composite([closes.get(s) or [] for s in _MGR_BASKET])
    spec = _composite([closes.get(s) or [] for s in _SPEC_BASKET])

    bdc_off_high, bdc_20d = _off_high_pct(bdc), _chg_pct(bdc, 20)
    mgr_off_high, mgr_20d = _off_high_pct(mgr), _chg_pct(mgr, 20)
    spec_off_high = _off_high_pct(spec)

    # --- carry forward monthly manual fields (CAPE, margin debt) -------------
    # CAPE and margin debt have NO free daily API (Shiller publishes monthly,
    # FINRA monthly with a lag), so today's row inherits them from the most
    # recent row that had them. A manual monthly upsert sets a fresh value and
    # the carry-forward propagates it from there.
    #
    # CONSEQUENCE: these two fields can be weeks stale while every other field is
    # same-day, and nothing in the row says how old they are. v_valuation and
    # v_leverage are therefore slow-moving structural reads by construction —
    # which is fine, since valuation and leverage genuinely move that slowly.
    cape: Optional[float] = None
    margin_bn: Optional[float] = None
    margin_yoy: Optional[float] = None
    try:
        prev = (
            db.table("crisis_checklist_snapshots")
            .select("cape,margin_debt_bn,margin_debt_yoy_pct")
            .order("obs_date", desc=True)
            .limit(1)
            .execute()
        )
        if prev.data:
            cape = prev.data[0].get("cape")
            margin_bn = prev.data[0].get("margin_debt_bn")
            margin_yoy = prev.data[0].get("margin_debt_yoy_pct")
    except Exception as exc:
        log.warning("crisis_pull: carry-forward read failed: %s", exc)

    # --- verdicts -------------------------------------------------------------
    # Thresholds calibrated on the 13-crisis ledger; 'firing' = the historical
    # pre-crisis condition is present.
    def verdict(value: Optional[float], firing, partial) -> str:
        """Three-state scoring with an explicit unknown.

        Order matters: `firing` is tested first, so the two predicates may
        overlap and the partial threshold can simply be the looser cut.
        `unknown` is returned for a missing input and counts toward neither
        total — a signal that could not be evaluated is not one that passed.
        """
        if value is None:
            return "unknown"
        if firing(value):
            return "firing"
        if partial(value):
            return "partial"
        return "clean"

    # STRUCTURAL 1 — index at highs. Crises start FROM highs, not from an
    # already-depressed market, so being within 2% of the 52-week high is the
    # fragile state.
    v_index = verdict(spy_off_ath, lambda v: v >= -2.0, lambda v: v >= -5.0)
    # STRUCTURAL 2 — valuation. CAPE >= 35 has been reached only around 1929,
    # 2000 and 2021. Note this reads the carried-forward value above.
    v_valuation = verdict(cape, lambda v: v >= 35.0, lambda v: v >= 30.0)
    # STRUCTURAL 3 — leverage. The GROWTH RATE of margin debt, not its level:
    # rapid accumulation is what forces the liquidation cascade when prices turn.
    v_leverage = verdict(margin_yoy, lambda v: v >= 25.0, lambda v: v >= 10.0)
    # STRUCTURAL 4 — the speculative tier cracking.
    # spec crack only means something while the index itself is near highs
    #
    # THE CONJUNCTION IS THE SIGNAL. A speculative basket down 20% in a general
    # selloff is just beta and says nothing. Down 20% WHILE the index is within
    # 5% of its high is a divergence — risk appetite withdrawing from the tail
    # first, which is the pattern the ledger found ahead of past breaks.
    spy_near_high = spy_off_ath is not None and spy_off_ath >= -5.0
    v_spec = (
        "unknown" if spec_off_high is None
        else "firing" if spec_off_high <= -20.0 and spy_near_high
        else "partial" if spec_off_high <= -10.0 and spy_near_high
        else "clean"
    )
    # CATALYST 1 — Fed tightening. 50bp of hikes in a quarter is a genuine
    # tightening impulse; ANY increase counts as partial.
    v_fed = verdict(fed_90d_chg, lambda v: v >= 50.0, lambda v: v > 0.0)
    # CATALYST 2 — curve inversion. 2s10s at or below zero. The most reliable
    # single recession signal on record, though with a long and variable lead.
    v_curve = verdict(curve_bps, lambda v: v <= 0.0, lambda v: v <= 25.0)
    # public credit: the ledger's signal is the TURN off the tights, not the level
    v_public = (
        "unknown" if hy_bps is None
        else "firing" if hy_bps >= 400.0 or (hy_20d_chg or 0) >= 50.0
        else "partial" if (hy_20d_chg or 0) >= 25.0
        else "clean"
    )
    # CATALYST 4 — private credit. The WORST of holders and originators drives
    # the verdict (min, since these are negative drawdowns), so stress in either
    # leg counts. Firing additionally requires 20-day momentum to be NEGATIVE:
    # off the high AND still falling, which distinguishes an active break from a
    # drawdown that has already stabilized.
    worst_pc_off = min(x for x in [bdc_off_high, mgr_off_high] if x is not None) if (bdc_off_high is not None or mgr_off_high is not None) else None
    v_private = (
        "unknown" if worst_pc_off is None
        else "firing" if worst_pc_off <= -15.0 and min(bdc_20d or 0, mgr_20d or 0) < 0
        else "partial" if worst_pc_off <= -15.0
        else "clean"
    )
    # breadth fails when RSP's own high is much staler than SPY's
    v_breadth = (
        "unknown" if breadth_lag is None
        else "firing" if breadth_lag >= 60
        else "partial" if breadth_lag >= 20
        else "clean"
    )

    # Counted and stored SEPARATELY — never summed. See the header: structural
    # signals can sit lit for years and are not timing, while catalysts firing
    # into a lit structure is the historical pre-crisis pattern. Only "firing"
    # counts; "partial" and "unknown" do not.
    structural = [v_index, v_valuation, v_leverage, v_spec]
    catalysts = [v_fed, v_curve, v_public, v_private, v_breadth]

    row = {
        "obs_date": obs_date,
        "spy_close": round(spy[-1], 2),
        "spy_off_ath_pct": round(spy_off_ath, 2) if spy_off_ath is not None else None,
        "spy_days_since_ath": spy_days_since_ath,
        "cape": cape,
        "margin_debt_bn": margin_bn,
        "margin_debt_yoy_pct": margin_yoy,
        "fed_funds_pct": round(fed_funds, 2) if fed_funds is not None else None,
        "fed_funds_90d_chg_bps": round(fed_90d_chg, 1) if fed_90d_chg is not None else None,
        "t10y2y_bps": round(curve_bps, 1) if curve_bps is not None else None,
        "cpi_yoy_pct": round(cpi_yoy, 2) if cpi_yoy is not None else None,
        "cpi_core_yoy_pct": round(core_yoy, 2) if core_yoy is not None else None,
        "hy_oas_bps": round(hy_bps, 1) if hy_bps is not None else None,
        "ig_oas_bps": round(ig_bps, 1) if ig_bps is not None else None,
        "hy_oas_20d_chg_bps": round(hy_20d_chg, 1) if hy_20d_chg is not None else None,
        "cc_delinq_pct": round(cc_delinq[-1], 2) if cc_delinq else None,
        "loan_delinq_pct": round(loan_delinq[-1], 2) if loan_delinq else None,
        "bank_deposits_yoy_pct": round(deposits_yoy, 2) if deposits_yoy is not None else None,
        "bank_credit_yoy_pct": round(bank_credit_yoy, 2) if bank_credit_yoy is not None else None,
        "dollar_idx": round(dollar[-1], 2) if dollar else None,
        "dollar_20d_pct": round(_chg_pct(dollar, 20), 2) if len(dollar) > 20 else None,
        "jpyusd_20d_pct": round(_chg_pct(jpyusd, 20), 2) if len(jpyusd) > 20 else None,
        "fxi_20d_pct": round(_chg_pct(fxi, 20), 2) if len(fxi) > 20 else None,
        "hyg_ief_ratio": round(hyg_ief[-1], 6) if hyg_ief else None,
        "hyg_ief_off_high_pct": round(_off_high_pct(hyg_ief), 2) if hyg_ief else None,
        "hyg_ief_20d_pct": round(_chg_pct(hyg_ief, 20), 2) if len(hyg_ief) > 20 else None,
        "lqd_ief_20d_pct": round(_chg_pct(lqd_ief, 20), 2) if len(lqd_ief) > 20 else None,
        "tlt_20d_pct": round(_chg_pct(tlt, 20), 2) if len(tlt) > 20 else None,
        "rsp_spy_ratio": round(rsp_spy[-1], 6) if rsp_spy else None,
        "rsp_spy_off_high_pct": round(_off_high_pct(rsp_spy), 2) if rsp_spy else None,
        "iwm_spy_ratio": round(iwm_spy[-1], 6) if iwm_spy else None,
        "iwm_spy_off_high_pct": round(_off_high_pct(iwm_spy), 2) if iwm_spy else None,
        "bdc_off_high_pct": round(bdc_off_high, 2) if bdc_off_high is not None else None,
        "bdc_20d_pct": round(bdc_20d, 2) if bdc_20d is not None else None,
        "mgr_off_high_pct": round(mgr_off_high, 2) if mgr_off_high is not None else None,
        "mgr_20d_pct": round(mgr_20d, 2) if mgr_20d is not None else None,
        "spec_off_high_pct": round(spec_off_high, 2) if spec_off_high is not None else None,
        "v_index_ath": v_index,
        "v_valuation": v_valuation,
        "v_leverage": v_leverage,
        "v_spec_tier": v_spec,
        "v_fed": v_fed,
        "v_curve": v_curve,
        "v_public_credit": v_public,
        "v_private_credit": v_private,
        "v_breadth": v_breadth,
        "structural_lit": sum(1 for v in structural if v == "firing"),
        "catalysts_firing": sum(1 for v in catalysts if v == "firing"),
        # JSONB provenance block: the basket membership and lookback that
        # produced this row. Essential because the baskets are expected to
        # change as cycles rotate — without it, a historical row could not be
        # interpreted after _SPEC_BASKET is edited.
        "signals": {
            "bdc_basket": _BDC_BASKET,
            "mgr_basket": _MGR_BASKET,
            "spec_basket": _SPEC_BASKET,
            "breadth_lag_sessions": breadth_lag,
            "lookback_days": _LOOKBACK_DAYS,
            "note": "ATH tracked as 52-week high; CAPE/margin carried forward from last manual upsert",
        },
        # True on the 16:00 ET close-capture cycle. The cron only fires this job
        # once daily at 21:10 UTC, so in normal operation this is always true —
        # it exists to mark a manual mid-session run as non-final.
        "is_final": is_eod_capture_run(),
    }

    db.table("crisis_checklist_snapshots").upsert(row, on_conflict="obs_date").execute()

    log.info(
        "crisis_pull: %s structural=%s catalysts=%s hy=%s curve=%s bdc_off=%s mgr_off=%s spec_off=%s",
        obs_date, row["structural_lit"], row["catalysts_firing"],
        row["hy_oas_bps"], row["t10y2y_bps"],
        row["bdc_off_high_pct"], row["mgr_off_high_pct"], row["spec_off_high_pct"],
    )
    return {"status": "ok", "obs_date": obs_date,
            "structural_lit": row["structural_lit"],
            "catalysts_firing": row["catalysts_firing"],
            "prediction_markets": pm_rows}
