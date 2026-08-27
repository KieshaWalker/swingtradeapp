// =============================================================================
// get-schwab-pricehistory — proxies Schwab priceHistory endpoint
// Body: { symbol: string, days?: number, startDate?: number, endDate?: number }
//   days       — trim to last N candles (default 65); ignored when startDate provided
//   startDate  — epoch ms; when provided, fetches that exact range instead of period=1year
//   endDate    — epoch ms; defaults to today when startDate is provided
//   frequencyType — 'daily' (default) | 'minute'. 'minute' is intraday and is
//                   subject to Schwab's ~48-day lookback ceiling.
//   frequency     — 1 for daily; one of 1|5|10|15|30 when frequencyType=minute.
//                   Schwab has NO native 4-hour bar — build 4H by aggregating
//                   30-minute candles downstream.
// Returns: { closes, volumes, dates, opens, highs, lows, timestamps }  oldest → newest
//
// BACKWARD COMPATIBILITY IS LOAD-BEARING. jobs/common.py fetch_schwab_closes,
// crisis_pull, schwab_pull and routers/heston.py all read `closes`/`volumes`
// and ignore the rest, so the original three keys must keep their exact names,
// order and semantics. opens/highs/lows/timestamps are PURELY ADDITIVE —
// existing callers are unaffected by their presence.
//
// WHY OHLC AT ALL: trendline channel fitting connects swing pivots, and pivots
// are made of HIGHS and LOWS. Returning closes alone makes that impossible,
// which is why this function grew the extra fields rather than a sibling.
// =============================================================================
import { getValidToken } from '../_shared/schwab_auth.ts'
import { jsonResponse } from '../_shared/compress.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  try {
    const { symbol, days = 65, startDate, endDate,
            frequencyType = 'daily', frequency = 1 } =
      await req.json() as {
        symbol: string; days?: number; startDate?: number; endDate?: number
        frequencyType?: 'daily' | 'minute'; frequency?: number
      }
    if (!symbol) return _error('symbol is required', 400)

    if (frequencyType !== 'daily' && frequencyType !== 'minute') {
      return _error("frequencyType must be 'daily' or 'minute'", 400)
    }
    // Schwab rejects any other value outright; fail here with a readable
    // message rather than passing it through for a 400 with an opaque body.
    if (frequencyType === 'minute' && ![1, 5, 10, 15, 30].includes(frequency)) {
      return _error('frequency must be one of 1, 5, 10, 15, 30 when frequencyType=minute', 400)
    }

    const supabaseUrl    = Deno.env.get('SUPABASE_URL')!
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const token          = await getValidToken(supabaseUrl, serviceRoleKey)

    const params = new URLSearchParams({
      symbol,
      frequencyType,
      frequency:     String(frequencyType === 'daily' ? 1 : frequency),
      needExtendedHoursData: 'false',
    })

    // periodType is not free-form: Schwab only accepts periodType=year with
    // frequencyType=daily, and periodType=day with frequencyType=minute.
    // Sending the wrong pair is a 400, so it is derived here, never passed in.
    const periodType = frequencyType === 'minute' ? 'day' : 'year'
    params.set('periodType', periodType)
    if (startDate != null) {
      // When startDate is provided, Schwab uses the date range instead of period.
      params.set('startDate', String(startDate))
      params.set('endDate',   String(endDate ?? Date.now()))
    } else {
      // periodType=day caps out at period=10; periodType=year at 1 gives ~250
      // sessions, comfortably more than the 200 bars a 200-day SMA needs.
      params.set('period', periodType === 'day' ? '10' : '1')
    }

    const ac  = new AbortController()
    const tid = setTimeout(() => ac.abort(), 20_000)
    let resp: Response
    try {
      resp = await fetch(
        `https://api.schwabapi.com/marketdata/v1/pricehistory?${params}`,
        { headers: { 'Authorization': `Bearer ${token}`, 'Accept': 'application/json' }, signal: ac.signal },
      )
    } finally {
      clearTimeout(tid)
    }

    const text = await resp.text()
    if (!resp.ok) return _error(`Schwab API error ${resp.status}: ${text}`, resp.status)

    const data    = JSON.parse(text)
    const candles = (data.candles ?? []) as {
      open: number; high: number; low: number; close: number
      volume: number; datetime: number
    }[]

    // When using date range return all candles; otherwise trim to last `days`
    const trimmed = startDate != null ? candles : candles.slice(-days)
    const closes  = trimmed.map(c => c.close)
    const volumes = trimmed.map(c => c.volume ?? 0)
    const dates   = trimmed.map(c => new Date(c.datetime).toISOString().slice(0, 10))
    const opens   = trimmed.map(c => c.open)
    const highs   = trimmed.map(c => c.high)
    const lows    = trimmed.map(c => c.low)
    // Raw epoch ms. `dates` collapses to a UTC calendar day, which is correct
    // for daily bars but destroys the intraday ordering that 30-minute candles
    // need, so the unreduced timestamp is returned alongside it.
    const timestamps = trimmed.map(c => c.datetime)

    return jsonResponse(
      req,
      { closes, volumes, dates, opens, highs, lows, timestamps },
      corsHeaders,
    )
  } catch (err) {
    const msg    = err instanceof Error ? err.message : String(err)
    const status = msg.startsWith('SCHWAB_REAUTH_REQUIRED') ? 401 : 400
    return _error(msg, status)
  }
})

function _error(message: string, status: number): Response {
  return new Response(JSON.stringify({ error: message }), {
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    status,
  })
}
