import React, { Fragment, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { useMutation, useQuery } from '@tanstack/react-query';
import { toast } from 'sonner';
import { Check, FastForward, Pause, Play, RefreshCw, Square, X } from 'lucide-react';
import {
  abortRelease,
  approveRelease,
  discardRelease,
  fastForwardRelease,
  fetchReleaseDetails,
  fetchReleaseEvents,
  pauseRelease,
  resumeRelease,
} from '../../releases/api';
import { StatusBadge } from '../../releases/components/StatusBadge';
import { Badge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { CardSkeleton } from '../../../shared/ui/skeleton';
import { SimpleTooltip } from '../../../shared/ui/tooltip';
import { useConfirm } from '../../../shared/ui/confirm-dialog';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { useAuth } from '../../../core/auth/AuthContext';
import { cn } from '../../../lib/utils';
import { parseConfigReleaseMeta } from '../types';

const formatTs = (ts: string) => {
  if (!ts) return '-';
  const d = new Date(ts);
  if (isNaN(d.getTime())) return '-';
  return d.toLocaleString('en-IN', {
    timeZone: 'Asia/Kolkata',
    month: 'short', day: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: true,
  }) + ' IST';
};

const tryFormatJson = (data: string): string => {
  try { return JSON.stringify(JSON.parse(data), null, 2); } catch { return data; }
};

const TABS = ['Summary', 'Stagger', 'Event Data'];

const ConfigReleaseSummary: React.FC = () => {
  const { id = '' } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const { user } = useAuth();
  const actor = user?.email || 'admin';
  const confirm = useConfirm();
  const [tab, setTab] = useState('Summary');
  const [expanded, setExpanded] = useState<Set<number>>(new Set());
  const [openItems, setOpenItems] = useState<Set<string>>(new Set());

  const { data: release, isLoading, isFetching, refetch } = useQuery({
    queryKey: ['config-release', id],
    queryFn: () => fetchReleaseDetails(id),
    enabled: !!id,
    refetchInterval: 10000,
  });
  const { data: events = [], refetch: refetchEvents } = useQuery({
    queryKey: ['config-release-events', id],
    queryFn: () => fetchReleaseEvents(id),
    enabled: !!id,
    refetchInterval: 15000,
  });

  const action = useMutation({
    mutationFn: (fn: () => Promise<unknown>) => fn(),
    onSuccess: () => { toast.success('Action completed'); refetch(); refetchEvents(); },
    onError: (err: any) => { toast.error(err?.response?.data?.message || err?.message || 'Action failed'); },
  });

  const run = async (label: string, fn: () => Promise<unknown>, danger = false, description?: string) => {
    const ok = await confirm({
      title: `${label} config release`,
      description: description ?? `Are you sure you want to ${label.toLowerCase()} this config release?`,
      confirmLabel: `Yes, ${label}`,
      variant: danger ? 'danger' : 'primary',
    });
    if (ok) action.mutate(fn);
  };

  if (isLoading) return <div className="flex flex-col w-full space-y-6"><CardSkeleton /><CardSkeleton /></div>;
  if (!release) return <div className="p-10 text-center text-red-500">Config release not found.</div>;

  const meta = parseConfigReleaseMeta(release);
  const s = release.status;
  const sortedEvents = [...events].sort((a, b) => b.timestamp.localeCompare(a.timestamp));
  const history = release.rollout_history;
  const currentStep = history.length;

  return (
    <div className="flex flex-col w-full pb-12">
      <div className="flex flex-col gap-3 mb-4 sm:mb-5">
        <div>
          <div className="flex items-center gap-2 sm:gap-3 mb-1 flex-wrap">
            <h1 className="text-lg sm:text-xl font-semibold text-zinc-900">Config Release</h1>
            <StatusBadge status={s} />
            <Badge variant="default" size="sm">{meta.side === 'BAP' ? 'Rider' : 'Driver'}</Badge>
            <Badge variant="info" size="sm">{release.mode}</Badge>
          </div>
          <div className="font-mono text-[11px] sm:text-xs text-zinc-500 break-all">ID: {release.id}</div>
          {release.description && <div className="text-sm text-zinc-600 mt-1">{release.description}</div>}
        </div>
        <div className="flex items-center gap-2 flex-wrap sm:justify-end">
          {s === 'CREATED' && release.is_approved === 0 && (
            <PermissionGate product="autopilot" permission="RELEASE_APPROVE" appGroup={release.appGroup}>
              <Button size="sm" variant="success" loading={action.isPending} onClick={() => run('Approve', () => approveRelease(id, actor))}>
                <Check className="w-3.5 h-3.5" /> Approve
              </Button>
            </PermissionGate>
          )}
          {s === 'CREATED' && (
            <PermissionGate product="autopilot" permission="RELEASE_DISCARD" appGroup={release.appGroup}>
              <Button size="sm" variant="outline" className="border-red-300 text-red-700 hover:bg-red-50" loading={action.isPending} onClick={() => run('Discard', () => discardRelease(id), true)}>
                <X className="w-3.5 h-3.5" /> Discard
              </Button>
            </PermissionGate>
          )}
          {s === 'INPROGRESS' && (
            <>
              <PermissionGate product="autopilot" permission="RELEASE_PAUSE" appGroup={release.appGroup}>
                <Button size="sm" variant="outline" className="border-amber-300 text-amber-700 hover:bg-amber-50" loading={action.isPending} onClick={() => run('Pause', () => pauseRelease(id))}>
                  <Pause className="w-3.5 h-3.5" /> Pause
                </Button>
              </PermissionGate>
              <PermissionGate product="autopilot" permission="RELEASE_UPDATE" appGroup={release.appGroup}>
                <Button size="sm" variant="outline" className="border-amber-300 bg-amber-600 text-white hover:bg-amber-700" loading={action.isPending} onClick={() => run('Fast Forward', () => fastForwardRelease(id), false, 'Skip the current cooloff and move to the next stagger step, bypassing the health check for this step.')}>
                  <FastForward className="w-3.5 h-3.5" /> Fast Forward
                </Button>
              </PermissionGate>
              <PermissionGate product="autopilot" permission="RELEASE_ABORT" appGroup={release.appGroup}>
                <Button size="sm" variant="danger" loading={action.isPending} onClick={() => run('Abort', () => abortRelease(id), true, 'This stops the rollout and aborts the experiment on every config in this release. Nothing is written to the config tables.')}>
                  <Square className="w-3.5 h-3.5" /> Abort
                </Button>
              </PermissionGate>
            </>
          )}
          {s === 'PAUSED' && (
            <>
              <PermissionGate product="autopilot" permission="RELEASE_RESUME" appGroup={release.appGroup}>
                <Button size="sm" className="bg-blue-600 text-white hover:bg-blue-700" loading={action.isPending} onClick={() => run('Resume', () => resumeRelease(id))}>
                  <Play className="w-3.5 h-3.5" /> Resume
                </Button>
              </PermissionGate>
              <PermissionGate product="autopilot" permission="RELEASE_ABORT" appGroup={release.appGroup}>
                <Button size="sm" variant="danger" loading={action.isPending} onClick={() => run('Abort', () => abortRelease(id), true)}>
                  <Square className="w-3.5 h-3.5" /> Abort
                </Button>
              </PermissionGate>
            </>
          )}
          <SimpleTooltip content="Refresh">
            <Button size="icon" variant="ghost" onClick={() => { refetch(); refetchEvents(); }} aria-label="Refresh">
              <RefreshCw className={`w-4 h-4 ${isFetching ? 'animate-spin' : ''}`} />
            </Button>
          </SimpleTooltip>
        </div>
      </div>

      <div className="bg-white rounded-xl border border-zinc-200">
        <div className="flex border-b border-zinc-200 px-2 sm:px-5 overflow-x-auto">
          {TABS.map(t => (
            <button
              key={t}
              onClick={() => setTab(t)}
              className={cn('py-3 px-3 sm:px-4 text-sm font-medium border-b-2 transition-colors cursor-pointer whitespace-nowrap', tab === t ? 'border-zinc-900 text-zinc-900' : 'border-transparent text-zinc-400 hover:text-zinc-600')}
            >
              {t}
            </button>
          ))}
        </div>

        {tab === 'Summary' && (
          <div className="p-4 sm:p-6 space-y-4">
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3 sm:gap-4">
              {[
                { title: 'TARGET', rows: [['Side', meta.side === 'BAP' ? 'Rider (BAP)' : 'Driver (BPP)'], ['Merchant', meta.merchantShortId], ['City', meta.city], ['App group', release.appGroup], ['Service', release.service], ['Env', release.env]] },
                { title: 'PEOPLE', rows: [['Created by', release.release_manager], ['Approved', release.is_approved === 1 ? 'Yes' : 'No'], ['Approved by', release.approved_by || ''], ['Mode', release.mode]] },
                { title: 'TIME', rows: [['Created', formatTs(release.date_created)], ['Started', formatTs(release.start_time)], ['Last updated', formatTs(release.last_updated)], ['Ended', formatTs(release.end_time)]] },
              ].map(card => (
                <div key={card.title} className="bg-zinc-50 rounded-xl border border-zinc-100 p-4 text-sm">
                  <h3 className="font-semibold text-zinc-500 uppercase text-[11px] tracking-wider mb-3">{card.title}</h3>
                  <dl className="space-y-2.5">
                    {card.rows.map(([label, value]) => (
                      <div key={label}>
                        <dt className="text-zinc-400 text-xs">{label}</dt>
                        <dd className="text-zinc-800 font-medium mt-0.5 break-all">{value || '-'}</dd>
                      </div>
                    ))}
                  </dl>
                </div>
              ))}
            </div>

            <div className="border border-zinc-200 rounded-xl overflow-hidden">
              <div className="px-4 py-3 bg-zinc-50 border-b border-zinc-200 text-[11px] font-semibold text-zinc-500 uppercase tracking-wider">
                Configs in this release ({meta.items.length})
              </div>
              <table className="w-full text-sm text-left">
                <thead>
                  <tr className="text-[12px] text-zinc-500 uppercase tracking-wider border-b border-zinc-100">
                    <th className="px-4 py-2">Config type</th>
                    <th className="px-4 py-2">Version</th>
                    <th className="px-4 py-2">State</th>
                    <th className="px-4 py-2">Change</th>
                  </tr>
                </thead>
                <tbody>
                  {meta.items.map(item => (
                    <Fragment key={item.configType}>
                    <tr className="border-b border-zinc-100 last:border-0">
                      <td className="px-4 py-2 text-zinc-800">{item.configType}</td>
                      <td className="px-4 py-2 font-mono text-xs">v{item.version}</td>
                      <td className="px-4 py-2">
                        {meta.concluded.includes(item.configType)
                          ? <Badge variant="success" size="sm">Concluded</Badge>
                          : <Badge variant="default" size="sm">{s === 'COMPLETED' ? 'Concluded' : 'Pending'}</Badge>}
                      </td>
                      <td className="px-4 py-2">
                        <button
                          className="text-xs text-blue-600 hover:underline cursor-pointer"
                          onClick={() => setOpenItems(prev => { const n = new Set(prev); if (n.has(item.configType)) n.delete(item.configType); else n.add(item.configType); return n; })}
                        >
                          {openItems.has(item.configType) ? 'Hide patch' : 'Show patch'}
                        </button>
                      </td>
                    </tr>
                    {openItems.has(item.configType) && (
                      <tr className="bg-zinc-50 border-b border-zinc-100">
                        <td colSpan={4} className="px-4 py-3">
                          {item.patch == null
                            ? <span className="text-xs text-zinc-400">Patch was not available when the release was created.</span>
                            : <pre className="text-xs font-mono bg-white text-zinc-800 border border-zinc-200 p-3 rounded-lg overflow-x-auto max-h-80 whitespace-pre-wrap break-all">{JSON.stringify(item.patch, null, 2)}</pre>}
                        </td>
                      </tr>
                    )}
                    </Fragment>
                  ))}
                  {meta.items.length === 0 && (
                    <tr><td colSpan={4} className="px-4 py-6 text-center text-zinc-400">No items recorded.</td></tr>
                  )}
                </tbody>
              </table>
            </div>
          </div>
        )}

        {tab === 'Stagger' && (
          <div className="overflow-x-auto">
            <table className="w-full text-sm text-left min-w-[760px]">
              <thead>
                <tr className="bg-zinc-50 border-b border-zinc-200 text-[12px] text-zinc-500 font-medium uppercase tracking-wider">
                  {['Step', 'Traffic %', 'Cooloff (min)', 'Started', 'Completed', 'Decision', 'Reason'].map(h => (
                    <th key={h} className="px-4 py-3">{h}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {release.rollout_strategy.map((step, i) => {
                  const h = history[i];
                  const isCurrent = i === currentStep - 1 && s === 'INPROGRESS';
                  return (
                    <tr key={i} className={cn('border-b border-zinc-100', isCurrent ? 'bg-amber-50' : i % 2 === 1 ? 'bg-zinc-50' : 'bg-white')}>
                      <td className="px-4 py-2 font-mono text-xs">{i + 1}{isCurrent && <Badge variant="warning" size="sm" className="ml-2">current</Badge>}</td>
                      <td className="px-4 py-2 font-medium">{step.rollout}%</td>
                      <td className="px-4 py-2">{step.cooloff}</td>
                      <td className="px-4 py-2 text-zinc-500 whitespace-nowrap">{h ? formatTs(h.started_at) : '-'}</td>
                      <td className="px-4 py-2 text-zinc-500 whitespace-nowrap">{h ? formatTs(h.completed_at) : '-'}</td>
                      <td className="px-4 py-2">{h?.last_decision || '-'}{h?.manual_override && <Badge variant="warning" size="sm" className="ml-2">fast-forwarded</Badge>}</td>
                      <td className="px-4 py-2 text-zinc-500 max-w-xs truncate" title={h?.decision_hs_result || h?.decision_result}>{h?.decision_hs_result || h?.decision_result || '-'}</td>
                    </tr>
                  );
                })}
                {release.rollout_strategy.length === 0 && (
                  <tr><td colSpan={7} className="px-4 py-8 text-center text-zinc-400">No stagger steps.</td></tr>
                )}
              </tbody>
            </table>
          </div>
        )}

        {tab === 'Event Data' && (
          <div className="overflow-x-auto">
            <table className="w-full text-sm text-left min-w-[720px]">
              <thead>
                <tr className="bg-zinc-50 border-b border-zinc-200 text-[12px] text-zinc-500 font-medium uppercase tracking-wider">
                  <th className="px-3 py-3 w-8"></th>
                  {['#', 'Timestamp', 'Category', 'Label', 'Value'].map(h => <th key={h} className="px-4 py-3">{h}</th>)}
                </tr>
              </thead>
              <tbody>
                {sortedEvents.map((ev, i) => (
                  <Fragment key={i}>
                    <tr
                      className={cn('border-b border-zinc-100 hover:bg-zinc-100 cursor-pointer', i % 2 === 1 ? 'bg-zinc-50' : 'bg-white')}
                      onClick={() => setExpanded(prev => { const n = new Set(prev); if (n.has(i)) n.delete(i); else n.add(i); return n; })}
                    >
                      <td className="px-3 py-2 text-zinc-400"><span className={`inline-block transition-transform text-xs ${expanded.has(i) ? 'rotate-90' : ''}`}>&#9654;</span></td>
                      <td className="px-4 py-2 text-zinc-400 font-mono text-xs">{i + 1}</td>
                      <td className="px-4 py-2 font-mono text-xs text-zinc-500 whitespace-nowrap">{formatTs(ev.timestamp)}</td>
                      <td className="px-4 py-2"><Badge variant={ev.category === 'BUSINESS' ? 'info' : 'default'} size="sm">{ev.category}</Badge></td>
                      <td className="px-4 py-2 text-zinc-600">{ev.label}</td>
                      <td className="px-4 py-2 text-zinc-500 max-w-sm truncate" title={ev.data}>{ev.data?.slice(0, 40)}{(ev.data?.length || 0) > 40 ? '...' : ''}</td>
                    </tr>
                    {expanded.has(i) && (
                      <tr className="bg-zinc-50 border-b border-zinc-100">
                        <td colSpan={6} className="px-6 py-3">
                          <pre className="text-xs font-mono bg-zinc-50 text-zinc-800 border border-zinc-200 p-4 rounded-lg overflow-x-auto max-h-60 whitespace-pre-wrap break-all">{tryFormatJson(ev.data)}</pre>
                        </td>
                      </tr>
                    )}
                  </Fragment>
                ))}
                {sortedEvents.length === 0 && (
                  <tr><td colSpan={6} className="px-4 py-8 text-center text-sm text-zinc-400">No events logged.</td></tr>
                )}
              </tbody>
            </table>
          </div>
        )}
      </div>

      <div className="flex justify-end pt-5">
        <Button variant="secondary" onClick={() => navigate('/backend/config-releases')}>Back to Config Releases</Button>
      </div>
    </div>
  );
};

export default ConfigReleaseSummary;
