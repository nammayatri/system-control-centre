import { useEffect, useState } from 'react';
import { Button } from '../../../shared/ui/button';
import { Dialog, DialogBody, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '../../../shared/ui/dialog';
import { cn } from '../../../lib/utils';
import { useSaveGuardrail } from '../hooks';
import { numOrUndef } from '../format';
import type { Guardrail } from '../types';

const input = 'h-9 w-full rounded-lg border border-zinc-300 bg-white px-3 text-sm focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-400';

export default function GuardrailDialog({ open, onOpenChange, product, service, value }: {
  open: boolean; onOpenChange: (o: boolean) => void; product: string; service: string; value: Guardrail;
}) {
  const [g, setG] = useState<Guardrail>(value);
  useEffect(() => { if (open) setG(value); }, [open, value]);
  const save = useSaveGuardrail(product, service, () => onOpenChange(false));
  const set = (k: 'maxReplicasCap' | 'minReplicasFloor' | 'maxStepPct') => (e: React.ChangeEvent<HTMLInputElement>) =>
    setG({ ...g, [k]: numOrUndef(e.target.value) ?? null });
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent size="md">
        <DialogHeader>
          <DialogTitle>Safety limits · {service}</DialogTitle>
          <DialogDescription>Limits that every change to this service must stay within, whether it comes from a schedule or from someone clicking “Change now”. A change that breaks a limit is refused.</DialogDescription>
        </DialogHeader>
        <DialogBody className="space-y-4">
          <label className="block text-xs text-zinc-600">Never let the maximum go above
            <input type="number" min={1} className={cn(input, 'mt-1')} value={g.maxReplicasCap ?? ''} placeholder="no limit" onChange={set('maxReplicasCap')} />
          </label>
          <label className="block text-xs text-zinc-600">Never let the minimum go below
            <input type="number" min={1} className={cn(input, 'mt-1')} value={g.minReplicasFloor ?? ''} placeholder="no limit" onChange={set('minReplicasFloor')} />
          </label>
          <label className="block text-xs text-zinc-600">Largest single jump allowed (%)
            <input type="number" min={1} max={1000} className={cn(input, 'mt-1')} value={g.maxStepPct ?? ''} placeholder="no limit" onChange={set('maxStepPct')} />
            <span className="mt-1 block text-[11px] text-zinc-500">For example 100 means a maximum of 20 can be raised to at most 40 in one go, never straight to 200.</span>
          </label>
          <div className="rounded-lg border border-zinc-200 p-3">
            <label className="flex cursor-pointer items-center gap-2 text-sm font-medium text-zinc-800">
              <input type="checkbox" checked={g.frozen} onChange={(e) => setG({ ...g, frozen: e.target.checked })} /> Freeze: allow no changes at all
            </label>
            <p className="mt-1 text-xs text-zinc-500">Use this during a sensitive period (for example a big release or an incident). Schedules wait or are skipped until you unfreeze.</p>
            {g.frozen && <input className={cn(input, 'mt-2')} placeholder="Reason (shown to others)" value={g.frozenReason ?? ''} onChange={(e) => setG({ ...g, frozenReason: e.target.value || null })} />}
          </div>
        </DialogBody>
        <DialogFooter>
          <Button variant="secondary" onClick={() => onOpenChange(false)}>Cancel</Button>
          <Button loading={save.isPending} onClick={() => save.mutate(g)}>Save</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
