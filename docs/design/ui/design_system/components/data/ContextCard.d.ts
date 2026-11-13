/**
 * The ticket an item is about: id, title, type, workflow track, and the facts that set the stakes. Opens every queue item.
 * @startingPoint section="Data" subtitle="Ticket context card" viewport="412x140"
 */
export interface ContextCardProps { id: string; title: string; type?: string; steps?: string[]; current?: number; next?: number; facts?: string[]; }
export function ContextCard(props: ContextCardProps): JSX.Element;
