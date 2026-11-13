import React from 'react';
import { WorkflowTrack } from './WorkflowTrack.jsx';
export function ContextCard({ id, title, type, steps, current, next, facts = [] }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 10, padding: 14, borderRadius: 'var(--radius-card)', background: 'var(--surface-card)', border: '1px solid var(--border-soft)' }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
        <span style={{ fontFamily: 'var(--font-mono)', fontSize: 12, opacity: .6 }}>{id}</span>
        <span style={{ flex: 1, minWidth: 0, fontSize: 15, fontWeight: 600, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{title}</span>
        {type && <span style={{ fontFamily: 'var(--font-mono)', fontSize: 10.5, opacity: .6, border: '1px solid var(--border)', borderRadius: 4, padding: '0 4px' }}>{type}</span>}
      </div>
      {steps && <WorkflowTrack steps={steps} current={current} next={next} />}
      {facts.length > 0 && <div style={{ display: 'flex', flexWrap: 'wrap', gap: '4px 14px', fontFamily: 'var(--font-mono)', fontSize: 11.5, opacity: .7 }}>{facts.map((f, i) => <span key={i}>{f}</span>)}</div>}
    </div>
  );
}
