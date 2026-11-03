import { useEffect, useState } from 'react';
import { Button } from '../../../shared/ui/button';
import { Dialog, DialogBody, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '../../../shared/ui/dialog';
import { cn } from '../../../lib/utils';
import { useEditTarget } from '../hooks';
import type { Target } from '../types';

const input = 'h-9 w-full rounded-lg border border-zinc-300 bg-white px-3 text-sm focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-400';

/** The name and the autoscaler job can change; the instance itself cannot (register a new target for that). */
export default function EditTargetDialog({ open, onOpenChange, target }: { open: boolean; onOpenChange: (o: boolean) => void; target: Target }) {
  const [name, setName] = useState(target.name);
  const [job, setJob] = useState(target.autoscalerJob ?? '');
  const [jobLocation, setJobLocation] = useState(target.autoscalerLocation ?? '');
  useEffect(() => {
    if (!open) return;
    setName(target.name); setJob(target.autoscalerJob ?? ''); setJobLocation(target.autoscalerLocation ?? '');
  }, [open, target]);
  const save = useEditTarget(target, () => onOpenChange(false));
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent size="md">
        <DialogHeader>
          <DialogTitle>Target settings</DialogTitle>
          <DialogDescription>{target.parent ? `${target.parent} / ` : ''}{target.resource} · {target.project} · {target.location}</DialogDescription>
        </DialogHeader>
        <DialogBody className="space-y-4">
          <label className="block text-xs font-medium text-zinc-700">Name
            <input className={cn(input, 'mt-1 font-normal')} value={name} maxLength={100} onChange={(e) => setName(e.target.value)} />
          </label>
          <label className="block text-xs font-medium text-zinc-700">Autoscaler job (Cloud Scheduler)
            <input className={cn(input, 'mt-1 font-normal')} value={job} placeholder="none" onChange={(e) => setJob(e.target.value)} />
            <span className="mt-1 block text-[11px] font-normal text-zinc-500">The server checks the job exists and manages this target before saving. Leave empty to remove it.</span>
          </label>
          <label className="block text-xs font-medium text-zinc-700">Job location
            <input className={cn(input, 'mt-1 font-normal')} value={jobLocation} placeholder={target.location} onChange={(e) => setJobLocation(e.target.value)} />
          </label>
        </DialogBody>
        <DialogFooter>
          <Button variant="secondary" onClick={() => onOpenChange(false)}>Cancel</Button>
          <Button loading={save.isPending} disabled={!name.trim()}
            onClick={() => save.mutate({ name: name.trim(), ...(job.trim() ? { autoscalerJob: job.trim() } : {}), ...(jobLocation.trim() ? { autoscalerLocation: jobLocation.trim() } : {}) })}>
            Save
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
