/** Passing confirmation after an action. Floats above the strip, no buttons, pointer-events none, 4s. Never used for errors that need action and never in the decision row's place. */
export interface ToastProps { title: string; detail?: string; tone?: 'success' | 'info' | 'danger'; bottom?: number; }
export function Toast(props: ToastProps): JSX.Element;
