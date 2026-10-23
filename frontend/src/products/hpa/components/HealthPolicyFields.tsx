import { cn } from '../../../lib/utils';
import type { HealthPolicy } from '../types';

const box = 'h-8 w-20 rounded-md border border-zinc-300 bg-white px-2 text-center text-sm focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-400';

/** The safety net, written as a sentence so it can be read, not decoded. */
export default function HealthPolicyFields({ value, onChange }: { value: HealthPolicy; onChange: (p: HealthPolicy) => void }) {
  const num = (k: keyof HealthPolicy) => (e: React.ChangeEvent<HTMLInputElement>) => onChange({ ...value, [k]: Number(e.target.value) });
  return (
    <div className="space-y-3 text-sm text-zinc-800">
      <label className="flex cursor-pointer items-start gap-2.5">
        <input type="checkbox" className="mt-1" checked={value.autoRollback} onChange={(e) => onChange({ ...value, autoRollback: e.target.checked })} />
        <span><span className="font-medium">Undo the change automatically if the service looks unhealthy</span>
          <span className="block text-xs text-zinc-500">Recommended. If you turn this off, problems are only reported on the timeline.</span></span>
      </label>
      <div className={cn('space-y-2 rounded-lg bg-zinc-50 px-3 py-3 leading-8', !value.autoRollback && 'opacity-50')}>
        <div>
          After the change, watch the service for{' '}
          <input type="number" min={0} max={7200} className={box} value={value.observeSeconds} onChange={num('observeSeconds')} /> seconds.
        </div>
        <div>
          It counts as unhealthy if more than{' '}
          <input type="number" min={1} max={100} className={box} value={value.maxUnavailablePct} onChange={num('maxUnavailablePct')} />
          {' '}% of pods are not ready for longer than{' '}
          <input type="number" min={0} max={7200} className={box} value={value.graceSeconds} onChange={num('graceSeconds')} /> seconds.
        </div>
        <p className="text-xs leading-5 text-zinc-500">New pods take a little while to start, so a short wait avoids undoing a healthy scale-up.</p>
      </div>
      <label className="flex cursor-pointer items-start gap-2.5">
        <input type="checkbox" className="mt-1" checked={value.rollbackOnScalingInactive} onChange={(e) => onChange({ ...value, rollbackOnScalingInactive: e.target.checked })} />
        <span>Also undo it if the autoscaler can no longer read its metrics</span>
      </label>
    </div>
  );
}
