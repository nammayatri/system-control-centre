import { useEffect, useMemo, useState } from 'react';
import { History, Pause, Play, RotateCcw } from 'lucide-react';
import { Badge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { Card, CardContent } from '../../../shared/ui/card';
import { Spinner } from '../../../shared/ui/spinner';
import { useConfirm } from '../../../shared/ui/confirm-dialog';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { cn } from '../../../lib/utils';
import { fmtTimeFull, relTime } from '../../hpa/format';
import { useAutoscaler, useEditAutoscaler, usePauseAutoscaler, useRevertAutoscaler } from '../hooks';
import { OPERATORS, settingLabel } from '../format';
import type { AutoscalerEntry, HistoryItem, ScalingCondition, ScalingRule, Target } from '../types';

const input = 'h-9 w-full rounded-lg border border-zinc-300 bg-white px-3 text-sm focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-400 disabled:bg-zinc-100 disabled:text-zinc-500';

/** Which list of conditions a rule uses (the autoscaler's rules use either `any` or `all`). */
const condsOf = (r: ScalingRule): { key: 'any' | 'all'; list: ScalingCondition[] } =>
  r.conditions.all ? { key: 'all', list: r.conditions.all } : { key: 'any', list: r.conditions.any ?? [] };

/** View and change the autoscaler that drives a target: its limits, cooldowns and scaling rules, with history and revert. */
export default function AutoscalerEditor({ target }: { target: Target }) {
  const q = useAutoscaler(target.kind, target.id, !!target.autoscalerJob);
  const v = q.data;
  const edit = useEditAutoscaler(target);
  const revert = useRevertAutoscaler(target);
  const pause = usePauseAutoscaler(target);
  const confirm = useConfirm();

  const [values, setValues] = useState<Record<string, unknown>>({});
  const [rules, setRules] = useState<ScalingRule[]>([]);
  const [note, setNote] = useState('');

  const entry: AutoscalerEntry | undefined = v?.entry;
  const settings = useMemo(() => (v?.editable ?? []).filter((e) => entry && e.key in entry), [v, entry]);
  useEffect(() => {
    if (!entry) return;
    setValues(Object.fromEntries(settings.map((s) => [s.key, entry[s.key]])));
    setRules(JSON.parse(JSON.stringify(entry.scalingRules ?? [])) as ScalingRule[]);
    setNote('');
  }, [entry, settings]);

  if (!target.autoscalerJob) {
    return <div className="rounded-lg border border-dashed border-zinc-300 px-4 py-10 text-center text-sm text-zinc-500">This target has no autoscaler job set. Add the Cloud Scheduler job that configures its autoscaler in the target's settings to manage it here.</div>;
  }
  if (q.isLoading) return <Spinner label="Reading the autoscaler…" />;
  if (!v) return <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800">Could not load the autoscaler.</div>;
  if (!v.ok || !entry) {
    return (
      <div className="space-y-3">
        <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800">Could not read this target's autoscaler: {v.error}</div>
        <HistoryList items={v.history} canRevert={false} onRevert={() => {}} reverting={false} />
      </div>
    );
  }

  const changedSet = Object.fromEntries(settings.filter((s) => values[s.key] !== entry[s.key]).map((s) => [s.key, values[s.key]]));
  const rulesChanged = JSON.stringify(rules) !== JSON.stringify(entry.scalingRules ?? []);
  const dirty = Object.keys(changedSet).length > 0 || rulesChanged;
  const paused = v.state === 'PAUSED';
  const minKey = target.kind === 'DB' ? 'minNodeCount' : 'minSize';
  const data = v.data ?? '';

  const setRuleValue = (ri: number, ci: number, patch: Partial<ScalingCondition>) =>
    setRules(rules.map((r, i) => {
      if (i !== ri) return r;
      const { key, list } = condsOf(r);
      return { ...r, conditions: { [key]: list.map((c, j) => (j === ci ? { ...c, ...patch } : c)) } };
    }));

  return (
    <div className="space-y-4">
      <Card><CardContent className="flex flex-wrap items-center gap-3">
        <div className="min-w-0">
          <div className="text-xs font-semibold uppercase tracking-wide text-zinc-500">Autoscaler job</div>
          <div className="font-mono text-sm text-zinc-900">{v.job} <span className="text-zinc-400">· {v.jobLocation} · {v.schedule}</span></div>
        </div>
        <Badge variant={paused ? 'warning' : 'success'} dot>{paused ? 'Paused' : 'Running'}</Badge>
        {v.heldBy && <Badge variant="info">Minimum held by a scheduled change</Badge>}
        <PermissionGate product="autopilot" permission="HPA_GUARDRAIL_EDIT">
          <Button className="ml-auto" size="sm" variant={paused ? 'primary' : 'secondary'} loading={pause.isPending}
            onClick={async () => {
              const ok = await confirm({
                title: paused ? 'Resume the autoscaler' : 'Pause the autoscaler',
                description: paused ? 'It starts making scaling decisions again.' : 'It stops making any scaling decisions (in or out) until resumed. Capacity stays as it is.',
                confirmLabel: paused ? 'Resume' : 'Pause', variant: paused ? 'primary' : 'danger',
              });
              if (ok) pause.mutate({ paused: !paused });
            }}>
            {paused ? <><Play className="h-4 w-4" />Resume</> : <><Pause className="h-4 w-4" />Pause</>}
          </Button>
        </PermissionGate>
      </CardContent></Card>

      <Card><CardContent className="space-y-4">
        <div className="text-xs font-semibold uppercase tracking-wide text-zinc-500">Limits and timing</div>
        <div className="grid gap-4 sm:grid-cols-2">
          {settings.map((s) => {
            const { label, hint } = settingLabel(s.key);
            const locked = s.key === minKey && !!v.heldBy;
            return (
              <label key={s.key} className="block text-xs font-medium text-zinc-700">{label}
                {s.kind.type === 'enum' ? (
                  <select className={cn(input, 'mt-1 font-normal')} value={String(values[s.key] ?? '')} onChange={(e) => setValues({ ...values, [s.key]: e.target.value })}>
                    {s.kind.options.map((o) => <option key={o} value={o}>{o}</option>)}
                  </select>
                ) : (
                  <input type="number" min={s.kind.min} max={s.kind.max} className={cn(input, 'mt-1 font-normal')} disabled={locked}
                    value={String(values[s.key] ?? '')} onChange={(e) => setValues({ ...values, [s.key]: e.target.value === '' ? '' : Number(e.target.value) })} />
                )}
                <span className="mt-1 block text-[11px] font-normal text-zinc-500">
                  {locked ? 'Held by a scheduled change right now; it is put back when the window ends.' : hint ?? (s.kind.type === 'int' ? `${s.kind.min}–${s.kind.max}` : '')}
                </span>
              </label>
            );
          })}
        </div>
      </CardContent></Card>

      <Card><CardContent className="space-y-3">
        <div className="text-xs font-semibold uppercase tracking-wide text-zinc-500">When it scales</div>
        {rules.length === 0 ? <div className="text-xs text-zinc-500">No scaling rules.</div> : rules.map((r, ri) => {
          const { key, list } = condsOf(r);
          return (
            <div key={`${r.name}-${ri}`} className="rounded-lg border border-zinc-200 p-3">
              <div className="mb-2 flex items-center gap-2">
                <Badge variant={r.event.type === 'OUT' ? 'blue' : 'purple'}>{r.event.type === 'OUT' ? 'Scale out' : 'Scale in'}</Badge>
                <span className="text-sm font-medium text-zinc-900">{r.name}</span>
                <span className="ml-auto text-[11px] text-zinc-400">{list.length > 1 ? (key === 'all' ? 'all of these' : 'any of these') : ''}</span>
              </div>
              <div className="space-y-2">
                {list.map((c, ci) => (
                  <div key={`${c.fact}-${ci}`} className="grid grid-cols-[1fr_auto_6rem] items-center gap-2 text-xs">
                    <span className="truncate font-mono text-zinc-700" title={c.fact}>{c.fact}</span>
                    <select className={cn(input, 'w-40')} value={c.operator} onChange={(e) => setRuleValue(ri, ci, { operator: e.target.value })}>
                      {OPERATORS.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
                      {!OPERATORS.some((o) => o.value === c.operator) && <option value={c.operator}>{c.operator}</option>}
                    </select>
                    <input type="number" className={input} value={String(c.value)} onChange={(e) => setRuleValue(ri, ci, { value: Number(e.target.value) })} />
                  </div>
                ))}
              </div>
            </div>
          );
        })}
        <p className="text-[11px] text-zinc-500">Only the thresholds and comparisons can be changed here. The rules themselves (which metrics, scale out or in) stay as configured.</p>
      </CardContent></Card>

      <PermissionGate product="autopilot" permission="HPA_GUARDRAIL_EDIT" fallback={<div className="text-xs text-zinc-500">You can view this but not change it.</div>}>
        <div className="flex flex-wrap items-center gap-3">
          <input className={cn(input, 'max-w-sm')} placeholder="Why? (kept in the history)" value={note} onChange={(e) => setNote(e.target.value)} maxLength={200} />
          <Button disabled={!dirty} loading={edit.isPending}
            onClick={async () => {
              const ok = await confirm({
                title: 'Change the autoscaler', confirmLabel: 'Save',
                description: 'This changes how the autoscaler behaves in production, within a minute. It can be reverted from the history below.',
              });
              if (ok) edit.mutate({ set: changedSet, ...(rulesChanged ? { rules } : {}), expectedData: data, note });
            }}>
            Save changes
          </Button>
          <Button variant="ghost" disabled={!dirty} onClick={() => { setValues(Object.fromEntries(settings.map((s) => [s.key, entry[s.key]]))); setRules(JSON.parse(JSON.stringify(entry.scalingRules ?? [])) as ScalingRule[]); }}>Discard</Button>
        </div>
      </PermissionGate>

      <HistoryList items={v.history} canRevert reverting={revert.isPending}
        onRevert={async (h) => {
          const ok = await confirm({ title: 'Revert this change', description: 'Put the settings and rules back to what they were before it.', confirmLabel: 'Revert', variant: 'danger' });
          if (ok) revert.mutate({ historyId: h.id, expectedData: data });
        }} />
    </div>
  );
}

function HistoryList({ items, canRevert, onRevert, reverting }: { items: HistoryItem[]; canRevert: boolean; onRevert: (h: HistoryItem) => void; reverting: boolean }) {
  return (
    <Card><CardContent>
      <div className="mb-2 flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-zinc-500"><History className="h-3.5 w-3.5" />History</div>
      {items.length === 0 ? <div className="text-xs text-zinc-500">No changes made from here yet.</div> : (
        <ul className="divide-y divide-zinc-100">
          {items.map((h) => (
            <li key={h.id} className="flex items-start gap-3 py-2 text-xs">
              <Badge variant={h.action === 'PAUSE' ? 'warning' : h.action === 'RESUME' ? 'success' : 'default'}>{h.action.toLowerCase()}</Badge>
              <div className="min-w-0 flex-1">
                <div className="text-zinc-800">{summarise(h)}</div>
                <div className="text-zinc-400">{h.actor} · {fmtTimeFull(h.ts)} ({relTime(h.ts)}){h.note ? ` · ${h.note}` : ''}</div>
              </div>
              {canRevert && (h.action === 'EDIT' || h.action === 'REVERT') && (
                <PermissionGate product="autopilot" permission="HPA_GUARDRAIL_EDIT">
                  <Button size="sm" variant="ghost" loading={reverting} onClick={() => onRevert(h)}><RotateCcw className="h-3.5 w-3.5" />Revert</Button>
                </PermissionGate>
              )}
            </li>
          ))}
        </ul>
      )}
    </CardContent></Card>
  );
}

/** What changed between the two entries, as short phrases. */
function summarise(h: HistoryItem): string {
  if (h.action === 'PAUSE') return 'Paused the autoscaler job';
  if (h.action === 'RESUME') return 'Resumed the autoscaler job';
  const b = h.before ?? {};
  const a = h.after ?? {};
  const parts: string[] = [];
  for (const k of Object.keys(a)) {
    if (k === 'scalingRules') continue;
    if (JSON.stringify(a[k]) !== JSON.stringify(b[k])) parts.push(`${settingLabel(k).label}: ${String(b[k])} → ${String(a[k])}`);
  }
  if (JSON.stringify(a.scalingRules) !== JSON.stringify(b.scalingRules)) parts.push('scaling rules changed');
  return parts.join(' · ') || 'No visible change';
}
