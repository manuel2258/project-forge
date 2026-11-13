import React from 'react';
export function Stepper({ value = 0, min = 0, max = 999, onChange, desktop = false }) {
  const h = desktop ? 32 : 44, w = desktop ? 30 : 44;
  const b = { width: w, height: '100%', border: 0, background: 'none', color: 'var(--ink)', opacity: .7, fontSize: desktop ? 14 : 18, cursor: 'pointer' };
  return (
    <div style={{ display: 'inline-flex', height: h, boxSizing: 'border-box', alignItems: 'center', border: '1px solid var(--border)', borderRadius: desktop ? 'var(--radius-sm)' : 'var(--radius)' }}>
      <button type="button" style={b} onClick={() => onChange && onChange(Math.max(min, value - 1))}>−</button>
      <span style={{ minWidth: desktop ? 30 : 40, textAlign: 'center', fontFamily: 'var(--font-mono)', fontSize: desktop ? 13 : 14 }}>{value}</span>
      <button type="button" style={b} onClick={() => onChange && onChange(Math.min(max, value + 1))}>+</button>
    </div>
  );
}
