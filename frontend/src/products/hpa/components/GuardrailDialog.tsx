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
          <DialogTitle>Guardrails · {service}</DialogTitle>
          <DialogDescription>Hard limits every change to this service is checked against, whoever makes it.</DialogDescription>
        </DialogHeader>
        <DialogBody className="space-y-4">
          <label className="block text-xs text-zinc-600">Highest allowed max replicas
            <input type="number" min={1} className={cn(input, 'mt-1')} value={g.maxReplicasCap ?? ''} placeholder="no cap" onChange={set('maxReplicasCap')} />
          </label>
          <label className="block text-xs text-zinc-600">Lowest allowed min replicas
            <input type="number" min={1} className={cn(input, 'mt-1')} value={g.minReplicasFloor ?? ''} placeholder="no floor" onChange={set('minReplicasFloor')} />
          </label>
          <label className="block text-xs text-zinc-600">Largest single change to min or max (%)
            <input type="number" min={1} max={1000} className={cn(input, 'mt-1')} value={g.maxStepPct ?? ''} placeholder="no limit" onChange={set('maxStepPct')} />
          </label>
          <div className="rounded-lg border border-zinc-200 p-3">
            <label className="flex cursor-pointer items-center gap-2 text-sm font-medium text-zinc-800">
              <input type="checkbox" checked={g.frozen} onChange={(e) => setG({ ...g, frozen: e.target.checked })} /> Freeze this service
            </label>
            <p className="mt-1 text-xs text-zinc-500">While frozen, no schedule or manual change will be applied.</p>
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
