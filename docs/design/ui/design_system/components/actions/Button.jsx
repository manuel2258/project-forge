import React from 'react';

const SIZES = { xl: 52, lg: 48, md: 42, sm: 36, desk: 34, 'desk-sm': 28 };

export function Button({ variant = 'primary', size = 'xl', fill = false, chevron = false, diamond, disabled = false, onClick, children, style }) {
  const h = SIZES[size] || 52;
  const desk = size === 'desk' || size === 'desk-sm';
  const base = {
    display: 'flex', alignItems: 'center', justifyContent: chevron ? 'space-between' : 'center', gap: 6,
    height: h, boxSizing: 'border-box', padding: chevron ? '0 16px' : (desk ? '0 12px' : '0 14px'),
    borderRadius: desk ? 'var(--radius-sm)' : 'var(--radius)', border: '1px solid transparent',
    fontFamily: 'var(--font-sans)', fontSize: size === 'xl' || size === 'lg' ? 14 : 13, fontWeight: 500,
    whiteSpace: 'nowrap', cursor: disabled ? 'default' : 'pointer', flex: fill ? 1 : undefined,
    background: 'transparent', color: 'var(--ink)', opacity: disabled ? 0.45 : 1,
  };
  const v = {
    primary: { background: 'var(--ink)', color: 'var(--bg)' },
    decision: { background: 'var(--accent)', color: 'var(--on-accent)', fontWeight: 600 },
    'decision-open': { borderColor: 'var(--accent)', color: 'var(--accent-text)', fontWeight: 600 },
    outline: { borderColor: 'var(--ink)' },
    secondary: { borderColor: 'var(--border)' },
    neutral: { borderColor: 'var(--ink-3)' },
    danger: { borderColor: 'var(--danger-line)', color: 'var(--danger)' },
    quiet: { color: 'var(--ink-2)', padding: '0 12px' },
    link: { color: 'var(--link)', padding: '0 8px', height: Math.min(h, 44) },
  }[variant] || {};
  const showDiamond = diamond ?? (variant === 'decision' || variant === 'decision-open');
  return (
    <button type="button" disabled={disabled} onClick={onClick} style={{ ...base, ...v, ...style }}>
      {showDiamond && <span style={{ fontSize: 9 }}>◆</span>}
      <span>{children}</span>
      {chevron && <span aria-hidden="true">›</span>}
    </button>
  );
}
