// =============================================================================
// get-schwab-movers — proxies Schwab /movers/{symbol_id} endpoint
// Body: {
//   symbolId:   string   "$DJI" | "$COMPX" | "$SPX" | "NYSE" | "NASDAQ" |
//                        "OTCBB" | "INDEX_ALL" | "EQUITY_ALL" |
//                        "OPTION_ALL" | "OPTION_PUT" | "OPTION_CALL"
//   sort?:      string   "VOLUME" | "TRADES" | "PERCENT_CHANGE_UP" | "PERCENT_CHANGE_DOWN"
//   frequency?: number   0 | 1 | 5 | 10 | 30 | 60  (default 0 = all day)
// }
// Returns: { movers: SchwabMover[] }
// =============================================================================
import { getValidToken } from '../_shared/schwab_auth.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  try {
    const {
      symbolId,
      sort      = 'PERCENT_CHANGE_UP',
      frequency = 0,
    } = await req.json() as {
      symbolId:   string
      sort?:      string
      frequency?: number
    }

    if (!symbolId) return _error('symbolId is required', 400)

    const supabaseUrl    = Deno.env.get('SUPABASE_URL')!
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const token          = await getValidToken(supabaseUrl, serviceRoleKey)

    const params = new URLSearchParams({
      sort:      sort,
      frequency: String(frequency),
    })

    const url  = `https://api.schwabapi.com/marketdata/v1/movers/${encodeURIComponent(symbolId)}?${params}`
    const resp = await fetch(url, {
      headers: {
        'Authorization': `Bearer ${token}`,
        'Accept':        'application/json',
      },
    })

    const text = await resp.text()
    if (!resp.ok) return _error(`Schwab API error ${resp.status}: ${text}`, resp.status)

    const data = JSON.parse(text)
    // Schwab returns either an array directly or { screeners: [...] }
    const raw: unknown[] = Array.isArray(data) ? data : (data?.screeners ?? [])

    const movers = raw.map((m: Record<string, unknown>) => ({
      symbol:      m['symbol'],
      description: m['description'],
      last:        m['last'],
      change:      m['change'],        // percent by default
      direction:   m['direction'],
      totalVolume: m['totalVolume'],
    }))

    return new Response(JSON.stringify({ movers }), {
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
