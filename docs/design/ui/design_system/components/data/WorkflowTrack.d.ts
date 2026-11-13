/** Where a ticket is in its workflow: done 50% ink, current amber, the step this decision leads to 30%, the rest 12%. compact = 8px ticks for list rows. */
export interface WorkflowTrackProps { steps: string[]; current: number; next?: number; compact?: boolean; }
export function WorkflowTrack(props: WorkflowTrackProps): JSX.Element;
