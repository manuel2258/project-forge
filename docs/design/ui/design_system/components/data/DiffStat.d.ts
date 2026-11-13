/** Size of a change: +added −removed, optional ratio bar and file count. */
export interface DiffStatProps { added?: number; removed?: number; files?: number; bar?: boolean; }
export function DiffStat(props: DiffStatProps): JSX.Element;
