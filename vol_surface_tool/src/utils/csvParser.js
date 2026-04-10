/**
 * csvParser.js
 *
 * Parses the ThinkorSwim "Stock and Option Quote" CSV export.
 *
 * Format overview:
 *   - File-level header (stock name, timestamp)
 *   - UNDERLYING section: spot price on the second data row
 *   - One section per expiration, headed by a line like:
 *       "10 APR 26  (0)  100 (Weeklys)"
 *     where (0) is the DTE.
 *   - Immediately after the section title: a column-header row
 *   - Data rows (one per strike):
 *       col[0-1]  : empty
 *       col[2]    : Call Volume
 *       col[3]    : Call Open Interest
 *       col[4]    : Call Prob.OTM
 *       col[5]    : Call Prob.ITM
 *       col[6]    : Call Size
 *       col[7]    : Call Delta
 *       col[8]    : Call Impl Vol  ← CALL IV
 *       col[9-12] : Call BID/BX/ASK/AX
 *       col[13]   : Expiration label
 *       col[14]   : Strike         ← STRIKE
 *       col[15-18]: Put BID/BX/ASK/AX
 *       col[19]   : Put Volume
 *       col[20]   : Put Open Interest
 *       col[21]   : Put Prob.OTM
 *       col[22]   : Put Prob.ITM
 *       col[23]   : Put Size
 *       col[24]   : Put Delta
 *       col[25]   : Put Impl Vol   ← PUT IV
 */

// Regex for expiration section headers, e.g.:
//   "10 APR 26  (0)  100 (Weeklys)"
//   "21 MAY 26  (41)  100"
const SECTION_RE = /^\d{1,2}\s+[A-Z]{3}\s+\d{2,4}\s+\((\d+)\)/i;

/**
 * Splits a single CSV line respecting double-quoted fields that may
 * contain commas (e.g. "10,624").
 */
function splitCsvLine(line) {
  const result = [];
  let cur = '';
  let inQuotes = false;

  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (ch === '"') {
      inQuotes = !inQuotes;
    } else if (ch === ',' && !inQuotes) {
      result.push(cur.trim());
      cur = '';
    } else {
      cur += ch;
    }
  }
  result.push(cur.trim());
  return result;
}

/**
 * Parses an IV string like "62.00%", "--", "<empty>", "690.04%" into a number
 * (percentage points, e.g. 62.00) or null if unavailable / nonsensical.
 */
function parseIv(raw) {
  if (!raw || raw === '--' || raw === '<empty>') return null;
  const n = parseFloat(raw.replace('%', '').replace(/,/g, ''));
  if (isNaN(n) || n <= 0 || n > 10000) return null;
  return n; // e.g. 62.00 means 62.00%
}

/**
 * Main parser entry point.
 *
 * @param {string} text  Raw pasted CSV text
 * @returns {{
 *   spotPrice: number | null,
 *   ticker: string | null,
 *   points: Array<{ strike: number, dte: number, callIv: number|null, putIv: number|null }>
 * }}
 */
export function parseOptionChain(text) {
  const lines = text.split('\n');
  const points = [];
  let spotPrice = null;
  let ticker = null;
  let currentDte = null;
  let skipNextLine = false; // true after a section header → skip the column-header row

  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i];
    const line = raw.trim();

    // ── Ticker from first line ────────────────────────────────────────────────
    // e.g. "Stock quote and option quote for AMZN on 4/10/26 07:31:41"
    if (ticker === null && line.toLowerCase().includes('stock quote')) {
      const m = line.match(/for\s+([A-Z]{1,6})\s+on/i);
      if (m) ticker = m[1].toUpperCase();
    }

    // ── Spot price from UNDERLYING data row ───────────────────────────────────
    // Column header: "LAST,LX,Net Chng,BID,..."
    // Data row immediately after: "233.65,Q,0,..."
    if (line.startsWith('LAST,LX,')) {
      const dataLine = lines[i + 1]?.trim();
      if (dataLine) {
        const cols = splitCsvLine(dataLine);
        const spot = parseFloat(cols[0]);
        if (!isNaN(spot) && spot > 0) spotPrice = spot;
      }
    }

    // ── Expiration section header ─────────────────────────────────────────────
    const sectionMatch = line.match(SECTION_RE);
    if (sectionMatch) {
      currentDte = parseInt(sectionMatch[1], 10);
      skipNextLine = true; // next line is the column-header row
      continue;
    }

    // ── Skip column-header row after section header ───────────────────────────
    if (skipNextLine) {
      skipNextLine = false;
      continue;
    }

    // ── Data rows ─────────────────────────────────────────────────────────────
    if (currentDte === null || line === '') continue;

    const cols = splitCsvLine(line);
    if (cols.length < 26) continue;

    // Strike at col[14]
    const strike = parseFloat(cols[14]);
    if (isNaN(strike) || strike <= 0) continue;

    const callIv = parseIv(cols[8]);
    const putIv  = parseIv(cols[25]);

    // Must have at least one valid IV to be useful
    if (callIv === null && putIv === null) continue;

    points.push({ strike, dte: currentDte, callIv, putIv });
  }

  return { spotPrice, ticker, points };
}
