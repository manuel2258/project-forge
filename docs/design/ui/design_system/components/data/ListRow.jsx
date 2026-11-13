import React from 'react';
export function ListRow({ title, kicker, meta, latest, latestTone, edge, selected, trailing, onClick }) {
  const tone = { warning: 'var(--warning)', danger: 'var(--danger)', info: 'var(--info)' }[latestTone];
  return (
    <div onClick={onClick} style={{ display: 'flex', gap: 10, alignItems: 'flex-start', padding: '13px 12px 13px 10px', borderBottom: '1px solid var(--border-soft)', cursor: onClick ? 'pointer' : undefined,
      boxShadow: edge ? 'inset 2px 0 0 ' + (edge === 'accent' ? 'var(--accent)' : edge === 'danger' ? 'var(--danger)' : 'var(--ink)') : undefined, background: selected ? 'var(--surface-selected)' : undefined }}>
      <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 4 }}>
        {kicker && <div style={{ fontFamily: 'var(--font-mono)', fontSize: 10.5, letterSpacing: '.12em', textTransform: 'uppercase', opacity: .7 }}>{kicker}</div>}
        <span style={{ fontSize: 14.5, fontWeight: 500, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{title}</span>
        {meta && <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontFamily: 'var(--font-mono)', fontSize: 11.5 }}>{meta}</div>}
        {latest && <span style={{ fontSize: 13, lineHeight: 1.45, color: tone, opacity: tone ? 1 : .65, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{latest}</span>}
      </div>
      {trailing !== undefined ? trailing : <span style={{ opacity: .4, alignSelf: 'center' }}>›</span>}
    </div>
  );
}
