import { useEffect, useState } from 'react';
import { Button } from '../../../shared/ui/button';
import { Dialog, DialogBody, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '../../../shared/ui/dialog';
import { cn } from '../../../lib/utils';
import { useManualApply } from '../hooks';
import { DEFAULT_HEALTH_POLICY, type HealthPolicy, type HpaChange, type ResolvedHpa } from '../types';
import ChangeForm from './ChangeForm';
import HealthPolicyFields from './HealthPolicyFields';
import ChangeSummary from './ChangeSummary';
import PreviewPanel, { type PreviewState } from './PreviewPanel';
import Step from './Step';

const input = 'h-9 w-full rounded-lg border border-zinc-300 bg-white px-3 text-sm focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-400';
const DURATIONS: { label: string; hours: number | null }[] = [
  { label: '1 hour', hours: 1 }, { label: '2 hours', hours: 2 }, { label: '4 hours', hours: 4 }, { label: '8 hours', hours: 8 }, { label: '24 hours', hours: 24 }, { label: 'Until I restore it', hours: null },
];

interface Props { open: boolean; onOpenChange: (o: boolean) => void; product: string; service: string; serving: ResolvedHpa[] }

/** Change the serving HPA right now, optionally for a limited time. Same checks and the same safety net as a schedule. */
export default function ManualApplyDialog({ open, onOpenChange, product, service, serving }: Props) {
  const [change, setChange] = useState<HpaChange>({});
  const [hours, setHours] = useState<number | null>(2);
  const [hpa, setHpa] = useState('');
  const [policy, setPolicy] = useState<HealthPolicy>(DEFAULT_HEALTH_POLICY);
  const [showPolicy, setShowPolicy] = useState(false);
  const [preview, setPreview] = useState<PreviewState>({ ready: false, blocking: [], allNoop: false });
  const apply = useManualApply(() => onOpenChange(false));

  useEffect(() => { if (open) { setChange({}); setHours(2); setHpa(''); setPolicy(DEFAULT_HEALTH_POLICY); setShowPolicy(false); } }, [open]);
  const reference = (serving.find((h) => h.name === hpa) ?? serving[0])?.spec ?? null;
  const noChange = !change.minReplicas && !change.maxReplicas && !(change.metricTargets?.length) && !change.scaleUp && !change.scaleDown;
  const whyNot = noChange ? 'Choose what to change in step 1.' : !preview.ready ? 'Checking against the live autoscaler…'
    : preview.blocking.length > 0 ? preview.blocking[0] : preview.allNoop ? 'These are already the current values.' : '';
  const canApply = whyNot === '' && !apply.isPending;
  const current = (serving.find((h) => h.name === hpa) ?? serving[0])?.status.currentReplicas;

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent size="xl">
        <DialogHeader>
          <DialogTitle>Change scaling limits now · {service}</DialogTitle>
          <DialogDescription>Applies right away. It is checked after it lands and undone automatically if the service looks unhealthy. Choose how long it should last, or restore it yourself later.</DialogDescription>
        </DialogHeader>
        <DialogBody className="space-y-7">
          {serving.length > 1 && (
            <label className="block text-xs font-medium text-zinc-700">Which autoscaler?
              <select className={cn(input, 'mt-1 font-normal')} value={hpa} onChange={(e) => setHpa(e.target.value)}>
                <option value="">All that are serving traffic ({serving.length})</option>
                {serving.map((h) => <option key={h.name} value={h.name}>{h.name}</option>)}
              </select>
            </label>
          )}
          <Step n={1} title="What should change?" help="Only fill in what you want to change.">
            <ChangeForm reference={reference} currentReplicas={current} value={change} onChange={setChange} />
          </Step>
          <Step n={2} title="For how long?" help="After this, the original values come back automatically.">
            <div className="flex flex-wrap gap-1.5">
              {DURATIONS.map((d) => (
                <button key={d.label} type="button" onClick={() => setHours(d.hours)}
                  className={cn('h-8 cursor-pointer rounded-lg border px-3 text-xs font-medium', hours === d.hours ? 'border-sky-600 bg-sky-50 text-sky-800' : 'border-zinc-300 text-zinc-600 hover:bg-zinc-50')}>{d.label}</button>
              ))}
            </div>
          </Step>
          <Step n={3} title="Safety net" help="Checks the service after the change and undoes it if something goes wrong.">
            <button type="button" className="cursor-pointer text-xs font-medium text-sky-700 hover:underline" onClick={() => setShowPolicy((x) => !x)}>
              {showPolicy ? 'Hide settings' : policy.autoRollback ? `On: watches for ${policy.observeSeconds}s. Change…` : 'Off. Change…'}
            </button>
            {showPolicy && <div className="mt-3"><HealthPolicyFields value={policy} onChange={setPolicy} /></div>}
          </Step>
          <Step n={4} title="Review">
            <div className="space-y-3">
              <ChangeSummary change={change} reference={reference} when={hours == null ? 'Applied now, until you restore it.' : `Applied now, for ${hours} hour${hours > 1 ? 's' : ''}.`} />
              <PreviewPanel product={product} service={service} hpa={hpa || undefined} change={change} onState={setPreview} />
            </div>
          </Step>
        </DialogBody>
        <DialogFooter>
          {whyNot && <span className="mr-auto self-center text-xs text-zinc-500">{whyNot}</span>}
          <Button variant="secondary" onClick={() => onOpenChange(false)}>Cancel</Button>
          <Button disabled={!canApply} loading={apply.isPending}
            onClick={() => apply.mutate({ product, service, hpa: hpa || undefined, change, healthPolicy: policy, endAt: hours == null ? undefined : new Date(Date.now() + hours * 3600_000).toISOString() })}>
            Apply now
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
