import { AlertTriangle, XCircle } from 'lucide-react';
import type { Issue } from './types';

/** Validation findings, errors first. Each row names the manifest path it is about. */
export function IssueList({ issues }: { issues: Issue[] }) {
  const sorted = [...issues].sort((a, b) => Number(b.severity === 'error') - Number(a.severity === 'error'));
  if (sorted.length === 0) return null;
  return (
    <ul className="space-y-1.5">
      {sorted.map((i, n) => {
        const isErr = i.severity === 'error';
        return (
          <li key={n} className={`flex gap-2 rounded-lg border px-3 py-2 text-sm ${isErr ? 'border-red-200 bg-red-50 text-red-800' : 'border-amber-200 bg-amber-50 text-amber-800'}`}>
            {isErr ? <XCircle className="mt-0.5 h-4 w-4 shrink-0" /> : <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />}
            <div className="min-w-0">
              <div>{i.message}</div>
              {i.path && <div className="mt-0.5 break-all font-mono text-[11px] opacity-70">{i.path}</div>}
            </div>
          </li>
        );
      })}
    </ul>
  );
}
