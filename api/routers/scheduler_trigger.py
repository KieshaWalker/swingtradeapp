# =============================================================================
# routers/scheduler_trigger.py
# =============================================================================
# HTTP endpoints called by Cloud Scheduler.
# These are also the entry points for the Cloud Functions deployment.
# =============================================================================
#
# THE PIPELINE, AND WHY THE MINUTES MATTER
# ----------------------------------------
# Every endpoint here is one node of a daily data pipeline. All cron times are
# UTC. The intraday jobs run hourly during the US session (13-21 UTC, Mon-Fri)
# and their staggered minute offsets are NOT cosmetic — they encode a DAG:
#
#   :00  vol-surface-pull   chain            -> vol_surface_snapshots
#   :03  sabr-pull          vol_surface      -> sabr_calibrations
#   :06  heston-pull b1     vol_surface      -> heston_calibrations   (A-M)
#   :09  iv-pull            chain + sabr     -> iv_snapshots
#   :12  greek-grid-pull    chain            -> greek_grid + greek_snapshots
#   :18  regime-pull        iv_snapshots +…  -> regime_snapshots
#   :20  heston-pull b2     vol_surface      -> heston_calibrations   (N-Z)
#
# Each job reads what the earlier ones wrote, so the gaps are a completion
# budget for the upstream step. Shortening one, or reordering the crons, means
# a downstream job reads yesterday's row and silently produces stale analytics
# rather than failing. The stagger also spreads the Schwab API load, which is
# rate-limited, and keeps concurrent Cloud Run instances down.
#
# Heston is split into two alphabetical batches because a full-universe
# calibration exceeds the request timeout — it is by far the heaviest job here.
#
# END-OF-DAY jobs run once, after the close, and are similarly ordered:
#   21:00 expected-move-pull      closing IV bands
#   21:05 position-eod-snapshot   open position legs
#   21:07 watched-contract-pull   not-yet-entered contracts
#   21:10 crisis-pull             market-level crisis checklist
#   21:15 focus-digest-pull       digest — depends on ALL of the above
#   21:30 equity-bars-pull        daily OHLCV -> equity_bars
#   21:40 swing-setups-pull       channel + SMA + volume + options -> swing_setups
#   22:00 vol-period-weekly (Fri) / vol-period-monthly (1st)
#
# equity-bars-pull sits at the END of the EOD chain on purpose. It depends on
# nothing here — it reads Schwab directly, not the tables the other jobs wrote —
# so it is placed last to keep it off the critical path of the digest, which
# does have real upstream dependencies.
#
# swing-setups-pull is the SECOND fan-in job, after focus-digest-pull, and its
# 21:40 slot IS a data dependency: it reads equity_bars (21:30) and the
# expected_move_snapshots written at 21:00. Moving it earlier makes it fit
# channels to yesterday's bars while stamping them with today's date.
#
# OPERATIONAL NOTES
# -----------------
# * /schwab-pull is the legacy monolith. Its Cloud Scheduler job is PAUSED and
#   is not expected to run — do not add logic there assuming it fires.
# * /greek-snapshots-pull is a deprecated no-op; greek-grid-pull writes both
#   tables from a single chain fetch.
# * heston-pull's scheduler entries surface intermittent 502s. Those are
#   COSMETIC: the job completes and the rows land — the response just outlives
#   the scheduler's patience. Accepted as-is; do not "fix" by shortening the
#   job or retrying, which would double the calibration load.
#
# LAZY IMPORTS: every handler imports its job module INSIDE the function body
# rather than at module scope. This is deliberate. Cloud Run cold-starts pay
# for every import at startup, and these jobs pull in scipy, numpy and
# scikit-learn between them — importing all of it up front would add seconds to
# the cold start of EVERY request, including /health. Deferring means a given
# instance only pays for the jobs it actually runs. Keep new handlers to the
# same pattern.
#
# RETURN VALUES: each handler returns the job's own result dict verbatim and
# logs it. Jobs are expected to report partial failure INSIDE that dict rather
# than raising, so a 200 does not by itself mean every ticker succeeded — read
# the body.
# =============================================================================

import logging

from fastapi import APIRouter, Request, HTTPException, Query

from core.config import settings

router = APIRouter()
log = logging.getLogger(__name__)


def _verify_scheduler(request: Request) -> None:
    """Verify request came from Cloud Scheduler (or local dev).

    When python_api_secret is configured, it is always required regardless of
    source IP or Cloud Scheduler headers (both are trivially forgeable).
    Without a secret (local dev), localhost IP or the Cloud Scheduler header suffices.

    The precedence is the security-relevant part. If a secret is configured it
    is the ONLY thing checked, and the header/IP path is never reached — so a
    correctly-configured production deployment cannot be reached by forging
    X-CloudScheduler-JobName, which any client can set. The permissive branch
    exists solely so local development works without a secret in .env, and it
    is unreachable once PYTHON_API_SECRET is set.

    403 rather than 401 throughout: there is no authentication scheme to
    challenge for, so the request is refused rather than prompted.

    Note the comparison is a plain !=, not a constant-time compare. The
    theoretical timing side-channel is not a practical concern for a
    high-entropy shared secret over the public internet, where network jitter
    dwarfs the signal.
    """
    secret = request.headers.get("X-Job-Secret", "")
    if settings.python_api_secret:
        if secret != settings.python_api_secret:
            raise HTTPException(status_code=403, detail="Unauthorized scheduler call")
        return
    # No secret configured — allow localhost or Cloud Scheduler header (dev mode only)
    is_scheduler = request.headers.get("X-CloudScheduler-JobName") is not None
    is_local = request.client and request.client.host in ("127.0.0.1", "::1")
    if not (is_scheduler or is_local):
        raise HTTPException(status_code=403, detail="Unauthorized scheduler call")


@router.post("/schwab-pull")
async def schwab_pull_trigger(request: Request):
    """Legacy monolithic pull — kept for manual testing.
    Prefer the individual job endpoints below for production.

    Its Cloud Scheduler job is DISABLED. This route still works when called by
    hand, but nothing invokes it on a schedule — do not add pipeline logic here
    expecting it to run.
    """
    _verify_scheduler(request)
    from jobs.schwab_pull import run_schwab_pull
    result = await run_schwab_pull()
    log.info("schwab_pull_complete result=%s", result)
    return result


# ── Individual pipeline job endpoints (staggered hourly, Mon–Fri) ─────────────

@router.post("/vol-surface-pull")
async def vol_surface_pull_trigger(request: Request):
    """Job 1 — Fetch chain → vol_surface_snapshots.
    Cron: 0 13-21 * * 1-5  (in-code ET market-session guard trims the edges)

    HEAD OF THE INTRADAY DAG: sabr-pull and heston-pull both read what this
    writes. The cron window is deliberately wider than the trading session and
    an in-code ET guard trims the edges, so the schedule does not have to be
    re-cut twice a year when US daylight saving shifts the session against UTC.
    """
    _verify_scheduler(request)
    from jobs.vol_surface_pull import run_vol_surface_pull
    result = await run_vol_surface_pull()
    log.info("vol_surface_pull_complete result=%s", result)
    return result


@router.post("/sabr-pull")
async def sabr_pull_trigger(request: Request):
    """Job 2 — vol_surface_snapshots → sabr_calibrations.
    Cron: 3 13-21 * * 1-5

    Reads job 1's output — the 3-minute gap is its completion budget. Fits
    (α, ρ, ν) per DTE slice; iv-pull at :09 consumes these calibrations.
    """
    _verify_scheduler(request)
    from jobs.sabr_pull import run_sabr_pull
    result = await run_sabr_pull()
    log.info("sabr_pull_complete result=%s", result)
    return result


@router.post("/heston-pull")
async def heston_pull_trigger(request: Request, batch: int = Query(1)):
    """Job 3 — vol_surface_snapshots → heston_calibrations.
    batch=1 (A–M) cron: 6 13-21 * * 1-5
    batch=2 (N–Z) cron: 20 13-21 * * 1-5

    Split alphabetically because a whole-universe Heston calibration does not
    fit inside one request timeout — five parameters fitted globally over the
    full surface is the most expensive computation in the system.

    The `batch` query parameter has NO validation and defaults to 1, so an
    unrecognized value is the job's problem, not this router's.

    Scheduler 502s on this endpoint are expected and cosmetic — the job
    finishes and the rows land, the HTTP response just outlives the scheduler's
    timeout. Verify by checking heston_calibrations for the run's obs_date
    rather than by trusting the scheduler's status.
    """
    _verify_scheduler(request)
    from jobs.heston_pull import run_heston_pull
    result = await run_heston_pull(batch=batch)
    log.info("heston_pull_complete batch=%d result=%s", batch, result)
    return result


@router.post("/iv-pull")
async def iv_pull_trigger(request: Request):
    """Job 4 — Fetch chain + sabr history → iv_snapshots.
    Cron: 9 13-21 * * 1-5

    The analytics workhorse: GEX/VEX/CEX, zero-gamma, IVR/IVP, skew, RND. Takes
    its own fresh chain fetch (it needs full open-interest detail, not just the
    surface points job 1 stored) plus sabr_calibrations from :03.

    Writes the same iv_snapshots rows that /iv/snapshot writes on demand, so
    the two paths must stay schema-compatible.
    """
    _verify_scheduler(request)
    from jobs.iv_pull import run_iv_pull
    result = await run_iv_pull()
    log.info("iv_pull_complete result=%s", result)
    return result


@router.post("/greek-grid-pull")
async def greek_grid_pull_trigger(request: Request):
    """Job 5 — Fetch chain → greek_grid_snapshots + greek_snapshots (one shared fetch).
    Cron: 12 13-21 * * 1-5

    Populates BOTH tables from a single chain fetch, which is why job 6 below
    is now a no-op — halving the Schwab calls for the same output.
    """
    _verify_scheduler(request)
    from jobs.greek_grid_pull import run_greek_grid_pull
    result = await run_greek_grid_pull()
    log.info("greek_grid_pull_complete result=%s", result)
    return result


@router.post("/greek-snapshots-pull")
async def greek_snapshots_pull_trigger(request: Request):
    """Job 6 — DEPRECATED no-op: greek_snapshots are written by greek-grid-pull.
    Delete the greek-snapshots-pull Cloud Scheduler job.

    Retained only so a scheduler entry that still exists gets a clean 200
    instead of a 404 alert. Safe to remove once the scheduler job is gone.
    """
    _verify_scheduler(request)
    from jobs.greek_snapshots_pull import run_greek_snapshots_pull
    result = await run_greek_snapshots_pull()
    log.info("greek_snapshots_pull_complete result=%s", result)
    return result


@router.post("/sofr-pull")
async def sofr_pull_trigger(request: Request):
    """Job 0 — Fetch live SOFR rate from FRED → update in-process cache.
    Cron: 30 13 * * 1-5  (8:30 AM ET Mon–Fri, after NY Fed publishes)

    Job ZERO: runs before everything else because every pricing path needs a
    discount rate. Timed just after the NY Fed publishes.

    IMPORTANT — this updates an IN-PROCESS module-level cache, not a table. On
    Cloud Run each instance has its own cache, and only the instance that
    happened to serve this request gets the fresh rates; other instances keep
    theirs until they are recycled. A cold instance starts from DEFAULT_R until
    the next successful refresh. The blast radius is small (rates move slowly,
    and r barely moves an option price relative to vol), which is why the
    simple design stands.
    """
    _verify_scheduler(request)
    from jobs.sofr_pull import run_sofr_pull
    result = await run_sofr_pull()
    log.info("sofr_pull_complete result=%s", result)
    return result


@router.post("/regime-pull")
async def regime_pull_trigger(request: Request):
    """Job 7 — iv_snapshots + price history + VIX → regime_snapshots.
    Cron: 18 13-21 * * 1-5

    LAST of the intraday chain, at :18, because it consumes iv_snapshots from
    :09 — it needs the gamma/vanna regime reads that job 4 produces.
    """
    _verify_scheduler(request)
    from jobs.regime_pull import run_regime_pull
    result = await run_regime_pull()
    log.info("regime_pull_complete result=%s", result)
    return result


@router.post("/fundamentals-pull")
async def fundamentals_pull_trigger(request: Request):
    """Job — EDGAR XBRL revenue/capex for AI-cycle universes → sector_fundamentals.
    Cron: 0 12 * * 0  (weekly, Sunday 12:00 UTC)

    Weekly, not daily: SEC filings arrive quarterly, so anything more frequent
    is wasted requests against EDGAR's rate limits. Sunday keeps it clear of
    the weekday pipeline entirely.
    """
    _verify_scheduler(request)
    from jobs.fundamentals_pull import run_fundamentals_pull
    result = await run_fundamentals_pull()
    log.info("fundamentals_pull_complete result=%s", result)
    return result


@router.post("/crisis-pull")
async def crisis_pull_trigger(request: Request):
    """Job — market-level crisis-signal checklist → crisis_checklist_snapshots.
    Cron: 10 21 * * 1-5  (16:10 ET close-capture, Mon-Fri)

    Runs ONCE per day after the close. Global (not per-ticker/user): FRED
    credit/curve/CPI series + Schwab closes for breadth, private-credit, and
    speculative-tier baskets, scored against the 13-crisis ledger thresholds.

    Scoring against a ledger of 13 historical crises is what makes this a
    checklist rather than another score: each signal is calibrated to how it
    behaved before actual past breaks, not fitted to recent returns.
    """
    _verify_scheduler(request)
    from jobs.crisis_pull import run_crisis_pull
    result = await run_crisis_pull()
    log.info("crisis_pull_complete result=%s", result)
    return result


@router.post("/expected-move-pull")
async def expected_move_pull_trigger(request: Request):
    """Job 9 — EOD chain → expected_move_snapshots (daily/weekly/monthly bands).
    Cron: 0 21 * * 1-5   (weekdays 9 PM UTC, after US market close)

    Runs ONCE per day at close — not part of the intraday hourly pipeline.
    Captures closing IV for all three period bands in a single chain fetch.

    Also the job that computes and stores REALIZED vol. RV must be produced
    here in the Python backend, never recomputed in Flutter — the app reads it
    from the DB so there is exactly one implementation. The term_comparison
    block in routers/fair_value.py reads what this writes.
    """
    _verify_scheduler(request)
    from jobs.expected_move_pull import run_expected_move_pull
    result = await run_expected_move_pull()
    log.info("expected_move_pull_complete result=%s", result)
    return result


@router.post("/equity-bars-pull")
async def equity_bars_pull_trigger(request: Request):
    """Daily OHLCV bars → equity_bars, for the swing-setup engine.
    Cron: 30 21 * * 1-5   (weekdays 21:30 UTC, after the EOD chain)

    The FOUNDATION for channel fitting, the 50/200-day SMAs and volume surge —
    all of which read equity_bars and none of which can run before it has
    populated. Before this job the system stored no equity OHLC at all.

    Independent of every other EOD job: it reads Schwab directly rather than
    the tables they write, so its 21:30 slot is for staying off the digest's
    critical path, not a data dependency.

    Refetches a full year per ticker every night. That is deliberate — it makes
    a missed night self-healing, and a gap inside an SMA window would otherwise
    be invisible in the output rather than an error.
    """
    _verify_scheduler(request)
    from jobs.equity_bars_pull import run
    result = await run()
    log.info("equity_bars_pull_complete result=%s", result)
    return result


@router.post("/swing-setups-pull")
async def swing_setups_pull_trigger(request: Request):
    """Channel + SMA + volume + options confirmation → swing_setups.
    Cron: 40 21 * * 1-5   (weekdays 21:40 UTC, after equity-bars-pull)

    A FAN-IN job: fetches nothing, reads equity_bars plus the
    expected_move_snapshots / iv_snapshots the EOD chain already wrote. Its slot
    is a hard dependency — see the pipeline map at the top of this file.

    Emits no buy/sell signal. structure_quality ranks how legible a chart is,
    never which way to trade it: channel position on its own was measured to
    carry no reliable directional edge on this universe.
    """
    _verify_scheduler(request)
    from jobs.swing_setups_pull import run
    result = await run()
    log.info("swing_setups_pull_complete result=%s", result)
    return result


@router.post("/vol-period-weekly")
async def vol_period_weekly_trigger(request: Request):
    """Job 8a — EOD IV + price history → vol_period_snapshots (weekly).
    Cron: 0 22 * * 5   (Friday 10 PM UTC — 1 hour after expected_move_pull)

    Friday-only: it closes out the week's IV-vs-realized comparison, so it must
    run after the final session's expected-move row exists. The full hour of
    slack is generous because a missed weekly row cannot be recovered by the
    next run — the window has passed.
    """
    _verify_scheduler(request)
    from jobs.vol_period_pull import run_weekly_vol_period_pull
    result = await run_weekly_vol_period_pull()
    log.info("vol_period_weekly_complete result=%s", result)
    return result


@router.post("/vol-period-monthly")
async def vol_period_monthly_trigger(request: Request):
    """Job 8b — EOD IV + price history → vol_period_snapshots (monthly).
    Cron: 0 22 1 * *   (1st of each month 10 PM UTC — 1 hour after expected_move_pull)

    Note the 1st can fall on a weekend or holiday, when no session preceded it.
    The job handles an empty run rather than the cron guarding against it.
    """
    _verify_scheduler(request)
    from jobs.vol_period_pull import run_monthly_vol_period_pull
    result = await run_monthly_vol_period_pull()
    log.info("vol_period_monthly_complete result=%s", result)
    return result


@router.post("/position-eod-snapshot")
async def position_eod_snapshot_trigger(request: Request):
    """Job 10 — Capture EOD Greeks + fair-value theos for all open position legs.
    Cron: 5 21 * * 1-5   (21:05 UTC Mon–Fri, ~5 min after US market close)

    Builds the per-leg time series that contract_opportunity scores against.
    Each daily row is one observation of a position's own history, so a missed
    run leaves a permanent gap — percentiles are computed over whatever rows
    exist, and cannot be reconstructed after the fact from anything stored.
    """
    _verify_scheduler(request)
    from jobs.position_eod_snapshot import run_position_eod_snapshot
    result = await run_position_eod_snapshot()
    log.info("position_eod_snapshot_complete result=%s", result)
    return result


@router.post("/watched-contract-pull")
async def watched_contract_pull_trigger(request: Request):
    """Job 11 — Capture EOD Greeks + fair-value theos + OI/volume for every
    watched (not-yet-entered) contract, into watched_contract_snapshots.
    Cron: 7 21 * * 1-5   (21:07 UTC Mon-Fri, 2 min after position-eod-snapshot)

    The pre-entry twin of job 10: same shape of row, for contracts being
    considered rather than held. /watched-contracts/evaluate scores exactly
    these rows, which is why history must accumulate BEFORE a signal can fire —
    a newly-watched contract returns insufficient_history until enough daily
    rows exist.
    """
    _verify_scheduler(request)
    from jobs.watched_contract_pull import run_watched_contract_pull
    result = await run_watched_contract_pull()
    log.info("watched_contract_pull_complete result=%s", result)
    return result


@router.post("/focus-digest-pull")
async def focus_digest_pull_trigger(request: Request):
    """Job 12 — Assemble the daily digest (IV/gamma read + scored open
    positions/watches) for the hand-picked focus ticker list ->
    focus_ticker_digest.
    Cron: 15 21 * * 1-5   (21:15 UTC Mon-Fri, after position-eod-snapshot,
    watched-contract-pull, and crisis-pull have all landed)

    LAST job of the day, and the only one that fans IN — it reads what jobs 10,
    11 and crisis-pull wrote rather than fetching anything new. Its 21:15 slot
    is therefore a hard dependency, not a preference: run it early and the
    digest is assembled from missing or stale rows.
    """
    _verify_scheduler(request)
    from jobs.focus_digest_pull import run_focus_digest_pull
    result = await run_focus_digest_pull()
    log.info("focus_digest_pull_complete result=%s", result)
    return result


@router.post("/backfill-rv")
async def backfill_rv_trigger(request: Request):
    """One-time backfill: 10 years of daily RV for all watched tickers → realized_vol_snapshots.

    MANUAL ONLY — no cron entry, and none should be added. Long-running and
    write-heavy; intended to be invoked by hand when a new ticker joins the
    watchlist or the RV computation changes and history needs rebuilding.
    """
    _verify_scheduler(request)
    from jobs.backfill_rv import run_backfill_rv
    result = await run_backfill_rv()
    log.info("backfill_rv_complete result=%s", result)
    return result


@router.post("/regime-train")
def regime_train_trigger(request: Request):
    """Triggered by Cloud Scheduler weekly (recommended: Sunday 00:00 UTC).
    Retrains the regime ML model on the latest 180 days of Supabase history
    and hot-reloads it into the inference cache.

    Cloud Scheduler job config:
      URL:      https://<your-cloud-run-url>/jobs/regime-train
      Method:   POST
      Schedule: 0 0 * * 0   (weekly, Sunday midnight UTC)
      Headers:  X-CloudScheduler-JobName: regime-train-weekly

    NOTE this handler is `def`, not `async def` — the only one in the file.
    That is correct and deliberate: model training is CPU-bound and fully
    blocking, and FastAPI automatically runs sync handlers in a threadpool.
    Declaring it async would pin the event loop for the whole fit and stall
    every other request on the instance.

    THE MODEL IS NOT ALWAYS REPLACED. train_and_store applies its own
    acceptance gate (≥40 labeled samples and out-of-sample AUC ≥0.52 — barely
    better than the 0.5 of a coin flip, but a floor), and load_trained_model is
    only called when it passes. A rejected run logs a warning and returns 200
    with sufficient_data=False, leaving the previous model serving. Refusing to
    ship a model no better than chance is the point; callers should read
    sufficient_data rather than assume a 200 means retrained.

    HOT RELOAD IS PER-INSTANCE, with the same caveat as /sofr-pull: only the
    Cloud Run instance that served this request reloads its in-memory model.
    Others pick it up when they next cold-start, since main.py's lifespan hook
    loads the latest stored model at startup.
    """
    _verify_scheduler(request)

    # Lazy imports again — scikit-learn is the heaviest dependency in the
    # service and is needed by this one endpoint only.
    from core.supabase_client import get_supabase
    from services.regime_ml_trainer import train_and_store
    from services.regime_ml_service import load_trained_model

    sb     = get_supabase()
    result = train_and_store(sb, model_type="logistic", history_days=180)

    if result.sufficient_data:
        load_trained_model(sb)
        log.info(
            "regime_train_weekly: trained %s on %d samples (%d flips) "
            "AUC-ROC=%.3f — model hot-reloaded",
            result.model_type, result.n_samples, result.n_positive, result.auc_roc,
        )
    else:
        log.warning(
            "regime_train_weekly: model not accepted (%d samples) — "
            "needs ≥40 labeled samples and OOS AUC ≥0.52; skipping model update",
            result.n_samples,
        )

    return {
        "model_type":      result.model_type,
        "trained_at":      result.trained_at,
        "n_samples":       result.n_samples,
        # Count of the positive class (regime flips). The classes are heavily
        # imbalanced — flips are rare — which is why AUC-ROC is the acceptance
        # metric rather than accuracy: a model predicting "no flip" every time
        # scores high accuracy and is worthless.
        "n_positive":      result.n_positive,
        "auc_roc":         result.auc_roc,
        "accuracy":        result.accuracy,
        # THE FIELD THAT MATTERS: False means the previous model is still live.
        "sufficient_data": result.sufficient_data,
    }
