import React from 'react';
export function Field({ label, value, placeholder, hint, error, mono = false, multiline = false, rows = 4, onChange, desktop = false }) {
  const s = { width: '100%', boxSizing: 'border-box', minHeight: desktop ? 34 : 48, padding: multiline ? 12 : (desktop ? '0 10px' : '0 12px'), border: '1px solid ' + (error ? 'var(--danger)' : 'var(--border)'),
    borderRadius: desktop ? 'var(--radius-sm)' : 'var(--radius)', background: 'transparent', color: 'var(--ink)', fontFamily: mono ? 'var(--font-mono)' : 'var(--font-sans)', fontSize: desktop ? 13 : 14, lineHeight: 1.5, outline: 'none', resize: 'vertical' };
  return (
    <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
      {label && <span style={{ fontSize: desktop ? 12.5 : 13, opacity: .7 }}>{label}</span>}
      {multiline ? <textarea rows={rows} value={value} placeholder={placeholder} onChange={onChange} style={s} /> : <input value={value} placeholder={placeholder} onChange={onChange} style={s} />}
      {error ? <span style={{ fontSize: 13, color: 'var(--danger)' }}>{error}</span> : hint && <span style={{ fontSize: 12.5, lineHeight: 1.45, opacity: .6 }}>{hint}</span>}
    </label>
  );
}
