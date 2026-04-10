/**
 * ComparisonControls.jsx
 *
 * Top bar for choosing view mode, selecting dates, and picking IV mode.
 *
 * View modes:
 *   'single' — show one surface for the selected date
 *   'diff'   — show the difference surface (Date B − Date A)
 */
import React from 'react';

export default function ComparisonControls({
  dates,
  mode,           // 'single' | 'diff'
  onModeChange,
  singleDate,
  onSingleDateChange,
  dateA,
  dateB,
  onDateAChange,
  onDateBChange,
  ivMode,
  onIvModeChange,
}) {
  const hasDates = dates.length > 0;

  return (
    <div className="controls-bar">
      {/* ── View Mode Toggle ──────────────────────────────────────── */}
      <div className="control-group">
        <label className="control-label">VIEW</label>
        <div className="segmented">
          <button
            className={`seg-btn ${mode === 'single' ? 'seg-btn--active' : ''}`}
            onClick={() => onModeChange('single')}
          >
            Single Surface
          </button>
          <button
            className={`seg-btn ${mode === 'diff' ? 'seg-btn--active' : ''}`}
            onClick={() => onModeChange('diff')}
            disabled={dates.length < 2}
            title={dates.length < 2 ? 'Save at least 2 datasets to compare' : ''}
          >
            Difference (B − A)
          </button>
        </div>
      </div>

      {/* ── Date Selection ────────────────────────────────────────── */}
      {mode === 'single' && (
        <div className="control-group">
          <label className="control-label">DATE</label>
          <select
            className="select-field"
            value={singleDate ?? ''}
            onChange={e => onSingleDateChange(e.target.value)}
            disabled={!hasDates}
          >
            {!hasDates && <option value="">— No data —</option>}
            {dates.map(d => <option key={d} value={d}>{d}</option>)}
          </select>
        </div>
      )}

      {mode === 'diff' && (
        <>
          <div className="control-group">
            <label className="control-label">DATE A (baseline)</label>
            <select
              className="select-field"
              value={dateA ?? ''}
              onChange={e => onDateAChange(e.target.value)}
            >
              {dates.map(d => <option key={d} value={d}>{d}</option>)}
            </select>
          </div>

          <div className="control-group">
            <label className="control-label">DATE B (compare)</label>
            <select
              className="select-field"
              value={dateB ?? ''}
              onChange={e => onDateBChange(e.target.value)}
            >
              {dates.map(d => <option key={d} value={d}>{d}</option>)}
            </select>
          </div>

          {dateA && dateB && dateA === dateB && (
            <span className="warn-text">⚠ Select two different dates</span>
          )}
        </>
      )}

      {/* ── IV Mode ───────────────────────────────────────────────── */}
      <div className="control-group" style={{ marginLeft: 'auto' }}>
        <label className="control-label">IV SOURCE</label>
        <select
          className="select-field"
          value={ivMode}
          onChange={e => onIvModeChange(e.target.value)}
        >
          <option value="otm">OTM Convention</option>
          <option value="call">Call IV</option>
          <option value="put">Put IV</option>
          <option value="average">Average (Call+Put)/2</option>
        </select>
      </div>
    </div>
  );
}
