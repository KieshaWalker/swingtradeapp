const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }
const controller = new AbortController();
const id = setTimeout(() => controller.abort(), 15000); // 15s timeout

  try {
    const body = await req.json();
  console.log("Request Body:", body);
    const { endpoint, params, requiresKey = true } = body;
    const apiKey = Deno.env.get('CENSUS_API_KEY')

    // Build query string without encoding — Census uses + as date-range syntax
    // and : / * as query operators that must remain literal
    const parts: string[] = []
    for (const [k, v] of Object.entries(params as Record<string, string>)) {
      parts.push(`${k}=${v}`)
    }
    if (requiresKey && apiKey) {
      parts.push(`key=${apiKey}`)
    }

    const url = `https://api.census.gov/data/${endpoint}?${parts.join('&')}`
const response = await fetch(url, { signal: controller.signal });
  clearTimeout(id);

    const text = await response.text()
    let data: unknown

    if (!response.ok) {
     const errorText = await response.text();
     console.error(`Census API Error (${response.status}):`, errorText);
     return new Response(JSON.stringify({ error: errorText, status: response.status }), {
       headers: { ...corsHeaders, 'Content-Type': 'application/json' },
       status: 400,
     });
  }
    try {
      data = JSON.parse(text)
    } catch {
      // Census returns plain-text errors for bad requests
      return new Response(JSON.stringify({ error: text }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400,
      })
    }

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
