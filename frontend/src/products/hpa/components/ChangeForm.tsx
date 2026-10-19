import { useState } from 'react';
import { cn } from '../../../lib/utils';
import { describeTarget, numOrUndef } from '../format';
import type { HpaChange, HpaSpec, MetricTarget, MetricTargetChange, ScalingRules } from '../types';

/** Mirrors the backend's `metricKey`: how a metric entry is addressed in a change. */
export function metricKey(m: any): string | null {
  switch (m?.type) {
    case 'Resource': return `resource/${m.resource?.name}`;
    case 'ContainerResource': return `containerResource/${m.containerResource?.container}/${m.containerResource?.name}`;
    case 'Pods': return `pods/${m.pods?.metric?.name}`;
    case 'Object': return `object/${m.object?.describedObject?.kind}/${m.object?.describedObject?.name}/${m.object?.metric?.name}`;
    case 'External': return `external/${m.external?.metric?.name}`;
    default: return null;
  }
}

function targetOf(m: any): MetricTarget | null {
  const t = m?.[{ Resource: 'resource', ContainerResource: 'containerResource', Pods: 'pods', Object: 'object', External: 'external' }[m?.type as string] ?? '']?.target;
  return t ?? null;
}

/** Percentages only make sense for cpu/memory; per-pod quantities for everything; totals for object/external. */
function allowedTargets(m: any): MetricTarget['type'][] {
  if (m.type === 'Resource' || m.type === 'ContainerResource') return ['Utilization', 'AverageValue'];
  if (m.type === 'Pods') return ['AverageValue'];
  return ['AverageValue', 'Value'];
}

const input = 'h-9 w-full rounded-lg border border-zinc-300 bg-white px-3 text-sm focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-400';

interface Props {
  /** The HPA whose current values are shown as hints and whose metrics can be overridden. */
  reference: HpaSpec | null;
  value: HpaChange;
  onChange: (c: HpaChange) => void;
}

export default function ChangeForm({ reference, value, onChange }: Props) {
  const [showBehavior, setShowBehavior] = useState(!!(value.scaleUp || value.scaleDown));
  const metrics = (reference?.metrics ?? []).filter((m) => metricKey(m) && m.type !== undefined);
  const overrides = value.metricTargets ?? [];

  const setOverride = (key: string, t: MetricTarget | null) => {
    const rest = overrides.filter((o) => o.key !== key);
    onChange({ ...value, metricTargets: t ? [...rest, { key, target: t }] : rest });
  };

  return (
    <div className="space-y-4">
      <div>
        <div className="mb-1.5 text-xs font-semibold text-zinc-700">Replica bounds</div>
        <div className="grid grid-cols-2 gap-3">
          <label className="text-xs text-zinc-600">
            Min replicas {reference && <span className="text-zinc-400">(now {reference.minReplicas})</span>}
            <input type="number" min={1} className={cn(input, 'mt-1')} value={value.minReplicas ?? ''} placeholder="leave unchanged"
              onChange={(e) => onChange({ ...value, minReplicas: numOrUndef(e.target.value) })} />
          </label>
          <label className="text-xs text-zinc-600">
            Max replicas {reference && <span className="text-zinc-400">(now {reference.maxReplicas})</span>}
            <input type="number" min={1} className={cn(input, 'mt-1')} value={value.maxReplicas ?? ''} placeholder="leave unchanged"
              onChange={(e) => onChange({ ...value, maxReplicas: numOrUndef(e.target.value) })} />
          </label>
        </div>
        <p className="mt-1 text-[11px] text-zinc-500">Raising min scales the service up immediately.</p>
      </div>

      <div>
        <div className="mb-1.5 text-xs font-semibold text-zinc-700">Scaling targets</div>
        {metrics.length === 0 && <div className="text-xs text-zinc-500">No editable metrics found on the serving HPA.</div>}
        <div className="space-y-2">
          {metrics.map((m) => {
            const key = metricKey(m) as string;
            const cur = targetOf(m);
            const ov = overrides.find((o) => o.key === key);
            const types = allowedTargets(m);
            return (
              <div key={key} className={cn('rounded-lg border px-3 py-2', ov ? 'border-sky-300 bg-sky-50/40' : 'border-zinc-200')}>
                <label className="flex cursor-pointer items-center gap-2 text-sm">
                  <input type="checkbox" checked={!!ov} onChange={(e) => setOverride(key, e.target.checked && cur ? cur : null)} />
                  <span className="font-medium text-zinc-800">{key}</span>
                  {cur && <span className="text-xs text-zinc-500">now {describeTarget(cur)}</span>}
                </label>
                {ov && <TargetEditor target={ov.target} types={types} onChange={(t) => setOverride(key, t)} />}
              </div>
            );
          })}
        </div>
        <p className="mt-1 text-[11px] text-zinc-500">
          Percent is relative to each pod's resource <em>request</em>. Quantities accept <code>500m</code>, <code>2</code>, <code>256Mi</code>, <code>1Gi</code>.
        </p>
      </div>

      <div>
        <button type="button" className="cursor-pointer text-xs font-semibold text-zinc-700 underline-offset-2 hover:underline" onClick={() => setShowBehavior((s) => !s)}>
          {showBehavior ? '▾' : '▸'} Scale-up / scale-down behaviour
        </button>
        {showBehavior && (
          <div className="mt-2 space-y-3">
            {(['scaleUp', 'scaleDown'] as const).map((dir) => (
              <RulesEditor key={dir} label={dir === 'scaleUp' ? 'Scale up' : 'Scale down'} current={reference?.behavior?.[dir]}
                value={value[dir]} onChange={(r) => onChange({ ...value, [dir]: r })} />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

function TargetEditor({ target, types, onChange }: { target: MetricTarget; types: MetricTarget['type'][]; onChange: (t: MetricTarget) => void }) {
  const val = target.type === 'Utilization' ? String(target.averageUtilization) : target.type === 'AverageValue' ? target.averageValue : target.value;
  const make = (type: MetricTarget['type'], v: string): MetricTarget =>
    type === 'Utilization' ? { type, averageUtilization: Number(v) || 0 } : type === 'AverageValue' ? { type, averageValue: v } : { type, value: v };
  return (
    <div className="mt-2 grid grid-cols-[130px_1fr] gap-2">
      <select className={input} value={target.type} onChange={(e) => onChange(make(e.target.value as MetricTarget['type'], target.type === 'Utilization' ? '' : val))}>
        {types.map((t) => <option key={t} value={t}>{t === 'Utilization' ? 'Percent (%)' : t === 'AverageValue' ? 'Per-pod value' : 'Total value'}</option>)}
      </select>
      <input className={input} value={val} inputMode={target.type === 'Utilization' ? 'numeric' : 'text'}
        placeholder={target.type === 'Utilization' ? 'e.g. 60' : 'e.g. 500m or 256Mi'} onChange={(e) => onChange(make(target.type, e.target.value))} />
    </div>
  );
}

function RulesEditor({ label, current, value, onChange }: { label: string; current?: ScalingRules; value?: ScalingRules; onChange: (r: ScalingRules | undefined) => void }) {
  const on = !!value;
  const rules = value ?? {};
  const pol = rules.policies ?? [];
  return (
    <div className={cn('rounded-lg border px-3 py-2', on ? 'border-sky-300 bg-sky-50/40' : 'border-zinc-200')}>
      <label className="flex cursor-pointer items-center gap-2 text-sm">
        <input type="checkbox" checked={on} onChange={(e) => onChange(e.target.checked ? { ...(current ?? {}) } : undefined)} />
        <span className="font-medium text-zinc-800">{label}</span>
        <span className="text-xs text-zinc-500">replaces this direction's whole rule block</span>
      </label>
      {on && (
        <div className="mt-2 space-y-2">
          <div className="grid grid-cols-2 gap-2">
            <label className="text-xs text-zinc-600">Stabilisation window (s)
              <input type="number" min={0} max={3600} className={cn(input, 'mt-1')} value={rules.stabilizationWindowSeconds ?? ''}
                onChange={(e) => onChange({ ...rules, stabilizationWindowSeconds: numOrUndef(e.target.value) })} />
            </label>
            <label className="text-xs text-zinc-600">When several policies apply
              <select className={cn(input, 'mt-1')} value={rules.selectPolicy ?? ''} onChange={(e) => onChange({ ...rules, selectPolicy: (e.target.value || undefined) as ScalingRules['selectPolicy'] })}>
                <option value="">default (Max)</option><option value="Max">Max — fastest</option><option value="Min">Min — slowest</option><option value="Disabled">Disabled — never scale this way</option>
              </select>
            </label>
          </div>
          {pol.map((p, i) => (
            <div key={i} className="grid grid-cols-[110px_1fr_1fr_28px] items-end gap-2">
              <label className="text-xs text-zinc-600">Unit
                <select className={cn(input, 'mt-1')} value={p.type} onChange={(e) => onChange({ ...rules, policies: pol.map((x, j) => (j === i ? { ...x, type: e.target.value as 'Pods' | 'Percent' } : x)) })}>
                  <option value="Pods">Pods</option><option value="Percent">% of pods</option>
                </select>
              </label>
              <label className="text-xs text-zinc-600">Up to
                <input type="number" min={1} className={cn(input, 'mt-1')} value={p.value} onChange={(e) => onChange({ ...rules, policies: pol.map((x, j) => (j === i ? { ...x, value: Number(e.target.value) } : x)) })} />
              </label>
              <label className="text-xs text-zinc-600">Per (seconds)
                <input type="number" min={1} max={1800} className={cn(input, 'mt-1')} value={p.periodSeconds} onChange={(e) => onChange({ ...rules, policies: pol.map((x, j) => (j === i ? { ...x, periodSeconds: Number(e.target.value) } : x)) })} />
              </label>
              <button type="button" aria-label="Remove policy" className="h-9 cursor-pointer text-zinc-400 hover:text-red-600" onClick={() => onChange({ ...rules, policies: pol.filter((_, j) => j !== i) })}>✕</button>
            </div>
          ))}
          <button type="button" className="cursor-pointer text-xs font-medium text-sky-700 hover:underline" onClick={() => onChange({ ...rules, policies: [...pol, { type: 'Pods', value: 4, periodSeconds: 60 }] })}>+ Add rate policy</button>
        </div>
      )}
    </div>
  );
}

export type { MetricTargetChange };
