import * as React from 'react';
/**
 * The single overlay pattern: drops from the bar it belongs to (title menu, object details, decision confirmation, usage). Full width on phone, scrim below, nothing underneath moves.
 * Render inside a position:relative bar (TopBar wrapper or DecisionRow).
 */
export interface DropPanelProps {
  title?: React.ReactNode; body?: React.ReactNode;
  /** Consequence warning, e.g. { title: '1 open question will stay unanswered', body: '…' } */
  warning?: { title: React.ReactNode; body?: React.ReactNode };
  children?: React.ReactNode;
  secondary?: string; secondaryVariant?: 'secondary' | 'danger' | 'quiet';
  primary?: string; primaryVariant?: 'decision' | 'primary' | 'neutral';
  onSecondary?: () => void; onPrimary?: () => void; onClose?: () => void; scrim?: boolean;
}
export function DropPanel(props: DropPanelProps): JSX.Element;
