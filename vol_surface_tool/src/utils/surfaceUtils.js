/**
 * surfaceUtils.js
 *
 * Transforms parsed option chain points into Plotly surface trace payloads.
 *
 * IV selection modes:
 *   'otm'     — OTM convention: put IV below spot, call IV above spot, average at ATM.
 *               Best practice for a "market" vol surface.
 *   'call'    — Always use call IV.
 *   'put'     — Always use put IV.
 *   'average' — Average of call and put IV when both present.
 */

/**
 * Pick the IV value for one point.
 */
export function selectIv(point, spotPrice, mode = 'otm') {
  const { strike, callIv, putIv } = point;

  const avg = () => {
    if (callIv !== null && putIv !== null) return (callIv + putIv) / 2;
    return callIv ?? putIv;
  };

  switch (mode) {
    case 'call':    return callIv ?? putIv;
    case 'put':     return putIv  ?? callIv;
    case 'average': return avg();
    case 'otm':
    default: {
      if (spotPrice == null) return avg();
      const ATM_BAND = spotPrice * 0.005; // ±0.5% of spot = ATM band
      if (strike < spotPrice - ATM_BAND) return putIv  ?? callIv;  // OTM put
      if (strike > spotPrice + ATM_BAND) return callIv ?? putIv;   // OTM call
      return avg();                                                   // ATM
    }
  }
}

/**
 * Build Plotly surface matrices from an array of parsed points.
 *
 * @param {Array<{strike, dte, callIv, putIv}>} points
 * @param {number|null} spotPrice
 * @param {'otm'|'call'|'put'|'average'} ivMode
 * @returns {{ x: number[], y: number[], z: (number|null)[][] }}
 *   x = unique strikes (sorted ascending)
 *   y = unique DTEs    (sorted ascending)
 *   z[i][j] = IV at y[i] (DTE) and x[j] (strike)
 */
export function buildSurfaceMatrix(points, spotPrice, ivMode = 'otm') {
  const strikesSet = new Set();
  const dtesSet    = new Set();

  // First pass: collect unique axes and build lookup map
  const ivMap = new Map(); // key: "dte_strike" → iv value

  for (const p of points) {
    const iv = selectIv(p, spotPrice, ivMode);
    if (iv === null) continue;

    strikesSet.add(p.strike);
    dtesSet.add(p.dte);
    ivMap.set(`${p.dte}_${p.strike}`, iv);
  }

  const strikes = Array.from(strikesSet).sort((a, b) => a - b);
  const dtes    = Array.from(dtesSet).sort((a, b) => a - b);

  // z[i][j]: row = DTE (y-axis), col = strike (x-axis)
  const z = dtes.map(dte =>
    strikes.map(strike => ivMap.get(`${dte}_${strike}`) ?? null)
  );

  return { x: strikes, y: dtes, z };
}

/**
 * Compute the difference surface: surfaceB − surfaceA.
 * Only cells where both surfaces have a non-null value are included.
 * Returns axes limited to the intersection of common strikes × DTEs.
 *
 * @param {{ x, y, z }} surfaceA
 * @param {{ x, y, z }} surfaceB
 * @returns {{ x: number[], y: number[], z: (number|null)[][] }}
 */
export function buildDiffMatrix(surfaceA, surfaceB) {
  // Build lookup maps for fast access
  const mapA = buildLookup(surfaceA);
  const mapB = buildLookup(surfaceB);

  // Intersect strikes and DTEs
  const strikesA = new Set(surfaceA.x);
  const dtesA    = new Set(surfaceA.y);

  const commonStrikes = surfaceB.x.filter(s => strikesA.has(s)).sort((a, b) => a - b);
  const commonDtes    = surfaceB.y.filter(d => dtesA.has(d)).sort((a, b) => a - b);

  const z = commonDtes.map(dte =>
    commonStrikes.map(strike => {
      const a = mapA.get(`${dte}_${strike}`);
      const b = mapB.get(`${dte}_${strike}`);
      if (a == null || b == null) return null;
      return parseFloat((b - a).toFixed(4));
    })
  );

  return { x: commonStrikes, y: commonDtes, z };
}

function buildLookup({ x, y, z }) {
  const map = new Map();
  y.forEach((dte, i) => {
    x.forEach((strike, j) => {
      const v = z[i]?.[j];
      if (v != null) map.set(`${dte}_${strike}`, v);
    });
  });
  return map;
}

/**
 * Compute summary statistics for a surface's z-values.
 */
export function surfaceStats(surface) {
  const vals = surface.z.flat().filter(v => v != null);
  if (vals.length === 0) return null;

  const min   = Math.min(...vals);
  const max   = Math.max(...vals);
  const mean  = vals.reduce((a, b) => a + b, 0) / vals.length;
  const atm   = vals[Math.floor(vals.length / 2)]; // rough ATM proxy

  return { min, max, mean, atm, count: vals.length };
}
