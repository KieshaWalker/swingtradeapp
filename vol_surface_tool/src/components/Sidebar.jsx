/**
 * Sidebar.jsx
 *
 * Left control panel:
 *   - Paste area for CSV data
 *   - Observation date input
 *   - Parse + Save button
 *   - Saved dataset list with delete buttons
 */
import React, { useState } from 'react';
import { parseOptionChain } from '../utils/csvParser';

export default function Sidebar({ datasets, onSave, onDelete, onSelect, selectedDate }) {
  const [rawText, setRawText]       = useState('');
  const [obsDate, setObsDate]       = useState('');
  const [parseError, setParseError] = useState('');
  const [parseInfo, setParseInfo]   = useState('');

  function handleSave() {
    setParseError('');
    setParseInfo('');

    if (!rawText.trim()) {
      setParseError('Paste CSV data first.');
      return;
    }
    if (!obsDate) {
      setParseError('Enter an observation date.');
      return;
    }
    if (datasets[obsDate]) {
      setParseError(`Date ${obsDate} already exists. Delete it first or choose a different date.`);
      return;
    }

    const { spotPrice, ticker, points } = parseOptionChain(rawText);

    if (points.length === 0) {
      setParseError('No option data found. Make sure you pasted the full ThinkorSwim CSV.');
      return;
    }

    const uniqueDtes    = [...new Set(points.map(p => p.dte))].sort((a, b) => a - b);
    const uniqueStrikes = [...new Set(points.map(p => p.strike))].length;

    setParseInfo(
      `Parsed ${points.length} data points · ${uniqueDtes.length} expirations (DTE: ${uniqueDtes.join(', ')}) · ${uniqueStrikes} strikes`
      + (spotPrice ? ` · Spot: $${spotPrice.toFixed(2)}` : '')
    );

    onSave(obsDate, { points, spotPrice, ticker: ticker ?? 'Unknown', parsedAt: new Date().toISOString() });
    setRawText('');
  }

  const sortedDates = Object.keys(datasets).sort();

  return (
    <aside className="sidebar">
      <div className="sidebar-header">
        <span className="sidebar-logo">📈</span>
        <h1 className="sidebar-title">Vol Surface Tool</h1>
      </div>

      {/* ── Data Input ───────────────────────────────────────────── */}
      <section className="sidebar-section">
        <h2 className="section-label">IMPORT DATA</h2>

        <label className="field-label">Observation Date</label>
        <input
          type="date"
          className="input-field"
          value={obsDate}
          onChange={e => setObsDate(e.target.value)}
        />

        <label className="field-label" style={{ marginTop: 12 }}>
          Paste CSV (ThinkorSwim export)
        </label>
        <textarea
          className="paste-area"
          placeholder="Paste the full contents of your .csv file here…"
          value={rawText}
          onChange={e => setRawText(e.target.value)}
          rows={8}
          spellCheck={false}
        />

        {parseError && <p className="msg msg-error">{parseError}</p>}
        {parseInfo  && <p className="msg msg-info">{parseInfo}</p>}

        <button className="btn btn-primary" onClick={handleSave}>
          Parse &amp; Save
        </button>
      </section>

      {/* ── Saved Datasets ───────────────────────────────────────── */}
      <section className="sidebar-section">
        <h2 className="section-label">SAVED DATASETS ({sortedDates.length})</h2>

        {sortedDates.length === 0 && (
          <p className="empty-hint">No datasets saved yet.</p>
        )}

        <ul className="dataset-list">
          {sortedDates.map(date => {
            const ds = datasets[date];
            const isSelected = date === selectedDate;
            return (
              <li
                key={date}
                className={`dataset-item ${isSelected ? 'dataset-item--active' : ''}`}
                onClick={() => onSelect(date)}
              >
                <div className="dataset-info">
                  <span className="dataset-date">{date}</span>
                  <span className="dataset-meta">
                    {ds.ticker} · {ds.points.length} pts
                    {ds.spotPrice ? ` · $${ds.spotPrice.toFixed(2)}` : ''}
                  </span>
                </div>
                <button
                  className="btn-delete"
                  title="Delete dataset"
                  onClick={e => { e.stopPropagation(); onDelete(date); }}
                >
                  ✕
                </button>
              </li>
            );
          })}
        </ul>
      </section>
    </aside>
  );
}
