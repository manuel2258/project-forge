/** Text field with label above, hint or error below. Errors stay under the field they belong to, in the server's words. */
export interface FieldProps { label?: string; value?: string; placeholder?: string; hint?: string; error?: string; mono?: boolean; multiline?: boolean; rows?: number; desktop?: boolean; onChange?: (e: any) => void; }
export function Field(props: FieldProps): JSX.Element;
