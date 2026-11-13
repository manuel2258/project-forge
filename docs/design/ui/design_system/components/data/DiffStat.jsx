import React from 'react';
export function DiffStat({ added = 0, removed = 0, files, bar = false }) {
  const t = added + removed || 1;
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 8, fontFamily: 'var(--font-mono)', fontSize: 12.5 }}>
      <span style={{ color: 'var(--success)' }}>+{added}</span><span style={{ color: 'var(--danger)' }}>−{removed}</span>
      {bar && <span style={{ display: 'flex', width: 80, height: 6, borderRadius: 999, overflow: 'hidden', background: 'var(--border)' }}><span style={{ width: (added / t * 100) + '%', background: 'var(--success)' }} /><span style={{ width: (removed / t * 100) + '%', background: 'var(--danger)' }} /></span>}
      {files != null && <span style={{ opacity: .55 }}>· {files} files</span>}
    </span>
  );
}
