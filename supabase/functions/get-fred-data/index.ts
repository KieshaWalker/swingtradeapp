import { jsonResponse } from '../_shared/compress.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

async function fetchOneSeries(
  apiKey: string,
  seriesId: string,
  limit: string,
): Promise<{ observations: unknown[] }> {
  const url = `https://api.stlouisfed.org/fred/series/observations?series_id=${seriesId}&api_key=${apiKey}&file_type=json&limit=${limit}&sort_order=desc`
  try {
    const resp = await fetch(url)
    if (!resp.ok) {
      console.error(`FRED ${seriesId} error ${resp.status}: ${await resp.text()}`)
      return { observations: [] }
    }
    const data = await resp.json()
    return { observations: data.observations ?? [] }
  } catch (err) {
    console.error(`FRED ${seriesId} fetch failed: ${err}`)
    return { observations: [] }
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const body = await req.json()
    const { series_id, series_ids, limit = '500' } = body

    const apiKey = Deno.env.get('FRED_API_KEY')
    if (!apiKey) {
      console.error('FRED_API_KEY not configured in Supabase secrets')
      return new Response(JSON.stringify({ error: 'Server configuration error: missing FRED_API_KEY' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 500,
      })
    }

    // Bulk mode: fetch multiple series sequentially to avoid rate-limit bursts
    if (Array.isArray(series_ids) && series_ids.length > 0) {
      console.log(`Bulk FRED fetch: ${series_ids.length} series, limit: ${limit}`)
      const results: Record<string, { observations: unknown[] }> = {}
      for (const id of series_ids) {
        results[id] = await fetchOneSeries(apiKey, id, limit)
      }
      return jsonResponse(req, { results }, corsHeaders)
    }

    // Single-series mode (backwards-compatible — used by Python backend)
    if (!series_id) {
      return new Response(JSON.stringify({ error: 'Missing series_id or series_ids parameter' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400,
      })
    }

    console.log(`Fetching FRED series: ${series_id}, limit: ${limit}`)
    const url = `https://api.stlouisfed.org/fred/series/observations?series_id=${series_id}&api_key=${apiKey}&file_type=json&limit=${limit}&sort_order=desc`
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
    } catch {
      console.error(`Failed to parse FRED response: ${text}`)
      return new Response(JSON.stringify({ error: 'Invalid JSON from FRED API' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 502,
      })
    }

    return jsonResponse(req, data, corsHeaders)
  } catch (error) {
    console.error(`get-fred-data error: ${error.message}`)
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 400,
    })
  }
})