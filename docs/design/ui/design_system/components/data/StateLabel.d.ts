/** Mono state with its mark: ▸ running (info blue), ● waiting on you (amber), ● workflow step (link), ✓ done, ✗ failed, ● stuck (warning), ○ idle. */
export interface StateLabelProps { state?: 'running' | 'waiting' | 'step' | 'done' | 'failed' | 'stuck' | 'idle'; children: React.ReactNode; }
export function StateLabel(props: StateLabelProps): JSX.Element;
