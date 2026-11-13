/**
 * Views of the current object (Steps · Changes · Docs · Activity; Tickets · Merge · Chats · Workflow · Proposals). Equal-width tabs with grey count bubbles. Navigation only: never a decision, never amber.
 * @startingPoint section="Navigation" subtitle="Bottom view strip" viewport="412x60"
 */
export interface BottomStripProps { tabs: { label: string; count?: number | string }[]; active?: string; onSelect?: (label: string) => void; }
export function BottomStrip(props: BottomStripProps): JSX.Element;
