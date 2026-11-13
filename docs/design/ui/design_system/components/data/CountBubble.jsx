import React from 'react';
export function CountBubble({ value, tone = 'neutral' }) {
  const acc = tone === 'accent';
  return <span style={{ minWidth: 18, height: 18, boxSizing: 'border-box', padding: '0 5px', borderRadius: 999, background: acc ? 'var(--accent)' : 'var(--chip)', color: acc ? 'var(--on-accent)' : 'var(--ink)', fontFamily: 'var(--font-mono)', fontSize: 10.5, fontWeight: acc ? 600 : 500, lineHeight: '18px', textAlign: 'center' }}>{value}</span>;
}
