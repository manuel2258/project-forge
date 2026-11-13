/** Count in a tab or nav item. Neutral grey by default; accent only for counts of things that wait on the person (the queue). */
export interface CountBubbleProps { value: number | string; tone?: 'neutral' | 'accent'; }
export function CountBubble(props: CountBubbleProps): JSX.Element;
