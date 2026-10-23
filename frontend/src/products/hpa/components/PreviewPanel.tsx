import { useEffect, useState } from 'react';
import { keepPreviousData, useQuery } from '@tanstack/react-query';
import { AlertTriangle, CheckCircle2 } from 'lucide-react';
import { Badge } from '../../../shared/ui/badge';
import { errorMessage, previewChange } from '../api';
import { fmtTime } from '../format';
import type { HpaChange, ScheduleKind } from '../types';
import { RoleBadge } from './Badges';
import DiffTable from './DiffTable';

function useDebounced<T>(v: T, ms: number): T {
  const [d, setD] = useState(v);
  useEffect(() => { const t = setTimeout(() => setD(v), ms); return () => clearTimeout(t); }, [v, ms]);
  return d;
}

export interface PreviewState {
  /** A preview for the current inputs has come back (not stale, not loading). */
  ready: boolean;
  /** Reasons the change cannot be saved; empty when it is fine. */
  blocking: string[];
  /** Every serving HPA already has these values. */
  allNoop: boolean;
}

interface Props {
  product: string; service: string; hpa?: string; change: HpaChange; kind?: ScheduleKind; kindProblems?: string[];
  onState?: (s: PreviewState) => void;
}

/** Live dry-run: what the change would do to each serving HPA, and every reason it would be refused. */
export default function PreviewPanel({ product, service, hpa, change, kind, kindProblems = [], onState }: Props) {
  const body = useDebounced({ product, service, hpa, change, kind }, 500);
  const empty = !change.minReplicas && !change.maxReplicas && !(change.metricTargets?.length) && !change.scaleUp && !change.scaleDown;
  const q = useQuery({
    queryKey: ['hpa', 'preview', JSON.stringify(body)],
    queryFn: () => previewChange(body),
    enabled: !empty && kindProblems.length === 0,
    retry: false,
    placeholderData: keepPreviousData,
    staleTime: 0,
  });

  const stale = JSON.stringify({ product, service, hpa, change, kind }) !== JSON.stringify(body);
  const settled = !empty && kindProblems.length === 0 && !stale && !q.isFetching;
  const blocking = q.isError ? [errorMessage(q.error)] : q.data?.blocking ?? [];
  const allNoop = !!q.data && q.data.targets.length > 0 && q.data.targets.every((t) => t.noop);
  useEffect(() => {
    onState?.({ ready: settled && (q.isError || !!q.data), blocking: kindProblems.length ? kindProblems : blocking, allNoop });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [settled, q.isError, q.data, kindProblems.join('|')]);

  if (empty) return <div className="rounded-lg bg-zinc-50 px-3 py-2 text-xs text-zinc-500">Fill in step 3 to see exactly what would happen.</div>;
  if (kindProblems.length) return <Problems items={kindProblems} />;
  if (q.isError) return <Problems items={[errorMessage(q.error)]} />;
  if (!q.data) return <div className="rounded-lg bg-zinc-50 px-3 py-2 text-xs text-zinc-500">Checking against the live HPA…</div>;
  const d = q.data;

  return (
    <div className={q.isFetching ? 'space-y-3 opacity-70' : 'space-y-3'}>
      {d.blocking.length > 0 ? <Problems items={d.blocking} /> : (
        <div className="flex items-center gap-2 rounded-lg bg-emerald-50 px-3 py-2 text-xs text-emerald-800">
          <CheckCircle2 className="h-4 w-4" /> Valid against the live HPA{d.targets.length > 1 ? 's' : ''}.
        </div>
      )}
      {d.warnings.map((w) => <div key={w} className="rounded-lg bg-amber-50 px-3 py-2 text-xs text-amber-800">{w}</div>)}
      {d.targets.map((t) => (
        <div key={t.hpa} className="rounded-lg border border-zinc-200 p-3">
          <div className="mb-2 flex flex-wrap items-center gap-2">
            <span className="font-mono text-xs font-semibold">{t.hpa}</span><RoleBadge role={t.role} />
            {t.noop && <Badge variant="warning">Already at these values</Badge>}
          </div>
          <DiffTable diff={t.diff} empty={t.errors.length ? 'No preview (see problems)' : 'No difference'} />
        </div>
      ))}
      {d.targets.length > 1 && <div className="text-xs text-amber-800">Traffic is split, so the change applies to all {d.targets.length} serving HPAs.</div>}
      {d.timing && (
        <div className="space-y-1 text-xs text-zinc-600">
          {d.timing.windowOpenNow && <div className="font-medium text-sky-700">The window is open right now — it will apply within about 15 seconds of saving.</div>}
          {d.timing.nextStarts.length > 0 && <div>Next windows: {d.timing.nextStarts.slice(0, 3).map(fmtTime).join(' · ')}</div>}
          {d.timing.overlaps.length > 0 && <div className="text-red-700">Overlaps: {d.timing.overlaps.join(', ')}</div>}
        </div>
      )}
    </div>
  );
}

function Problems({ items }: { items: string[] }) {
  return (
    <div className="rounded-lg border border-red-200 bg-red-50 px-3 py-2 text-xs text-red-800">
      <div className="mb-1 flex items-center gap-1.5 font-semibold"><AlertTriangle className="h-3.5 w-3.5" /> Cannot be applied</div>
      <ul className="list-disc space-y-0.5 pl-5">{items.map((p) => <li key={p}>{p}</li>)}</ul>
    </div>
  );
}
