/** Usage hairline. 5h (3px) caps the top bar, week (2px) replaces its bottom border. Yellow ≥80%, red ≥95%, never amber. Tap opens the usage panel. */
export interface UsageLineProps { percent?: number; window?: '5h' | 'week'; onClick?: () => void; }
export function UsageLine(props: UsageLineProps): JSX.Element;
