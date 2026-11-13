import React from 'react';
const K = { doc: ['md', 'var(--doc)'], changeset: ['±', 'var(--success)'], branch: ['⑂', 'var(--info)'], release: ['⇡', 'var(--success)'], error: ['⌁', 'var(--danger)'] };
export function TypeIcon({ kind = 'doc', label }) {
  const [t, c] = K[kind] || K.doc;
  return <span style={{ display: 'inline-flex', width: 26, height: 26, flexShrink: 0, alignItems: 'center', justifyContent: 'center', borderRadius: 6, color: c, background: 'color-mix(in oklch, ' + c + ' 16%, transparent)', fontFamily: 'var(--font-mono)', fontSize: (label || t).length > 1 ? 9.5 : 12 }}>{label || t}</span>;
}
