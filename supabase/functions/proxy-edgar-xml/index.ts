import { jsonResponse } from '../_shared/compress.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const { url } = await req.json()

    if (!url || typeof url !== 'string') {
      return new Response(JSON.stringify({ error: 'Missing url' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400,
      })
    }

    // Restrict to EDGAR filing documents only
    if (!url.startsWith('https://www.sec.gov/Archives/edgar/')) {
      return new Response(JSON.stringify({ error: 'Only SEC EDGAR archive URLs are allowed' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 403,
      })
    }

    const response = await fetch(url, {
      headers: {
        // EDGAR requires a descriptive User-Agent with contact info
        'User-Agent': 'SwingOptionsTrader/1.0 llcwalkerk@gmail.com',
        'Accept': 'application/xml, text/xml, */*',
      },
    })

    if (!response.ok) {
      return new Response(JSON.stringify({ error: `EDGAR returned ${response.status}` }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: response.status >= 500 ? 502 : response.status,
      })
    }

    const xml = await response.text()
    return jsonResponse(req, { xml }, corsHeaders)
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 500,
    })
  }
})
