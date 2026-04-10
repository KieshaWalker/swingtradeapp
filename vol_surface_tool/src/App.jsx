/**
 * App.jsx
 *
 * Root component: manages all state, wires together Sidebar,
 * ComparisonControls, and SurfacePlot.
 *
 * Auth: Flutter passes the Supabase session in the iframe URL hash:
 *   /vol-surface/#access_token=xxx&refresh_token=yyy
 * We read the hash on mount, call supabase.auth.setSession(), then load
 * snapshots from Supabase. Falls back to localStorage when unauthenticated.
 */
import React, { useState, useMemo, useEffect, useCallback } from 'react';
import Sidebar from './components/Sidebar';
import ComparisonControls from './components/ComparisonControls';
import SurfacePlot from './components/SurfacePlot';
import { buildSurfaceMatrix, buildDiffMatrix, surfaceStats } from './utils/surfaceUtils';
import { supabase } from './utils/supabaseClient';
import { loadSnapshots, saveSnapshot, deleteSnapshot } from './utils/snapshotService';
import './App.css';

export default function App() {
  const [datasets,   setDatasets]   = useState({});
  const [loading,    setLoading]    = useState(true);
  const [mode,       setMode]       = useState('single');
  const [singleDate, setSingleDate] = useState(null);
  const [dateA,      setDateA]      = useState(null);
  const [dateB,      setDateB]      = useState(null);
  const [ivMode,     setIvMode]     = useState('otm');

  const sortedDates = useMemo(() => Object.keys(datasets).sort(), [datasets]);

  // ── Auth init from URL hash, then load snapshots ────────────────────────────
  useEffect(() => {
    async function init() {
      // Read Flutter-passed tokens from URL hash: #access_token=...&refresh_token=...
      const hash = window.location.hash.slice(1);
      if (hash && supabase) {
        const params = new URLSearchParams(hash);
        const accessToken  = params.get('access_token');
        const refreshToken = params.get('refresh_token');
        if (accessToken && refreshToken) {
          await supabase.auth.setSession({ access_token: accessToken, refresh_token: refreshToken });
          // Clear hash from URL so tokens don't linger
          history.replaceState(null, '', window.location.pathname + window.location.search);
        }
      }

      const data = await loadSnapshots();
      setDatasets(data);
      setLoading(false);
    }

    init();
  }, []);

  // ── Auto-select dates when datasets change ──────────────────────────────────
  useEffect(() => {
    if (sortedDates.length > 0 && !singleDate) {
      setSingleDate(sortedDates[sortedDates.length - 1]);
    }
    if (sortedDates.length >= 2) {
      if (!dateA || !datasets[dateA]) setDateA(sortedDates[0]);
      if (!dateB || !datasets[dateB]) setDateB(sortedDates[sortedDates.length - 1]);
    }
  }, [sortedDates]); // eslint-disable-line react-hooks/exhaustive-deps

  // ── Handlers ────────────────────────────────────────────────────────────────
  const handleSave = useCallback(async (obsDate, dataset) => {
    setDatasets(prev => ({ ...prev, [obsDate]: dataset }));
    setSingleDate(obsDate);
    await saveSnapshot(obsDate, dataset);
  }, []);

  const handleDelete = useCallback(async (obsDate) => {
    setDatasets(prev => {
      const next = { ...prev };
      delete next[obsDate];
      return next;
    });
    if (singleDate === obsDate) {
      const remaining = sortedDates.filter(d => d !== obsDate);
      setSingleDate(remaining.length > 0 ? remaining[remaining.length - 1] : null);
    }
    if (dateA === obsDate) setDateA(null);
    if (dateB === obsDate) setDateB(null);
    await deleteSnapshot(obsDate);
  }, [singleDate, dateA, dateB, sortedDates]);

  function handleModeChange(newMode) {
    setMode(newMode);
    if (newMode === 'diff' && sortedDates.length >= 2) {
      if (!dateA) setDateA(sortedDates[0]);
      if (!dateB) setDateB(sortedDates[sortedDates.length - 1]);
    }
  }

  // ── Computed surfaces ───────────────────────────────────────────────────────
  const { surface, spotPrice, title, stats } = useMemo(() => {
    if (mode === 'single') {
      if (!singleDate || !datasets[singleDate]) {
        return { surface: null, spotPrice: null, title: 'No data', stats: null };
      }
      const ds   = datasets[singleDate];
      const surf = buildSurfaceMatrix(ds.points, ds.spotPrice, ivMode);
      return {
        surface:   surf,
        spotPrice: ds.spotPrice,
        title:     `${ds.ticker} · IV Surface · ${singleDate}`,
        stats:     surfaceStats(surf),
      };
    }

    if (!dateA || !dateB || dateA === dateB || !datasets[dateA] || !datasets[dateB]) {
      return { surface: null, spotPrice: null, title: 'Difference Surface', stats: null };
    }

    const dsA   = datasets[dateA];
    const dsB   = datasets[dateB];
    const surfA = buildSurfaceMatrix(dsA.points, dsA.spotPrice, ivMode);
    const surfB = buildSurfaceMatrix(dsB.points, dsB.spotPrice, ivMode);
    const diff  = buildDiffMatrix(surfA, surfB);

    const ticker = dsA.ticker === dsB.ticker ? dsA.ticker : `${dsA.ticker}/${dsB.ticker}`;
    return {
      surface:   diff,
      spotPrice: null,
      title:     `${ticker} · Δ IV Surface · ${dateB} − ${dateA}`,
      stats:     surfaceStats(diff),
    };
  }, [mode, singleDate, dateA, dateB, ivMode, datasets]);

  // ── Render ──────────────────────────────────────────────────────────────────
  if (loading) {
    return (
      <div className="app-loading">
        <span className="app-loading-text">Loading datasets…</span>
      </div>
    );
  }

  return (
    <div className="app-shell">
      <Sidebar
        datasets={datasets}
        onSave={handleSave}
        onDelete={handleDelete}
        onSelect={setSingleDate}
        selectedDate={singleDate}
      />

      <div className="main-panel">
        <ComparisonControls
          dates={sortedDates}
          mode={mode}
          onModeChange={handleModeChange}
          singleDate={singleDate}
          onSingleDateChange={setSingleDate}
          dateA={dateA}
          onDateAChange={setDateA}
          dateB={dateB}
          onDateBChange={setDateB}
          ivMode={ivMode}
          onIvModeChange={setIvMode}
        />

        <div className="plot-area">
          <SurfacePlot
            surface={surface}
            mode={mode}
            title={title}
            spotPrice={spotPrice}
            stats={stats}
          />
        </div>
      </div>
    </div>
  );
}
