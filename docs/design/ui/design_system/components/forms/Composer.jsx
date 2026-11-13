import React from 'react';
const Up = () => <svg width="18" height="18" viewBox="0 0 18 18" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d="M9 14V4M4.5 8.5 9 4l4.5 4.5" /></svg>;
export function Composer({ placeholder = 'Reply to the agent', value, onChange, onSend, interrupt = false }) {
  return (
    <div style={{ flexShrink: 0, height: 'var(--bar-composer)', boxSizing: 'border-box', display: 'flex', alignItems: 'center', padding: '0 12px', borderTop: '1px solid var(--border)' }}>
      <div style={{ flex: 1, display: 'flex', alignItems: 'center', gap: 8, height: 48, boxSizing: 'border-box', border: '1px solid var(--border)', borderRadius: 24, padding: '0 4px 0 16px' }}>
        <input value={value} onChange={onChange} placeholder={placeholder} style={{ flex: 1, minWidth: 0, border: 0, background: 'none', outline: 'none', color: 'var(--ink)', fontFamily: 'var(--font-sans)', fontSize: 14 }} />
        {interrupt
          ? <button type="button" onClick={onSend} style={{ height: 40, padding: '0 12px', borderRadius: 20, border: '1px solid var(--border)', background: 'none', color: 'var(--ink)', fontSize: 12.5 }}>Interrupt and send</button>
          : <button type="button" aria-label="Send" onClick={onSend} style={{ display: 'flex', width: 40, height: 40, alignItems: 'center', justifyContent: 'center', borderRadius: 999, border: '1px solid var(--border)', background: 'none', color: 'var(--ink)', opacity: .7 }}><Up /></button>}
      </div>
    </div>
  );
}
