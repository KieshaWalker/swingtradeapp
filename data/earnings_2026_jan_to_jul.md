# Earnings dates — AAPL, GOOG, MU, SNDK (Jan 2026 → Jul 15, 2026)

All reports are after market close (pm), so the price reaction lands on the **next trading day**.
Source: Robinhood earnings data, pulled 2026-07-15.

## Reported within the window

| Symbol | Report date | Fiscal qtr | EPS est | EPS actual | Surprise |
|--------|-------------|-----------|---------|------------|----------|
| AAPL   | 2026-01-29  | FQ1 2026  | 2.66    | 2.84       | +6.8%    |
| SNDK   | 2026-01-29  | FQ2 2026  | 3.43    | 6.20       | +80.8%   |
| GOOG   | 2026-02-04  | Q4 2025   | 2.62    | 2.82       | +7.6%    |
| MU     | 2026-03-18  | FQ2 2026  | 8.60    | 12.20      | +41.9%   |
| GOOG   | 2026-04-29  | Q1 2026   | 2.63    | 5.11       | +94.3%   |
| AAPL   | 2026-04-30  | FQ2 2026  | 1.94    | 2.01       | +3.6%    |
| SNDK   | 2026-04-30  | FQ3 2026  | 14.36   | 23.41      | +63.0%   |
| MU     | 2026-06-24  | FQ3 2026  | 20.20   | 25.11      | +24.3%   |

## Upcoming (next report per ticker)

| Symbol | Report date | Timing | EPS est | Confirmed? |
|--------|-------------|--------|---------|------------|
| GOOG   | 2026-07-22  | pm     | 2.88    | yes        |
| AAPL   | 2026-07-30  | pm     | 1.89    | yes        |
| SNDK   | 2026-08-05  | pm     | 33.38   | yes        |
| MU     | 2026-09-22  | pm     | 31.24   | tentative  |

## Notes

- Price CSVs in this folder (`{ticker}_daily_2026.csv`, `combined_daily_2026.csv`) carry an
  `earnings_report_pm` column: 1 on the date the company reported after that day's close.
- Every reported quarter in the window was a beat; MU and SNDK show the memory-cycle
  blowout quarters (EPS estimates ramping ~4x within the window).
