// =============================================================================
// get-schwab-pricehistory — proxies Schwab priceHistory endpoint
// Body: { symbol: string, days?: number, startDate?: number, endDate?: number }
//   days       — trim to last N candles (default 65); ignored when startDate provided
//   startDate  — epoch ms; when provided, fetches that exact range instead of period=1year
//   endDate    — epoch ms; defaults to today when startDate is provided
// Returns: { closes: number[], volumes: number[], dates: string[] }  oldest → newest
// =============================================================================
import { getValidToken } from '../_shared/schwab_auth.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  try {
    const { symbol, days = 65, startDate, endDate } =
      await req.json() as { symbol: string; days?: number; startDate?: number; endDate?: number }
    if (!symbol) return _error('symbol is required', 400)

    const supabaseUrl    = Deno.env.get('SUPABASE_URL')!
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const token          = await getValidToken(supabaseUrl, serviceRoleKey)

    const params = new URLSearchParams({
      symbol,
      frequencyType: 'daily',
      frequency:     '1',
      needExtendedHoursData: 'false',
    })

    if (startDate != null) {
      // Exact date range — Schwab ignores periodType/period when startDate is set
      params.set('startDate', String(startDate))
      params.set('endDate',   String(endDate ?? Date.now()))
    } else {
      // Default: 1 year rolling window
      params.set('periodType', 'year')
      params.set('period',     '1')
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
    const candles = (data.candles ?? []) as { close: number; volume: number; datetime: number }[]

    // When using date range return all candles; otherwise trim to last `days`
    const trimmed = startDate != null ? candles : candles.slice(-days)
    const closes  = trimmed.map(c => c.close)
    const volumes = trimmed.map(c => c.volume ?? 0)
    const dates   = trimmed.map(c => new Date(c.datetime).toISOString().slice(0, 10))

    return new Response(JSON.stringify({ closes, volumes, dates }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status:  200,
    })
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
