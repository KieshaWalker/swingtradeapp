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
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
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

    // Slim the payload — Schwab returns ~45 fields per contract but the app only
    // reads ~23. Dropping the rest cuts response size by ~40-50%, keeping us well
    // below Schwab's Apigee TooBigBody limit for high-strike-count requests.
    const chain    = JSON.parse(text)
    const slimmed  = slimChain(chain)

    return new Response(JSON.stringify(slimmed), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status:  200,
    })
  } catch (err) {
    const msg    = err instanceof Error ? err.message : String(err)
    const status = msg.startsWith('SCHWAB_REAUTH_REQUIRED') ? 401 : 400
    return _error(msg, status)
  }
})

// Only keep fields read by SchwabOptionContract.fromJson — drops description,
// exchangeName, tradeDate, theoreticalVolatility, optionDeliverablesList, mini,
// nonStandard, percentChange, markChange, penultimateLastSize, etc.
const CONTRACT_KEEP = new Set([
  'symbol', 'strikePrice', 'bid', 'ask', 'last', 'mark',
  'bidSize', 'askSize', 'highPrice', 'lowPrice',
  'delta', 'gamma', 'theta', 'vega', 'rho',
  'volatility', 'totalVolume', 'openInterest', 'daysToExpiration',
  'inTheMoney', 'intrinsicValue', 'timeValue', 'theoreticalOptionValue',
  'expirationDate',
])

function slimContract(c: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {}
  for (const k of CONTRACT_KEEP) if (k in c) out[k] = c[k]
  return out
}

function slimExpMap(
  expMap: Record<string, Record<string, unknown[]>>,
): Record<string, Record<string, unknown[]>> {
  const result: Record<string, Record<string, unknown[]>> = {}
  for (const [exp, strikes] of Object.entries(expMap)) {
    result[exp] = {}
    for (const [strike, contracts] of Object.entries(strikes)) {
      result[exp][strike] = (contracts as Record<string, unknown>[]).map(slimContract)
    }
  }
  return result
}

function slimChain(chain: Record<string, unknown>): Record<string, unknown> {
  const out = { ...chain }
  if (out['callExpDateMap']) out['callExpDateMap'] = slimExpMap(out['callExpDateMap'] as Record<string, Record<string, unknown[]>>)
  if (out['putExpDateMap'])  out['putExpDateMap']  = slimExpMap(out['putExpDateMap']  as Record<string, Record<string, unknown[]>>)
  return out
}

function _error(message: string, status: number): Response {
  return new Response(JSON.stringify({ error: message }), {
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    status,
  })
}
