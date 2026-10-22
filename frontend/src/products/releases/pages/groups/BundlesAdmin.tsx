import React, { useMemo, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { ArrowDown, ArrowUp, Plus, Trash2 } from 'lucide-react';
import { toast } from 'sonner';
import { Button } from '../../../../shared/ui/button';
import { Badge } from '../../../../shared/ui/badge';
import { PermissionGate } from '../../../../core/auth/PermissionGate';
import { archiveBundle, createBundle, fetchBundles, updateBundle } from '../../api';
import type { BundleInput, BundleStage, BundleStep, ReleaseBundle, StageMode } from '../../api';
import { useProductConfigs, useServices } from '../../useProducts';
import type { ProductConfig } from '../../api';

const inputClass =
  'w-full h-9 border border-zinc-300 rounded-lg px-3 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent';

const emptyStage = (n: number): BundleStage => ({ name: `Stage ${n}`, mode: 'PARALLEL', steps: [{ appGroup: '', service: '' }] });

/** One bundle step: pick an app group, then one of its services. */
const StepRow: React.FC<{
  step: BundleStep;
  appGroups: string[];
  onChange: (s: BundleStep) => void;
  onRemove: () => void;
  canRemove: boolean;
}> = ({ step, appGroups, onChange, onRemove, canRemove }) => {
  const { data: services = [] } = useServices(step.appGroup);
  return (
    <div className="flex items-center gap-2">
      <select
        className={inputClass}
        value={step.appGroup}
        onChange={e => onChange({ appGroup: e.target.value, service: '' })}
      >
        <option value="">App group…</option>
        {appGroups.map(g => (
          <option key={g} value={g}>{g}</option>
        ))}
      </select>
      <select
        className={inputClass}
        value={step.service}
        disabled={!step.appGroup}
        onChange={e => onChange({ ...step, service: e.target.value })}
      >
        <option value="">Service…</option>
        {services.map((s: string) => (
          <option key={s} value={s}>{s}</option>
        ))}
      </select>
      <Button variant="ghost" size="icon-sm" onClick={onRemove} disabled={!canRemove} aria-label="Remove service">
        <Trash2 className="w-4 h-4" />
      </Button>
    </div>
  );
};

const BundleEditor: React.FC<{
  initial?: ReleaseBundle;
  appGroups: string[];
  onDone: () => void;
}> = ({ initial, appGroups, onDone }) => {
  const qc = useQueryClient();
  const [name, setName] = useState(initial?.name ?? '');
  const [description, setDescription] = useState(initial?.description ?? '');
  const [stages, setStages] = useState<BundleStage[]>(initial?.stages ?? [emptyStage(1)]);

  const save = useMutation({
    mutationFn: (input: BundleInput) => (initial ? updateBundle(initial.bundleId, input) : createBundle(input)),
    onSuccess: () => {
      toast.success(initial ? 'Bundle updated' : 'Bundle created');
      qc.invalidateQueries({ queryKey: ['release-bundles'] });
      onDone();
    },
    onError: (err: any) => toast.error(err?.response?.data?.message || err.message || 'Failed to save bundle'),
  });

  const patchStage = (i: number, patch: Partial<BundleStage>) =>
    setStages(prev => prev.map((s, idx) => (idx === i ? { ...s, ...patch } : s)));
  const move = (i: number, dir: -1 | 1) =>
    setStages(prev => {
      const j = i + dir;
      if (j < 0 || j >= prev.length) return prev;
      const next = [...prev];
      [next[i], next[j]] = [next[j], next[i]];
      return next;
    });

  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    const clean = stages.map(s => ({ ...s, steps: s.steps.filter(st => st.appGroup && st.service) }));
    if (!name.trim()) return toast.error('Give the bundle a name');
    if (clean.some(s => s.steps.length === 0)) return toast.error('Every stage needs at least one service');
    save.mutate({ name: name.trim(), description: description.trim(), stages: clean });
  };

  return (
    <form onSubmit={submit} className="bg-white rounded-xl border border-zinc-200 p-4 sm:p-6 space-y-5">
      <h2 className="text-base font-semibold text-zinc-900">{initial ? `Edit ${initial.name}` : 'New bundle'}</h2>
      <div className="grid sm:grid-cols-2 gap-4">
        <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider">
          Name
          <input className={`${inputClass} mt-1.5 normal-case tracking-normal`} value={name} onChange={e => setName(e.target.value)} placeholder="Driver platform" />
        </label>
        <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider">
          Description
          <input className={`${inputClass} mt-1.5 normal-case tracking-normal`} value={description} onChange={e => setDescription(e.target.value)} placeholder="driver-offer, allocator, producer, ride-event-stream" />
        </label>
      </div>

      <div className="space-y-3">
        <p className="text-xs text-zinc-500">
          Stages run top to bottom — a stage starts only after the one above it completes. Inside a stage, services
          release together (Parallel) or one after another (Sequential).
        </p>
        {stages.map((stage, i) => (
          <div key={i} className="rounded-lg border border-zinc-200 p-3 space-y-3 bg-zinc-50/50">
            <div className="flex flex-wrap items-center gap-2">
              <span className="text-xs font-mono text-zinc-400 w-5">{i + 1}</span>
              <input className={`${inputClass} flex-1 min-w-40`} value={stage.name} onChange={e => patchStage(i, { name: e.target.value })} placeholder="Stage name" />
              <select className={`${inputClass} w-40`} value={stage.mode} onChange={e => patchStage(i, { mode: e.target.value as StageMode })}>
                <option value="PARALLEL">Parallel</option>
                <option value="SEQUENTIAL">One by one</option>
              </select>
              <Button variant="ghost" size="icon-sm" onClick={() => move(i, -1)} disabled={i === 0} aria-label="Move stage up"><ArrowUp className="w-4 h-4" /></Button>
              <Button variant="ghost" size="icon-sm" onClick={() => move(i, 1)} disabled={i === stages.length - 1} aria-label="Move stage down"><ArrowDown className="w-4 h-4" /></Button>
              <Button variant="ghost" size="icon-sm" onClick={() => setStages(prev => prev.filter((_, idx) => idx !== i))} disabled={stages.length === 1} aria-label="Remove stage"><Trash2 className="w-4 h-4" /></Button>
            </div>
            <div className="space-y-2 pl-0 sm:pl-7">
              {stage.steps.map((step, j) => (
                <StepRow
                  key={j}
                  step={step}
                  appGroups={appGroups}
                  canRemove={stage.steps.length > 1}
                  onChange={s => patchStage(i, { steps: stage.steps.map((x, k) => (k === j ? s : x)) })}
                  onRemove={() => patchStage(i, { steps: stage.steps.filter((_, k) => k !== j) })}
                />
              ))}
              <Button variant="ghost" size="sm" onClick={() => patchStage(i, { steps: [...stage.steps, { appGroup: '', service: '' }] })}>
                <Plus className="w-3.5 h-3.5" /> Add service
              </Button>
            </div>
          </div>
        ))}
        <Button variant="secondary" size="sm" onClick={() => setStages(prev => [...prev, emptyStage(prev.length + 1)])}>
          <Plus className="w-3.5 h-3.5" /> Add stage
        </Button>
      </div>

      <div className="flex justify-end gap-2">
        <Button variant="secondary" onClick={onDone}>Cancel</Button>
        <Button type="submit" loading={save.isPending}>{initial ? 'Save changes' : 'Create bundle'}</Button>
      </div>
    </form>
  );
};

/** Compact "A + B → C" rendering of a bundle's stages. */
export const BundleFlow: React.FC<{ stages: BundleStage[] }> = ({ stages }) => (
  <div className="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm">
    {stages.map((stage, i) => (
      <React.Fragment key={i}>
        {i > 0 && <span className="text-zinc-300">→</span>}
        <span className="inline-flex items-center gap-1.5 rounded-md bg-zinc-100 px-2 py-1">
          <span className="text-zinc-800">{stage.steps.map(s => s.service).join(stage.mode === 'PARALLEL' ? ' + ' : ' → ')}</span>
          <span className="text-[10px] uppercase tracking-wide text-zinc-400">{stage.mode === 'PARALLEL' ? 'parallel' : 'in order'}</span>
        </span>
      </React.Fragment>
    ))}
  </div>
);

const BundlesAdmin: React.FC = () => {
  const qc = useQueryClient();
  const [showArchived, setShowArchived] = useState(false);
  const [editing, setEditing] = useState<ReleaseBundle | 'new' | null>(null);
  const { data: bundles = [], isLoading } = useQuery({ queryKey: ['release-bundles', showArchived], queryFn: () => fetchBundles(showArchived) });
  const { data: productConfigs = [] } = useProductConfigs();
  const appGroups = useMemo(
    () => [...new Set(productConfigs.map((c: ProductConfig) => c.appGroup).filter(Boolean))].sort((a, b) => a.localeCompare(b)),
    [productConfigs],
  );

  const archive = useMutation({
    mutationFn: ({ id, archived }: { id: string; archived: boolean }) => archiveBundle(id, archived),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['release-bundles'] }),
    onError: (err: any) => toast.error(err?.response?.data?.message || err.message || 'Failed'),
  });

  if (editing) {
    return (
      <BundleEditor
        initial={editing === 'new' ? undefined : editing}
        appGroups={appGroups}
        onDone={() => setEditing(null)}
      />
    );
  }

  return (
    <div className="space-y-4 pb-12">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold text-zinc-900">Release bundles</h1>
          <p className="text-sm text-zinc-500">Reusable release recipes: which services go together and in what order.</p>
        </div>
        <div className="flex items-center gap-3">
          <label className="flex items-center gap-1.5 text-xs text-zinc-500">
            <input type="checkbox" checked={showArchived} onChange={e => setShowArchived(e.target.checked)} /> Show archived
          </label>
          <PermissionGate product="autopilot" permission="PRODUCT_CONFIG_EDIT">
            <Button onClick={() => setEditing('new')}><Plus className="w-4 h-4" /> New bundle</Button>
          </PermissionGate>
        </div>
      </div>

      {isLoading ? (
        <p className="text-sm text-zinc-400">Loading…</p>
      ) : bundles.length === 0 ? (
        <div className="rounded-xl border border-dashed border-zinc-300 p-8 text-center text-sm text-zinc-500">
          No bundles yet. Create one to release several services together.
        </div>
      ) : (
        <div className="grid gap-3">
          {bundles.map(b => (
            <div key={b.bundleId} className="bg-white rounded-xl border border-zinc-200 p-4 space-y-2">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <div className="flex items-center gap-2">
                  <h3 className="font-medium text-zinc-900">{b.name}</h3>
                  {b.archived && <Badge variant="muted">archived</Badge>}
                </div>
                <PermissionGate product="autopilot" permission="PRODUCT_CONFIG_EDIT">
                  <div className="flex gap-2">
                    <Button variant="secondary" size="sm" onClick={() => setEditing(b)}>Edit</Button>
                    <Button variant="ghost" size="sm" onClick={() => archive.mutate({ id: b.bundleId, archived: !b.archived })}>
                      {b.archived ? 'Restore' : 'Archive'}
                    </Button>
                  </div>
                </PermissionGate>
              </div>
              {b.description && <p className="text-sm text-zinc-500">{b.description}</p>}
              <BundleFlow stages={b.stages} />
            </div>
          ))}
        </div>
      )}
    </div>
  );
};

export default BundlesAdmin;
