import React from 'react';

const Inbox = () => (
  <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <path d="M2 9.5h3.2l1 2h3.6l1-2H14" /><path d="M2 9.5 3.8 3.5h8.4L14 9.5v3H2z" />
  </svg>
);

export function QueueButton({ count = 0, onClick }) {
  const waiting = count > 0;
  return (
    <button type="button" onClick={onClick} aria-label={'Queue, ' + count + ' waiting'} style={{ display: 'flex', height: 46, alignItems: 'center', padding: '0 6px 0 2px', background: 'none', border: 0, cursor: 'pointer' }}>
      <span style={{ display: 'flex', height: 34, alignItems: 'center', gap: 6, padding: '0 10px 0 6px', borderRadius: 999, fontWeight: 600,
        background: waiting ? 'var(--accent)' : 'transparent', color: waiting ? 'var(--on-accent)' : 'var(--ink)', border: waiting ? 0 : '1px solid var(--border)' }}>
        <span style={{ fontSize: 18, lineHeight: 1, marginTop: -2 }}>‹</span><Inbox />
        <span style={{ fontFamily: 'var(--font-mono)', fontSize: 12.5 }}>{count}</span>
      </span>
    </button>
  );
}
