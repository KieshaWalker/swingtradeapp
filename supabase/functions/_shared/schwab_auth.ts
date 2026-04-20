// =============================================================================
// _shared/schwab_auth.ts — Schwab OAuth token manager
// =============================================================================
// Call getValidToken(supabaseUrl, serviceRoleKey) from any Edge Function.
// Automatically refreshes the access token when it's within 5 min of expiry.
// Throws 'SCHWAB_REAUTH_REQUIRED' if the refresh token has expired (>7 days
// unused) — operator must re-run the one-time bootstrap flow in that case.
// =============================================================================

const SCHWAB_TOKEN_URL = 'https://api.schwabapi.com/v1/oauth/token'
const REFRESH_BUFFER_MS = 30 * 60 * 1000 // refresh 30 min before expiry

export async function getValidToken(
  supabaseUrl: string,
  serviceRoleKey: string,
): Promise<string> {
  const clientId     = Deno.env.get('SCHWAB_CLIENT_ID')
  const clientSecret = Deno.env.get('SCHWAB_CLIENT_SECRET')
  if (!clientId || !clientSecret) {
    throw new Error('SCHWAB_CLIENT_ID or SCHWAB_CLIENT_SECRET not set')
  }

  // Read the stored token row
  const row = await _fetchTokenRow(supabaseUrl, serviceRoleKey)
  if (!row) throw new Error('SCHWAB_REAUTH_REQUIRED: no token row found — run bootstrap')

  const expiresAt = new Date(row.expires_at).getTime()
  const now       = Date.now()
  const REFRESH_TOKEN_LIMIT_MS = 7 * 24 * 60 * 60 * 1000;
  const rowAge = Date.now() - new Date(row.created_at).getTime();

  if (rowAge > REFRESH_TOKEN_LIMIT_MS - (12 * 60 * 60 * 1000)) {
  console.warn("WARNING: Schwab Refresh Token expires in less than 12 hours.");
  }
  // Still valid with buffer to spare
  if (expiresAt - now > REFRESH_BUFFER_MS) {
    return row.access_token
  }

  // Need a refresh
  const basic = btoa(`${clientId}:${clientSecret}`)
  const resp  = await fetch(SCHWAB_TOKEN_URL, {
    method: 'POST',
    headers: {
      'Authorization': `Basic ${basic}`,
      'Content-Type':  'application/x-www-form-urlencoded',
    },
    body: new URLSearchParams({
      grant_type:    'refresh_token',
      refresh_token: row.refresh_token,
    }),
  })

  if (!resp.ok) {
    const text = await resp.text()
    if (resp.status === 400 || resp.status === 401) {
      throw new Error(`SCHWAB_REAUTH_REQUIRED: refresh failed — ${text}`)
    }
    throw new Error(`Schwab token refresh failed ${resp.status}: ${text}`)
  }

  const tokens = await resp.json()
  const updatedRefreshToken = tokens.refresh_token || row.refresh_token;
  const newExpiresAt = new Date(now + tokens.expires_in * 1000).toISOString()

  await _updateTokenRow(supabaseUrl, serviceRoleKey, row.id, {
    access_token:  tokens.access_token,
    refresh_token: updatedRefreshToken,
    expires_at:    newExpiresAt,
  })

  return tokens.access_token
}

// ── Supabase REST helpers (service role, no JWT auth needed) ──────────────────

async function _fetchTokenRow(
  supabaseUrl: string,
  serviceRoleKey: string,
): Promise<{ id: string; access_token: string; refresh_token: string; expires_at: string; created_at: string } | null> {
  const resp = await fetch(
    `${supabaseUrl}/rest/v1/schwab_tokens?select=id,access_token,refresh_token,expires_at,created_at&order=created_at.desc&limit=1`,
    { headers: _headers(serviceRoleKey) },
  )
  if (!resp.ok) return null
  const rows = await resp.json()
  return rows.length > 0 ? rows[0] : null
}

async function _updateTokenRow(
  supabaseUrl: string,
  serviceRoleKey: string,
  id: string,
  patch: { access_token: string; refresh_token: string; expires_at: string },
): Promise<void> {
  await fetch(
    `${supabaseUrl}/rest/v1/schwab_tokens?id=eq.${id}`,
    {
      method:  'PATCH',
      headers: { ..._headers(serviceRoleKey), 'Content-Type': 'application/json' },
      body:    JSON.stringify({ ...patch, updated_at: new Date().toISOString() }),
    },
  )
}

function _headers(serviceRoleKey: string): Record<string, string> {
  return {
    'apikey':        serviceRoleKey,
    'Authorization': `Bearer ${serviceRoleKey}`,
    'Prefer':        'return=minimal',
  }
}


// then in the terminal, run:
// deno run --allow-env --allow-net supabase/functions/_shared/schwab_auth.ts
// if deno command does not work then use npx:
// npx deno run --allow-env --allow-net supabase/functions/_shared/schwab_auth.ts