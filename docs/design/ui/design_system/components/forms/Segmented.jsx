import React from 'react';
export function Segmented({ options = [], value, onChange, size = 'lg' }) {
  const h = { lg: 44, md: 40, sm: 32, xs: 28 }[size] || 44;
  return (
    <div role="radiogroup" style={{ display: 'flex', height: h, boxSizing: 'border-box', border: '1px solid var(--border)', borderRadius: 'var(--radius)', padding: 3, gap: 3, fontSize: size === 'lg' ? 13 : 12.5 }}>
      {options.map(o => { const on = o === value; return (
        <button key={o} type="button" role="radio" aria-checked={on} onClick={() => onChange && onChange(o)} style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', whiteSpace: 'nowrap', border: 0, borderRadius: 4, cursor: 'pointer', fontFamily: 'var(--font-sans)', fontSize: 'inherit', color: 'var(--ink)', background: on ? 'var(--surface-2)' : 'transparent', fontWeight: on ? 500 : 400, opacity: on ? 1 : .6 }}>{o}</button>
      ); })}
    </div>
  );
}
