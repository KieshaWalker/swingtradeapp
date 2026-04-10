/**
 * SurfacePlot.jsx
 *
 * Renders a single Plotly 3D surface (either one date's IV surface
 * or the difference surface between two dates).
 *
 * Props:
 *   surface   — { x: strike[], y: dte[], z: iv[][] }  (from surfaceUtils)
 *   mode      — 'single' | 'diff'
 *   title     — string shown above the chart
 *   spotPrice — number | null   (draws a vertical plane at spot)
 *   stats     — { min, max, mean } | null
 */
import React, { useMemo } from 'react';
import Plot from 'react-plotly.js';

export default function SurfacePlot({ surface, mode, title, spotPrice, stats }) {
  const isDiff = mode === 'diff';

  // ── Build Plotly trace ──────────────────────────────────────────────────────
  const { data, layout } = useMemo(() => {
    if (!surface || surface.x.length === 0 || surface.y.length === 0) {
      return { data: [], layout: {} };
    }

    const colorscale = isDiff
      ? 'RdBu'       // Red = positive shift, Blue = negative shift
      : 'Viridis';   // Low IV = purple, High IV = yellow

    // For diff surface: center colorscale at 0
    const zmid = isDiff ? 0 : undefined;

    const surfaceTrace = {
      type:        'surface',
      x:           surface.x,   // strikes
      y:           surface.y,   // DTEs
      z:           surface.z,   // IV values
      colorscale,
      zmid,
      reversescale: isDiff,     // RdBu: red = positive, blue = negative
      connectgaps: true,        // interpolate across null cells
      contours: {
        x: { show: false },
        y: { show: false },
        z: {
          show:      true,
          usecolormap: true,
          highlightcolor: '#ffffff',
          project:   { z: false },
        },
      },
      hovertemplate:
        'Strike: %{x}<br>DTE: %{y}<br>' +
        (isDiff ? 'Δ IV: %{z:.2f}%' : 'IV: %{z:.2f}%') +
        '<extra></extra>',
      lighting: {
        ambient:     0.7,
        diffuse:     0.6,
        specular:    0.1,
        roughness:   0.6,
        fresnel:     0.1,
      },
      colorbar: {
        title: { text: isDiff ? 'Δ IV (pp)' : 'IV (%)', side: 'right' },
        thickness: 14,
        len:       0.7,
        tickfont:  { color: '#9ca3af', size: 11 },
        titlefont: { color: '#d1d5db', size: 12 },
        bgcolor:   'rgba(0,0,0,0)',
        bordercolor: 'rgba(0,0,0,0)',
      },
    };

    const traces = [surfaceTrace];

    // ── Spot price vertical plane ─────────────────────────────────────────────
    if (spotPrice && !isDiff && surface.y.length >= 2) {
      const yMin = surface.y[0];
      const yMax = surface.y[surface.y.length - 1];
      // Vertical plane at spot: a thin 2-row surface at x ≈ spot
      const zPlaneMin = Math.min(...surface.z.flat().filter(v => v != null));
      const zPlaneMax = Math.max(...surface.z.flat().filter(v => v != null));

      traces.push({
        type:      'surface',
        x:         [[spotPrice, spotPrice], [spotPrice, spotPrice]],
        y:         [[yMin, yMax], [yMin, yMax]],
        z:         [[zPlaneMin, zPlaneMin], [zPlaneMax, zPlaneMax]],
        colorscale: [['0', 'rgba(251,191,36,0.25)'], ['1', 'rgba(251,191,36,0.25)']],
        showscale: false,
        hoverinfo: 'skip',
        name:      `Spot $${spotPrice.toFixed(2)}`,
      });
    }

    const plotLayout = {
      paper_bgcolor: '#0f0f14',
      plot_bgcolor:  '#0f0f14',
      font:  { color: '#d1d5db', family: 'monospace' },
      title: {
        text:     title,
        font:     { color: '#f9fafb', size: 15, family: 'monospace' },
        x: 0.05,
        xanchor: 'left',
      },
      margin: { l: 0, r: 0, t: 48, b: 0 },
      scene: {
        bgcolor: '#0f0f14',
        xaxis: {
          title:     { text: 'Strike ($)', font: { color: '#9ca3af', size: 12 } },
          tickfont:  { color: '#6b7280', size: 10 },
          gridcolor: '#1f2937',
          zerolinecolor: '#374151',
          showbackground: true,
          backgroundcolor: '#111827',
        },
        yaxis: {
          title:     { text: 'DTE (days)', font: { color: '#9ca3af', size: 12 } },
          tickfont:  { color: '#6b7280', size: 10 },
          gridcolor: '#1f2937',
          zerolinecolor: '#374151',
          showbackground: true,
          backgroundcolor: '#111827',
        },
        zaxis: {
          title: {
            text: isDiff ? 'Δ IV (pp)' : 'IV (%)',
            font: { color: '#9ca3af', size: 12 },
          },
          tickfont:  { color: '#6b7280', size: 10 },
          gridcolor: '#1f2937',
          zerolinecolor: isDiff ? '#60a5fa' : '#374151',
          showbackground: true,
          backgroundcolor: '#111827',
          // For diff, add a zero-plane reference line
          ...(isDiff && { zeroline: true, zerolinewidth: 2 }),
        },
        camera: {
          eye:    { x: 1.6, y: -1.6, z: 0.8 },
          center: { x: 0,   y: 0,    z: -0.1 },
          up:     { x: 0,   y: 0,    z: 1 },
        },
        aspectmode: 'manual',
        aspectratio: { x: 1.6, y: 1.0, z: 0.7 },
      },
    };

    return { data: traces, layout: plotLayout };
  }, [surface, mode, title, spotPrice, isDiff]);

  // ── Empty state ─────────────────────────────────────────────────────────────
  if (!surface || surface.x.length === 0) {
    return (
      <div className="plot-empty">
        <p className="plot-empty-text">
          {mode === 'diff'
            ? 'Select two different dates to compute the difference surface.'
            : 'Save a dataset and select a date to view the surface.'}
        </p>
      </div>
    );
  }

  return (
    <div className="plot-wrapper">
      {/* ── Stats bar ───────────────────────────────────────────────── */}
      {stats && (
        <div className="stats-bar">
          <StatChip label="Min IV"  value={`${stats.min.toFixed(2)}%`}  color="#60a5fa" />
          <StatChip label="Max IV"  value={`${stats.max.toFixed(2)}%`}  color="#fbbf24" />
          <StatChip label="Mean IV" value={`${stats.mean.toFixed(2)}%`} color="#4ade80" />
          {spotPrice && (
            <StatChip label="Spot" value={`$${spotPrice.toFixed(2)}`} color="#f59e0b" />
          )}
          {isDiff && (
            <span className="stats-note">
              Positive (red) = IV rose · Negative (blue) = IV fell
            </span>
          )}
        </div>
      )}

      <Plot
        data={data}
        layout={layout}
        config={{
          displaylogo:     false,
          modeBarButtonsToRemove: ['toImage'],
          responsive:      true,
        }}
        style={{ width: '100%', height: '100%' }}
        useResizeHandler
      />
    </div>
  );
}

function StatChip({ label, value, color }) {
  return (
    <span className="stat-chip" style={{ borderColor: color + '55', color }}>
      <span className="stat-label">{label}</span>
      <span className="stat-value">{value}</span>
    </span>
  );
}
