import * as React from 'react';
/** The list row for tickets, chats, machines, templates, queue items: optional kicker, title, mono meta line, latest event. edge marks waiting (accent) or broken (danger). */
export interface ListRowProps {
  title: React.ReactNode; kicker?: React.ReactNode; meta?: React.ReactNode; latest?: React.ReactNode;
  latestTone?: 'warning' | 'danger' | 'info'; edge?: 'accent' | 'danger' | 'ink'; selected?: boolean; trailing?: React.ReactNode; onClick?: () => void;
}
export function ListRow(props: ListRowProps): JSX.Element;
