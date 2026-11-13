import * as React from 'react';
/**
 * Phone top bar, 52px, framed by the two usage lines. Left: queue. Middle: title + mono state subline. Right: the context object ("game ›").
 * Top-level pages pass menu to show ▾ (opens the navigation drop panel). Inner pages: tapping the title drops the object's details.
 * @startingPoint section="Navigation" subtitle="Top bar with usage lines" viewport="412x80"
 */
export interface TopBarProps {
  title: React.ReactNode;
  /** Mono state line, e.g. <><span style={{color:'var(--info)'}}>▸</span> implementing</> */
  subline?: React.ReactNode;
  queueCount?: number;
  /** The parent object shown on the right, e.g. "game". */
  context?: string;
  /** Show ▾ / ▴ after the title. */
  menu?: boolean;
  menuOpen?: boolean;
  onTitle?: () => void;
  /** Usage windows in percent; pass null to hide on modal screens. */
  usage?: { fiveH: number; week: number } | null;
  /** Disconnected: bar turns red-hatched; pass the countdown text, e.g. "retrying in 4s". */
  disconnected?: false | string;
  left?: React.ReactNode;
  right?: React.ReactNode;
}
export function TopBar(props: TopBarProps): JSX.Element;
