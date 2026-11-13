/** Small integer input (days, max machines, idle minutes). */
export interface StepperProps { value?: number; min?: number; max?: number; desktop?: boolean; onChange?: (v: number) => void; }
export function Stepper(props: StepperProps): JSX.Element;
