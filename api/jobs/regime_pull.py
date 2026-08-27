from __future__ import annotations
from typing import Optional

# =============================================================================
# jobs/regime_pull.py
# =============================================================================
# Job 7 — Read iv_snapshots + price history → regime classification → upsert regime_snapshots.
# Cron: 18 13-21 * * 1-5  (18 min after vol_surface_pull, Mon–Fri)
#
# Reads today's iv_snapshots (written by iv_pull).
# Fetches price/volume history for SMA and ROC computation.
# Fetches VIX (VIXCLS), VIX3M (VXVCLS), and VVIX (VVIXCLS) from FRED.
# Fetches SPY/RSP from Schwab for breadth proxy.
# Note: Schwab price history does not support index symbols ($VIX.X, $VVIX.X, $VIX3M.X) —
#   all VIX-family series must come via the FRED edge function.
# =============================================================================
#
# LAST OF THE INTRADAY CHAIN, at :18, because it consumes iv_snapshots written
# by iv_pull at :09. It combines three layers into one verdict per ticker:
#
#   PER-TICKER    dealer gamma positioning, IV percentile (from iv_snapshots)
#   PER-TICKER    price/volume trend — SMA10/50, 5-day ROC (from Schwab)
#   MARKET-WIDE   VIX level/RSI/HMM state, VIX term structure, VVIX, breadth
#
# The market-wide layer is fetched ONCE per run and shared by every ticker,
# which is why it is computed up front rather than inside _process.
#
# THE is_final FLAG IS THE MOST IMPORTANT FIELD HERE. Every hourly run
# overwrites the same (ticker, obs_date) row, so the row is a moving intraday
# value until the 4 PM ET close-capture cycle marks it final. ML training and
# supervised inference filter on is_final=true — training on intraday rows would
# label a regime by whatever it happened to be at 10 AM, not by where it closed.
#
# ABORTS WITHOUT VIX. Unlike every other job here, which contains failures
# per-ticker, a missing VIX series stops the whole run. Deliberate: VIX feeds
# the HMM state that is Gate 1 of the decision table, and a snapshot written
# without it would be silently classified on a subset of the rules, then
# permanently stored as if complete.

import asyncio
import logging
from datetime import date

import httpx

from core.config import settings
from core.supabase_client import get_supabase
from jobs.common import get_tickers, fetch_schwab_closes, is_eod_capture_run, market_session_guard
from services.regime_service import classify_regime, compute_wilder_rsi
from services.hmm_regime import classify_vix_regime

log = logging.getLogger(__name__)

_CONCURRENCY = 5


async def _fetch_fred_series(
    client: httpx.AsyncClient,
    series_id: str,
    limit: int = 70,
) -> list[float]:
    """Fetch daily closes for any FRED series, returned oldest→newest.

    Routed through the Supabase edge function rather than FRED directly, so the
    API key stays server-side.

    Necessary because SCHWAB CANNOT SERVE INDEX HISTORY — $VIX.X, $VVIX.X and
    $VIX3M.X all fail against its pricehistory endpoint (see the header). FRED
    is the only source for the whole VIX family here.

    Two transformations on the response: FRED returns most-recent-FIRST, so the
    list is reversed to match the oldest-first convention every consumer
    assumes; and "." placeholders (FRED's marker for a market holiday) are
    dropped rather than parsed, since float(".") would raise.

    Returns [] on any failure — the caller decides whether that is fatal.
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
        # FRED returns most-recent-first; filter "." placeholders; reverse to oldest→newest
        return [float(o["value"]) for o in reversed(obs) if o.get("value") not in (".", None, "")]
    except Exception as exc:
        log.warning("fred_%s_error error=%s", series_id, exc)
        return []


async def run_regime_pull() -> dict:
    skip = market_session_guard()
    if skip:
        log.info("regime_pull: skipped (%s)", skip)
        return {"status": "skipped", "reason": skip}

    db = get_supabase()
    today = date.today().isoformat()
    all_rows = get_tickers(db)
    if not all_rows:
        log.warning("regime_pull: no tickers")
        return {"status": "no_tickers"}

    # regime_snapshots is keyed (ticker, obs_date) — global, not per-user — so
    # classify each ticker exactly once regardless of how many users watch it.
    # Sorted (not just de-duplicated) so run order is reproducible.
    tickers = sorted({r["ticker"] for r in all_rows})

    results: dict[str, str] = {}
    sem = asyncio.Semaphore(_CONCURRENCY)

    # The 4 PM ET close-capture cycle writes the finalized EOD snapshot;
    # earlier intraday runs overwrite the same (ticker, obs_date) row but are
    # excluded from ML training and supervised inference.
    is_final = is_eod_capture_run()

    async with httpx.AsyncClient(timeout=60.0) as client:
        # Fetch macro index histories in parallel
        # FRED series: VIXCLS=30-day VIX, VXVCLS=93-day VIX3M, VVIXCLS=VVIX (vol-of-vol)
        # VIX gets 500 obs (~2 years): the HMM fits on the full series, and
        # ~70 returns is far too few for stable 2-state identification. The
        # 10-MA/RSI/deviation metrics only consume the tail either way.
        vix_closes, vix3m_closes, vvix_closes, (spy_closes, _), (rsp_closes, _) = (
            await asyncio.gather(
                # 500 observations ~ 2 years. The HMM needs the long series;
                # the other three only read the tail.
                _fetch_fred_series(client, "VIXCLS", limit=500),
                _fetch_fred_series(client, "VXVCLS"),
                _fetch_fred_series(client, "VVIXCLS"),
                # SPY (cap-weighted) vs RSP (equal-weighted) — the breadth
                # pair. 25 calendar days ~ 17 sessions, enough for the 5-day
                # return series and its z-score below.
                fetch_schwab_closes(client, "SPY", days=25),
                fetch_schwab_closes(client, "RSP", days=25),
            )
        )

        # VIX metrics
        vix_current:Optional[float] = None
        vix_10ma:Optional[float] = None
        vix_dev_pct:Optional[float] = None
        vix_rsi:Optional[float] = None
        vix_term_structure_ratio:Optional[float] = None
        vvix_current:Optional[float] = None
        vvix_10ma:Optional[float] = None
        hmm_result = None
        breadth_proxy:Optional[float] = None

        if vix_closes:
            vix_current = vix_closes[-1]
            ma10 = vix_closes[-10:] if len(vix_closes) >= 10 else []
            vix_10ma = sum(ma10) / len(ma10) if ma10 else None
            if vix_10ma and vix_10ma > 0 and vix_current is not None:
                vix_dev_pct = (vix_current - vix_10ma) / vix_10ma * 100
            vix_rsi    = compute_wilder_rsi(vix_closes)
            hmm_result = classify_vix_regime(vix_closes)

        # VIX term structure: VIX / VIX3M; >1 = backwardation (near-term stress)
        # Normally < 1 (contango — further-out vol priced higher). Above 1 means
        # near-term risk is bid above three-month risk, which is one of the
        # strongest single stress signals available and feeds both the decision
        # table and the ML feature vector.
        if vix_current is not None and vix3m_closes:
            vix3m_current = vix3m_closes[-1]
            if vix3m_current > 0:
                vix_term_structure_ratio = vix_current / vix3m_current

        # VVIX: vol-of-vol — spike signals hidden tail risk (Gate 0 in regime_service)
        # The vol of VIX itself. Gate 0 is the HIGHEST-priority rule in the
        # decision table: a VVIX spike (>15% above its 10-day mean) overrides any
        # premium_sell verdict to straddle_only. The reasoning is that VVIX can
        # move before VIX does, so it catches stress the level alone misses.
        if vvix_closes:
            vvix_current = vvix_closes[-1]
            ma10_vvix = vvix_closes[-10:] if len(vvix_closes) >= 10 else []
            vvix_10ma = sum(ma10_vvix) / len(ma10_vvix) if ma10_vvix else None

        # ── BREADTH PROXY ────────────────────────────────────────────────
        # RSP/SPY relative performance, z-scored. RSP is the equal-weighted
        # S&P and SPY the cap-weighted one, so their ratio measures whether a
        # rally is broad or is being carried by a handful of mega-caps.
        # A negative z-score means breadth is narrowing versus its own recent
        # norm — historically a late-cycle tell.
        #
        # 5-day returns rather than daily, to cut single-session noise. The
        # ratio is z-scored rather than used raw because its absolute level is
        # dominated by the secular mega-cap regime and says little.
        if len(spy_closes) >= 10 and len(rsp_closes) >= 10:
            spy_rets = [
                (spy_closes[i] - spy_closes[i - 5]) / spy_closes[i - 5]
                for i in range(5, len(spy_closes))
                if spy_closes[i - 5] > 0
            ]
            rsp_rets = [
                (rsp_closes[i] - rsp_closes[i - 5]) / rsp_closes[i - 5]
                for i in range(5, len(rsp_closes))
                if rsp_closes[i - 5] > 0
            ]
            n = min(len(spy_rets), len(rsp_rets))
            if n >= 5:
                # Guard against a near-zero SPY return blowing the ratio up:
                # substitute 1.0 (parity, i.e. "no divergence") rather than
                # dividing. Note this also means a flat-SPY session contributes
                # a neutral reading regardless of what RSP did.
                ratios = [
                    rsp_rets[i] / spy_rets[i] if abs(spy_rets[i]) > 1e-6 else 1.0
                    for i in range(n)
                ]
                mean = sum(ratios) / len(ratios)
                std  = (sum((r - mean) ** 2 for r in ratios) / len(ratios)) ** 0.5
                if std > 1e-6:
                    breadth_proxy = (ratios[-1] - mean) / std

        # HARD ABORT — the one job-level failure in this package. See the
        # header: a snapshot classified without VIX would be missing the HMM
        # gate entirely, then stored permanently looking complete.
        if vix_current is None:
            log.warning("regime_pull: VIX data unavailable (FRED error); aborting to avoid incomplete snapshots")
            return {"status": "no_vix_data"}

        # VVIX, by contrast, is DEGRADE-NOT-ABORT: losing it disables one
        # override rule while every other gate still applies, so a snapshot
        # without it is incomplete but not misleading.
        if vvix_current is None:
            log.warning(
                "regime_pull: VVIX data unavailable (FRED error) — "
                "Gate 0 (VVIX spike override) disabled for this run"
            )

        log.info(
            "regime_pull: vix=%.2f 10ma=%s dev_pct=%s ts_ratio=%s vvix=%s breadth_z=%s hmm=%s",
            vix_current or 0,
            f"{vix_10ma:.2f}" if vix_10ma else "—",
            f"{vix_dev_pct:.1f}%" if vix_dev_pct else "—",
            f"{vix_term_structure_ratio:.3f}" if vix_term_structure_ratio else "—",
            f"{vvix_current:.1f}" if vvix_current else "—",
            f"{breadth_proxy:.2f}" if breadth_proxy else "—",
            hmm_result.state.value if hmm_result else "—",
        )

        async def _process(ticker: str) -> tuple[str, str]:
            try:
                # Read today's IV snapshot (written by iv_pull)
                iv_snap = (
                    db.table("iv_snapshots")
                    .select(
                        "gamma_regime,iv_gex_signal,spot_to_zero_gamma_pct,"
                        "iv_percentile,delta_gex,total_gex,"
                        "spot_to_vt_pct,gex_0dte,gex_0dte_pct,underlying_price"
                    )
                    .eq("ticker", ticker)
                    .eq("date", today)
                    # maybe_single() returns one row or None instead of a list,
                    # and unlike single() does not error when nothing matches.
                    .maybe_single()
                    .execute()
                )
                # The expected miss: iv_pull has not landed yet, or failed for
                # this ticker. Named status, not an error.
                if iv_snap is None or not iv_snap.data:
                    log.warning("regime_pull: no iv_snapshot for ticker=%s", ticker)
                    return ticker, "no_iv_snapshot"

                iv = iv_snap.data
                spot = float(iv.get("underlying_price") or 0)

                # Price/volume history for SMA + ROC
                async with sem:
                    closes, volumes = await fetch_schwab_closes(client, ticker, days=65)
                clean_c = [c for c in closes  if c and c > 0]
                clean_v = [v for v in volumes if v and v > 0]

                # Every window is all-or-nothing: below the required length the
                # value is None rather than an average over a short window. The
                # classifier treats None as "cannot tell" and skips the rules
                # that need it — a 3-day "SMA10" would instead produce a
                # confident but wrong trend read.
                sma10:Optional[float] = sum(clean_c[-10:]) / 10  if len(clean_c) >= 10  else None
                sma50:Optional[float] = sum(clean_c[-50:]) / 50  if len(clean_c) >= 50  else None
                # 30/50 replaced the old 3/20 pair. These are a PARTICIPATION
                # REGIME read — busier over ~6 weeks than ~10 — and by
                # construction cannot register a single-day spike: a 10x volume
                # day moves this ratio to only 1.102 against its own p90 of
                # 1.167. Single-day surge detection lives in
                # services/trend_volume.py against a 30-day median.
                vol_sma30:Optional[float] = sum(clean_v[-30:]) / 30  if len(clean_v) >= 30  else None
                vol_sma50:Optional[float] = sum(clean_v[-50:]) / 50  if len(clean_v) >= 50  else None
                # 5-session rate of change — the tiebreaker in rule 8 of the
                # decision table, where negative gamma and a bullish SMA
                # alignment conflict. Needs 6 closes for 5 sessions of change.
                price_roc5:Optional[float] = None
                if len(clean_c) >= 6 and clean_c[-6] > 0:
                    price_roc5 = (clean_c[-1] - clean_c[-6]) / clean_c[-6] * 100

                regime = classify_regime(
                    ticker=ticker,
                    gamma_regime=iv.get("gamma_regime"),
                    iv_gex_signal=iv.get("iv_gex_signal"),
                    spot_to_zgl_pct=iv.get("spot_to_zero_gamma_pct"),
                    iv_percentile=iv.get("iv_percentile"),
                    sma10=sma10,
                    sma50=sma50,
                    vix_current=vix_current,
                    vix_10ma=vix_10ma,
                    vix_dev_pct=vix_dev_pct,
                    vix_rsi=vix_rsi,
                    hmm_result=hmm_result,
                    vol_sma30=vol_sma30,
                    vol_sma50=vol_sma50,
                    delta_gex=iv.get("delta_gex"),
                    vix_term_structure_ratio=vix_term_structure_ratio,
                    vvix_current=vvix_current,
                    vvix_10ma=vvix_10ma,
                    spot_to_vt_pct=iv.get("spot_to_vt_pct"),
                    breadth_proxy=breadth_proxy,
                    price_roc5=price_roc5,
                    total_gex=iv.get("total_gex"),
                    gex_0dte=iv.get("gex_0dte"),
                    gex_0dte_pct=iv.get("gex_0dte_pct"),
                )
                _upsert_regime_snapshot(db, today, regime, is_final)
                log.info("regime_ok ticker=%s bias=%s", ticker, regime.strategy_bias.value)
                return ticker, "ok"
            except Exception as exc:
                log.error("regime_failed ticker=%s error=%r", ticker, exc, exc_info=True)
                return ticker, f"error:{exc!r}"

        results = dict(await asyncio.gather(*[_process(t) for t in tickers]))

    # ML retraining is handled by the weekly regime-train Cloud Scheduler job
    # (routers/scheduler_trigger.py). Training data only changes once per day,
    # so retraining here on every hourly run was pure waste.

    # On the close-capture run, log today's predictions (scored from the
    # just-finalized snapshots) and reconcile pending ones whose 5-obs outcome
    # window has closed. Failures here must never break the snapshot pipeline.
    #
    # THIS IS WHAT MAKES THE LIVE METRICS HONEST. log_predictions records what
    # the model forecast TODAY, before the outcome is known; reconcile_predictions
    # later scores forecasts whose window has closed. That produces the live_auc /
    # live_hit_rate / live_brier figures in /regime/ml-analyze — real forecasts
    # graded after the fact, as opposed to training metrics, which a model can
    # overfit its way to.
    #
    # Runs only on the close-capture cycle, so each prediction is logged once per
    # day against the finalized snapshot rather than an intraday one.
    #
    # Wrapped so a monitoring failure can never cost the snapshot pipeline: the
    # error is captured into the returned dict and the job still reports
    # complete.
    monitor: dict = {}
    if is_final:
        try:
            from services.regime_ml_monitor import log_predictions, reconcile_predictions
            monitor["predictions"]    = log_predictions(db)
            monitor["reconciliation"] = reconcile_predictions(db)
        except Exception as exc:
            log.error("regime_ml_monitor_failed error=%r", exc, exc_info=True)
            monitor["error"] = repr(exc)

    return {"status": "complete", "tickers": results, "date": today, "is_final": is_final, "ml_monitor": monitor}


def _upsert_regime_snapshot(db, today: str, regime, is_final: bool) -> None:
    """Write one ticker's classification, echoing every input that produced it.

    The echo is deliberate — this row is the ML training data, and a stored
    verdict is useless for learning without the features behind it. The column
    set here must stay in step with regime_ml_trainer's feature extraction and
    with RegimeRequest in routers/regime.py.

    Unlike most helpers in this package this one RE-RAISES after logging, so a
    write failure surfaces as a per-ticker "error:" entry rather than being
    silently swallowed while the ticker reports ok.
    """
    try:
        db.table("regime_snapshots").upsert(
            {
                "ticker":                   regime.ticker,
                "obs_date":                 today,
                "gamma_regime":             regime.gamma_regime,
                "iv_gex_signal":            regime.iv_gex_signal,
                "sma10":                    regime.sma10,
                "sma50":                    regime.sma50,
                "sma_crossed":              regime.sma_crossed,
                "vix_current":              regime.vix_current,
                "vix_10ma":                 regime.vix_10ma,
                "vix_dev_pct":              regime.vix_dev_pct,
                "vix_rsi":                  regime.vix_rsi,
                "spot_to_zgl_pct":          regime.spot_to_zgl_pct,
                "iv_percentile":            regime.iv_percentile,
                "hmm_state":                regime.hmm_state,
                "hmm_probability":          regime.hmm_probability,
                "strategy_bias":            regime.strategy_bias.value,
                "signals":                  regime.signals,
                "vol_sma30":                regime.vol_sma30,
                "vol_sma50":                regime.vol_sma50,
                "delta_gex":                regime.delta_gex,
                "spot_to_vt_pct":           regime.spot_to_vt_pct,
                "breadth_proxy":            regime.breadth_proxy,
                "gex_0dte":                 regime.gex_0dte,
                "gex_0dte_pct":             regime.gex_0dte_pct,
                "price_roc5":               regime.price_roc5,
                "total_gex":                regime.total_gex,
                "vix_term_structure_ratio": regime.vix_term_structure_ratio,
                "vvix_current":             regime.vvix_current,
                "vvix_10ma":                regime.vvix_10ma,
                # See the header: intraday rows are overwritten all session and
                # only the close-capture run sets this true. ML training and
                # supervised inference both filter on it.
                "is_final":                 is_final,
            },
            on_conflict="ticker,obs_date",
        ).execute()
    except Exception as exc:
        log.error("regime_snapshot_upsert_failed ticker=%s error=%r", regime.ticker, exc)
        raise
