import React, { useMemo, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Check } from 'lucide-react';
import { toast } from 'sonner';
import { Button } from '../../../../shared/ui/button';
import { useAuth } from '../../../../core/auth/AuthContext';
import { cn } from '../../../../lib/utils';
import { createGroupRun, fetchBundles, fetchGroupRun } from '../../api';
import type { ReleaseBundle } from '../../api';
import CreateRelease from '../CreateRelease';
import { BundleFlow } from './BundlesAdmin';

type FlatStep = { stage: number; step: number; stageName: string; mode: string; appGroup: string; service: string };

const flatten = (b: ReleaseBundle): FlatStep[] =>
  b.stages.flatMap((stage, si) =>
    stage.steps.map((s, pi) => ({ stage: si, step: pi, stageName: stage.name, mode: stage.mode, appGroup: s.appGroup, service: s.service })),
  );

const keyOf = (s: FlatStep) => `${s.appGroup}/${s.service}`;

/**
 * Group release wizard: pick a bundle, fill in one service per page (the same
 * form as a single release), review the whole plan, then create it as one
 * group awaiting a single approval.
 *
 * Every service form stays mounted (hidden when not current) so going Back
 * keeps what was typed.
 */
const CreateGroupRelease: React.FC = () => {
  const navigate = useNavigate();
  const qc = useQueryClient();
  const { env } = useAuth();
  const [search] = useSearchParams();
  const cloneRunId = search.get('from');
  const { data: bundles = [], isLoading } = useQuery({ queryKey: ['release-bundles', false], queryFn: () => fetchBundles(false) });
  const [bundle, setBundle] = useState<ReleaseBundle | null>(null);
  const [cursor, setCursor] = useState(0); // 0..n-1 = service forms, n = review
  const [payloads, setPayloads] = useState<Record<string, any>>({});
  const [description, setDescription] = useState('');
  const [error, setError] = useState('');
  // service key -> release id of the group being cloned
  const [cloneSources, setCloneSources] = useState<Record<string, string>>({});

  // Clone: start from an existing group release. Its bundle is selected and every
  // service form prefills from that service's release in the source group.
  const { data: sourceRun, error: sourceError } = useQuery({
    queryKey: ['release-group', cloneRunId],
    queryFn: () => fetchGroupRun(cloneRunId!),
    enabled: !!cloneRunId,
    staleTime: Infinity,
  });
  const [cloneApplied, setCloneApplied] = useState(false);
  React.useEffect(() => {
    if (!sourceRun || cloneApplied || isLoading) return;
    const b = bundles.find(x => x.bundleId === sourceRun.bundleId);
    if (!b) {
      setError(`The bundle "${sourceRun.bundleName}" was archived or removed, so this group cannot be cloned. Pick another bundle.`);
      setCloneApplied(true);
      return;
    }
    setCloneSources(Object.fromEntries(sourceRun.steps.map(s => [`${s.appGroup}/${s.service}`, s.releaseId])));
    setDescription(sourceRun.description);
    setBundle(b);
    setCloneApplied(true);
  }, [sourceRun, bundles, isLoading, cloneApplied]);

  const steps = useMemo(() => (bundle ? flatten(bundle) : []), [bundle]);
  const reviewing = !!bundle && cursor === steps.length;

  const create = useMutation({
    mutationFn: () => {
      const missing = steps.filter(s => !payloads[keyOf(s)]).map(s => s.service);
      if (missing.length) return Promise.reject(new Error(`Configure every service first. Missing: ${missing.join(', ')}`));
      return createGroupRun(bundle!.bundleId, description, steps.map(s => payloads[keyOf(s)]));
    },
    onSuccess: run => {
      toast.success('Group release created — approve it to start');
      qc.invalidateQueries({ queryKey: ['release-groups'] });
      navigate(`/backend/group-releases/${run.runId}`);
    },
    onError: (err: any) => setError(err?.response?.data?.message || err.message || 'Failed to create group release'),
  });

  if (!bundle) {
    return (
      <div className="space-y-4 pb-12">
        <div>
          <h1 className="text-lg font-semibold text-zinc-900">Create release</h1>
          {error && <div className="bg-red-50 border border-red-200 text-red-700 px-4 py-3 rounded-xl text-sm">{error}</div>}
          {sourceError && <div className="bg-red-50 border border-red-200 text-red-700 px-4 py-3 rounded-xl text-sm">Could not load the group release to clone.</div>}
          <p className="text-sm text-zinc-500">Choose the bundle to release. Services ship together, in the order the bundle defines.</p>
        </div>
        {isLoading ? (
          <p className="text-sm text-zinc-400">Loading…</p>
        ) : bundles.length === 0 ? (
          <div className="rounded-xl border border-dashed border-zinc-300 p-8 text-center text-sm text-zinc-500">
            No bundles are set up yet. Ask an admin to create one under Release Bundles, or use Single Service Release.
          </div>
        ) : (
          <div className="grid gap-3 sm:grid-cols-2">
            {bundles.map(b => (
              <button
                key={b.bundleId}
                type="button"
                onClick={() => { setBundle(b); setCursor(0); setPayloads({}); setCloneSources({}); setError(''); }}
                className="text-left bg-white rounded-xl border border-zinc-200 p-4 space-y-2 hover:border-zinc-400 transition-colors"
              >
                <h3 className="font-medium text-zinc-900">{b.name}</h3>
                {b.description && <p className="text-sm text-zinc-500">{b.description}</p>}
                <BundleFlow stages={b.stages} />
              </button>
            ))}
          </div>
        )}
      </div>
    );
  }

  const current = steps[cursor];
  return (
    <div className="space-y-4 pb-12">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h1 className="text-lg font-semibold text-zinc-900">{bundle.name}</h1>
          <p className="text-sm text-zinc-500">
            {reviewing ? 'Review the plan' : `Service ${cursor + 1} of ${steps.length}: ${current.service}`}
          </p>
        </div>
        <Button variant="ghost" size="sm" onClick={() => setBundle(null)}>Change bundle</Button>
      </div>

      <ol className="flex flex-wrap gap-1.5">
        {steps.map((s, i) => {
          const done = !!payloads[keyOf(s)];
          return (
            <li key={keyOf(s)}>
              <button
                type="button"
                onClick={() => setCursor(i)}
                className={cn(
                  'inline-flex items-center gap-1 rounded-full border px-2.5 py-1 text-xs',
                  i === cursor ? 'border-zinc-900 bg-zinc-900 text-white' : 'border-zinc-200 bg-white text-zinc-600 hover:border-zinc-400',
                )}
              >
                {done && <Check className="w-3 h-3" />} {s.service}
              </button>
            </li>
          );
        })}
        <li>
          <button
            type="button"
            disabled={steps.some(s => !payloads[keyOf(s)])}
            onClick={() => setCursor(steps.length)}
            className={cn(
              'rounded-full border px-2.5 py-1 text-xs disabled:opacity-40 disabled:cursor-not-allowed',
              reviewing ? 'border-zinc-900 bg-zinc-900 text-white' : 'border-zinc-200 bg-white text-zinc-600',
            )}
          >
            Review
          </button>
        </li>
      </ol>

      {steps.map((s, i) => (
        <div key={`${bundle.bundleId}:${keyOf(s)}`} className={i === cursor ? '' : 'hidden'}>
          <CreateRelease
            groupStep={{
              appGroup: s.appGroup,
              service: s.service,
              env,
              title: `${s.stageName} · ${s.service}`,
              cloneFrom: cloneSources[keyOf(s)],
              submitLabel: i === steps.length - 1 ? 'Review plan' : `Next: ${steps[i + 1].service}`,
              onCollect: payload => {
                const next = { ...payloads, [keyOf(s)]: payload };
                setPayloads(next);
                // Move on to the next unfilled service; Review only once every service has a config.
                const open = steps.findIndex((x, j) => j > i && !next[keyOf(x)]);
                const anyOpen = steps.findIndex(x => !next[keyOf(x)]);
                setCursor(open >= 0 ? open : anyOpen >= 0 ? anyOpen : steps.length);
                window.scrollTo({ top: 0 });
              },
              onBack: i > 0 ? () => setCursor(i - 1) : undefined,
            }}
          />
        </div>
      ))}

      {reviewing && (
        <div className="bg-white rounded-xl border border-zinc-200 p-4 sm:p-6 space-y-5">
          {error && <div className="bg-red-50 border border-red-200 text-red-700 px-4 py-3 rounded-xl text-sm whitespace-pre-wrap">{error}</div>}
          <div className="space-y-4">
            {bundle.stages.map((stage, si) => (
              <div key={si}>
                <div className="flex items-center gap-2 mb-1.5">
                  <span className="text-xs font-mono text-zinc-400">{si + 1}</span>
                  <h3 className="text-sm font-medium text-zinc-900">{stage.name}</h3>
                  <span className="text-[10px] uppercase tracking-wide text-zinc-400">{stage.mode === 'PARALLEL' ? 'all at once' : 'one after another'}</span>
                </div>
                <ul className="divide-y divide-zinc-100 rounded-lg border border-zinc-200">
                  {stage.steps.map(st => {
                    const p = payloads[`${st.appGroup}/${st.service}`];
                    return (
                      <li key={st.service} className="px-3 py-2 text-sm flex flex-wrap items-center justify-between gap-2">
                        <span className="font-medium text-zinc-800">{st.service} <span className="text-zinc-400 font-normal">({st.appGroup})</span></span>
                        <span className="font-mono text-xs text-zinc-500">{p?.old_version || '?'} → {p?.new_version}</span>
                      </li>
                    );
                  })}
                </ul>
              </div>
            ))}
          </div>
          <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider">
            Group description
            <input
              className="mt-1.5 w-full h-9 border border-zinc-300 rounded-lg px-3 text-sm normal-case tracking-normal focus:outline-none focus:ring-2 focus:ring-zinc-400"
              value={description}
              onChange={e => setDescription(e.target.value)}
              placeholder="Optional"
            />
          </label>
          <p className="text-xs text-zinc-500">
            Nothing deploys yet. Creating the group makes one release per service; a single approval then starts stage 1.
          </p>
          <div className="flex justify-end gap-2">
            <Button variant="secondary" onClick={() => setCursor(steps.length - 1)}>Back</Button>
            <Button loading={create.isPending} onClick={() => { setError(''); create.mutate(); }}>Create group release</Button>
          </div>
        </div>
      )}
    </div>
  );
};

export default CreateGroupRelease;
