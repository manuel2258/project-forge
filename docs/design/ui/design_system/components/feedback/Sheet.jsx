import React from 'react';
export function Sheet({ title, children, onClose }) {
  return (
    <>
      <div onClick={onClose} style={{ position: 'absolute', inset: 0, background: 'var(--overlay)', zIndex: 'var(--z-panel)' }} />
      <div style={{ position: 'absolute', left: 0, right: 0, bottom: 0, zIndex: 'var(--z-panel)', boxSizing: 'border-box', background: 'var(--bg)', borderTop: '1px solid var(--border)', borderRadius: 'var(--radius-panel) var(--radius-panel) 0 0', padding: '8px 20px 16px', display: 'flex', flexDirection: 'column', gap: 12 }}>
        <div style={{ margin: '0 auto 2px', width: 40, height: 4, borderRadius: 999, background: 'var(--border)' }} />
        {title && <span style={{ fontSize: 16, fontWeight: 600 }}>{title}</span>}
        {children}
      </div>
    </>
  );
}
