import React from 'react';
import { QueueButton } from './QueueButton.jsx';
import { UsageLine } from './UsageLine.jsx';

export function TopBar({ title, subline, queueCount = 4, context, menu, menuOpen = false, onTitle, usage = { fiveH: 42, week: 18 }, disconnected = false, left, right }) {
  const bar = {
    display: 'flex', height: 'var(--bar-top)', boxSizing: 'border-box', flexShrink: 0, alignItems: 'center', gap: 2, padding: '0 4px',
    background: disconnected ? 'repeating-linear-gradient(135deg, var(--danger-wash) 0 8px, transparent 8px 16px), var(--bg)' : 'var(--bg)',
    borderTop: disconnected ? '2px solid var(--danger)' : undefined,
  };
  return (
    <div style={{ flexShrink: 0, display: 'flex', flexDirection: 'column', position: 'relative', zIndex: 'var(--z-row)' }}>
      {usage && !disconnected && <UsageLine window="5h" percent={usage.fiveH} />}
      <div style={bar}>
        {left !== undefined ? left : <QueueButton count={queueCount} />}
        <button type="button" onClick={onTitle} style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 1, padding: '0 0 0 4px', background: 'none', border: 0, textAlign: 'left', color: 'inherit', cursor: onTitle ? 'pointer' : 'default' }}>
          <span style={{ fontSize: 14, fontWeight: 500, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', color: disconnected ? 'var(--danger)' : undefined }}>
            {disconnected ? 'Not connected' : title}
            {menu && !disconnected && <span style={{ fontSize: 11, opacity: .6, fontWeight: 400, marginLeft: 6 }}>{menuOpen ? '▴' : '▾'}</span>}
          </span>
          <span style={{ fontFamily: 'var(--font-mono)', fontSize: 11.5, whiteSpace: 'nowrap', overflow: 'hidden', opacity: disconnected ? 1 : undefined, color: disconnected ? 'var(--danger)' : undefined }}>{disconnected || subline}</span>
        </button>
        {right !== undefined ? right : context && (
          <span style={{ display: 'flex', height: 46, alignItems: 'center', padding: '0 2px' }}>
            <span style={{ display: 'flex', height: 34, alignItems: 'center', padding: '0 10px', borderRadius: 'var(--radius)', border: '1px solid var(--border)', fontFamily: 'var(--font-mono)', fontSize: 12 }}>{context} ›</span>
          </span>
        )}
      </div>
      {usage && !disconnected ? <UsageLine window="week" percent={usage.week} /> : <div style={{ height: 1, background: 'var(--border)' }} />}
    </div>
  );
}
