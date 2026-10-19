import { useEffect, useState } from 'react';
import { Button } from '../../../shared/ui/button';
import { Dialog, DialogBody, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '../../../shared/ui/dialog';
import { cn } from '../../../lib/utils';
import { useManualApply } from '../hooks';
import { DEFAULT_HEALTH_POLICY, type HealthPolicy, type HpaChange, type ResolvedHpa } from '../types';
import ChangeForm from './ChangeForm';
import HealthPolicyFields from './HealthPolicyFields';
import PreviewPanel, { type PreviewState } from './PreviewPanel';

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
  const canApply = preview.ready && preview.blocking.length === 0 && !preview.allNoop && !apply.isPending;

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent size="xl">
        <DialogHeader>
          <DialogTitle>Change HPA now · {service}</DialogTitle>
          <DialogDescription>Applies immediately, is checked after it lands, and rolls back on its own if the service looks unhealthy.</DialogDescription>
        </DialogHeader>
        <DialogBody className="space-y-5">
          {serving.length > 1 && (
            <label className="block text-xs font-semibold text-zinc-700">Apply to
              <select className={cn(input, 'mt-1 font-normal')} value={hpa} onChange={(e) => setHpa(e.target.value)}>
                <option value="">All serving HPAs ({serving.length})</option>
                {serving.map((h) => <option key={h.name} value={h.name}>{h.name}</option>)}
              </select>
            </label>
          )}
          <ChangeForm reference={reference} value={change} onChange={setChange} />
          <div>
            <div className="mb-1.5 text-xs font-semibold text-zinc-700">For how long</div>
            <div className="flex flex-wrap gap-1.5">
              {DURATIONS.map((d) => (
                <button key={d.label} type="button" onClick={() => setHours(d.hours)}
                  className={cn('h-8 cursor-pointer rounded-lg border px-3 text-xs font-medium', hours === d.hours ? 'border-sky-600 bg-sky-50 text-sky-800' : 'border-zinc-300 text-zinc-600 hover:bg-zinc-50')}>{d.label}</button>
              ))}
            </div>
          </div>
          <div>
            <button type="button" className="cursor-pointer text-xs font-semibold text-zinc-700 hover:underline" onClick={() => setShowPolicy((s) => !s)}>
              {showPolicy ? '▾' : '▸'} Health check &amp; auto-rollback
            </button>
            {showPolicy && <div className="mt-2"><HealthPolicyFields value={policy} onChange={setPolicy} /></div>}
          </div>
          <PreviewPanel product={product} service={service} hpa={hpa || undefined} change={change} onState={setPreview} />
        </DialogBody>
        <DialogFooter>
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
