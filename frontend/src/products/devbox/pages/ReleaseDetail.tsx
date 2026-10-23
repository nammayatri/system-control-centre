import { useNavigate, useParams } from 'react-router-dom';
import { ArrowLeft, Copy, ExternalLink, Square } from 'lucide-react';
import { toast } from 'sonner';
import { Button } from '../../../shared/ui/button';
import { Card, CardContent } from '../../../shared/ui/card';
import { CardSkeleton } from '../../../shared/ui/skeleton';
import { useConfirm } from '../../../shared/ui/confirm-dialog';
import { copyToClipboard, formatDate, timeAgo } from '../../../lib/utils';
import { devboxError } from '../api';
import { DevboxStatusBadge, StageBar, stageLabel } from '../components/DevboxStatus';
import { useDevboxRelease, useStopDevboxRelease } from '../hooks';
import { ACTIVE_STATUSES, APP_BUILDS, type DevboxBuild, type DevboxEvent, type DevboxRelease } from '../types';

export default function DevboxReleaseDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const confirm = useConfirm();
  const { data, isLoading, error } = useDevboxRelease(id);
  const stop = useStopDevboxRelease();

  if (isLoading) return <CardSkeleton />;
  if (error || !data) return <p className="text-sm text-red-600">{devboxError(error).message}</p>;
  const { release: r, events, builds, canStop } = data;
  const live = ACTIVE_STATUSES.includes(r.status);
  const running = r.status === 'QUEUED' || r.status === 'RUNNING';

  const onStop = async () => {
    const ok = await confirm({
      title: `Stop ${r.workspace}?`,
      description: r.devboxHost
        ? 'This removes the workspace from the dev-box: its services, database, files and URLs. The history stays here.'
        : 'It is still building, so the GitHub run is cancelled. The history stays here.',
      confirmLabel: 'Stop',
      variant: 'danger',
    });
    if (!ok) return;
    try {
      await stop.mutateAsync(r.id);
      toast.success(r.devboxHost ? 'Stopping · removing the workspace' : 'Run cancelled');
    } catch (err) {
      toast.error(devboxError(err).message);
    }
  };

  const urls: [string, string | null][] =
    r.status === 'READY'
      ? [
          // backendUrl itself is not a link: the public front desk only
          // passes the rider and driver APIs under it.
          ['Rider app API', r.backendUrl && `${r.backendUrl}/rider-app/v2`],
          ['Driver app API', r.backendUrl && `${r.backendUrl}/dynamic-offer-driver-app/ui`],
          ['Control centre', r.ccUrl],
        ]
      : [];

  return (
    <div className="space-y-4">
      <button type="button" onClick={() => navigate('/devbox/releases')} className="inline-flex items-center gap-1 text-sm text-zinc-500 hover:text-zinc-800 cursor-pointer">
        <ArrowLeft className="h-4 w-4" /> Devbox Releases
      </button>

      <div className="flex flex-wrap items-center gap-3">
        <h1 className="font-mono text-xl font-semibold text-zinc-900 dark:text-zinc-100">{r.workspace}</h1>
        <DevboxStatusBadge status={r.status} />
        <div className="flex-1" />
        {r.ghRunUrl && (
          <a href={r.ghRunUrl} target="_blank" rel="noreferrer">
            <Button variant="outline">
              {running ? 'Watch live on GitHub' : 'View GitHub logs'} <ExternalLink className="h-4 w-4" />
            </Button>
          </a>
        )}
        {live && r.status !== 'STOPPING' && canStop && (
          <Button variant="danger" onClick={onStop} loading={stop.isPending}>
            <Square className="h-4 w-4" /> Stop
          </Button>
        )}
        {(live || r.status === 'FAILED') && !canStop && r.status !== 'STOPPING' && (
          <span className="text-xs text-zinc-500">Only {r.createdBy} or a Devbox manager can stop this</span>
        )}
        {r.status === 'FAILED' && canStop && (
          <Button variant="danger" onClick={onStop} loading={stop.isPending}>
            <Square className="h-4 w-4" /> Remove workspace
          </Button>
        )}
      </div>

      <div className="flex flex-wrap gap-x-6 gap-y-1 text-sm text-zinc-500">
        <span>Owner <b className="text-zinc-800 dark:text-zinc-200">{r.createdBy}</b></span>
        <span>Created <b className="text-zinc-800 dark:text-zinc-200">{timeAgo(r.createdAt)}</b></span>
        {live && <span>Auto-stop <b className="text-zinc-800 dark:text-zinc-200">{formatDate(r.expiresAt)}</b></span>}
        {r.status === 'STOPPED' && (
          <span>Stopped <b className="text-zinc-800 dark:text-zinc-200">{r.stopReason === 'expired' ? 'after its lifetime' : `by ${r.stoppedBy ?? r.createdBy}`}</b></span>
        )}
        <span>Dev-box <b className="text-zinc-800 dark:text-zinc-200">{r.devboxName ?? (running ? 'being picked…' : '—')}</b></span>
      </div>

      {r.error && (
        <div className="rounded-lg border border-red-300 bg-red-50 p-3 text-sm text-red-900 dark:border-red-800 dark:bg-red-950 dark:text-red-200">
          <b>{r.status === 'FAILED' ? `${stageLabel(r.stage)} failed: ` : ''}</b>
          {r.error}
          {r.status === 'FAILED' && ' The workspace is left as it is so you can look; Remove workspace cleans it up.'}
        </div>
      )}
      {r.status === 'STOPPED' && (
        <div className="rounded-lg border border-blue-200 bg-blue-50 p-3 text-sm text-blue-900 dark:border-blue-900 dark:bg-blue-950 dark:text-blue-200">
          The workspace was removed from the dev-box. This page keeps its history.
        </div>
      )}

      <Card>
        <CardContent className="p-4">
          <StageBar release={r} events={events} />
        </CardContent>
      </Card>

      <div className="grid gap-4 lg:grid-cols-2">
        <Card>
          <CardContent className="space-y-3 p-5">
            <h2 className="text-sm font-semibold">Open it</h2>
            {urls.length ? (
              <div className="space-y-2">
                {urls.map(([label, url]) =>
                  url ? (
                    <div key={label} className="flex min-w-0 items-center gap-2 rounded-lg border border-zinc-200 bg-zinc-50 px-3 py-2 dark:border-zinc-800 dark:bg-zinc-900">
                      <span className="w-28 shrink-0 text-xs text-zinc-500">{label}</span>
                      <a href={url} target="_blank" rel="noreferrer" className="min-w-0 flex-1 truncate font-mono text-xs text-blue-700 hover:underline dark:text-blue-300">
                        {url}
                      </a>
                      <button
                        type="button"
                        aria-label={`Copy ${label}`}
                        className="text-zinc-400 hover:text-zinc-700 cursor-pointer"
                        onClick={() => {
                          copyToClipboard(url);
                          toast.success('Copied');
                        }}
                      >
                        <Copy className="h-3.5 w-3.5" />
                      </button>
                    </div>
                  ) : null,
                )}
                <p className="text-xs text-zinc-500">API links work from any network. Control centre opens on the office network only.</p>
              </div>
            ) : (
              <p className="text-sm text-zinc-500">{live ? 'Links appear when the release is ready.' : 'No links: the workspace is gone.'}</p>
            )}

            {r.frontendBranch && (r.appBuilds?.length ?? 0) > 0 && (
              <>
                <h2 className="pt-2 text-sm font-semibold">App builds</h2>
                <div className="grid gap-2 sm:grid-cols-2">
                  {buildCards(r, builds).map(({ key, label, where, build }) => (
                    <div key={key} className="space-y-1 rounded-lg border border-zinc-200 bg-zinc-50 p-3 dark:border-zinc-800 dark:bg-zinc-900">
                      <div className="flex items-center justify-between gap-2">
                        <b className="text-sm">{label}</b>
                        <span className={`text-xs font-semibold ${BUILD_COLOR[build?.status ?? 'WAITING']}`}>
                          {(build?.status ?? (r.status === 'READY' ? 'STARTING' : 'WAITING')).toLowerCase()}
                        </span>
                      </div>
                      <p className="text-xs text-zinc-500">
                        {build?.status === 'DONE'
                          ? build.downloadUrl
                            ? `Uploaded to ${where}`
                            : `TestFlight build ${build.buildNumber ?? '?'}: install it from the TestFlight app`
                          : build?.status === 'FAILED'
                            ? build.error
                            : build
                              ? `Building against this backend…`
                              : `Starts when the backend is ready`}
                      </p>
                      <div className="flex gap-3 text-xs font-semibold">
                        {build?.downloadUrl && (
                          <a href={build.downloadUrl} target="_blank" rel="noreferrer" className="text-blue-700 hover:underline dark:text-blue-300">
                            Open in Firebase
                          </a>
                        )}
                        {build?.ghRunUrl && (
                          <a href={build.ghRunUrl} target="_blank" rel="noreferrer" className="text-zinc-500 hover:underline">
                            Build logs
                          </a>
                        )}
                      </div>
                    </div>
                  ))}
                </div>
              </>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardContent className="space-y-3 p-5">
            <h2 className="text-sm font-semibold">What is being tested</h2>
            <dl className="grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-2 text-sm">
              <dt className="text-zinc-500">Backend</dt>
              <dd className="break-all font-mono text-xs">{r.backendBranch} @ {r.backendSha.slice(0, 10)}</dd>
              <dt className="text-zinc-500">Control centre</dt>
              <dd className="break-all font-mono text-xs">{r.ccBranch ? `${r.ccBranch} @ ${r.ccSha?.slice(0, 10)}` : '—'}</dd>
              <dt className="text-zinc-500">App</dt>
              <dd className="break-all font-mono text-xs">
                {r.frontendBranch ? `${r.frontendBranch} · ${APP_BUILDS.filter((b) => r.appBuilds.includes(b.key)).map((b) => b.label).join(', ') || 'no builds'}` : '—'}
              </dd>
              <dt className="text-zinc-500">Data</dt>
              <dd className="font-mono text-xs">{r.dataSource} {r.dataVersion ?? 'latest safe'}</dd>
            </dl>
            <h2 className="pt-2 text-sm font-semibold">Events</h2>
            <EventList events={events} />
          </CardContent>
        </Card>
      </div>
    </div>
  );
}

/** One card per app build asked for, with its build row once it has started. */
function buildCards(r: DevboxRelease, builds: DevboxBuild[]) {
  return APP_BUILDS.filter((b) => r.appBuilds.includes(b.key)).map((b) => ({
    ...b,
    build: builds.find((x) => `${x.app}:${x.platform}` === b.key),
  }));
}

const BUILD_COLOR: Record<string, string> = {
  DONE: 'text-emerald-600',
  FAILED: 'text-red-600',
  RUNNING: 'text-amber-600',
  QUEUED: 'text-amber-600',
  CANCELLED: 'text-zinc-500',
  WAITING: 'text-zinc-500',
};

const LABEL_COLOR: Record<DevboxEvent['label'], string> = {
  done: 'text-emerald-600',
  failed: 'text-red-600',
  started: 'text-amber-600',
  skipped: 'text-zinc-500',
  info: 'text-zinc-500',
};

function EventList({ events }: { events: DevboxEvent[] }) {
  if (!events.length) return <p className="text-sm text-zinc-500">No events yet.</p>;
  return (
    <ul className="divide-y divide-dashed divide-zinc-200 text-sm dark:divide-zinc-800">
      {[...events].reverse().map((e) => {
        const ms = typeof e.payload?.ms === 'number' ? ` · ${Math.round((e.payload.ms as number) / 1000)} s` : '';
        const err = typeof e.payload?.error === 'string' ? ` · ${e.payload.error}` : '';
        return (
          <li key={e.id} className="grid grid-cols-[52px_72px_minmax(0,1fr)] gap-2 py-1.5">
            <time className="font-mono text-xs text-zinc-500">{new Date(e.createdAt).toTimeString().slice(0, 5)}</time>
            <span className={`font-semibold ${LABEL_COLOR[e.label]}`}>{e.label}</span>
            <span className="min-w-0 break-words">
              {stageLabel(e.stage)}
              <span className="text-zinc-500">{ms}{err}</span>
              {e.ghStepUrl && (
                <a href={e.ghStepUrl} target="_blank" rel="noreferrer" className="ml-1 text-xs text-blue-700 hover:underline dark:text-blue-300">
                  log
                </a>
              )}
            </span>
          </li>
        );
      })}
    </ul>
  );
}
