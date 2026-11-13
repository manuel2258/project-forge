import React from 'react';
export function ChoiceRow({ label, detail, selected = false, recommended = false, multi = false, onClick, desktop = false }) {
  const mark = multi
    ? <span style={{ width: 16, height: 16, boxSizing: 'border-box', flexShrink: 0, borderRadius: 4, background: selected ? 'var(--link)' : 'transparent', border: selected ? 0 : '1.5px solid var(--border-strong)', display: 'flex', alignItems: 'center', justifyContent: 'center', color: 'var(--bg)', fontSize: 11, fontWeight: 700 }}>{selected ? '✓' : ''}</span>
    : <span style={{ width: desktop ? 12 : 16, height: desktop ? 12 : 16, boxSizing: 'border-box', flexShrink: 0, borderRadius: 999, border: selected ? (desktop ? 4 : 5) + 'px solid var(--link)' : '1px solid var(--border-strong)' }} />;
  return (
    <button type="button" onClick={onClick} style={{ display: 'flex', width: '100%', minHeight: desktop ? 32 : (detail ? 52 : 46), boxSizing: 'border-box', alignItems: 'center', gap: desktop ? 10 : 12, textAlign: 'left', cursor: 'pointer',
      borderRadius: desktop ? 'var(--radius-sm)' : 'var(--radius)', border: '1px solid ' + (selected ? 'var(--link)' : 'var(--border)'), background: selected ? 'var(--surface-2)' : 'transparent', padding: desktop ? '0 10px' : '8px 14px', color: 'var(--ink)', fontFamily: 'var(--font-sans)' }}>
      {mark}
      <span style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 2 }}>
        <span style={{ fontSize: desktop ? 13 : 14, fontWeight: 500 }}>{label}</span>
        {detail && <span style={{ fontSize: 12.5, lineHeight: 1.45, opacity: .65 }}>{detail}</span>}
      </span>
      {recommended && <span style={{ fontFamily: 'var(--font-mono)', fontSize: 10.5, letterSpacing: '.12em', textTransform: 'uppercase', border: '1px solid color-mix(in oklch, var(--ink) 30%, transparent)', borderRadius: 5, padding: '0 4px', opacity: .6 }}>recommended</span>}
    </button>
  );
}
