import React from 'react';
import { Button } from '../actions/Button.jsx';
import { Notice } from '../feedback/Notice.jsx';

export function DropPanel({ title, body, warning, children, secondary, secondaryVariant = 'secondary', primary, primaryVariant = 'decision', onSecondary, onPrimary, onClose, scrim = true }) {
  return (
    <>
      {scrim && <div onClick={onClose} style={{ position: 'absolute', top: '100%', left: 0, right: 0, height: 2000, background: 'var(--overlay-soft)' }} />}
      <div style={{ position: 'absolute', top: '100%', left: 0, right: 0, zIndex: 'var(--z-panel)', display: 'flex', flexDirection: 'column', gap: 12, padding: 16, background: 'var(--surface-1)', borderBottom: '1px solid var(--border)', borderRadius: '0 0 var(--radius-panel) var(--radius-panel)', boxShadow: 'var(--shadow-panel)' }}>
        {(title || body) && <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
          {title && <span style={{ fontSize: 16, fontWeight: 600 }}>{title}</span>}
          {body && <span style={{ fontSize: 13, lineHeight: 1.5, opacity: .7 }}>{body}</span>}
        </div>}
        {warning && <Notice tone="accent" title={warning.title}>{warning.body}</Notice>}
        {children}
        {(secondary || primary) && <div style={{ display: 'flex', gap: 8 }}>
          {secondary && <Button variant={secondaryVariant} size="lg" onClick={onSecondary}>{secondary}</Button>}
          {primary && <Button variant={primaryVariant} size="lg" fill diamond={false} onClick={onPrimary}>{primary}</Button>}
        </div>}
      </div>
    </>
  );
}
