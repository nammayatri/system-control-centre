import { useState } from 'react';
import { cn } from '../../../lib/utils';
import { describeTarget, metricLabel, numOrUndef } from '../format';
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
  /** Pods running right now (for the quick presets). */
  currentReplicas?: number;
  value: HpaChange;
  onChange: (c: HpaChange) => void;
}

const heading = 'text-sm font-semibold text-zinc-900';
const help = 'mt-0.5 text-xs text-zinc-500';

export default function ChangeForm({ reference, currentReplicas, value, onChange }: Props) {
  const [showBehavior, setShowBehavior] = useState(!!(value.scaleUp || value.scaleDown));
  const metrics = (reference?.metrics ?? []).filter((m) => metricKey(m) && m.type !== undefined);
  const overrides = value.metricTargets ?? [];

  const setOverride = (key: string, t: MetricTarget | null) => {
    const rest = overrides.filter((o) => o.key !== key);
    onChange({ ...value, metricTargets: t ? [...rest, { key, target: t }] : rest });
  };

  return (
    <div className="space-y-6">
      <div>
        <div className={heading}>Pod limits</div>
        <p className={help}>The autoscaler keeps the number of pods between these two numbers. Leave a box empty to keep its current value.</p>
        <div className="mt-2 grid grid-cols-2 gap-3">
          <label className="text-xs font-medium text-zinc-700">
            Minimum pods {reference && <span className="font-normal text-zinc-400">· now {reference.minReplicas}</span>}
            <input type="number" min={1} className={cn(input, 'mt-1 font-normal')} value={value.minReplicas ?? ''} placeholder={reference ? `keep ${reference.minReplicas}` : 'keep current'}
              onChange={(e) => onChange({ ...value, minReplicas: numOrUndef(e.target.value) })} />
          </label>
          <label className="text-xs font-medium text-zinc-700">
            Maximum pods {reference && <span className="font-normal text-zinc-400">· now {reference.maxReplicas}</span>}
            <input type="number" min={1} className={cn(input, 'mt-1 font-normal')} value={value.maxReplicas ?? ''} placeholder={reference ? `keep ${reference.maxReplicas}` : 'keep current'}
              onChange={(e) => onChange({ ...value, maxReplicas: numOrUndef(e.target.value) })} />
          </label>
        </div>
        {reference && (
          <div className="mt-2 flex flex-wrap items-center gap-1.5 text-xs">
            <span className="text-zinc-500">Quick fill:</span>
            <Preset onClick={() => onChange({ ...value, maxReplicas: reference.maxReplicas * 2 })}>Double the maximum ({reference.maxReplicas * 2})</Preset>
            <Preset onClick={() => onChange({ ...value, maxReplicas: Math.ceil(reference.maxReplicas * 1.5) })}>Maximum +50% ({Math.ceil(reference.maxReplicas * 1.5)})</Preset>
            {currentReplicas != null && currentReplicas > reference.minReplicas && (
              <Preset onClick={() => onChange({ ...value, minReplicas: currentReplicas, maxReplicas: Math.max(value.maxReplicas ?? reference.maxReplicas, currentReplicas) })}>Keep at least today's {currentReplicas} pods</Preset>
            )}
          </div>
        )}
        <p className="mt-2 rounded-md bg-amber-50 px-2.5 py-1.5 text-xs text-amber-800">Raising the minimum starts extra pods straight away, even if traffic is low.</p>
      </div>

      <div>
        <div className={heading}>When to add pods <span className="font-normal text-zinc-400">(optional)</span></div>
        <p className={help}>The autoscaler adds pods when these numbers go above target. With several, it follows whichever asks for the most pods.</p>
        {metrics.length === 0 && <div className="mt-2 text-xs text-zinc-500">No editable metrics found on the serving HPA.</div>}
        <div className="mt-2 space-y-2">
          {metrics.map((m) => {
            const key = metricKey(m) as string;
            const cur = targetOf(m);
            const ov = overrides.find((o) => o.key === key);
            const types = allowedTargets(m);
            const label = metricLabel(key);
            return (
              <div key={key} className={cn('rounded-lg border px-3 py-2.5', ov ? 'border-sky-300 bg-sky-50/50' : 'border-zinc-200')}>
                <label className="flex cursor-pointer items-start gap-2.5 text-sm">
                  <input type="checkbox" className="mt-1" checked={!!ov} onChange={(e) => setOverride(key, e.target.checked && cur ? cur : null)} />
                  <span>
                    <span className="font-medium text-zinc-900">Change the {label.title.toLowerCase()}</span>
                    {cur && <span className="ml-2 rounded bg-zinc-100 px-1.5 py-0.5 text-xs text-zinc-600">now {describeTarget(cur)}</span>}
                    <span className="block text-xs text-zinc-500">{label.hint}</span>
                  </span>
                </label>
                {ov && <TargetEditor target={ov.target} types={types} onChange={(t) => setOverride(key, t)} />}
              </div>
            );
          })}
        </div>
      </div>

      <div>
        <button type="button" className="cursor-pointer text-sm font-semibold text-zinc-800 hover:underline" onClick={() => setShowBehavior((x) => !x)}>
          {showBehavior ? '▾' : '▸'} Advanced: how fast it scales <span className="font-normal text-zinc-400">(rarely needed)</span>
        </button>
        {showBehavior && (
          <div className="mt-2 space-y-3">
            <p className={help}>Normally the autoscaler decides how quickly to add or remove pods. Use this only to speed up or slow down that, for example to scale up faster before a sale.</p>
            {(['scaleUp', 'scaleDown'] as const).map((dir) => (
              <RulesEditor key={dir} label={dir === 'scaleUp' ? 'Change how fast it adds pods' : 'Change how fast it removes pods'} current={reference?.behavior?.[dir]}
                value={value[dir]} onChange={(r) => onChange({ ...value, [dir]: r })} />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

function Preset({ onClick, children }: { onClick: () => void; children: React.ReactNode }) {
  return <button type="button" onClick={onClick} className="cursor-pointer rounded-full border border-zinc-300 px-2.5 py-1 text-zinc-700 hover:border-sky-400 hover:bg-sky-50">{children}</button>;
}

function TargetEditor({ target, types, onChange }: { target: MetricTarget; types: MetricTarget['type'][]; onChange: (t: MetricTarget) => void }) {
  const val = target.type === 'Utilization' ? String(target.averageUtilization) : target.type === 'AverageValue' ? target.averageValue : target.value;
  const make = (type: MetricTarget['type'], v: string): MetricTarget =>
    type === 'Utilization' ? { type, averageUtilization: Number(v) || 0 } : type === 'AverageValue' ? { type, averageValue: v } : { type, value: v };
  return (
    <div className="mt-2.5 grid grid-cols-[170px_1fr] gap-2 pl-6">
      <select className={input} value={target.type} onChange={(e) => onChange(make(e.target.value as MetricTarget['type'], target.type === 'Utilization' ? '' : val))}>
        {types.map((t) => <option key={t} value={t}>{t === 'Utilization' ? 'Percent of requested' : t === 'AverageValue' ? 'Amount per pod' : 'Total amount'}</option>)}
      </select>
      <div>
        <input className={input} value={val} inputMode={target.type === 'Utilization' ? 'numeric' : 'text'}
          placeholder={target.type === 'Utilization' ? 'e.g. 60' : 'e.g. 500m or 256Mi'} onChange={(e) => onChange(make(target.type, e.target.value))} />
        <div className="mt-1 text-[11px] text-zinc-500">
          {target.type === 'Utilization'
            ? 'Lower number = scales up sooner (more pods, more cost). 60 means “keep average use around 60% of what each pod requested”.'
            : 'Examples: 500m = half a CPU core, 2 = two cores, 256Mi = 256 MiB of memory.'}
        </div>
      </div>
    </div>
  );
}

function RulesEditor({ label, current, value, onChange }: { label: string; current?: ScalingRules; value?: ScalingRules; onChange: (r: ScalingRules | undefined) => void }) {
  const on = !!value;
  const rules = value ?? {};
  const pol = rules.policies ?? [];
  return (
    <div className={cn('rounded-lg border px-3 py-2.5', on ? 'border-sky-300 bg-sky-50/50' : 'border-zinc-200')}>
      <label className="flex cursor-pointer items-center gap-2.5 text-sm">
        <input type="checkbox" checked={on} onChange={(e) => onChange(e.target.checked ? { ...(current ?? {}) } : undefined)} />
        <span className="font-medium text-zinc-900">{label}</span>
      </label>
      {on && (
        <div className="mt-2.5 space-y-3 pl-6">
          <div className="grid grid-cols-2 gap-3">
            <label className="text-xs font-medium text-zinc-700">Wait before acting (seconds)
              <input type="number" min={0} max={3600} className={cn(input, 'mt-1 font-normal')} value={rules.stabilizationWindowSeconds ?? ''}
                onChange={(e) => onChange({ ...rules, stabilizationWindowSeconds: numOrUndef(e.target.value) })} />
              <span className="mt-0.5 block text-[11px] font-normal text-zinc-500">Ignores short spikes. 0 = react immediately.</span>
            </label>
            <label className="text-xs font-medium text-zinc-700">If several limits apply
              <select className={cn(input, 'mt-1 font-normal')} value={rules.selectPolicy ?? ''} onChange={(e) => onChange({ ...rules, selectPolicy: (e.target.value || undefined) as ScalingRules['selectPolicy'] })}>
                <option value="">Default (use the fastest)</option><option value="Max">Use the fastest</option><option value="Min">Use the slowest</option><option value="Disabled">Never do this</option>
              </select>
            </label>
          </div>
          {pol.map((p, i) => (
            <div key={i} className="grid grid-cols-[120px_1fr_1fr_28px] items-end gap-2">
              <label className="text-xs font-medium text-zinc-700">Change by
                <select className={cn(input, 'mt-1 font-normal')} value={p.type} onChange={(e) => onChange({ ...rules, policies: pol.map((x, j) => (j === i ? { ...x, type: e.target.value as 'Pods' | 'Percent' } : x)) })}>
                  <option value="Pods">Pods</option><option value="Percent">% of pods</option>
                </select>
              </label>
              <label className="text-xs font-medium text-zinc-700">At most
                <input type="number" min={1} className={cn(input, 'mt-1 font-normal')} value={p.value} onChange={(e) => onChange({ ...rules, policies: pol.map((x, j) => (j === i ? { ...x, value: Number(e.target.value) } : x)) })} />
              </label>
              <label className="text-xs font-medium text-zinc-700">Every (seconds)
                <input type="number" min={1} max={1800} className={cn(input, 'mt-1 font-normal')} value={p.periodSeconds} onChange={(e) => onChange({ ...rules, policies: pol.map((x, j) => (j === i ? { ...x, periodSeconds: Number(e.target.value) } : x)) })} />
              </label>
              <button type="button" aria-label="Remove limit" className="h-9 cursor-pointer text-zinc-400 hover:text-red-600" onClick={() => onChange({ ...rules, policies: pol.filter((_, j) => j !== i) })}>✕</button>
            </div>
          ))}
          <button type="button" className="cursor-pointer text-xs font-medium text-sky-700 hover:underline" onClick={() => onChange({ ...rules, policies: [...pol, { type: 'Pods', value: 4, periodSeconds: 60 }] })}>+ Limit how many pods can change per period</button>
          <p className="text-[11px] text-zinc-500">This replaces the whole rule set for this direction, so set everything you want here.</p>
        </div>
      )}
    </div>
  );
}

export type { MetricTargetChange };
