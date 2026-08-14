import { useMemo, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import {
  KeyIcon,
  MegaphoneIcon,
  PlugsIcon,
  ShieldWarningIcon,
  XCircleIcon,
} from '@phosphor-icons/react';
import { chimeApi, type ChimeJobFunnel, type ChimeJobStatus, type ChimeJobSummary } from '../../api';
import { useMobileAccess } from '../../hooks';

// Fleet campaign (Chime) — one shared card for the summary page and the group
// detail row. Layout model (user-decided during integ testing):
//   · a RUNNING campaign owns the card alone;
//   · a SETTLED campaign's funnel stays PERMANENTLY visible, with the launch
//     zone below it — dry-run results and the skipped conflict swap ONLY that
//     zone, never the settled card;
//   · the big idle invitation renders only for a FIRST-EVER campaign.
// Chime semantics baked in: one campaign per (role, platform, package) —
// "skipped" is a NORMAL outcome; null rates render "—", never 0; Chime being
// down or unconfigured never blocks the release UI around this card.

export interface CampaignCardProps {
  /** App-catalog id — the server derives role/platform/package from the row. */
  appId: number;
  /** Store package id, e.g. in.juspay.nammayatri (display only). */
  pkg: string;
  /** Human caption for the idle card, e.g. "consumer · ios". */
  appLabel: string;
  /** False when a section title already sits above the card (summary page) —
   * the card header then shows only the status. */
  titled?: boolean;
}

const nf = (n: number | undefined | null) => (n == null ? '—' : n.toLocaleString('en-US'));
const pct = (r: number | null | undefined) => (r == null ? '—' : `${Math.round(r * 100)}%`);

// Chime leaves as_of empty on the Postgres path — fall back to updated_at,
// and omit the segment entirely rather than render "Invalid Date".
function asOfLabel(fn: { as_of?: string; updated_at?: string }): string {
  const raw = fn.as_of || fn.updated_at;
  if (!raw) return '';
  const d = new Date(raw);
  return Number.isNaN(d.getTime()) ? '' : ` · as of ${d.toLocaleTimeString()}`;
}

function errText(e: unknown): string {
  const anyE = e as { response?: { data?: { message?: string; error?: string } }; message?: string };
  return anyE?.response?.data?.message ?? anyE?.response?.data?.error ?? anyE?.message ?? 'Request failed';
}

export function CampaignCard({ appId, pkg, appLabel, titled = true }: CampaignCardProps) {
  const qc = useQueryClient();
  const access = useMobileAccess();
  const perms = useMemo(
    () => access.data?.apps.find((a) => a.id === appId)?.mobilePerms ?? [],
    [access.data, appId],
  );
  const hasView = perms.includes('MB_RELEASE_VIEW');
  const canRamp = perms.includes('MB_RELEASE_ROLLOUT');

  const [busy, setBusy] = useState(false);
  const [skipped, setSkipped] = useState(false);
  const [cancelRequested, setCancelRequested] = useState(false);
  const [dryRunJobId, setDryRunJobId] = useState<string | null>(null);

  // Latest REAL campaign for this package. Every dry run mints its own
  // dry_run job at the top of the list, so a small window would let heavy
  // dry-run testing shadow the actual campaign — fetch a generous window
  // and pick the newest non-dry_run. Poll only while one is in flight.
  const realJob = (jobs?: ChimeJobSummary[]) => jobs?.find((j) => j.status !== 'dry_run');
  const jobsQ = useQuery({
    queryKey: ['chime-jobs', appId],
    queryFn: () => chimeApi.listJobs(appId, { limit: 50 }),
    enabled: hasView,
    retry: false,
    refetchInterval: (q) => {
      const j = realJob(q.state.data?.data?.jobs);
      return j && j.status === 'running' ? 10_000 : false;
    },
  });
  const latest: ChimeJobSummary | undefined = realJob(jobsQ.data?.data?.jobs);
  const running = latest?.status === 'running';
  const settled = !!latest && ['completed', 'cancelled'].includes(latest.status);
  // Active dry run — the newest job overall being a dry_run (the list is
  // newest-first, so it necessarily post-dates the real campaign). Restored
  // from the API so a reload shows the recorded result instead of inviting
  // another dry run; clears by itself once a real campaign takes the top.
  const newestJob: ChimeJobSummary | undefined = jobsQ.data?.data?.jobs?.[0];
  const activeDryRunId = dryRunJobId ?? (newestJob?.status === 'dry_run' ? newestJob.job_id : null);

  // Delivery counters — polled while running (GET /chime/status/{jobID}).
  const statusQ = useQuery({
    queryKey: ['chime-job-status', appId, latest?.job_id],
    queryFn: () => chimeApi.jobStatus(appId, latest!.job_id),
    enabled: hasView && !!latest && latest.status !== 'dry_run',
    retry: false,
    refetchInterval: running ? 10_000 : false,
  });
  const st: ChimeJobStatus | null | undefined = statusQ.data?.data;

  // Device funnel — fills in live while running, final when terminal.
  const funnelQ = useQuery({
    queryKey: ['chime-job-funnel', appId, latest?.job_id],
    queryFn: () => chimeApi.jobFunnel(appId, latest!.job_id),
    enabled: hasView && !!latest && latest.status !== 'dry_run',
    retry: false,
    refetchInterval: running ? 15_000 : false,
  });
  const fn: ChimeJobFunnel | null | undefined = funnelQ.data?.data;

  // Dry-run result: the recorded dry_run job's audience counters.
  const dryQ = useQuery({
    queryKey: ['chime-dryrun', appId, activeDryRunId],
    queryFn: () => chimeApi.jobStatus(appId, activeDryRunId!),
    enabled: hasView && !!activeDryRunId,
    retry: false,
  });
  const dry: ChimeJobStatus | null | undefined = dryQ.data?.data;

  const refresh = () => {
    void qc.invalidateQueries({ queryKey: ['chime-jobs', appId] });
    void qc.invalidateQueries({ queryKey: ['chime-job-status', appId] });
    void qc.invalidateQueries({ queryKey: ['chime-job-funnel', appId] });
  };

  const launch = async (dryRun: boolean) => {
    setBusy(true);
    try {
      const resp = await chimeApi.launchCampaign(appId, { dryRun });
      if (resp.status === 'skipped') {
        setSkipped(true);
      } else if (dryRun) {
        const jid = (resp.data as { job_id?: string } | null)?.job_id;
        if (jid) setDryRunJobId(jid);
        toast.success('Dry run recorded — nothing was sent');
      } else {
        setSkipped(false);
        setDryRunJobId(null);
        toast.success('Campaign launched');
      }
      refresh();
    } catch (e) {
      toast.error(errText(e));
    } finally {
      setBusy(false);
    }
  };

  const cancel = async () => {
    if (!latest) return;
    setBusy(true);
    try {
      await chimeApi.cancelJob(appId, latest.job_id);
      setCancelRequested(true);
      toast.success('Cancellation signalled — campaign winds down cooperatively');
      refresh();
    } catch (e) {
      toast.error(errText(e));
    } finally {
      setBusy(false);
    }
  };

  // No OTA grant on this app → the card simply isn't there.
  if (!hasView) return null;

  // ── i · DEGRADED — Chime unreachable / key missing. Never blocks the page.
  if (jobsQ.isError) {
    const msg = errText(jobsQ.error);
    const misconfigured = /not configured|API key/i.test(msg);
    return misconfigured ? (
      <div className="bg-amber-50 rounded-lg border border-amber-200 p-4 flex items-start gap-3">
        <KeyIcon size={20} weight="fill" className="text-amber-500 shrink-0" aria-hidden="true" />
        <div className="text-xs text-amber-900">
          <p className="font-bold">Campaign key not configured</p>
          <p className="mt-0.5">
            Set <span className="font-mono bg-amber-100 px-1 rounded text-[10px]">SC_CHIME_URL</span> and{' '}
            <span className="font-mono bg-amber-100 px-1 rounded text-[10px]">SC_CHIME_API_KEY</span> in the server
            environment to enable fleet campaigns. Everything else on this page works without it.
          </p>
        </div>
      </div>
    ) : (
      <div className="bg-zinc-50 rounded-lg border border-zinc-200 p-4 flex items-start gap-3">
        <PlugsIcon size={20} weight="fill" className="text-zinc-400 shrink-0" aria-hidden="true" />
        <div className="text-xs text-zinc-600">
          <p className="font-bold text-zinc-800">Chime unreachable</p>
          <p className="mt-0.5">Campaign state unknown — retrying automatically. The OTA release itself is unaffected.</p>
        </div>
      </div>
    );
  }

  // ── h · ERROR — delivery aborted; relaunch is safe.
  if (latest?.status === 'error') {
    return (
      <div className="bg-red-50 rounded-lg border border-red-100 p-4 flex items-start gap-3">
        <XCircleIcon size={20} weight="fill" className="text-red-500 shrink-0" aria-hidden="true" />
        <div className="text-xs text-red-900 flex-1">
          <p className="font-bold text-sm">Campaign errored</p>
          <p className="mt-0.5">
            Delivery aborted at{' '}
            <span className="font-mono">
              {nf(st?.successes)} / {nf(st?.tokens_found)}
            </span>{' '}
            sends. Relaunching is safe — devices already on the new bundle simply report{' '}
            <span className="font-mono bg-red-100 px-1 rounded text-[10px]">no_update</span>.
          </p>
        </div>
        {canRamp && (
          <button
            onClick={() => void launch(false)}
            disabled={busy}
            className="text-[11px] bg-white border border-red-300 text-red-700 font-bold px-3 py-1.5 rounded hover:bg-red-100 cursor-pointer disabled:opacity-50 shrink-0"
          >
            Relaunch
          </button>
        )}
      </div>
    );
  }

  // ── e · SKIPPED — one already in flight for this (role, platform, package).
  const skippedCard = (
    <div className="bg-rose-50 rounded-lg border border-rose-200 p-4 flex items-start gap-3">
      <ShieldWarningIcon size={20} weight="fill" className="text-rose-500 shrink-0" aria-hidden="true" />
      <div className="text-xs text-rose-900 flex-1">
        <p className="font-bold text-sm">Not launched — a campaign is already running for this app · platform</p>
        <p className="mt-0.5">Chime allows one campaign per (role, platform, package). Wait for it to finish, or cancel it first.</p>
      </div>
      <button
        onClick={() => {
          setSkipped(false);
          refresh();
        }}
        className="text-[11px] bg-white border border-rose-300 text-rose-700 font-bold px-3 py-1.5 rounded hover:bg-rose-100 cursor-pointer shrink-0"
      >
        View running campaign →
      </button>
    </div>
  );

  // ── b · DRY RUN result — audience resolved, nothing sent.
  const dryRunCard = (
    <div className="bg-white rounded-lg border border-zinc-200 border-l-4 border-l-violet-400 p-4 flex items-center justify-between gap-4">
      <div className="min-w-0 text-xs text-zinc-600">
        <span className="eyebrow flex items-center gap-1 mb-1">
          {titled && (
            <>
              <MegaphoneIcon size={14} weight="bold" className="text-violet-500" aria-hidden="true" /> Fleet campaign ·{' '}
            </>
          )}
          dry run
        </span>
        {dry ? (
          <>
            <p>
              <b className="font-mono">{nf(dry.users_queried)}</b> users resolved ·{' '}
              <b className="font-mono">{nf(dry.tokens_found)}</b> push tokens found. Nothing was sent — this recorded a{' '}
              <span className="font-mono bg-zinc-100 px-1 rounded text-[10px]">dry_run</span> job only.
            </p>
            {dry.users_queried > 0 && (
              <p className="text-[10px] text-zinc-400 mt-1">
                ~{Math.round(((dry.users_queried - dry.tokens_found) / dry.users_queried) * 1000) / 10}% of the audience
                has no usable token and can't be reached by push.
              </p>
            )}
          </>
        ) : (
          <p className="text-zinc-400">Resolving audience…</p>
        )}
      </div>
      {canRamp && (
        <span className="flex items-center gap-3 shrink-0">
          <button
            onClick={() => void launch(true)}
            disabled={busy}
            className="text-[10px] text-zinc-500 font-semibold hover:text-zinc-800 cursor-pointer disabled:opacity-50"
            title="Audiences drift — re-resolve without sending anything"
          >
            Re-run dry run
          </button>
          <button
            onClick={() => void launch(false)}
            disabled={busy}
            className="bg-violet-600 text-white font-bold text-[11px] px-4 py-2 rounded hover:bg-violet-700 cursor-pointer disabled:opacity-50"
          >
            Launch for real
          </button>
        </span>
      )}
    </div>
  );

  // Launch row shown under a settled campaign — the compact next-campaign entry
  // point (the big idle invitation is reserved for a FIRST campaign).
  const launchRow = canRamp ? (
    <div className="bg-white rounded-lg border border-zinc-200 p-3 flex items-center justify-between gap-3">
      <span className="text-[11px] text-zinc-500 min-w-0">
        Launch another campaign for <code className="font-mono bg-zinc-100 px-1 rounded">{pkg}</code> — one per app ·
        platform at a time.
      </span>
      <span className="flex items-center gap-2 shrink-0">
        <button
          onClick={() => void launch(true)}
          disabled={busy}
          className="bg-white border border-zinc-300 text-zinc-700 font-bold text-[10px] px-3 py-1.5 rounded hover:bg-zinc-50 cursor-pointer disabled:opacity-50"
          title="Resolves the audience and records a dry_run job — sends nothing"
        >
          Dry run
        </button>
        <button
          onClick={() => void launch(false)}
          disabled={busy}
          className="bg-violet-600 text-white font-bold text-[10px] px-3 py-1.5 rounded hover:bg-violet-700 cursor-pointer disabled:opacity-50"
        >
          Notify fleet
        </button>
      </span>
    </div>
  ) : null;

  // ── c+f · RUNNING / SETTLED — the funnel card. A settled campaign stays
  // permanently visible; the launch zone below is the only part that swaps
  // (skipped conflict → dry-run result → launch row).
  if (latest && latest.status !== 'dry_run' && (running || settled)) {
    const cancelled = latest.status === 'cancelled';
    const winding = running && cancelRequested;
    const base = st?.users_queried || 0;
    const w = (v: number | undefined) => (base > 0 && v != null ? `${Math.min(100, (v / base) * 100)}%` : '0%');
    const sent = st?.successes ?? 0;
    const progress = st && st.tokens_found > 0 ? Math.round(((st.successes + st.failures) / st.tokens_found) * 100) : 0;
    const rows: Array<{ label: string; value: number | undefined; fill: string; count: string; dim?: boolean }> = [
      { label: 'users_queried', value: st?.users_queried, fill: 'bg-zinc-300', count: 'text-zinc-700', dim: true },
      { label: 'sent ok', value: sent, fill: 'bg-sky-300', count: 'text-zinc-700' },
      { label: 'fcm_received', value: fn?.funnel.fcm_received, fill: 'bg-sky-500', count: 'text-zinc-700' },
      { label: 'worker_started', value: fn?.funnel.worker_started, fill: 'bg-sky-700', count: 'text-zinc-700' },
      { label: 'downloaded', value: fn?.funnel.downloaded, fill: 'bg-emerald-400', count: 'text-emerald-700 font-bold' },
      { label: 'no_update', value: fn?.funnel.no_update, fill: 'bg-zinc-300', count: 'text-zinc-500', dim: true },
      { label: 'failed', value: fn?.funnel.failed, fill: 'bg-rose-400', count: 'text-rose-600', dim: true },
    ];
    const funnelRow = (r: (typeof rows)[number]) => (
      <div key={r.label} className="flex items-center gap-2">
        <span className={`w-24 ${r.dim ? 'text-zinc-400' : 'text-zinc-500'} font-sans font-medium text-right shrink-0`}>
          {r.label}
        </span>
        <div className="flex-1 h-4 bg-zinc-50 rounded overflow-hidden">
          <div className={`h-full ${r.fill}`} style={{ width: w(r.value) }} />
        </div>
        <span className={`w-14 text-right ${r.count}`}>{nf(r.value)}</span>
      </div>
    );
    return (
      <>
        <div className="bg-white rounded-lg border border-zinc-200 border-l-4 border-l-violet-400 p-4 flex flex-col gap-3">
          <div className="flex items-center justify-between">
            <span className="eyebrow flex items-center gap-1">
              {titled && (
                <>
                  <MegaphoneIcon size={14} weight="bold" className="text-violet-500" aria-hidden="true" /> Fleet
                  campaign ·{' '}
                </>
              )}
              {running ? (
                <span className="text-violet-600 inline-flex items-center gap-1">
                  {winding ? 'cancelling' : 'running'}
                  <span className="w-2 h-2 bg-violet-500 rounded-full animate-pulse ml-1" />
                </span>
              ) : (
                <span className={cancelled ? 'text-zinc-500' : 'text-emerald-600'}>{latest.status}</span>
              )}
            </span>
            <span className="text-[9px] font-mono text-zinc-400">
              {running
                ? `job ${latest.job_id.slice(0, 10)}… · polls every 10s`
                : fn
                  ? `source: ${fn.source}${asOfLabel(fn)} · flushes to Postgres after 168h`
                  : `job ${latest.job_id.slice(0, 10)}…`}
            </span>
          </div>
          {running && (
            <div className="flex items-center gap-3">
              <div className="flex-1 h-1.5 bg-zinc-100 rounded-full overflow-hidden">
                <div className="h-full bg-violet-500 rounded-full" style={{ width: `${progress}%` }} />
              </div>
              <span className="text-[10px] font-mono text-zinc-500">{progress}%</span>
              {canRamp && !winding && (
                <button
                  onClick={() => void cancel()}
                  disabled={busy}
                  className="bg-white border border-red-200 text-red-600 font-bold text-[10px] px-3 py-1.5 rounded hover:bg-red-50 cursor-pointer disabled:opacity-50"
                  title="Cancellation is cooperative — the campaign winds down rather than stopping dead"
                >
                  Cancel
                </button>
              )}
            </div>
          )}
          <div className="flex flex-col gap-1.5 font-mono text-[10px]">
            {/* Server-side delivery rows — always known. */}
            {rows.slice(0, 2).map(funnelRow)}
            {fn && !fn.funnel_reported && !running ? (
              // g · delivered but no DEVICE reports yet — only the device-side
              // stages are unknown; never fabricate those bars.
              <div className="border border-dashed border-zinc-200 rounded-lg px-4 py-4 text-center text-[11px] text-zinc-400">
                No devices have reported back yet — the device stages (received → downloaded) fill in as reports arrive.
              </div>
            ) : (
              rows.slice(2).map(funnelRow)
            )}
          </div>
          <div className="flex items-center justify-between border-t border-zinc-100 pt-2">
            <span className="flex flex-wrap items-center gap-2 text-[9px] font-mono text-zinc-500">
              <span className="bg-zinc-50 border border-zinc-200 rounded px-1.5 py-0.5">delivery {pct(fn?.rates.delivery)}</span>
              <span
                className="bg-zinc-50 border border-zinc-200 rounded px-1.5 py-0.5"
                title="server-side send failures (FCM) — distinct from device-side OTA failures"
              >
                send fail {nf(st?.failures)}
              </span>
              <span className="bg-zinc-50 border border-zinc-200 rounded px-1.5 py-0.5">reach {pct(fn?.rates.reach)}</span>
              <span className="bg-zinc-50 border border-zinc-200 rounded px-1.5 py-0.5">worker start {pct(fn?.rates.worker_start)}</span>
              <span className="bg-zinc-50 border border-zinc-200 rounded px-1.5 py-0.5">download {pct(fn?.rates.download)}</span>
              <span className="bg-zinc-50 border border-zinc-200 rounded px-1.5 py-0.5 text-red-600">failure {pct(fn?.rates.failure)}</span>
            </span>
            <span className="text-[9px] text-zinc-400 font-medium">
              <span className="font-mono text-zinc-600">{nf(fn?.in_flight)}</span> in flight (no terminal stage yet)
            </span>
          </div>
        </div>
        {/* The launch zone — only below a SETTLED campaign, never a running one. */}
        {settled && !running && (
          <div className="mt-3">{skipped ? skippedCard : activeDryRunId ? dryRunCard : launchRow}</div>
        )}
      </>
    );
  }

  // No campaign history at all from here on.
  if (skipped) return skippedCard;
  if (activeDryRunId) return dryRunCard;

  // ── a · IDLE — reserved for the app's FIRST campaign.
  return (
    <div className="bg-white rounded-lg border border-zinc-200 border-l-4 border-l-violet-400 p-4 flex items-center justify-between gap-4">
      <div className="min-w-0 text-xs text-zinc-600">
        {titled && (
          <span className="eyebrow flex items-center gap-1 mb-1">
            <MegaphoneIcon size={14} weight="bold" className="text-violet-500" aria-hidden="true" /> Fleet campaign
          </span>
        )}
        <p>
          Push-nudge every <b>{appLabel}</b> device on{' '}
          <code className="font-mono bg-zinc-100 px-1 rounded">{pkg}</code> to fetch this bundle now, instead of waiting
          for organic app-opens.
        </p>
        <p className="text-[10px] text-zinc-400 mt-1">One campaign per app · platform at a time.</p>
      </div>
      {canRamp && (
        <div className="flex items-center gap-2 shrink-0">
          <button
            onClick={() => void launch(true)}
            disabled={busy}
            className="bg-white border border-zinc-300 text-zinc-700 font-bold text-[11px] px-3 py-2 rounded hover:bg-zinc-50 cursor-pointer disabled:opacity-50"
            title="Resolves the audience and records a dry_run job — sends nothing"
          >
            Dry run
          </button>
          <button
            onClick={() => void launch(false)}
            disabled={busy}
            className="bg-violet-600 text-white font-bold text-[11px] px-4 py-2 rounded hover:bg-violet-700 cursor-pointer disabled:opacity-50"
          >
            Notify fleet
          </button>
        </div>
      )}
    </div>
  );
}
