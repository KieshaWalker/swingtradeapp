// =============================================================================
// get-schwab-quotes — proxies Schwab Market Data quotes endpoint
// Body: { symbols: string[] }  e.g. { symbols: ["SPY", "QQQ"] }
// Returns Schwab's raw quotes map — Flutter adapter converts to StockQuote
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
    const { symbols } = await req.json() as { symbols: string[] }
    if (!symbols || symbols.length === 0) {
      return _error('symbols array is required', 400)
    }

    const supabaseUrl      = Deno.env.get('SUPABASE_URL')!
    const serviceRoleKey   = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const token            = await getValidToken(supabaseUrl, serviceRoleKey)

    const url = `https://api.schwabapi.com/marketdata/v1/quotes?symbols=${encodeURIComponent(symbols.join(','))}&fields=quote,fundamental`

    const resp = await fetch(url, {
      headers: {
        'Authorization': `Bearer ${token}`,
        'Accept':        'application/json',
      },
    })

    const text = await resp.text()
    if (!resp.ok) {
      return _error(`Schwab API error ${resp.status}: ${text}`, resp.status)
    }

    return new Response(text, {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status:  200,
    })
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
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
