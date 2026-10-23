import type { ApplyStatus, HpaChange, HpaRole, MetricTarget, ScheduleKind } from './types';

export const IST = 'Asia/Kolkata';

export function fmtTime(iso?: string | null): string {
  if (!iso) return '—';
  const d = new Date(iso);
  if (isNaN(d.getTime())) return '—';
  return d.toLocaleString('en-IN', { timeZone: IST, day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit', hour12: false }) + ' IST';
}

export function fmtTimeFull(iso?: string | null): string {
  if (!iso) return '—';
  const d = new Date(iso);
  if (isNaN(d.getTime())) return '—';
  return d.toLocaleString('en-IN', { timeZone: IST, day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false }) + ' IST';
}

export function fmtClock(iso: string): string {
  return new Date(iso).toLocaleTimeString('en-IN', { timeZone: IST, hour: '2-digit', minute: '2-digit', hour12: false });
}

export function fmtDay(iso: string): string {
  return new Date(iso).toLocaleDateString('en-IN', { timeZone: IST, day: '2-digit', month: 'short' });
}

export function relTime(iso?: string | null): string {
  if (!iso) return '';
  const diff = new Date(iso).getTime() - Date.now();
  const abs = Math.abs(diff);
  const mins = Math.round(abs / 60000);
  const text = mins < 1 ? 'moments' : mins < 60 ? `${mins}m` : mins < 1440 ? `${Math.round(mins / 60)}h` : `${Math.round(mins / 1440)}d`;
  return diff >= 0 ? `in ${text}` : `${text} ago`;
}

export function durationText(minutes: number): string {
  if (minutes < 60) return `${minutes}m`;
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return m ? `${h}h ${m}m` : `${h}h`;
}

export const WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

export function offsetLabel(minutes: number): string {
  if (minutes === 0) return 'UTC';
  const sign = minutes < 0 ? '-' : '+';
  const a = Math.abs(minutes);
  return `UTC${sign}${String(Math.floor(a / 60)).padStart(2, '0')}:${String(a % 60).padStart(2, '0')}${minutes === 330 ? ' (IST)' : ''}`;
}

export function describeKind(k: ScheduleKind): string {
  if (k.kind === 'ONCE') {
    return k.endAt ? `Once · ${fmtTime(k.startAt)} → ${fmtTime(k.endAt)}` : `Once · from ${fmtTime(k.startAt)}, until restored by hand`;
  }
  const days = k.days.length === 7 ? 'Every day' : k.days.length === 5 && k.days.every((d) => d <= 5) ? 'Mon–Fri' : k.days.map((d) => WEEKDAYS[d - 1]).join(', ');
  return `${days} · ${k.startTime} for ${durationText(k.durationMinutes)} · ${offsetLabel(k.utcOffsetMinutes)}`;
}

export function describeTarget(t: MetricTarget): string {
  switch (t.type) {
    case 'Utilization': return `${t.averageUtilization}%`;
    case 'AverageValue': return `avg ${t.averageValue}`;
    case 'Value': return `value ${t.value}`;
  }
}

export function describeChange(c: HpaChange): string[] {
  const out: string[] = [];
  if (c.minReplicas != null) out.push(`min ${c.minReplicas}`);
  if (c.maxReplicas != null) out.push(`max ${c.maxReplicas}`);
  for (const m of c.metricTargets ?? []) out.push(`${m.key.replace(/^[a-zA-Z]+\//, '')} ${describeTarget(m.target)}`);
  if (c.scaleUp) out.push('scale-up rules');
  if (c.scaleDown) out.push('scale-down rules');
  return out;
}

export type Variant = 'default' | 'success' | 'warning' | 'danger' | 'info' | 'muted' | 'purple' | 'blue';

export function statusVariant(s: ApplyStatus): Variant {
  switch (s) {
    case 'APPLIED': return 'success';
    case 'PENDING': return 'muted';
    case 'APPLYING': case 'OBSERVING': case 'RESTORING': return 'info';
    case 'ROLLING_BACK': case 'ROLLED_BACK': return 'warning';
    case 'FAILED': case 'NEEDS_ATTENTION': return 'danger';
    case 'RESTORED': return 'default';
    case 'SKIPPED': return 'muted';
  }
}

export const STATUS_LABEL: Record<ApplyStatus, string> = {
  PENDING: 'Pending', APPLYING: 'Applying', OBSERVING: 'Observing', APPLIED: 'Change live', RESTORING: 'Restoring',
  RESTORED: 'Restored', ROLLING_BACK: 'Rolling back', ROLLED_BACK: 'Rolled back', FAILED: 'Failed',
  NEEDS_ATTENTION: 'Needs attention', SKIPPED: 'Skipped',
};

export function roleVariant(r: HpaRole): Variant {
  return r === 'SERVING' ? 'success' : r === 'DRAINING' ? 'warning' : 'muted';
}

/** Browser-local `datetime-local` value (YYYY-MM-DDTHH:mm) from an ISO instant. */
export function toLocalInput(iso: string | null | undefined): string {
  if (!iso) return '';
  const d = new Date(iso);
  if (isNaN(d.getTime())) return '';
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
}

/** ISO instant from a browser-local `datetime-local` value. */
export function fromLocalInput(v: string): string | null {
  if (!v) return null;
  const d = new Date(v);
  return isNaN(d.getTime()) ? null : d.toISOString();
}

/** Parse a quantity-ish number field; empty = undefined. NaN-safe. */
export function numOrUndef(v: string): number | undefined {
  if (v.trim() === '') return undefined;
  const n = Number(v);
  return Number.isFinite(n) ? n : undefined;
}

/** Plain-language name and one-line explanation for a metric key such as `resource/cpu`. */
export function metricLabel(key: string): { title: string; hint: string } {
  const [kind, ...rest] = key.split('/');
  const name = rest[rest.length - 1] ?? key;
  if (kind === 'resource' && name === 'cpu') return { title: 'CPU target', hint: 'Adds pods when average CPU use goes above this, removes them when it falls well below.' };
  if (kind === 'resource' && name === 'memory') return { title: 'Memory target', hint: 'Adds pods when average memory use goes above this.' };
  if (kind === 'containerResource') return { title: `${name} target (container ${rest[0]})`, hint: 'Same idea as CPU/memory, measured for one container only.' };
  if (kind === 'pods') return { title: `Custom metric: ${name}`, hint: 'Average value of this metric per pod.' };
  if (kind === 'object') return { title: `Object metric: ${name}`, hint: 'A metric read from a Kubernetes object (for example an Ingress).' };
  if (kind === 'external') return { title: `External metric: ${name}`, hint: 'A metric from outside the cluster (for example a queue length).' };
  return { title: key, hint: '' };
}

/** "Min 2 → 10" style lines describing what a change does to a reference spec. */
export function summaryLines(
  change: HpaChange,
  ref: { minReplicas: number; maxReplicas: number; metrics: any[] } | null,
  keyOf: (m: any) => string | null,
): string[] {
  const out: string[] = [];
  if (change.minReplicas != null) out.push(`Minimum pods: ${ref ? ref.minReplicas : '?'} → ${change.minReplicas}`);
  if (change.maxReplicas != null) out.push(`Maximum pods: ${ref ? ref.maxReplicas : '?'} → ${change.maxReplicas}`);
  for (const m of change.metricTargets ?? []) {
    const cur = ref?.metrics.find((x) => keyOf(x) === m.key);
    const t = cur ? (cur[{ Resource: 'resource', ContainerResource: 'containerResource', Pods: 'pods', Object: 'object', External: 'external' }[cur.type as string] ?? '']?.target as MetricTarget | undefined) : undefined;
    out.push(`${metricLabel(m.key).title}: ${t ? describeTarget(t) : '?'} → ${describeTarget(m.target)}`);
  }
  const rules = (r: HpaChange['scaleUp']) => (r && (r.stabilizationWindowSeconds != null || r.selectPolicy || (r.policies ?? []).length) ? 'custom rules' : 'reset to defaults (nothing set)');
  if (change.scaleUp) out.push(`How fast it adds pods: ${rules(change.scaleUp)}`);
  if (change.scaleDown) out.push(`How fast it removes pods: ${rules(change.scaleDown)}`);
  return out;
}
