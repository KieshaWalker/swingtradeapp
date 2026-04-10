// =============================================================================
// schwab-bootstrap — one-time OAuth authorization code exchange
// =============================================================================
// Step 1: GET  /functions/v1/schwab-bootstrap?action=auth_url
//         → Returns the Schwab authorization URL to open in a browser
//
// Step 2: After you approve in the browser, Schwab redirects to your
//         redirect_uri with ?code=XXX&session_token=YYY
//
// Step 3: POST /functions/v1/schwab-bootstrap
//         Body: { code: "...", session_token: "..." }
//         → Exchanges the code for tokens and saves them to schwab_tokens table
//
// Only needs to be run ONCE. After that, schwab_auth.ts handles all refreshes.
// =============================================================================

const corsHeaders = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const SCHWAB_TOKEN_URL = 'https://api.schwabapi.com/v1/oauth/token'
const SCHWAB_AUTH_URL  = 'https://api.schwabapi.com/v1/oauth/authorize'

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  const clientId      = Deno.env.get('SCHWAB_CLIENT_ID')!
  const clientSecret  = Deno.env.get('SCHWAB_CLIENT_SECRET')!
  const redirectUri   = Deno.env.get('SCHWAB_REDIRECT_URI')!
  const supabaseUrl   = Deno.env.get('SUPABASE_URL')!
  const serviceKey    = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

  // Step 1 — GET: return the auth URL to open in browser
  if (req.method === 'GET') {
    const url = new URL(req.url)
    if (url.searchParams.get('action') === 'auth_url') {
      const authUrl = new URL(SCHWAB_AUTH_URL)
      authUrl.searchParams.set('client_id',     clientId)
      authUrl.searchParams.set('redirect_uri',  redirectUri)
      authUrl.searchParams.set('response_type', 'code')
      authUrl.searchParams.set('scope',         'readonly')
      return new Response(JSON.stringify({ auth_url: authUrl.toString() }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }
  }

  // Step 3 — POST: exchange code for tokens
  if (req.method === 'POST') {
    try {
      const { code: rawCode } = await req.json() as { code: string }
      if (!rawCode) return _error('code is required', 400)

      // Schwab URL-encodes the code in the redirect — decode it
      const code  = decodeURIComponent(rawCode)
      const basic = btoa(`${clientId}:${clientSecret}`)
      const resp  = await fetch(SCHWAB_TOKEN_URL, {
        method:  'POST',
        headers: {
          'Authorization': `Basic ${basic}`,
          'Content-Type':  'application/x-www-form-urlencoded',
        },
        body: new URLSearchParams({
          grant_type:   'authorization_code',
          code,
          redirect_uri: redirectUri,
        }),
      })

      if (!resp.ok) {
        const text = await resp.text()
        return _error(`Token exchange failed ${resp.status}: ${text}`, resp.status)
      }

      const tokens    = await resp.json()
      const expiresAt = new Date(Date.now() + tokens.expires_in * 1000).toISOString()

      // Delete all existing rows (keep table single-row)
      // PostgREST requires at least one filter — use a catch-all UUID comparison
      await fetch(`${supabaseUrl}/rest/v1/schwab_tokens?id=neq.00000000-0000-0000-0000-000000000000`, {
        method:  'DELETE',
        headers: { 'apikey': serviceKey, 'Authorization': `Bearer ${serviceKey}` },
      })

      const insert = await fetch(`${supabaseUrl}/rest/v1/schwab_tokens`, {
        method:  'POST',
        headers: {
          'apikey':        serviceKey,
          'Authorization': `Bearer ${serviceKey}`,
          'Content-Type':  'application/json',
          'Prefer':        'return=minimal',
        },
        body: JSON.stringify({
          access_token:  tokens.access_token,
          refresh_token: tokens.refresh_token,
          expires_at:    expiresAt,
        }),
      })

      if (!insert.ok) return _error('Failed to save tokens to database', 500)

      return new Response(
        JSON.stringify({ success: true, expires_at: expiresAt }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    } catch (err) {
      return _error(err instanceof Error ? err.message : String(err), 400)
    }
  }

  return _error('Method not allowed', 405)
})

function _error(message: string, status: number): Response {
  return new Response(JSON.stringify({ error: message }), {
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    status,
  })
}
