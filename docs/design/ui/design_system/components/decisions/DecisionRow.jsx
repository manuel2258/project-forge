import React from 'react';
import { TypeIcon } from '../data/TypeIcon.jsx';
import { Button } from '../actions/Button.jsx';

export function DecisionRow({ kind = 'changeset', title, meta, action = 'Approve', tone = 'accent', open = false, onToggle, children, desktop = false }) {
  const edge = tone === 'accent' ? 'var(--accent)' : 'color-mix(in oklch, var(--ink) 50%, transparent)';
  return (
    <div style={{ flexShrink: 0, position: 'relative', zIndex: 'var(--z-row)' }}>
      <div style={{ display: 'flex', height: desktop ? 'var(--bar-decision-desk)' : 'var(--bar-decision)', boxSizing: 'border-box', alignItems: 'center', gap: 12, padding: desktop ? '0 var(--gutter-desk)' : '0 10px 0 16px',
        borderBottom: '1px solid var(--border)', boxShadow: 'inset 2px 0 0 ' + edge + ', var(--shadow-row)', background: 'var(--bg)' }}>
        <TypeIcon kind={kind} />
        <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 2 }}>
          <span style={{ fontFamily: 'var(--font-mono)', fontSize: 14, fontWeight: 500, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{title}</span>
          {meta && <span style={{ fontFamily: 'var(--font-mono)', fontSize: 11, opacity: .65, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{meta}</span>}
        </div>
        <Button size={desktop ? 'desk' : 'md'} variant={tone === 'accent' ? (open ? 'decision-open' : 'decision') : 'neutral'} onClick={onToggle}>{action}{open ? ' ▴' : ''}</Button>
      </div>
      {open && children}
    </div>
  );
}
