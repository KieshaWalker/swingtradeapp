const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

Deno.serve(async (req) => {
  // Handle CORS preflight requests
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const body = await req.json()
    const { series_id, limit = '500' } = body
    
    if (!series_id) {
      return new Response(JSON.stringify({ error: 'Missing series_id parameter' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400,
      })
    }

    const apiKey = Deno.env.get('FRED_API_KEY')
    if (!apiKey) {
      console.error('FRED_API_KEY not configured in Supabase secrets')
      return new Response(JSON.stringify({ error: 'Server configuration error: missing FRED_API_KEY' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 500,
      })
    }
    
    const url = `https://api.stlouisfed.org/fred/series/observations?series_id=${series_id}&api_key=${apiKey}&file_type=json&limit=${limit}&sort_order=desc`
    console.log(`Fetching FRED series: ${series_id}, limit: ${limit}`)
    
    const response = await fetch(url)
    const text = await response.text()

    if (!response.ok) {
      console.error(`FRED API error (${response.status}): ${text}`)
      return new Response(JSON.stringify({ error: `FRED API error ${response.status}: ${text}` }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: response.status === 400 ? 400 : 502,
      })
    }

    let data
    try {
      data = JSON.parse(text)
    } catch (parseErr) {
      console.error(`Failed to parse FRED response: ${text}`)
      return new Response(JSON.stringify({ error: 'Invalid JSON from FRED API' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 502,
      })
    }

    return new Response(JSON.stringify(data), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    })
  } catch (error) {
    console.error(`get-fred-data error: ${error.message}`)
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 400,
    })
  }
})