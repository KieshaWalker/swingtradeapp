const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const { endpoint, params, requiresKey = true } = await req.json()
    const apiKey = Deno.env.get('CENSUS_API_KEY')

    const urlParams = new URLSearchParams(params)
    if (requiresKey && apiKey) {
      urlParams.set('key', apiKey)
    }

    const url = `https://api.census.gov/data/${endpoint}?${urlParams.toString()}`
    const response = await fetch(url)
    const data = await response.json()

    return new Response(JSON.stringify(data), {
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
