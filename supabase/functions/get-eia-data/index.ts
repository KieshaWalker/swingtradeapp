const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const { route, frequency, length, data, start, end, facets } = await req.json()
    const apiKey = Deno.env.get('EIA_API_KEY')

    const params = new URLSearchParams()
    params.set('api_key', apiKey!)
    params.set('frequency', frequency)
    params.set('length', String(length))
    params.set('sort[0][column]', 'period')
    params.set('sort[0][direction]', 'desc')
    params.set('offset', '0')

    for (const d of (data ?? ['value'])) {
      params.append('data[]', d)
    }

    if (start) params.set('start', start)
    if (end) params.set('end', end)

    if (facets) {
      for (const [k, v] of Object.entries(facets)) {
        params.set(`facets[${k}][]`, String(v))
      }
    }

    const url = `https://api.eia.gov/v2/${route}/data/?${params.toString()}`
    const response = await fetch(url)
    const responseData = await response.json()

    return new Response(JSON.stringify(responseData), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    })
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 400,
    })
  }
})
