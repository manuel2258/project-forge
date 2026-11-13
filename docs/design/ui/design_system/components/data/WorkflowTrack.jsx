import React from 'react';
export function WorkflowTrack({ steps = [], current = 0, next, compact = false }) {
  if (compact) return (
    <span style={{ display: 'inline-flex', gap: 2 }}>{steps.map((s, i) => <span key={i} style={{ width: 8, height: 3, borderRadius: 1, background: i < current ? 'color-mix(in oklch, var(--ink) 50%, transparent)' : i === current ? 'var(--accent)' : 'color-mix(in oklch, var(--ink) 14%, transparent)' }} />)}</span>
  );
  return (
    <div style={{ display: 'flex', fontFamily: 'var(--font-mono)', fontSize: 10.5 }}>
      {steps.map((s, i) => {
        const bg = i < current ? 'color-mix(in oklch, var(--ink) 50%, transparent)' : i === current ? 'var(--accent)' : i === next ? 'color-mix(in oklch, var(--ink) 30%, transparent)' : 'color-mix(in oklch, var(--ink) 12%, transparent)';
        return (
          <div key={i} style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 5, minWidth: 0 }}>
            <span style={{ height: 3, marginRight: 2, borderRadius: 1, background: bg }} />
            <span style={{ whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', color: i === current ? 'var(--accent-text)' : undefined, opacity: i === current ? 1 : i === next ? .75 : .4 }}>{s}</span>
          </div>
        );
      })}
    </div>
  );
}
