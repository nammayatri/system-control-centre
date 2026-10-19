import { ArrowRight } from 'lucide-react';
import { metricLabel, summaryLines } from '../format';
import type { HpaChange, HpaSpec } from '../types';
import { metricKey } from './ChangeForm';

/** A plain "what will happen" box, shown instantly (before the server preview comes back). */
export default function ChangeSummary({ change, reference, when }: { change: HpaChange; reference: HpaSpec | null; when?: string }) {
  const lines = summaryLines(change, reference, metricKey);
  if (lines.length === 0) {
    return (
      <div className="rounded-lg border border-dashed border-zinc-300 bg-zinc-50 px-3 py-3 text-xs text-zinc-600">
        Nothing to change yet. Fill in at least one box above, for example <b>Maximum pods</b>.
      </div>
    );
  }
  return (
    <div className="rounded-lg border border-sky-200 bg-sky-50 px-4 py-3 text-sm text-sky-950">
      <div className="mb-1 text-xs font-semibold uppercase tracking-wide text-sky-700">What will happen</div>
      {when && <div className="mb-1">{when}</div>}
      <ul className="space-y-0.5">
        {lines.map((l) => {
          const [name, vals] = l.split(': ');
          return (
            <li key={l} className="flex flex-wrap items-center gap-1.5">
              <span className="font-medium">{name}</span>
              {vals && <span className="inline-flex items-center gap-1.5 font-mono text-xs">{vals.split(' → ').map((v, i) => (
                <span key={i} className="inline-flex items-center gap-1.5">{i > 0 && <ArrowRight className="h-3 w-3" />}{v}</span>
              ))}</span>}
            </li>
          );
        })}
      </ul>
      <div className="mt-2 text-xs text-sky-800">Everything else stays as it is, and the original values come back automatically when it ends.</div>
    </div>
  );
}

export { metricLabel };
