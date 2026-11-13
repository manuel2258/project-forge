import React from 'react';
export function Eyebrow({ children, tone }) {
  const c = { accent: 'var(--accent-text)', success: 'var(--success)', danger: 'var(--danger)' }[tone];
  return <span style={{ fontFamily: 'var(--font-mono)', fontSize: 'var(--text-eyebrow)', letterSpacing: 'var(--tracking-eyebrow)', textTransform: 'uppercase', color: c, opacity: c ? 1 : .55 }}>{children}</span>;
}
