import React from 'react';
import { CountBubble } from '../data/CountBubble.jsx';

export function BottomStrip({ tabs = [], active, onSelect }) {
  return (
    <nav style={{ flexShrink: 0, height: 'var(--bar-strip)', boxSizing: 'border-box', display: 'flex', alignItems: 'center', gap: 4, padding: '0 8px', borderTop: '1px solid var(--border)', background: 'var(--surface-strip)' }}>
      {tabs.map(t => {
        const on = t.label === active;
        return (
          <button key={t.label} type="button" onClick={() => onSelect && onSelect(t.label)} style={{
            flex: '1 1 auto', minWidth: 0, display: 'flex', height: 'var(--control-tab)', boxSizing: 'border-box', alignItems: 'center', justifyContent: 'center', gap: 5, padding: '0 6px',
            borderRadius: 'var(--radius)', fontFamily: 'var(--font-sans)', fontSize: 13, whiteSpace: 'nowrap', color: 'var(--ink)', cursor: 'pointer',
            background: on ? 'var(--bg)' : 'transparent', border: '1px solid ' + (on ? 'var(--border)' : 'transparent'), fontWeight: on ? 500 : 400, opacity: on ? 1 : .6 }}>
            {t.label}{t.count ? <CountBubble value={t.count} /> : null}
          </button>
        );
      })}
    </nav>
  );
}
