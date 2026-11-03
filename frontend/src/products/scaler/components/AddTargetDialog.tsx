import { useEffect, useState } from 'react';
import { Search } from 'lucide-react';
import { Badge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { Dialog, DialogBody, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '../../../shared/ui/dialog';
import { cn } from '../../../lib/utils';
import Step from '../../hpa/components/Step';
import { discover, errorMessage } from '../api';
import { useAddTarget } from '../hooks';
import { kindLabel, modeLabel, stateLabel, stateVariant } from '../format';
import type { DiscoverItem, TargetKind } from '../types';

const input = 'h-9 w-full rounded-lg border border-zinc-300 bg-white px-3 text-sm focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-400';

/** Register something to scale: a Valkey instance or an AlloyDB read pool. The server reads it from Google Cloud before saving. */
export default function AddTargetDialog({ open, onOpenChange, onAdded }: { open: boolean; onOpenChange: (o: boolean) => void; onAdded?: (kind: TargetKind, id: string) => void }) {
  const [kind, setKind] = useState<TargetKind>('REDIS');
  const [project, setProject] = useState('');
  const [location, setLocation] = useState('');
  const [cluster, setCluster] = useState('');
  const [resource, setResource] = useState('');
  const [name, setName] = useState('');
  const [job, setJob] = useState('');
  const [jobLocation, setJobLocation] = useState('');
  const [items, setItems] = useState<DiscoverItem[] | null>(null);
  const [finding, setFinding] = useState(false);
  const [findError, setFindError] = useState<string | null>(null);

  useEffect(() => {
    if (!open) return;
    setKind('REDIS'); setProject(''); setLocation(''); setCluster(''); setResource(''); setName(''); setJob(''); setJobLocation('');
    setItems(null); setFindError(null);
  }, [open]);

  const add = useAddTarget((id) => { onOpenChange(false); onAdded?.(kind, id); });

  const find = async () => {
    setFinding(true); setFindError(null);
    try {
      const r = await discover(kind, project.trim(), location.trim());
      setItems(r.items);
      if (r.error) setFindError(r.error);
    } catch (e) {
      setItems(null); setFindError(errorMessage(e));
    } finally {
      setFinding(false);
    }
  };

  const pick = (i: DiscoverItem) => {
    setResource(i.resource);
    setCluster(i.cluster ?? '');
    if (!name.trim()) setName(i.resource);
  };

  const why =
    !project.trim() || !location.trim() ? 'Enter the project and location.'
    : !resource.trim() ? (kind === 'DB' ? 'Choose the read pool.' : 'Choose the instance.')
    : kind === 'DB' && !cluster.trim() ? 'A read pool needs its cluster.'
    : !name.trim() ? 'Give it a name.'
    : '';

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent size="xl">
        <DialogHeader>
          <DialogTitle>Add a target</DialogTitle>
          <DialogDescription>Register a Valkey instance or an AlloyDB read pool so it can be scheduled and its autoscaler managed from here.</DialogDescription>
        </DialogHeader>
        <DialogBody className="space-y-6">
          <Step n={1} title="What kind?">
            <div className="inline-flex rounded-lg border border-zinc-300 p-0.5 text-xs">
              {(['REDIS', 'DB'] as TargetKind[]).map((k) => (
                <button key={k} type="button" onClick={() => { setKind(k); setItems(null); setResource(''); setCluster(''); }}
                  className={cn('cursor-pointer rounded-md px-3 py-1.5 font-medium', kind === k ? 'bg-zinc-900 text-white' : 'text-zinc-600 hover:bg-zinc-100')}>{kindLabel(k)}</button>
              ))}
            </div>
          </Step>

          <Step n={2} title="Where is it?" help="The Google Cloud project and region. Find lists what exists there.">
            <div className="grid grid-cols-[1fr_1fr_auto] items-end gap-3">
              <label className="text-xs font-medium text-zinc-700">Project
                <input className={cn(input, 'mt-1 font-normal')} value={project} placeholder="e.g. ny-prod" onChange={(e) => setProject(e.target.value)} />
              </label>
              <label className="text-xs font-medium text-zinc-700">Location
                <input className={cn(input, 'mt-1 font-normal')} value={location} placeholder="e.g. asia-south1" onChange={(e) => setLocation(e.target.value)} />
              </label>
              <Button variant="secondary" loading={finding} disabled={!project.trim() || !location.trim()} onClick={find}><Search className="h-4 w-4" />Find</Button>
            </div>
            {findError && <div className="mt-2 rounded-lg bg-red-50 px-3 py-2 text-xs text-red-800">{findError}</div>}
            {items && items.length === 0 && !findError && <div className="mt-2 text-xs text-zinc-500">Nothing found there. You can still type the {kind === 'DB' ? 'cluster and read pool' : 'instance'} below.</div>}
            {items && items.length > 0 && (
              <ul className="mt-3 max-h-48 divide-y divide-zinc-100 overflow-y-auto rounded-lg border border-zinc-200">
                {items.map((i) => (
                  <li key={`${i.cluster ?? ''}/${i.resource}`}>
                    <button type="button" disabled={i.registered} onClick={() => pick(i)}
                      className={cn('flex w-full items-center gap-3 px-3 py-2 text-left text-sm', i.registered ? 'cursor-not-allowed opacity-50' : 'cursor-pointer hover:bg-zinc-50', resource === i.resource && cluster === (i.cluster ?? '') && 'bg-sky-50')}>
                      <span className="min-w-0 flex-1 truncate font-medium text-zinc-900">{i.cluster ? `${i.cluster} / ` : ''}{i.resource}</span>
                      <Badge variant="muted">{modeLabel(i.state.mode)}</Badge>
                      <Badge variant={stateVariant(i.state.state)} dot>{stateLabel(i.state.state)}</Badge>
                      <span className="w-20 text-right text-xs tabular-nums text-zinc-500">{i.state.units} {i.state.mode === 'READ_POOL' ? 'nodes' : 'shards'}</span>
                      {i.registered && <Badge variant="info">Added</Badge>}
                    </button>
                  </li>
                ))}
              </ul>
            )}
            <div className={cn('mt-3 grid gap-3', kind === 'DB' ? 'grid-cols-2' : 'grid-cols-1')}>
              {kind === 'DB' && (
                <label className="text-xs font-medium text-zinc-700">AlloyDB cluster
                  <input className={cn(input, 'mt-1 font-normal')} value={cluster} placeholder="e.g. driver-db-cluster" onChange={(e) => setCluster(e.target.value)} />
                </label>
              )}
              <label className="text-xs font-medium text-zinc-700">{kind === 'DB' ? 'Read pool' : 'Instance'}
                <input className={cn(input, 'mt-1 font-normal')} value={resource} placeholder={kind === 'DB' ? 'e.g. driver-db-cluster-reader-pool' : 'e.g. beckn-redis-cluster-001'} onChange={(e) => setResource(e.target.value)} />
              </label>
            </div>
          </Step>

          <Step n={3} title="Name it" help="How it shows up in the list.">
            <input className={cn(input, 'font-normal')} value={name} maxLength={100} placeholder="e.g. Beckn Redis cluster" onChange={(e) => setName(e.target.value)} />
          </Step>

          <Step n={4} title="Its autoscaler (optional)" help="The Cloud Scheduler job whose payload configures the autoscaler. Needed to edit the autoscaler here and to block its scale-in. The server checks the job really manages this target.">
            <div className="grid grid-cols-2 gap-3">
              <label className="text-xs font-medium text-zinc-700">Job name
                <input className={cn(input, 'mt-1 font-normal')} value={job} placeholder={kind === 'DB' ? 'e.g. poll-alloydb-readpool-metrics' : 'e.g. poll-cluster-metrics'} onChange={(e) => setJob(e.target.value)} />
              </label>
              <label className="text-xs font-medium text-zinc-700">Job location
                <input className={cn(input, 'mt-1 font-normal')} value={jobLocation} placeholder={location || 'same as above'} onChange={(e) => setJobLocation(e.target.value)} />
              </label>
            </div>
          </Step>
        </DialogBody>
        <DialogFooter>
          {why && <span className="mr-auto self-center text-xs text-zinc-500">{why}</span>}
          <Button variant="secondary" onClick={() => onOpenChange(false)}>Cancel</Button>
          <Button disabled={why !== '' || add.isPending} loading={add.isPending}
            onClick={() => add.mutate({
              kind, name: name.trim(), project: project.trim(), location: location.trim(), resource: resource.trim(),
              ...(kind === 'DB' ? { cluster: cluster.trim() } : {}),
              ...(job.trim() ? { autoscalerJob: job.trim() } : {}), ...(jobLocation.trim() ? { autoscalerLocation: jobLocation.trim() } : {}),
            })}>
            Add target
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
