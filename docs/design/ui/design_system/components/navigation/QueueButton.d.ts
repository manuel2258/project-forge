/** The fixed left slot of every phone top bar: always returns to the queue, shows how many decisions wait. Amber when > 0. */
export interface QueueButtonProps { count?: number; onClick?: () => void; }
export function QueueButton(props: QueueButtonProps): JSX.Element;
