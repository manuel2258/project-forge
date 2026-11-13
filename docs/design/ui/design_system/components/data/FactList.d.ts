/** Key/value facts for details panels and desktop rails. Values in mono. Optional tone per fact: warning | danger | success | info. */
export interface FactListProps { facts: [string, React.ReactNode, ('warning' | 'danger' | 'success' | 'info')?][]; dense?: boolean; }
export function FactList(props: FactListProps): JSX.Element;
