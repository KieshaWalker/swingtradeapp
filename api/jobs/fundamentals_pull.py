from __future__ import annotations
from typing import Optional

# =============================================================================
# jobs/fundamentals_pull.py
# =============================================================================
# Job — SEC EDGAR XBRL fundamentals for the AI-cycle universes
#       → upsert sector_fundamentals.
# Cron: 0 12 * * 0  (weekly, Sunday 12:00 UTC — filings land on their own
#       schedule; a weekly poll catches everything within days)
#
# Source: data.sec.gov companyconcept API (free, no key; requires User-Agent,
# ~10 req/s ceiling). Revenue and capex tags drift across filers, so each
# metric tries a priority list of tags and records which one matched.
# Capex cash-flow entries are fiscal year-to-date durations in 10-Qs; they are
# differenced into discrete quarters (rows marked derived=true).
# Foreign filers (TSM, ASML) report under IFRS tags and possibly non-USD
# units — values are stored as reported with the unit recorded.
# =============================================================================
#
# THE THESIS THIS SERVES. The supply/demand split is the point: _SUPPLY is the
# semiconductor chain that SELLS AI capacity, _DEMAND is the hyperscalers that
# BUY it. Hyperscaler capex is semiconductor revenue one or two quarters later,
# so tracking both sides in one table is what makes the AI-cycle question
# answerable — is demand still accelerating, and is supply keeping up?
#
# WHY THIS IS HARD, AND WHAT THE CODE SPENDS ITS EFFORT ON. XBRL is standardized
# in name only:
#   * TAG DRIFT — filers report revenue under at least six different tags, so
#     each metric walks a priority list and records which one matched
#     (tag_used), making the choice auditable rather than invisible.
#   * YTD vs DISCRETE — capex in a 10-Q is fiscal YEAR-TO-DATE, not the quarter.
#     Q3's filed figure covers nine months. _capex_rows differences consecutive
#     YTD entries into discrete quarters, marking them derived=true.
#   * RESTATEMENTS — the same period gets filed repeatedly. _dedupe_latest keeps
#     the most recently FILED version of each period.
#   * FOREIGN FILERS — TSM and ASML report IFRS tags in TWD/EUR. Values are
#     stored as reported with the unit recorded, NOT converted, so any
#     cross-currency comparison must convert at read time.
#
# WEEKLY, NOT DAILY: filings arrive quarterly, so a more frequent poll is wasted
# requests against SEC's rate limit. Sunday keeps it clear of the weekday
# pipeline entirely.
#
# NO market_session_guard() — this is filing data, not market data, and has no
# session or date-rollover hazard.

import asyncio
import logging

import httpx

from core.supabase_client import get_supabase

log = logging.getLogger(__name__)

# SEC REQUIRES a descriptive User-Agent with contact details on every request;
# anonymous traffic is blocked outright. A hard API requirement, not a courtesy.
_UA = {"User-Agent": "swing-options-trader research llcwalkerk@gmail.com"}

# SELLERS of AI capacity: chip designers, memory, and the equipment makers
# (AMAT/LRCX/KLAC/ASML) sitting one layer further upstream again.
_SUPPLY = ["MU", "SNDK", "NVDA", "AVGO", "AMD", "INTC", "TXN", "AMAT", "LRCX", "KLAC", "TSM", "ASML"]
# BUYERS: the hyperscalers whose capex becomes the supply side's revenue.
_DEMAND = ["MSFT", "GOOGL", "AMZN", "META", "ORCL"]

# (taxonomy, tag) priority lists per metric
# ORDER IS SIGNIFICANT — _concept takes the FIRST tag that returns data, so the
# most specific and modern tags come first and the legacy/IFRS fallbacks last.
# Inserting a tag in the wrong position can silently change which series a filer
# reports under, producing a discontinuity in the stored history.
_REVENUE_TAGS = [
    ("us-gaap", "RevenueFromContractWithCustomerExcludingAssessedTax"),
    ("us-gaap", "Revenues"),
    ("us-gaap", "RevenueFromContractWithCustomerIncludingAssessedTax"),
    ("us-gaap", "SalesRevenueNet"),
    ("ifrs-full", "Revenue"),
    ("ifrs-full", "RevenueFromContractsWithCustomers"),
]
_CAPEX_TAGS = [
    ("us-gaap", "PaymentsToAcquirePropertyPlantAndEquipment"),
    ("us-gaap", "PaymentsToAcquireProductiveAssets"),
    ("ifrs-full", "PurchaseOfPropertyPlantAndEquipmentClassifiedAsInvestingActivities"),
]

# WS3 — private credit's interior: BDC net asset value per share from the
# same XBRL API (instant concept, quarterly). Against the daily market
# prices crisis_pull already fetches, this yields the discount-to-NAV series
# ("does the market believe the marks"). Non-accrual/PIK live in filing text,
# not XBRL — that assisted flow is a separate pass.
_BDC_UNIVERSE = ["ARCC", "OBDC", "FSK", "BXSL", "MAIN", "GBDC", "TSLX", "OCSL", "HTGC", "PSEC"]
_NAV_TAGS = [("us-gaap", "NetAssetValuePerShare")]

# Deliberately low. SEC's ceiling is ~10 req/s, but each ticker fires two or
# three sequential concept requests and the per-ticker sleep below adds further
# headroom — being throttled or blocked by SEC costs far more than a slower job.
_CONCURRENCY = 3


async def _get_json(client: httpx.AsyncClient, url: str) -> Optional[dict]:
    try:
        resp = await client.get(url, headers=_UA, timeout=30.0)
        if resp.status_code != 200:
            return None
        return resp.json()
    except Exception as exc:
        log.warning("edgar_fetch_error url=%s error=%r", url, exc)
        return None


async def _cik_map(client: httpx.AsyncClient) -> dict[str, str]:
    """ticker -> zero-padded 10-digit CIK, from SEC's official mapping.

    The CIK is SEC's permanent company identifier and the only way to address
    the XBRL API. Zero-padding to 10 digits is required by the URL format
    (CIK0000320193), so zfill is not optional.

    Fetched fresh each run rather than cached, so ticker changes and new listings
    are picked up automatically. An empty result aborts the whole job — without
    the map no ticker can be resolved.
    """
    data = await _get_json(client, "https://www.sec.gov/files/company_tickers.json")
    if not data:
        return {}
    return {v["ticker"].upper(): str(v["cik_str"]).zfill(10) for v in data.values()}


async def _concept(
    client: httpx.AsyncClient, cik: str, tags: list[tuple[str, str]]
) -> tuple[Optional[str], Optional[str], list[dict]]:
    """First tag with data wins. Returns (tag_used, unit, entries).

    Walks the priority list in order, requesting one tag at a time and stopping
    at the first that returns usable data. Costs an extra HTTP round trip per
    miss, which is why the lists are ordered most-likely-first.

    UNIT SELECTION: USD is preferred when present; otherwise the unit with the
    MOST entries wins, which picks a foreign filer's reporting currency (TWD for
    TSM, EUR for ASML) over an incidental secondary bucket. The chosen unit is
    returned and stored, since values are NOT converted.

    Entries missing `val` or `end` are dropped — `end` is the period key
    everything downstream dedupes and upserts on.
    """
    for taxonomy, tag in tags:
        data = await _get_json(
            client,
            f"https://data.sec.gov/api/xbrl/companyconcept/CIK{cik}/{taxonomy}/{tag}.json",
        )
        if not data or not data.get("units"):
            continue
        # Prefer USD; otherwise take the largest unit bucket (TWD, EUR, ...)
        units = data["units"]
        unit = "USD" if "USD" in units else max(units, key=lambda u: len(units[u]))
        entries = [e for e in units[unit] if e.get("val") is not None and e.get("end")]
        if entries:
            return f"{taxonomy}:{tag}", unit, entries
    return None, None, []


def _days(e: dict) -> Optional[int]:
    """Duration of an XBRL entry in days, or None for a point-in-time fact.

    THE CENTRAL CLASSIFIER of this module: XBRL does not label a fact as
    "quarterly" or "annual", it just gives start and end dates, so duration is
    the only way to tell them apart. Hence the wide ranges used below — 60-120
    days for a quarter, 330-400 for a year — since fiscal calendars vary
    (52/53-week years, non-calendar quarter ends).

    A missing `start` means an INSTANT fact (a balance-sheet value like NAV per
    share) rather than a duration, so None here is meaningful, not an error.
    """
    from datetime import date
    if not e.get("start"):
        return None
    try:
        s = date.fromisoformat(e["start"])
        d = date.fromisoformat(e["end"])
        return (d - s).days
    except ValueError:
        return None


def _dedupe_latest(entries: list[dict], key) -> list[dict]:
    """Keep the latest-filed entry per key.

    RESTATEMENT HANDLING. The same period appears repeatedly across filings —
    first in a 10-Q, then in the 10-K, then in next year's comparative columns —
    sometimes with revised numbers. Keying on the period and taking the latest
    `filed` date means the stored value is always the most recent version the
    filer stands behind.

    `key` is a callable so callers can dedupe on the period end alone (revenue,
    instants) or on the (start, end) pair (capex YTD, where two entries can share
    an end date with different starts).

    String comparison on `filed` works because the dates are ISO-formatted; a
    missing `filed` sorts lowest via the `or ""` default, so a dated entry always
    beats an undated one.
    """
    best: dict = {}
    for e in entries:
        k = key(e)
        if k not in best or (e.get("filed") or "") > (best[k].get("filed") or ""):
            best[k] = e
    return list(best.values())


def _revenue_rows(entries: list[dict]) -> list[dict]:
    """Discrete quarters (60-120d durations) + fiscal years (330-400d).

    Revenue is simpler than capex: income-statement facts are usually filed as
    discrete periods already, so no differencing is needed and every row is
    derived=False.

    Durations outside both bands — six-month interims, odd stub periods — are
    dropped entirely rather than misclassified.
    """
    rows = []
    quarters = _dedupe_latest(
        [e for e in entries if (_days(e) or 0) in range(60, 121)], lambda e: e["end"]
    )
    years = _dedupe_latest(
        [e for e in entries if (_days(e) or 0) in range(330, 401)], lambda e: e["end"]
    )
    for e in quarters:
        rows.append({"period_type": "Q", "derived": False, **_common(e)})
    for e in years:
        rows.append({"period_type": "FY", "derived": False, **_common(e)})
    return rows


def _capex_rows(entries: list[dict]) -> list[dict]:
    """10-Q capex is fiscal YTD: difference each fiscal-year group into
    discrete quarters. Annual durations become FY rows.

    THE HARDEST TRANSFORM IN THIS FILE. Cash-flow-statement items are reported
    cumulatively from the fiscal year start, so a filer's Q3 capex figure covers
    NINE MONTHS. Storing those as-is would badly over-count.

    The fix: group entries by their duration START date (the fiscal-year anchor,
    shared by every YTD entry in that year), sort by end date, and subtract each
    from the one before to recover the discrete quarter.

    `prev_val = 0.0` seeds the first entry of each group, so Q1's YTD figure IS
    the discrete quarter — correctly marked derived=False, since nothing was
    subtracted. Later quarters get derived=True.

    `period_start` is rewritten to the previous entry's end date so the stored
    row describes the discrete quarter rather than the YTD window it came from.

    The differencing assumes entries within a fiscal-year group are complete and
    monotonic. A missing interim filing folds two quarters into one oversized row
    rather than leaving a gap — worth knowing when a derived quarter looks
    anomalous.
    """
    rows = []
    dated = [e for e in entries if _days(e) is not None]
    years = _dedupe_latest(
        [e for e in dated if _days(e) in range(330, 401)], lambda e: e["end"]
    )
    for e in years:
        rows.append({"period_type": "FY", "derived": False, **_common(e)})

    # YTD family: group by fiscal-year anchor (the duration start date)
    ytd = _dedupe_latest(
        [e for e in dated if _days(e) < 330], lambda e: (e["start"], e["end"])
    )
    by_start: dict[str, list[dict]] = {}
    for e in ytd:
        by_start.setdefault(e["start"], []).append(e)
    for start, group in by_start.items():
        group.sort(key=lambda e: e["end"])
        prev_val = 0.0
        prev_end = None
        for e in group:
            discrete = float(e["val"]) - prev_val
            row = _common(e)
            row["value"] = int(discrete)
            # discrete quarter runs from the day after the previous YTD end
            if prev_end:
                row["period_start"] = prev_end
            rows.append({"period_type": "Q", "derived": prev_end is not None, **row})
            prev_val = float(e["val"])
            prev_end = e["end"]
    return rows


def _instant_rows(entries: list[dict]) -> list[dict]:
    """Point-in-time concepts (e.g. NAV per share): no duration, dedupe by
    the instant date preferring the latest filing.

    Selected by the ABSENCE of `start` — the balance-sheet counterpart to the
    duration-based classification the revenue and capex helpers use.
    """
    rows = []
    for e in _dedupe_latest([e for e in entries if not e.get("start")], lambda e: e["end"]):
        rows.append({"period_type": "PIT", "derived": False, **_common(e)})
    return rows


def _common(e: dict) -> dict:
    """Fields every row shares, whatever the metric or period type.

    WARNING — `int(e["val"])` TRUNCATES. Correct for revenue and capex, which are
    whole dollars and far too large for a fractional part to matter, but it is
    applied to EVERY metric including per-share values.

    That defeats the cents-scaling in _process_bdc: NAV per share is truncated to
    whole dollars HERE, and the later "* 100 to preserve precision" step then
    scales an already-truncated integer. A reported NAV of $19.87 is stored as
    1900 cents ($19.00), losing $0.87 — around 4%, enough to make the
    discount-to-NAV series materially wrong. Fixing it means keeping the raw
    float through _common (or rounding rather than truncating) before the
    per-metric scaling runs.

    `form` and `filed` are carried through because _dedupe_latest needs `filed`
    for restatement handling and _process_bdc filters on `form`.
    """
    return {
        "period_start": e.get("start"),
        "period_end": e["end"],
        "fy": e.get("fy"),
        "fp": e.get("fp"),
        "value": int(e["val"]),
        "form": e.get("form"),
        "filed": e.get("filed"),
    }


async def run_fundamentals_pull() -> dict:
    db = get_supabase()
    sem = asyncio.Semaphore(_CONCURRENCY)
    written = 0
    errors: list[str] = []

    async with httpx.AsyncClient(timeout=60.0) as client:
        ciks = await _cik_map(client)
        if not ciks:
            return {"status": "no_cik_map"}

        async def _process(ticker: str, universe: str) -> None:
            nonlocal written
            cik = ciks.get(ticker)
            if not cik:
                errors.append(f"{ticker}:no_cik")
                return
            # Both concept walks AND the sleep happen inside the semaphore, so
            # the rate limit applies to whole tickers rather than to individual
            # requests — a ticker that has to try five revenue tags cannot burst
            # past the ceiling.
            async with sem:
                rev_tag, rev_unit, rev = await _concept(client, cik, _REVENUE_TAGS)
                cap_tag, cap_unit, cap = await _concept(client, cik, _CAPEX_TAGS)
                await asyncio.sleep(0.2)  # stay far below SEC's 10 req/s ceiling

            rows = []
            for r in _revenue_rows(rev):
                rows.append({**r, "metric": "revenue", "tag_used": rev_tag, "unit": rev_unit})
            for r in _capex_rows(cap):
                rows.append({**r, "metric": "capex", "tag_used": cap_tag, "unit": cap_unit})
            if not rows:
                errors.append(f"{ticker}:no_data")
                return
            # SECOND dedupe pass, distinct from _dedupe_latest: that one runs
            # within a single metric's entry list, while this collapses
            # collisions ACROSS the revenue and capex row builders on the exact
            # upsert key. Postgres error 21000 ("ON CONFLICT DO UPDATE cannot
            # affect row a second time") rejects the ENTIRE batch, so a single
            # duplicate would cost the whole ticker.
            #
            # Filers can report the same quarter as both a discrete 3-month
            # duration and a fiscal-YTD duration ending on the same date —
            # dedupe on the upsert key or Postgres rejects the batch (21000).
            # Prefer as-reported rows over derived ones, then latest filed.
            unique: dict = {}
            for r in rows:
                k = (r["metric"], r["period_type"], r["period_end"])
                cur = unique.get(k)
                if (
                    cur is None
                    or (cur["derived"] and not r["derived"])
                    or (cur["derived"] == r["derived"]
                        and (r.get("filed") or "") > (cur.get("filed") or ""))
                ):
                    unique[k] = r
            rows = list(unique.values())
            for r in rows:
                r.update({"ticker": ticker, "cik": cik, "universe": universe})
            try:
                db.table("sector_fundamentals").upsert(
                    rows, on_conflict="ticker,metric,period_type,period_end"
                ).execute()
            except Exception as exc:
                # Isolate failures: one company's bad batch must not kill the
                # gather (and with it the shared HTTP client) for the rest.
                errors.append(f"{ticker}:upsert_failed:{exc}")
                log.warning("fundamentals_pull: %s upsert failed: %r", ticker, exc)
                return
            written += len(rows)
            log.info("fundamentals_pull: %s rows=%d rev_tag=%s cap_tag=%s",
                     ticker, len(rows), rev_tag, cap_tag)

        async def _process_bdc(ticker: str) -> None:
            nonlocal written
            cik = ciks.get(ticker)
            if not cik:
                errors.append(f"{ticker}:no_cik")
                return
            async with sem:
                tag, unit, entries = await _concept(client, cik, _NAV_TAGS)
                await asyncio.sleep(0.2)
            # BDCs also file NAV-tagged facts in prospectus supplements
            # (424B/N-2): rounded estimates, sometimes forward-dated contexts.
            # Only periodic reports carry the audited point-in-time truth.
            #
            # Hence two filters below: form must be 10-Q or 10-K, and the instant
            # date must not be in the future. The forward-dated guard matters
            # because a prospectus can carry an ESTIMATED NAV for a date that has
            # not happened yet, which would otherwise become the latest point in
            # the series and drag the whole discount-to-NAV calculation.
            from datetime import date as _date
            cutoff = _date.today().isoformat()
            entries = [
                e for e in entries
                if e.get("form") in ("10-Q", "10-K") and e.get("end", "9999") <= cutoff
            ]
            rows = _instant_rows(entries)
            if not rows:
                errors.append(f"{ticker}:no_nav")
                return
            for r in rows:
                r.update({"ticker": ticker, "cik": cik, "universe": "bdc",
                          "metric": "nav_per_share", "tag_used": tag, "unit": unit})
            # NAV values are dollars-and-cents; the table stores whole numbers
            # for revenue/capex, so scale to cents to preserve precision.
            #
            # WARNING — THIS DOES NOT ACHIEVE THAT. See the note in _common():
            # int() has already truncated the value, so by the time this runs the
            # cents are gone and it scales a whole-dollar integer. $19.87 lands
            # in the table as 1900, not 1987. The "_cents" unit suffix is
            # accurate about the SCALE but misleading about the PRECISION.
            for r in rows:
                r["value"] = int(round(float(r["value"]) * 100))
                r["unit"] = f"{unit}_cents"
            try:
                db.table("sector_fundamentals").upsert(
                    rows, on_conflict="ticker,metric,period_type,period_end"
                ).execute()
                written += len(rows)
                log.info("fundamentals_pull: %s nav rows=%d", ticker, len(rows))
            except Exception as exc:
                errors.append(f"{ticker}:nav_upsert_failed:{exc}")

        # All three universes run in one gather, sharing the semaphore, so the
        # rate limit is global rather than per-universe.
        #
        # NOTE no return_exceptions=True: an unhandled exception inside a task
        # would propagate and cancel its siblings. Both worker functions catch
        # their own upsert failures into `errors` for exactly that reason, but an
        # unexpected error elsewhere in them would still take the run down.
        await asyncio.gather(
            *[_process(t, "supply") for t in _SUPPLY],
            *[_process(t, "demand") for t in _DEMAND],
            *[_process_bdc(t) for t in _BDC_UNIVERSE],
        )

    # Always reports "ok" — `errors` is the field that matters, listing
    # per-ticker failures as "<ticker>:<reason>". A run can write zero rows and
    # still report ok, so check both `rows` and `errors`.
    #
    # `written` is incremented from concurrent tasks via `nonlocal`. Safe under
    # asyncio, which is single-threaded and only switches at await points — the
    # += happens between them.
    log.info("fundamentals_pull: done rows=%d errors=%s", written, errors)
    return {"status": "ok", "rows": written, "errors": errors}
