import React from 'react';
export function Notice({ tone = 'accent', title, children }) {
  const c = { accent: ['var(--accent-line)', 'var(--accent-wash)', 'var(--accent-text)'], danger: ['var(--danger-line)', 'var(--danger-wash)', 'var(--danger)'], neutral: ['var(--border)', 'var(--surface-1)', 'var(--ink)'] }[tone];
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 6, padding: '12px 14px', borderRadius: 'var(--radius-card)', border: '1px solid ' + c[0], background: c[1] }}>
      {title && <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        {tone === 'accent' && <span style={{ width: 8, height: 8, transform: 'rotate(45deg)', background: 'var(--accent)' }} />}
        <span style={{ fontSize: 14, fontWeight: 500, color: c[2] }}>{title}</span>
      </div>}
      {children && <div style={{ fontSize: 13, lineHeight: 1.5, opacity: .85 }}>{children}</div>}
    </div>
  );
}
