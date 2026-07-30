// Created-date display for the v4 summary page: compact date in the UI
// ("27 Jul 2026"), exact date+time on hover.

export const shortDate = (iso: string): string => {
  const d = new Date(iso);
  if (isNaN(d.getTime())) return '';
  return d.toLocaleDateString('en-IN', { day: '2-digit', month: 'short', year: 'numeric' });
};

/** Full "27 Jul 2026, 16:50" stamp — pair as the `title` of a shortDate. */
export const fullStamp = (iso: string): string => {
  const d = new Date(iso);
  if (isNaN(d.getTime())) return '';
  return d.toLocaleString('en-IN', {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
};
