/** Reply composer, 64px. Send is an icon inside the field, never a filled button, so a message never looks like a decision. interrupt names the cost while the agent is responding. */
export interface ComposerProps { placeholder?: string; value?: string; onChange?: (e: any) => void; onSend?: () => void; interrupt?: boolean; }
export function Composer(props: ComposerProps): JSX.Element;
