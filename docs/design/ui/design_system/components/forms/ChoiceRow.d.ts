/** A visible choice: answers, ways forward, git scope, model fallbacks. 52px with detail, 46 without, 32 on desktop. Use a Select instead when the set is large (models). */
export interface ChoiceRowProps { label: string; detail?: string; selected?: boolean; recommended?: boolean; multi?: boolean; desktop?: boolean; onClick?: () => void; }
export function ChoiceRow(props: ChoiceRowProps): JSX.Element;
