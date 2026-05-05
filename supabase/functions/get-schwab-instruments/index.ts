// =============================================================================
// get-schwab-instruments — proxies Schwab symbol search endpoint
// Body: { query: string }
// Returns array of { symbol, description, exchange, assetType }
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
    const { query } = await req.json() as { query: string }
    if (!query || query.trim().length === 0) return _ok([])

    const supabaseUrl    = Deno.env.get('SUPABASE_URL')!
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const token          = await getValidToken(supabaseUrl, serviceRoleKey)

    const params = new URLSearchParams({
      symbol:     query.toUpperCase(),
      projection: 'symbol-search',
    })

    const resp = await fetch(
      `https://api.schwabapi.com/marketdata/v1/instruments?${params}`,
      { headers: { 'Authorization': `Bearer ${token}`, 'Accept': 'application/json' } },
    )

    const text = await resp.text()
    if (!resp.ok) return _error(`Schwab API error ${resp.status}: ${text}`, resp.status)

    const data = JSON.parse(text)
    // Schwab returns { instruments: [...] }
    const instruments = data?.instruments ?? (Array.isArray(data) ? data : [])

    // Normalise to { symbol, name, exchange } — same shape as FmpTickerSearchResult
    const results = instruments.slice(0, 10).map((i: Record<string, string>) => ({
      symbol:   i.symbol ?? '',
      name:     i.description ?? i.fundamentalData?.description ?? '',
      exchange: i.exchange ?? '',
    }))

    return _ok(results)
  } catch (err) {
    const msg    = err instanceof Error ? err.message : String(err)
    const status = msg.startsWith('SCHWAB_REAUTH_REQUIRED') ? 401 : 400
    return _error(msg, status)
  }
})

function _ok(data: unknown): Response {
  return new Response(JSON.stringify(data), {
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    status:  200,
  })
}

function _error(message: string, status: number): Response {
  return new Response(JSON.stringify({ error: message }), {
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    status,
  })
}
