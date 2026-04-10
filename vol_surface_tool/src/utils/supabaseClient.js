/**
 * supabaseClient.js
 *
 * Initializes the Supabase JS client using Vite env variables.
 * VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY must be set at build time.
 *
 * Auth flow: Flutter passes the current session tokens in the iframe URL hash:
 *   /vol-surface/#access_token=xxx&refresh_token=yyy
 * App.jsx reads the hash on mount and calls supabase.auth.setSession().
 */
import { createClient } from '@supabase/supabase-js';

const supabaseUrl  = import.meta.env.VITE_SUPABASE_URL;
const supabaseKey  = import.meta.env.VITE_SUPABASE_ANON_KEY;

if (!supabaseUrl || !supabaseKey) {
  console.warn(
    '[vol-surface] VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY not set — ' +
    'Supabase persistence disabled, falling back to localStorage only.'
  );
}

export const supabase = (supabaseUrl && supabaseKey)
  ? createClient(supabaseUrl, supabaseKey, {
      auth: {
        // Don't auto-redirect — we set the session manually from Flutter's tokens
        detectSessionInUrl: false,
        persistSession: true,
        storageKey: 'vol_surface_supabase_session',
      },
    })
  : null;
