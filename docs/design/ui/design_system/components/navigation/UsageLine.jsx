import React from 'react';

export function usageColor(p, dim) {
  if (p >= 95) return 'var(--danger)';
  if (p >= 80) return 'var(--warning)';
  return dim ? 'oklch(94% 0.004 300 / .45)' : 'oklch(94% 0.004 300 / .6)';
}

export function UsageLine({ percent = 0, window = '5h', onClick }) {
  const week = window === 'week';
  return (
    <div onClick={onClick} role="meter" aria-valuenow={percent} aria-valuemin={0} aria-valuemax={100} aria-label={(week ? 'Weekly' : '5-hour') + ' usage'}
      style={{ flexShrink: 0, height: week ? 'var(--usage-week)' : 'var(--usage-5h)', background: 'var(--track)', cursor: onClick ? 'pointer' : undefined }}>
      <div style={{ height: '100%', width: Math.min(100, percent) + '%', background: percent >= 80 ? usageColor(percent) : (week ? 'color-mix(in oklch, var(--ink) 45%, transparent)' : 'color-mix(in oklch, var(--ink) 60%, transparent)') }} />
    </div>
  );
}
