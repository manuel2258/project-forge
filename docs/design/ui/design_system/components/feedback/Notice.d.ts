/** Inline consequence or problem, inside the panel or page it concerns (open questions, does not merge cleanly). Not a toast; it stays. */
export interface NoticeProps { tone?: 'accent' | 'danger' | 'neutral'; title?: React.ReactNode; children?: React.ReactNode; }
export function Notice(props: NoticeProps): JSX.Element;
