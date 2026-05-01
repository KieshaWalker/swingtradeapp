// =============================================================================
// get-schwab-pricehistory — proxies Schwab priceHistory endpoint
// Body: { symbol: string, days?: number }
// Returns: { closes: number[], volumes: number[] }  oldest → newest
// =============================================================================
import { getValidToken } from '../_shared/schwab_auth.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  try {
    const { symbol, days = 65 } = await req.json() as { symbol: string; days?: number }
    if (!symbol) return _error('symbol is required', 400)

    const supabaseUrl    = Deno.env.get('SUPABASE_URL')!
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const token          = await getValidToken(supabaseUrl, serviceRoleKey)

    // Convert calendar days needed → a start date far enough back.
    // trading days ≈ 70% of calendar days; add 50% buffer to be safe.
    const calendarDays = Math.ceil(days * 1.5) + 10
    const startDate    = new Date()
    startDate.setDate(startDate.getDate() - calendarDays)

    // When startDate is provided Schwab ignores periodType/period, but some
    // symbols return 400 if periodType is present alongside startDate.
    const params = new URLSearchParams({
      symbol,
      frequencyType: 'daily',
      frequency:     '1',
      startDate:     String(startDate.getTime()),
      needExtendedHoursData: 'false',
    })

    const resp = await fetch(
      `https://api.schwabapi.com/marketdata/v1/pricehistory?${params}`,
      { headers: { 'Authorization': `Bearer ${token}`, 'Accept': 'application/json' } },
    )

    const text = await resp.text()
    if (!resp.ok) return _error(`Schwab API error ${resp.status}: ${text}`, resp.status)

    const data    = JSON.parse(text)
    const candles = (data.candles ?? []) as { close: number; volume: number }[]

    // Return only the last `days` candles (oldest → newest already from Schwab)
    const trimmed = candles.slice(-days)
    const closes  = trimmed.map(c => c.close)
    const volumes = trimmed.map(c => c.volume ?? 0)

    return new Response(JSON.stringify({ closes, volumes }), {
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
