import React from 'react';
export function Toast({ title, detail, tone = 'success', bottom = 84 }) {
  const c = { success: 'oklch(72% 0.120 150)', danger: 'oklch(72% 0.170 22)', info: 'oklch(72% 0.100 240)' }[tone];
  const icon = { success: '✓', danger: '!', info: 'i' }[tone];
  return (
    <div role="status" style={{ position: 'absolute', left: '50%', bottom, transform: 'translateX(-50%)', zIndex: 'var(--z-toast)', pointerEvents: 'none', display: 'flex', alignItems: 'center', gap: 12, width: 372, maxWidth: 'calc(100% - 40px)', boxSizing: 'border-box', padding: '12px 18px 12px 14px', borderRadius: 999, background: 'var(--toast-bg)', color: 'var(--toast-ink)', boxShadow: 'var(--shadow-toast)' }}>
      <span style={{ display: 'flex', width: 22, height: 22, flexShrink: 0, alignItems: 'center', justifyContent: 'center', borderRadius: 999, background: c, color: 'var(--toast-bg)', fontSize: 12, fontWeight: 700 }}>{icon}</span>
      <span style={{ display: 'flex', flexDirection: 'column', gap: 1, minWidth: 0 }}>
        <span style={{ fontSize: 13.5, fontWeight: 500 }}>{title}</span>
        {detail && <span style={{ fontFamily: 'var(--font-mono)', fontSize: 11, opacity: .7 }}>{detail}</span>}
      </span>
    </div>
  );
}
