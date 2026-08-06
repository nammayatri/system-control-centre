import React, { useState } from 'react';
import { Search } from 'lucide-react';
import { Badge } from '../../../shared/ui/badge';
import { cn } from '../../../lib/utils';
import type { RolloutEvent } from '../api';

// Format in Asia/Kolkata so dashboard users worldwide see the same timestamps as on-call India.
const formatDate = (d?: string) => {
  if (!d) return '-';
  const date = new Date(d);
  if (isNaN(date.getTime())) return '-';
  return date.toLocaleString('en-IN', {
    timeZone: 'Asia/Kolkata',
    month: 'short',
    day: '2-digit',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    hour12: true,
  }) + ' IST';
};

const tryFormatJson = (data: string): string => {
  try { return JSON.stringify(JSON.parse(data), null, 2); }
  catch { return data; }
};

// A GitHub run/job URL carried in the event payload (MATRIX_JOB_UPDATED's
// html_url, dispatch events' run urls) — rendered as a direct CI link.
const ghUrlOf = (data?: string): string | null => {
  if (!data) return null;
  try {
    const d = JSON.parse(data) as Record<string, unknown>;
    const u = d.html_url ?? d.github_run_url ?? d.run_url ?? d.expected_run_url ?? d.gh_run_url;
    return typeof u === 'string' && u.startsWith('http') ? u : null;
  } catch {
    return null;
  }
};

export const ReleaseEventsTab: React.FC<{ events: RolloutEvent[] }> = ({ events }) => {
  const [expandedRows, setExpandedRows] = useState<Set<number>>(new Set());
  const [eventSearch, setEventSearch] = useState('');

  const toggleRow = (idx: number) => {
    setExpandedRows(prev => { const next = new Set(prev); if (next.has(idx)) next.delete(idx); else next.add(idx); return next; });
  };

  const sorted = [...events]
    .sort((a, b) => b.timestamp.localeCompare(a.timestamp))
    .filter(e => !eventSearch || e.label?.toLowerCase().includes(eventSearch.toLowerCase()) || e.category?.toLowerCase().includes(eventSearch.toLowerCase()) || e.data?.toLowerCase().includes(eventSearch.toLowerCase()));

  return (
    <div className="p-4 sm:p-6">
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 mb-4">
        <h3 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider">Release Events</h3>
        <div className="relative">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-zinc-400" />
          <input type="text" placeholder="Filter events..." value={eventSearch} onChange={(e) => setEventSearch(e.target.value)}
            className="pl-8 pr-3 h-10 sm:h-9 border border-zinc-300 rounded-lg text-sm w-full sm:w-56 focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150" />
        </div>
      </div>
      {sorted.length > 0 ? (
        <div className="overflow-x-auto -mx-4 sm:mx-0">
          <table className="w-full text-sm text-left border-collapse">
            <thead>
              <tr className="bg-zinc-50 border-y border-zinc-200 text-[12px] text-zinc-500 font-medium uppercase tracking-wider">
                <th className="py-2 px-3 w-8"></th>
                <th className="py-2 px-3">#</th>
                <th className="py-2 px-3">Timestamp</th>
                <th className="py-2 px-3">Category</th>
                <th className="py-2 px-3">Label</th>
                <th className="py-2 px-3">Value</th>
              </tr>
            </thead>
            <tbody>
              {sorted.map((evt, idx) => (
                <React.Fragment key={idx}>
                  <tr className={cn('border-b border-zinc-100 cursor-pointer hover:bg-zinc-100 transition-colors duration-150', idx % 2 === 1 ? 'bg-zinc-50' : 'bg-white')} onClick={() => toggleRow(idx)}>
                    <td className="py-2 px-3 text-zinc-400"><span className={`inline-block transition-transform duration-200 text-xs ${expandedRows.has(idx) ? 'rotate-90' : ''}`}>&#9654;</span></td>
                    <td className="py-2 px-3 text-zinc-400 font-mono text-xs">{idx + 1}</td>
                    <td className="py-2 px-3 font-mono text-xs text-zinc-500 whitespace-nowrap">{formatDate(evt.timestamp)}</td>
                    <td className="py-2 px-3">
                      <Badge variant={evt.category === 'BUSINESS' ? 'info' : evt.category === 'DECISION_ENGINE' ? 'purple' : evt.category === 'NOTIFICATION' ? 'success' : 'default'} size="sm">
                        {evt.category}
                      </Badge>
                    </td>
                    <td className="py-2 px-3 font-mono text-xs">{evt.label}</td>
                    <td className="py-2 px-3 text-xs text-zinc-500 max-w-xs">
                      <span className="flex items-center gap-2">
                        <span className="truncate" title={evt.data}>
                          {evt.data?.slice(0, 40)}
                          {(evt.data?.length || 0) > 40 ? '...' : ''}
                        </span>
                        {ghUrlOf(evt.data) && (
                          <a
                            href={ghUrlOf(evt.data)!}
                            target="_blank"
                            rel="noreferrer"
                            onClick={(e) => e.stopPropagation()}
                            className="text-blue-600 font-bold hover:underline shrink-0 whitespace-nowrap"
                            title="Open the GitHub workflow run/job"
                          >
                            CI ↗
                          </a>
                        )}
                      </span>
                    </td>
                  </tr>
                  {expandedRows.has(idx) && (
                    <tr className="border-b border-zinc-100 bg-zinc-50">
                      <td colSpan={6} className="px-6 py-3">
                        <pre className="text-xs font-mono bg-zinc-50 text-zinc-800 border border-zinc-200 p-4 rounded-lg overflow-x-auto max-h-60 whitespace-pre-wrap break-all">{tryFormatJson(evt.data)}</pre>
                      </td>
                    </tr>
                  )}
                </React.Fragment>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        <p className="text-sm text-zinc-400">No events recorded.</p>
      )}
    </div>
  );
};
