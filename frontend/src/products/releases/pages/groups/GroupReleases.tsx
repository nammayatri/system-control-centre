import React from 'react';
import { Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { Plus } from 'lucide-react';
import { Button } from '../../../../shared/ui/button';
import { PermissionGate } from '../../../../core/auth/PermissionGate';
import { fetchGroupRuns } from '../../api';
import { GroupStateBadge } from './GroupReleaseDetail';

const GroupReleases: React.FC = () => {
  const { data: runs = [], isLoading } = useQuery({
    queryKey: ['release-groups'],
    queryFn: fetchGroupRuns,
    refetchInterval: 10000,
  });

  return (
    <div className="space-y-4 pb-12">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold text-zinc-900">Group releases</h1>
          <p className="text-sm text-zinc-500">Bundles released together, stage by stage.</p>
        </div>
        <PermissionGate product="autopilot" permission="RELEASE_CREATE">
          <Link to="/backend/group-releases/new">
            <Button><Plus className="w-4 h-4" /> New group release</Button>
          </Link>
        </PermissionGate>
      </div>

      {isLoading ? (
        <p className="text-sm text-zinc-400">Loading…</p>
      ) : runs.length === 0 ? (
        <div className="rounded-xl border border-dashed border-zinc-300 p-8 text-center text-sm text-zinc-500">
          No group releases yet.
        </div>
      ) : (
        <div className="bg-white rounded-xl border border-zinc-200 divide-y divide-zinc-100">
          {runs.map(r => {
            const finished = r.steps.filter(s => s.state === 'SKIPPED' || s.releaseStatus === 'COMPLETED').length;
            return (
              <Link key={r.runId} to={`/backend/group-releases/${r.runId}`} className="flex flex-wrap items-center justify-between gap-3 px-4 py-3 hover:bg-zinc-50">
                <div className="space-y-0.5">
                  <div className="flex items-center gap-2">
                    <span className="font-medium text-zinc-900">{r.bundleName}</span>
                    <GroupStateBadge state={r.state} />
                  </div>
                  <p className="text-xs text-zinc-500">
                    {r.env} · by {r.createdBy} · {new Date(r.createdAt).toLocaleString()}
                    {r.description && ` · ${r.description}`}
                  </p>
                </div>
                <span className="text-sm text-zinc-500">{finished}/{r.steps.length} services done</span>
              </Link>
            );
          })}
        </div>
      )}
    </div>
  );
};

export default GroupReleases;
