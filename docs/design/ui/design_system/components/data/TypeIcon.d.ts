/** 26px tinted square that names an object's kind: doc (md), changeset (±), branch (⑂), release (⇡), error (⌁). Lead decision rows and file lists with it. */
export interface TypeIconProps { kind?: 'doc' | 'changeset' | 'branch' | 'release' | 'error'; label?: string; }
export function TypeIcon(props: TypeIconProps): JSX.Element;
