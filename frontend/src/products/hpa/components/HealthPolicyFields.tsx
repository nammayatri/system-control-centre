import { cn } from '../../../lib/utils';
import type { HealthPolicy } from '../types';

const input = 'h-9 w-full rounded-lg border border-zinc-300 bg-white px-3 text-sm focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-400';

export default function HealthPolicyFields({ value, onChange }: { value: HealthPolicy; onChange: (p: HealthPolicy) => void }) {
  const num = (k: keyof HealthPolicy) => (e: React.ChangeEvent<HTMLInputElement>) => onChange({ ...value, [k]: Number(e.target.value) });
  return (
    <div className="space-y-3">
      <label className="flex cursor-pointer items-center gap-2 text-sm">
        <input type="checkbox" checked={value.autoRollback} onChange={(e) => onChange({ ...value, autoRollback: e.target.checked })} />
        <span className="font-medium text-zinc-800">Roll back automatically if the change looks unhealthy</span>
      </label>
      <div className="grid grid-cols-3 gap-3">
        <label className="text-xs text-zinc-600">Watch for (seconds)
          <input type="number" min={0} max={7200} className={cn(input, 'mt-1')} value={value.observeSeconds} onChange={num('observeSeconds')} />
        </label>
        <label className="text-xs text-zinc-600">Unready pods limit (%)
          <input type="number" min={1} max={100} className={cn(input, 'mt-1')} value={value.maxUnavailablePct} onChange={num('maxUnavailablePct')} />
        </label>
        <label className="text-xs text-zinc-600">…for longer than (s)
          <input type="number" min={0} max={7200} className={cn(input, 'mt-1')} value={value.graceSeconds} onChange={num('graceSeconds')} />
        </label>
      </div>
      <label className="flex cursor-pointer items-center gap-2 text-sm">
        <input type="checkbox" checked={value.rollbackOnScalingInactive} onChange={(e) => onChange({ ...value, rollbackOnScalingInactive: e.target.checked })} />
        <span className="text-zinc-700">Treat "HPA cannot read its metrics" as unhealthy</span>
      </label>
      <p className="text-[11px] text-zinc-500">
        A scale-up legitimately has unready pods for a while, so an issue only counts once it has lasted the grace period.
        Prometheus latency/error checks can be added through the API (<code>promChecks</code>).
      </p>
    </div>
  );
}
