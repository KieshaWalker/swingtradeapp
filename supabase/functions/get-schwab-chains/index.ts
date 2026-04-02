// =============================================================================
// get-schwab-chains — proxies Schwab options chain endpoint
// Body: {
//   symbol:          string   (e.g. "SPY")
//   contractType?:   string   "CALL" | "PUT" | "ALL"  (default "ALL")
//   strikeCount?:    number   strikes above/below ATM  (default 10)
//   expirationDate?: string   "YYYY-MM-DD" to filter one expiry
// }
// Returns the full Schwab chain JSON including greeks per contract
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
      symbol,
      contractType   = 'ALL',
      strikeCount    = 10,
      expirationDate,
    } = await req.json() as {
      symbol:           string
      contractType?:    string
      strikeCount?:     number
      expirationDate?:  string
    }

    if (!symbol) return _error('symbol is required', 400)

    const supabaseUrl    = Deno.env.get('SUPABASE_URL')!
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const token          = await getValidToken(supabaseUrl, serviceRoleKey)

    const params = new URLSearchParams({
      symbol,
      contractType,
      strikeCount:              String(strikeCount),
      includeUnderlyingQuote:   'true',
      strategy:                 'SINGLE',
    })
    if (expirationDate) params.set('expirationDate', expirationDate)

    const url  = `https://api.schwabapi.com/marketdata/v1/chains?${params}`
    const resp = await fetch(url, {
      headers: {
        'Authorization': `Bearer ${token}`,
        'Accept':        'application/json',
      },
    })

    const text = await resp.text()
    if (!resp.ok) return _error(`Schwab API error ${resp.status}: ${text}`, resp.status)

    return new Response(text, {
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
