// get-kalshi-data — Supabase Edge Function
// Proxies requests to api.elections.kalshi.com to avoid CORS in Flutter Web.
//
// Request body (JSON):
//   { path: "/events", params: { status: "open", with_nested_markets: "true", limit: "200" } }
//
// The function appends params as query string and forwards the call to Kalshi.

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const BASE = 'https://api.elections.kalshi.com/trade-api/v2'

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const body = await req.json()
    const { path, params = {} } = body
    
    if (!path) {
      return new Response(JSON.stringify({ error: 'Missing path parameter' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400,
      })
    }
    
    const apiKey = Deno.env.get('KALSHI_ACCESS_KEY')
    if (!apiKey) {
      return new Response(JSON.stringify({ error: 'Missing KALSHI_ACCESS_KEY' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 500,
      })
    }

    // Convert all param values to strings
    const stringParams: Record<string, string> = {}
    for (const [key, value] of Object.entries(params)) {
      stringParams[key] = String(value)
    }
    
    const qs = new URLSearchParams(stringParams).toString()
    const url = `${BASE}${path}${qs ? '?' + qs : ''}`

    const response = await fetch(url, {
      headers: {
        'Authorization': `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
    })

    if (!response.ok) {
      const text = await response.text()
      return new Response(JSON.stringify({ error: `Kalshi ${response.status}: ${text}` }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: response.status,
      })
    }

    const data = await response.json()
    return new Response(JSON.stringify(data), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    })
  } catch (error) {
    console.error('Error:', error)
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 400,
    })
  }
})
