import { useEffect, useState } from 'react';
import { Button } from '../../../shared/ui/button';
import { Dialog, DialogBody, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '../../../shared/ui/dialog';
import { cn } from '../../../lib/utils';
import { numOrUndef } from '../../hpa/format';
import { useSaveGuardrail } from '../hooks';
import type { Guardrail, Target } from '../types';

const input = 'h-9 w-full rounded-lg border border-zinc-300 bg-white px-3 text-sm focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-400';

export default function ScaleGuardrailDialog({ open, onOpenChange, target, value }: {
  open: boolean; onOpenChange: (o: boolean) => void; target: Target; value: Guardrail;
}) {
  const [g, setG] = useState<Guardrail>(value);
  useEffect(() => { if (open) setG(value); }, [open, value]);
  const save = useSaveGuardrail(target, () => onOpenChange(false));
  const set = (k: 'maxUnits' | 'maxReplicas' | 'maxStep') => (e: React.ChangeEvent<HTMLInputElement>) =>
    setG({ ...g, [k]: numOrUndef(e.target.value) ?? null });
  const unit = target.kind === 'DB' ? 'nodes' : 'shards';
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent size="md">
        <DialogHeader>
          <DialogTitle>Safety limits · {target.name}</DialogTitle>
          <DialogDescription>Limits every change must stay within, from a schedule or from “Scale now”. A change that breaks one is refused.</DialogDescription>
        </DialogHeader>
        <DialogBody className="space-y-4">
          <label className="block text-xs text-zinc-600">Never scale above ({unit})
            <input type="number" min={1} className={cn(input, 'mt-1')} value={g.maxUnits ?? ''} placeholder={`no limit (hard cap ${target.kind === 'DB' ? 20 : 250})`} onChange={set('maxUnits')} />
          </label>
          {target.kind === 'REDIS' && (
            <label className="block text-xs text-zinc-600">Never scale above (replicas)
              <input type="number" min={0} className={cn(input, 'mt-1')} value={g.maxReplicas ?? ''} placeholder="no limit (hard cap 5)" onChange={set('maxReplicas')} />
            </label>
          )}
          <label className="block text-xs text-zinc-600">Most {unit} added in one go
            <input type="number" min={1} className={cn(input, 'mt-1')} value={g.maxStep ?? ''} placeholder="no limit" onChange={set('maxStep')} />
          </label>
          <div className="rounded-lg border border-zinc-200 p-3">
            <label className="flex cursor-pointer items-center gap-2 text-sm font-medium text-zinc-800">
              <input type="checkbox" checked={g.frozen} onChange={(e) => setG({ ...g, frozen: e.target.checked })} /> Freeze: allow no resizes at all
            </label>
            <p className="mt-1 text-xs text-zinc-500">Use this during an incident or a sensitive period. Schedules are skipped until you unfreeze; an apply already running is rolled back.</p>
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
