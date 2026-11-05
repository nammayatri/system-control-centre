import { useEffect, useRef, useState } from 'react';
import { Loader2 } from 'lucide-react';
import { cn } from '../../../lib/utils';
import { errorMessage, previewChange } from '../api';
import { unitLabel } from '../format';
import type { InstanceMode, InstanceState, Preview, ScaleChange, ScheduleKind, Target } from '../types';

const input = 'h-9 w-full rounded-lg border border-zinc-300 bg-white px-3 text-sm focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-400';

const num = (v: string): number | undefined => (v.trim() === '' || Number.isNaN(Number(v)) ? undefined : Number(v));

export const modeOf = (target: Target, state: InstanceState | null): InstanceMode =>
  state?.mode ?? (target.kind === 'DB' ? 'READ_POOL' : 'CLUSTER');

/** What the user has to fill in for one change, depending on how the target scales. */
export function ChangeFields({ target, state, value, onChange }: { target: Target; state: InstanceState | null; value: ScaleChange; onChange: (c: ScaleChange) => void }) {
  const mode = modeOf(target, state);
  const unit = unitLabel(mode);
  const canBlock = mode !== 'CLUSTER_DISABLED';
  return (
    <div className="space-y-4">
      {state && (
        <div className="rounded-lg bg-zinc-50 px-3 py-2 text-xs text-zinc-600">
          Right now: <b>{state.units}</b> {mode === 'READ_POOL' ? `node${state.units === 1 ? '' : 's'}` : `shard${state.units === 1 ? '' : 's'}`}
          {mode !== 'READ_POOL' && <>, <b>{state.replicas}</b> replica{state.replicas === 1 ? '' : 's'}</>} ({state.state.toLowerCase()}).
          Capacity only ever goes <b>up</b> when a window starts; a target at or below the current value changes nothing.
        </div>
      )}
      {mode === 'CLUSTER_DISABLED' ? (
        <label className="block text-xs font-medium text-zinc-700">Scale up to (replicas)
          <input type="number" min={0} max={5} className={cn(input, 'mt-1 font-normal')} value={value.replicas ?? ''} placeholder="e.g. 2"
            onChange={(e) => onChange({ ...value, replicas: num(e.target.value), units: undefined })} />
          <span className="mt-1 block text-[11px] font-normal text-zinc-500">A standalone instance always has one shard, so it scales by replicas.</span>
        </label>
      ) : (
        <label className="block text-xs font-medium text-zinc-700">Scale up to ({unit})
          <input type="number" min={1} max={mode === 'READ_POOL' ? 20 : 250} className={cn(input, 'mt-1 font-normal')} value={value.units ?? ''} placeholder={mode === 'READ_POOL' ? 'e.g. 3' : 'e.g. 16'}
            onChange={(e) => onChange({ ...value, units: num(e.target.value) })} />
        </label>
      )}
      {canBlock && (
        <label className={cn('flex items-start gap-2 text-sm text-zinc-800', target.autoscalerJob ? 'cursor-pointer' : 'opacity-60')}>
          <input type="checkbox" className="mt-1" disabled={!target.autoscalerJob} checked={value.blockScaleIn} onChange={(e) => onChange({ ...value, blockScaleIn: e.target.checked })} />
          <span>Block scale-in while the window is open
            <span className="block text-xs text-zinc-500">
              {target.autoscalerJob
                ? "Raises the autoscaler's minimum to the target so it cannot shrink this during the window. The original minimum is put back at the end, unless someone changed it meanwhile."
                : 'This target has no autoscaler job set, so there is nothing to hold. Set one on the target to enable this.'}
            </span>
          </span>
        </label>
      )}
      <label className="flex cursor-pointer items-start gap-2 text-sm text-zinc-800">
        <input type="checkbox" className="mt-1" checked={value.shrinkOnEnd} onChange={(e) => onChange({ ...value, shrinkOnEnd: e.target.checked })} />
        <span>Shrink back when the window ends
          <span className="block text-xs text-zinc-500">Off by default: the target keeps the added {unit} and the autoscaler decides later. Shrinking is itself a resize, and only happens if nobody else resized the target meanwhile.</span>
        </span>
      </label>
    </div>
  );
}

export interface PreviewState { ready: boolean; blocking: string[] }

/** Checks the change against the live target (and the autoscaler's job) as the user types. */
export function PreviewBox({ target, change, timing, excludeScheduleId, onState }: {
  target: Target; change: ScaleChange; timing?: ScheduleKind; excludeScheduleId?: string; onState: (s: PreviewState) => void;
}) {
  const [data, setData] = useState<Preview | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const seq = useRef(0);
  const cb = useRef(onState);
  cb.current = onState;

  const key = JSON.stringify({ id: target.id, change, timing, excludeScheduleId });
  const empty = change.units == null && change.replicas == null;
  useEffect(() => {
    if (empty) { setData(null); setErr(null); cb.current({ ready: false, blocking: [] }); return; }
    const mine = ++seq.current;
    setBusy(true);
    cb.current({ ready: false, blocking: [] });
    const t = setTimeout(async () => {
      try {
        const p = await previewChange({ targetKind: target.kind, targetId: target.id, change, timing, excludeScheduleId });
        if (mine !== seq.current) return;
        setData(p); setErr(null);
        const blocking = [...p.issues, ...p.refusedBecause, ...p.overlaps.map((o) => `Overlaps schedule “${o}”`),
          ...(p.autoscaler && !p.autoscaler.ok ? [`Autoscaler: ${p.autoscaler.error ?? 'cannot read its job'}`] : [])];
        cb.current({ ready: true, blocking });
      } catch (e) {
        if (mine !== seq.current) return;
        setData(null); setErr(errorMessage(e));
        cb.current({ ready: true, blocking: [errorMessage(e)] });
      } finally {
        if (mine === seq.current) setBusy(false);
      }
    }, 400);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);

  if (empty) return <div className="text-xs text-zinc-500">Fill in the target to see what would happen.</div>;
  const target_ = change.units;
  return (
    <div className="space-y-2 text-xs">
      {busy && <div className="flex items-center gap-1.5 text-zinc-500"><Loader2 className="h-3.5 w-3.5 animate-spin" />Checking against the live target…</div>}
      {err && <div className="rounded-lg bg-red-50 px-3 py-2 text-red-800">{err}</div>}
      {data && (
        <>
          {data.plan && (
            <div className={cn('rounded-lg px-3 py-2', data.plan.noop ? 'bg-zinc-100 text-zinc-700' : 'bg-sky-50 text-sky-900')}>
              {data.plan.noop ? 'The target already has this capacity, so no resize is needed.' : `Would resize: ${data.plan.summary}.`}
            </div>
          )}
          {data.autoscaler?.ok && (
            <div className="rounded-lg bg-zinc-50 px-3 py-2 text-zinc-700">
              The autoscaler's minimum is <b>{data.autoscaler.minimum}</b>
              {data.autoscaler.wouldPin ? <> and would be raised to <b>{target_}</b> for the window.</> : <>, which is already at or above the target, so it is left alone.</>}
              {data.autoscaler.jobState === 'PAUSED' && <div className="mt-1 text-amber-700">Its job is paused, so it is not making scaling decisions right now.</div>}
            </div>
          )}
          {[...data.issues, ...data.refusedBecause, ...(data.autoscaler && !data.autoscaler.ok ? [`Autoscaler: ${data.autoscaler.error ?? 'cannot read its job'}`] : []),
            ...data.overlaps.map((o) => `Overlaps schedule “${o}”; one target can hold one change at a time.`)].map((m) => (
            <div key={m} className="rounded-lg bg-red-50 px-3 py-2 text-red-800">{m}</div>
          ))}
        </>
      )}
    </div>
  );
}
