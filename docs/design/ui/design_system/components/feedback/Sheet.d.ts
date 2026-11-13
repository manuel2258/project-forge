/** Bottom sheet, only for things opened from the bottom of the screen ("+ New", "All items", workflow map). Things opened from a bar use DropPanel. */
export interface SheetProps { title?: React.ReactNode; children?: React.ReactNode; onClose?: () => void; }
export function Sheet(props: SheetProps): JSX.Element;
