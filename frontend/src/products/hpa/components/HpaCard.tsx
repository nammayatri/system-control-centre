import { Badge } from '../../../shared/ui/badge';
import { Card, CardContent } from '../../../shared/ui/card';
import { cn } from '../../../lib/utils';
import { RoleBadge } from './Badges';
import type { ResolvedHpa } from '../types';

export default function HpaCard({ hpa }: { hpa: ResolvedHpa }) {
  const managedBy = hpa.annotations['sc.juspay.in/hpa-schedule-id'];
  const bad = hpa.status.conditions.filter((c) => c.type === 'ScalingActive' && c.status === 'False');
  const limited = hpa.status.conditions.find((c) => c.type === 'ScalingLimited' && c.status === 'True');
  return (
    <Card className={cn(hpa.role === 'SERVING' && 'border-emerald-300')}>
      <CardContent className="space-y-3">
        <div className="flex flex-wrap items-center gap-2">
          <span className="font-mono text-sm font-semibold text-zinc-900">{hpa.name}</span>
          <RoleBadge role={hpa.role} />
          {hpa.trafficWeight != null && <Badge variant="muted">{hpa.trafficWeight}% traffic</Badge>}
          {managedBy && <Badge variant="blue">Change applied by {managedBy === 'manual' ? 'a manual apply' : 'a schedule'}</Badge>}
          {!hpa.editable && <Badge variant="danger">Not editable</Badge>}
        </div>

        <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          <Stat label="Current" value={hpa.status.currentReplicas} />
          <Stat label="Desired" value={hpa.status.desiredReplicas} />
          <Stat label="Min" value={hpa.spec.minReplicas} />
          <Stat label="Max" value={hpa.spec.maxReplicas} />
        </div>

        <div>
          <div className="mb-1 text-[11px] font-medium uppercase tracking-wide text-zinc-500">Scales on</div>
          <div className="flex flex-wrap gap-1.5">
            {hpa.metricSummary.map((m) => <Badge key={m} variant="default">{m}</Badge>)}
          </div>
          <div className="mt-1 text-[11px] text-zinc-500">HPA scales to the highest replica count any metric asks for.</div>
        </div>

        {(hpa.spec.behavior?.scaleUp || hpa.spec.behavior?.scaleDown) && (
          <div className="text-xs text-zinc-600">
            {(['scaleUp', 'scaleDown'] as const).map((d) => {
              const r = hpa.spec.behavior?.[d];
              if (!r) return null;
              return (
                <div key={d}>
                  <span className="font-medium">{d === 'scaleUp' ? 'Scale up' : 'Scale down'}:</span>{' '}
                  {r.stabilizationWindowSeconds != null && `stabilise ${r.stabilizationWindowSeconds}s`}
                  {r.selectPolicy && ` · ${r.selectPolicy}`}
                  {(r.policies ?? []).map((p, i) => ` · ${p.value}${p.type === 'Percent' ? '%' : ' pods'}/${p.periodSeconds}s${i ? '' : ''}`)}
                </div>
              );
            })}
          </div>
        )}

        {bad.map((c) => (
          <div key={c.type} className="rounded-md bg-red-50 px-3 py-2 text-xs text-red-800">
            HPA cannot read its metrics: {c.reason}{c.message ? ` — ${c.message}` : ''}
          </div>
        ))}
        {limited && <div className="rounded-md bg-amber-50 px-3 py-2 text-xs text-amber-800">Scaling is limited: {limited.reason}</div>}
        {hpa.notEditableReason && <div className="rounded-md bg-zinc-100 px-3 py-2 text-xs text-zinc-700">{hpa.notEditableReason}</div>}
        {hpa.validationIssues.length > 0 && (
          <div className="rounded-md bg-amber-50 px-3 py-2 text-xs text-amber-800">{hpa.validationIssues.join('; ')}</div>
        )}
      </CardContent>
    </Card>
  );
}

function Stat({ label, value }: { label: string; value: number }) {
  return (
    <div className="rounded-lg bg-zinc-50 px-3 py-2">
      <div className="text-[11px] uppercase tracking-wide text-zinc-500">{label}</div>
      <div className="text-xl font-semibold text-zinc-900">{value}</div>
    </div>
  );
}
