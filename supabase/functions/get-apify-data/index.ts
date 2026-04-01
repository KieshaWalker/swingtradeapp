const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const body = await req.json()
    const { action } = body
    const token = Deno.env.get('APIFY_API_KEY')
    const base = 'https://api.apify.com/v2'

    let url: string
    let method = 'GET'
    let requestBody: string | undefined

    switch (action) {
      case 'runActor': {
        const { actorId, input = {}, build, memoryMbytes, timeoutSecs } = body
        const p = new URLSearchParams({ token: token! })
        if (build) p.set('build', build)
        if (memoryMbytes) p.set('memoryMbytes', String(memoryMbytes))
        if (timeoutSecs) p.set('timeout', String(timeoutSecs))
        url = `${base}/acts/${actorId}/runs?${p}`
        method = 'POST'
        requestBody = JSON.stringify(input)
        break
      }
      case 'runActorSync': {
        const { actorId, input = {}, timeoutSecs = 300, memoryMbytes = 512 } = body
        const p = new URLSearchParams({
          token: token!,
          timeout: String(timeoutSecs),
          memoryMbytes: String(memoryMbytes),
          format: 'json',
        })
        url = `${base}/acts/${actorId}/run-sync-get-dataset-items?${p}`
        method = 'POST'
        requestBody = JSON.stringify(input)
        break
      }
      case 'getRunStatus': {
        const { runId } = body
        url = `${base}/actor-runs/${runId}?token=${token}`
        break
      }
      case 'getDatasetItems': {
        const { datasetId, limit = 1000, offset = 0 } = body
        const p = new URLSearchParams({
          token: token!,
          format: 'json',
          limit: String(limit),
          offset: String(offset),
        })
        url = `${base}/datasets/${datasetId}/items?${p}`
        break
      }
      case 'getLastRunDataset': {
        const { actorId, limit = 1000 } = body
        const p = new URLSearchParams({
          token: token!,
          format: 'json',
          limit: String(limit),
          status: 'SUCCEEDED',
        })
        url = `${base}/acts/${actorId}/runs/last/dataset/items?${p}`
        break
      }
      case 'getDatasetInfo': {
        const { datasetId } = body
        url = `${base}/datasets/${datasetId}?token=${token}`
        break
      }
      default:
        throw new Error(`Unknown action: ${action}`)
    }

    const response = await fetch(url, {
      method,
      headers: method === 'POST' ? { 'Content-Type': 'application/json' } : undefined,
      body: requestBody,
    })

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
