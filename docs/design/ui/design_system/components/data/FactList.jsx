import React from 'react';
export function FactList({ facts = [], dense = false }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column' }}>
      {facts.map(([k, v, tone], i) => (
        <div key={i} style={{ display: 'flex', height: dense ? 26 : 30, alignItems: 'center', justifyContent: 'space-between', gap: 12, fontSize: dense ? 12 : 13, borderBottom: '1px solid var(--border-soft)' }}>
          <span style={{ opacity: .55 }}>{k}</span>
          <span style={{ fontFamily: 'var(--font-mono)', fontSize: dense ? 11.5 : 12.5, color: tone ? 'var(--' + tone + ')' : undefined }}>{v}</span>
        </div>
      ))}
    </div>
  );
}
