import React from 'react';
const MARK = { running: ['▸', 'var(--info)'], waiting: ['●', 'var(--accent-text)'], step: ['●', 'var(--link)'], done: ['✓', 'var(--success)'], failed: ['✗', 'var(--danger)'], stuck: ['●', 'var(--warning)'], idle: ['○', 'var(--ink-3)'] };
export function StateLabel({ state = 'step', children }) {
  const [m, c] = MARK[state] || MARK.step;
  return <span style={{ fontFamily: 'var(--font-mono)', fontSize: 11.5, whiteSpace: 'nowrap' }}><span style={{ color: c }}>{m}</span> {children}</span>;
}
