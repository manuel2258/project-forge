import * as React from 'react';
/**
 * The only place a decision lives: a row pinned under the top bar, on the page that shows the thing being decided.
 * Amber when it waits on the person (Approve, Accept); neutral when it does not (Merge a chat). Appears only once the decision exists.
 * Its button opens a DropPanel (pass as children) with the consequence and the secondary act (Reject, Answer first).
 * @startingPoint section="Decisions" subtitle="Pinned approval row" viewport="412x80"
 */
export interface DecisionRowProps {
  kind?: 'doc' | 'changeset' | 'branch' | 'release';
  /** Object and key facts in mono, e.g. "changeset v1 +48 −6". */
  title: React.ReactNode;
  /** e.g. "✓ check 21s · review → merging". */
  meta?: React.ReactNode;
  action?: string;
  tone?: 'accent' | 'neutral';
  open?: boolean;
  onToggle?: () => void;
  desktop?: boolean;
  /** The DropPanel shown while open. */
  children?: React.ReactNode;
}
export function DecisionRow(props: DecisionRowProps): JSX.Element;
