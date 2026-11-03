import { useEffect, useState } from 'react';
import { Button } from '../../../shared/ui/button';
import { Dialog, DialogBody, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '../../../shared/ui/dialog';
import { cn } from '../../../lib/utils';
import { fromLocalInput, toLocalInput } from '../../hpa/format';
import { useManualApply } from '../hooks';
import type { InstanceState, ScaleChange, Target } from '../types';
import { ChangeFields, PreviewBox, type PreviewState } from './ChangeFields';

const input = 'h-9 w-full rounded-lg border border-zinc-300 bg-white px-3 text-sm focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-400';
const EMPTY: ScaleChange = { blockScaleIn: false, shrinkOnEnd: false };

/** Scale now. By default the hold ends on its own after a few hours; holding until restored by hand is a deliberate choice. */
export default function ScaleManualDialog({ open, onOpenChange, target, state }: {
  open: boolean; onOpenChange: (o: boolean) => void; target: Target; state: InstanceState | null;
}) {
  const [change, setChange] = useState<ScaleChange>(EMPTY);
  const [hold, setHold] = useState(false);
  const [endAt, setEndAt] = useState('');
  const [preview, setPreview] = useState<PreviewState>({ ready: false, blocking: [] });

  useEffect(() => {
    if (!open) return;
    setChange(EMPTY);
    setHold(false);
    setEndAt(toLocalInput(new Date(Date.now() + 4 * 3600_000).toISOString()));
  }, [open]);

  const end = hold ? null : fromLocalInput(endAt);
  const endProblem = !hold && (!end ? 'Choose when it ends.' : new Date(end).getTime() <= Date.now() ? 'The end is in the past.' : '');
  const noTarget = change.units == null && change.replicas == null;
  const whyNot = noTarget ? 'Choose the capacity to scale up to.' : endProblem || (!preview.ready ? 'Checking against the live target…' : preview.blocking[0] ?? '');
  const save = useManualApply(() => onOpenChange(false));

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent size="xl">
        <DialogHeader>
          <DialogTitle>Scale now · {target.name}</DialogTitle>
          <DialogDescription>
            Starts a resize right away. A resize takes a few minutes and can briefly disturb clients, so prefer a quiet hour or a schedule. Capacity is never reduced by this.
          </DialogDescription>
        </DialogHeader>
        <DialogBody className="space-y-5">
          <ChangeFields target={target} state={state} value={change} onChange={setChange} />
          <div>
            <div className="mb-1 text-xs font-medium text-zinc-700">When should the hold end?</div>
            <label className="flex cursor-pointer items-center gap-2 text-xs text-zinc-700">
              <input type="checkbox" checked={hold} onChange={(e) => setHold(e.target.checked)} /> Never: I will restore it by hand
            </label>
            {!hold && <input type="datetime-local" className={cn(input, 'mt-2')} value={endAt} onChange={(e) => setEndAt(e.target.value)} />}
            {hold && <p className="mt-1 text-[11px] text-amber-700">A hold with no end keeps this target's autoscaler pinned and blocks every scheduled window until someone restores it.</p>}
            {endProblem && <div className="mt-1 text-xs text-red-700">{endProblem}</div>}
          </div>
          <PreviewBox target={target} change={change} onState={setPreview} />
        </DialogBody>
        <DialogFooter>
          {whyNot && <span className="mr-auto self-center text-xs text-zinc-500">{whyNot}</span>}
          <Button variant="secondary" onClick={() => onOpenChange(false)}>Cancel</Button>
          <Button disabled={whyNot !== '' || save.isPending} loading={save.isPending}
            onClick={() => save.mutate({ targetKind: target.kind, targetId: target.id, change, ...(end ? { endAt: end } : {}) })}>
            Scale now
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
