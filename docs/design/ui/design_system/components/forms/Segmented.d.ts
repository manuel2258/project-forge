/** 2–4 short mutually exclusive options with equal widths (API access, effort, Admit as, sub-views). Never wraps; if labels don't fit, give it its own line. */
export interface SegmentedProps { options: string[]; value?: string; onChange?: (v: string) => void; size?: 'lg' | 'md' | 'sm' | 'xs'; }
export function Segmented(props: SegmentedProps): JSX.Element;
