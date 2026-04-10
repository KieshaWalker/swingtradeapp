/**
 * snapshotService.js
 *
 * Load and save vol surface snapshots.
 * Primary store: Supabase `vol_surface_snapshots` table (when authenticated).
 * Fallback: localStorage (same key used by App.jsx for offline/unauthenticated use).
 *
 * Dataset shape (both localStorage and Supabase):
 *   { [obsDate: string]: { points, spotPrice, ticker, parsedAt } }
 *
 * Supabase row shape:
 *   { id, user_id, ticker, obs_date, spot_price, points, parsed_at }
 */
import { supabase } from './supabaseClient';

const LOCAL_KEY = 'vol_surface_datasets_v1';

// ── localStorage helpers ──────────────────────────────────────────────────────

function localLoad() {
  try {
    const raw = localStorage.getItem(LOCAL_KEY);
    return raw ? JSON.parse(raw) : {};
  } catch {
    return {};
  }
}

function localSave(datasets) {
  try {
    localStorage.setItem(LOCAL_KEY, JSON.stringify(datasets));
  } catch { /* quota exceeded — silently skip */ }
}

// ── Supabase helpers ──────────────────────────────────────────────────────────

function isAuthed() {
  return supabase !== null;
}

/**
 * Convert a Supabase row → the dataset map entry format used by App.jsx.
 * Returns [obsDate, datasetEntry].
 */
function rowToEntry(row) {
  return [
    row.obs_date,
    {
      ticker:     row.ticker,
      spotPrice:  row.spot_price ? parseFloat(row.spot_price) : null,
      points:     row.points,
      parsedAt:   row.parsed_at,
      _supabaseId: row.id,
    },
  ];
}

// ── Public API ────────────────────────────────────────────────────────────────

/**
 * Load all snapshots for the current user.
 * Falls back to localStorage if Supabase is unavailable or not authenticated.
 * Always merges remote data into localStorage so offline access works.
 */
export async function loadSnapshots() {
  if (!isAuthed()) return localLoad();

  const { data, error } = await supabase
    .from('vol_surface_snapshots')
    .select('id, ticker, obs_date, spot_price, points, parsed_at')
    .order('obs_date', { ascending: true });

  if (error || !data) {
    console.warn('[snapshotService] Supabase load failed, using localStorage', error);
    return localLoad();
  }

  const datasets = Object.fromEntries(data.map(rowToEntry));
  // Keep local copy in sync for offline fallback
  localSave(datasets);
  return datasets;
}

/**
 * Save a single snapshot.
 * Uses upsert (unique on user_id + obs_date) so re-saving the same date
 * overwrites it rather than creating a duplicate.
 */
export async function saveSnapshot(obsDate, dataset) {
  // Always write to localStorage immediately for instant UI
  const current = localLoad();
  current[obsDate] = dataset;
  localSave(current);

  if (!isAuthed()) return;

  const { error } = await supabase
    .from('vol_surface_snapshots')
    .upsert({
      ticker:     dataset.ticker,
      obs_date:   obsDate,
      spot_price: dataset.spotPrice ?? null,
      points:     dataset.points,
      parsed_at:  dataset.parsedAt,
    }, { onConflict: 'user_id,obs_date' });

  if (error) {
    console.warn('[snapshotService] Supabase save failed', error);
  }
}

/**
 * Delete a snapshot by observation date.
 */
export async function deleteSnapshot(obsDate) {
  // Remove from localStorage
  const current = localLoad();
  delete current[obsDate];
  localSave(current);

  if (!isAuthed()) return;

  const { error } = await supabase
    .from('vol_surface_snapshots')
    .delete()
    .eq('obs_date', obsDate);

  if (error) {
    console.warn('[snapshotService] Supabase delete failed', error);
  }
}
