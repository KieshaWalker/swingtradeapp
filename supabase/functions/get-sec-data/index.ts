const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

Deno.serve(async (req) => {
    if (req.method === 'OPTIONS') {
        return new Response('ok', { headers: corsHeaders })
    }

    try {
        const { params } = await req.json()
        const apiKey = Deno.env.get('SEC_API_KEY')

        const urlParams = new URLSearchParams({
            ...params,
            token: apiKey!,
        })

        const url = `https://cloud.iexapis.com/stable/stock/${params.symbol}/sec-filings?${urlParams.toString()}`
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