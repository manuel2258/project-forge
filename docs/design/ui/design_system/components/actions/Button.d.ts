import * as React from 'react';
/**
 * The one button. Filled ink = the next step. Amber = a decision that waits on you. Outline = navigates.
 * Never place two filled buttons next to each other.
 * @startingPoint section="Actions" subtitle="Primary, decision, outline, danger" viewport="700x260"
 */
export interface ButtonProps {
  /** primary: filled ink (the next step). decision: amber (waits on you). decision-open: amber outline while its panel is open. outline: navigates. secondary: bordered. neutral: decision that does not wait on you. danger: destructive. quiet: text-only. link: inline link. */
  variant?: 'primary' | 'decision' | 'decision-open' | 'outline' | 'secondary' | 'neutral' | 'danger' | 'quiet' | 'link';
  /** xl 52 (phone primary) · lg 48 · md 42 (decision row) · sm 36 · desk 34 · desk-sm 28 */
  size?: 'xl' | 'lg' | 'md' | 'sm' | 'desk' | 'desk-sm';
  /** Grow to fill the row (use for the one primary in a dock). */
  fill?: boolean;
  /** Trailing › for actions that move somewhere ("Review the changeset ›"). */
  chevron?: boolean;
  /** Leading ◆. Defaults on for decision variants. */
  diamond?: boolean;
  /** Keeps size and place; never hide a disabled action. */
  disabled?: boolean;
  onClick?: () => void;
  children?: React.ReactNode;
  style?: React.CSSProperties;
}
export function Button(props: ButtonProps): JSX.Element;
