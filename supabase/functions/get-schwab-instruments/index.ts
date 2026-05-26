// =============================================================================
// get-schwab-instruments — proxies Schwab instruments endpoint
//
// Two modes, selected by the `projection` field in the request body:
//
//   symbol-search (default)
//     Body:    { query: string }
//     Returns: array of { symbol, name, exchange }
//
//   fundamental
//     Body:    { symbol: string }
//     Returns: raw fundamentalData object for the symbol
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
    const body       = await req.json() as { query?: string; symbol?: string; projection?: string }
    const projection = body.projection ?? 'symbol-search'

    const supabaseUrl    = Deno.env.get('SUPABASE_URL')!
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const token          = await getValidToken(supabaseUrl, serviceRoleKey)

    // ── fundamental projection ────────────────────────────────────────────────
    if (projection === 'fundamental') {
      const symbol = body.symbol?.trim().toUpperCase()
      if (!symbol) return _error('symbol is required for fundamental projection', 400)

      const params = new URLSearchParams({ symbol, projection: 'fundamental' })
      const resp = await fetch(
        `https://api.schwabapi.com/marketdata/v1/instruments?${params}`,
        { headers: { 'Authorization': `Bearer ${token}`, 'Accept': 'application/json' } },
      )
      const text = await resp.text()
      if (!resp.ok) return _error(`Schwab API error ${resp.status}: ${text}`, resp.status)

      const data = JSON.parse(text)
      const instruments: Record<string, unknown>[] = data?.instruments ?? (Array.isArray(data) ? data : [])
      const instrument = instruments.find((i) => (i.symbol as string)?.toUpperCase() === symbol)
        ?? instruments[0]

      if (!instrument) return jsonResponse(req, null, corsHeaders)

      // Schwab returns fundamental data under the `fundamental` key
      const fundamentalData = instrument.fundamental ?? null
      return jsonResponse(req, fundamentalData, corsHeaders)
    }

    // ── symbol-search projection (original behaviour) ─────────────────────────
    const query = (body.query ?? '').trim()
    if (!query) return _ok([], req)

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
    const instruments: Record<string, string>[] = data?.instruments ?? (Array.isArray(data) ? data : [])

    const results = instruments.slice(0, 10).map((i) => ({
      symbol:   i.symbol ?? '',
      name:     i.description ?? '',
      exchange: i.exchange ?? '',
    }))

    return _ok(results, req)
  } catch (err) {
    const msg    = err instanceof Error ? err.message : String(err)
    const status = msg.startsWith('SCHWAB_REAUTH_REQUIRED') ? 401 : 400
    return _error(msg, status)
  }
})

function _ok(data: unknown, req: Request): Response {
  return jsonResponse(req, data, corsHeaders)
}

function _error(message: string, status: number): Response {
  return new Response(JSON.stringify({ error: message }), {
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    status,
  })
}
