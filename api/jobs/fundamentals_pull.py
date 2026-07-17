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

import asyncio
import logging

import httpx

from core.supabase_client import get_supabase

log = logging.getLogger(__name__)

_UA = {"User-Agent": "swing-options-trader research llcwalkerk@gmail.com"}

_SUPPLY = ["MU", "SNDK", "NVDA", "AVGO", "AMD", "INTC", "TXN", "AMAT", "LRCX", "KLAC", "TSM", "ASML"]
_DEMAND = ["MSFT", "GOOGL", "AMZN", "META", "ORCL"]

# (taxonomy, tag) priority lists per metric
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
    """ticker -> zero-padded 10-digit CIK, from SEC's official mapping."""
    data = await _get_json(client, "https://www.sec.gov/files/company_tickers.json")
    if not data:
        return {}
    return {v["ticker"].upper(): str(v["cik_str"]).zfill(10) for v in data.values()}


async def _concept(
    client: httpx.AsyncClient, cik: str, tags: list[tuple[str, str]]
) -> tuple[Optional[str], Optional[str], list[dict]]:
    """First tag with data wins. Returns (tag_used, unit, entries)."""
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
    """Keep the latest-filed entry per key."""
    best: dict = {}
    for e in entries:
        k = key(e)
        if k not in best or (e.get("filed") or "") > (best[k].get("filed") or ""):
            best[k] = e
    return list(best.values())


def _revenue_rows(entries: list[dict]) -> list[dict]:
    """Discrete quarters (60-120d durations) + fiscal years (330-400d)."""
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
    discrete quarters. Annual durations become FY rows."""
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
    the instant date preferring the latest filing."""
    rows = []
    for e in _dedupe_latest([e for e in entries if not e.get("start")], lambda e: e["end"]):
        rows.append({"period_type": "PIT", "derived": False, **_common(e)})
    return rows


def _common(e: dict) -> dict:
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

        await asyncio.gather(
            *[_process(t, "supply") for t in _SUPPLY],
            *[_process(t, "demand") for t in _DEMAND],
            *[_process_bdc(t) for t in _BDC_UNIVERSE],
        )

    log.info("fundamentals_pull: done rows=%d errors=%s", written, errors)
    return {"status": "ok", "rows": written, "errors": errors}
