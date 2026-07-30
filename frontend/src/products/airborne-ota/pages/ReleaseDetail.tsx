import { useMemo, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { AlertTriangle, ArrowLeft, Check, Copy, Download, Target, Users } from 'lucide-react';
import { toast } from 'sonner';
import {
  useConcludeOtaRelease,
  useDiscardOtaRelease,
  useOtaAccess,
  useOtaActiveDevices,
  useOtaAdoption,
  useOtaFailures,
  useOtaRelease,
  useOtaServeConfig,
  useRampOtaRelease,
} from '../hooks';
import type { ReactNode } from 'react';
import { OtaStatusBadge } from '../components/OtaStatusBadge';
import { Badge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '../../../shared/ui/card';
import { Input, SelectInput, Textarea } from '../../../shared/ui/input';
import {
  Dialog,
  DialogBody,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '../../../shared/ui/dialog';
import { useConfirm } from '../../../shared/ui/confirm-dialog';
import { Skeleton } from '../../../shared/ui/skeleton';
import { useOtaTheme } from '../theme';
import { cn, copyToClipboard, formatDate } from '../../../lib/utils';
import { ReleaseAnalytics } from '../components/ReleaseAnalytics';

const fieldDark = 'dark:bg-zinc-900 dark:border-zinc-700 dark:text-zinc-100';
const primaryBtnDark = 'bg-airborne border-airborne text-white hover:bg-airborne-hover';
const secondaryBtnDark = 'dark:bg-zinc-900 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800';
const cardDark = 'dark:bg-zinc-900 dark:border-zinc-800';

// Dialogs portal to document.body, escaping the OtaThemeWrapper's .dark
// scope — re-enter it by stamping `dark` (plus surface colors) on the
// dialog content itself when the theme is dark.
const dialogDark = 'dark bg-zinc-900 border-zinc-800 sm:border-zinc-800';

// Airborne variants are plain variant-id strings, not objects.
function VariantRow({ variant, kind }: { variant: string; kind: 'control' | 'experimental' }) {
  return (
    <div className="flex items-center gap-2 py-2.5 border-b border-zinc-100 dark:border-zinc-800 last:border-b-0 min-w-0">
      <Badge
        variant={kind === 'control' ? 'muted' : 'default'}
        className={
          kind === 'control'
            ? 'dark:bg-transparent dark:border-zinc-700 dark:text-zinc-400'
            : 'bg-airborne/10 border-airborne/30 text-airborne dark:bg-transparent dark:border-airborne dark:text-airborne'
        }
      >
        {kind}
      </Badge>
      <span className="text-sm text-zinc-800 dark:text-zinc-200 font-mono truncate">{variant || '—'}</span>
    </div>
  );
}

const num = (v: unknown): number => (typeof v === 'number' && isFinite(v) ? v : 0);

// Top-of-overview summary tile: label, big number, icon (airborne dashboard style).
function MetricTile({ label, value, icon }: { label: string; value: ReactNode; icon: ReactNode }) {
  return (
    <div className="bg-white border border-zinc-200 dark:bg-zinc-900 dark:border-zinc-800 rounded-xl p-4 sm:p-5">
      <div className="flex items-start justify-between gap-2">
        <span className="text-sm text-zinc-500 dark:text-zinc-400">{label}</span>
        <span className="text-zinc-400 dark:text-zinc-500 shrink-0">{icon}</span>
      </div>
      <div className="text-2xl font-bold text-zinc-900 dark:text-zinc-100 mt-2 tabular-nums">{value}</div>
    </div>
  );
}

// Key/value row for the Release Information grid.
function InfoField({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="min-w-0">
      <div className="text-[11px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500">{label}</div>
      <div className="text-sm text-zinc-700 dark:text-zinc-300 mt-1 break-words">{children}</div>
    </div>
  );
}

// Lightweight JSON syntax highlighter — tokenizes into colored spans (no lib,
// no dangerouslySetInnerHTML; React escapes the text). Class names are literal
// so Tailwind keeps them.
const JSON_KEY = 'text-sky-700 dark:text-sky-300';
const JSON_STRING = 'text-amber-700 dark:text-amber-300';
const JSON_NUMBER = 'text-emerald-700 dark:text-emerald-400';
const JSON_KEYWORD = 'text-purple-700 dark:text-purple-300';

function highlightJson(value: unknown): ReactNode[] {
  const json = JSON.stringify(value, null, 2) ?? 'null';
  const re = /"(?:\\.|[^"\\])*"|\b(?:true|false|null)\b|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/g;
  const out: ReactNode[] = [];
  let last = 0;
  let m: RegExpExecArray | null;
  let i = 0;
  while ((m = re.exec(json)) !== null) {
    if (m.index > last) out.push(json.slice(last, m.index));
    const tok = m[0];
    let cls: string;
    if (tok.startsWith('"')) {
      // A string is a key iff the next non-space char is ':'.
      let j = re.lastIndex;
      while (j < json.length && /\s/.test(json[j])) j++;
      cls = json[j] === ':' ? JSON_KEY : JSON_STRING;
    } else if (tok === 'true' || tok === 'false' || tok === 'null') {
      cls = JSON_KEYWORD;
    } else {
      cls = JSON_NUMBER;
    }
    out.push(
      <span key={i++} className={cls}>
        {tok}
      </span>,
    );
    last = re.lastIndex;
  }
  if (last < json.length) out.push(json.slice(last));
  return out;
}

function JsonView({ value, className }: { value: unknown; className?: string }) {
  return (
    <pre
      className={cn(
        'text-xs leading-relaxed text-zinc-600 dark:text-zinc-300 bg-zinc-50 dark:bg-zinc-800/50 rounded-lg p-4 overflow-x-auto',
        className,
      )}
    >
      <code>{highlightJson(value)}</code>
    </pre>
  );
}

const RELEASE_TABS = ['overview', 'files', 'targeting', 'analytics'] as const;
type ReleaseTab = (typeof RELEASE_TABS)[number];

export default function ReleaseDetail() {
  const { app, releaseId } = useParams<{ app: string; releaseId: string }>();
  const navigate = useNavigate();
  const confirm = useConfirm();
  const { isDark } = useOtaTheme();

  const { data: release, isLoading, error, refetch } = useOtaRelease(app, releaseId);
  const { data: access } = useOtaAccess();
  const perms = access?.apps.find((a) => a.appRef === app)?.permissions ?? [];

  const rampMutation = useRampOtaRelease();
  const concludeMutation = useConcludeOtaRelease();
  const discardMutation = useDiscardOtaRelease();

  const [tab, setTab] = useState<ReleaseTab>('overview');
  const [configCopied, setConfigCopied] = useState(false);
  const [rampOpen, setRampOpen] = useState(false);
  const [rampFetching, setRampFetching] = useState(false);
  const [rampFresh, setRampFresh] = useState(false);
  const [rampPercent, setRampPercent] = useState('');
  // The value we SHOWED, kept apart from rampPercent (which the user edits) —
  // this is what the backend compares against to detect a concurrent change.
  const [rampBaseline, setRampBaseline] = useState<number | null>(null);
  const [rampReason, setRampReason] = useState('');

  const [concludeOpen, setConcludeOpen] = useState(false);
  const [chosenVariant, setChosenVariant] = useState('');
  const [concludeReason, setConcludeReason] = useState('');

  // Serve-config preview: run only after the user hits Preview.
  const [dimensionInput, setDimensionInput] = useState('');
  const [previewDim, setPreviewDim] = useState<string | null>(null);
  const serveQuery = useOtaServeConfig(app, previewDim ?? '', previewDim != null);
  const runPreview = () => {
    const dim = dimensionInput.trim();
    if (previewDim === dim) void serveQuery.refetch();
    else setPreviewDim(dim);
  };

  const experiment = release?.experiment;
  const status = experiment?.status ? String(experiment.status).toUpperCase() : undefined;
  const terminal = status === 'CONCLUDED' || status === 'DISCARDED';
  const canAct = ['OTA_RELEASE_RAMP', 'OTA_RELEASE_CONCLUDE', 'OTA_RELEASE_DISCARD'].some((p) =>
    perms.includes(p),
  );
  const canCreate = perms.includes('OTA_RELEASE_CREATE');
  const traffic = typeof experiment?.traffic_percentage === 'number' ? experiment.traffic_percentage : null;
  // `traffic_percentage` is the mid-experiment RAMP (capped at 50% upstream);
  // a CONCLUDED release rolls its chosen variant out to 100%. Matches the
  // airborne dashboard exactly: `status != "CONCLUDED" ? traffic_percentage : 100`
  // — only concluded is special-cased; all other states show the raw ramp.
  const effectiveTraffic = status === 'CONCLUDED' ? 100 : traffic;
  const control = experiment?.experiment_variants?.control;
  const experimentals = experiment?.experiment_variants?.experimentals ?? [];
  const pkgVersion = experiment?.package_version ?? release?.package?.version;
  const dimensions =
    release?.dimensions && typeof release.dimensions === 'object' && !Array.isArray(release.dimensions)
      ? (release.dimensions as Record<string, unknown>)
      : {};

  // Overview summary metrics — pulled from analytics (30-day window,
  // release-scoped), fetched only while the Overview tab is open; every number
  // degrades to 0 when analytics is unconfigured/unreachable.
  const metricsEnabled = tab === 'overview';
  const { adoptionParams, days } = useMemo(() => {
    const end = Math.floor(Date.now() / 60_000) * 60_000;
    const start = end - 30 * 86_400_000;
    return {
      days: 30,
      adoptionParams: {
        interval: 'DAY' as const,
        start_date: String(start),
        end_date: String(end),
        date: String(end),
        release_id: releaseId,
      },
    };
  }, [releaseId]);
  const adoptionM = useOtaAdoption(app, adoptionParams, metricsEnabled);
  const activeM = useOtaActiveDevices(app, days, metricsEnabled);
  const failuresM = useOtaFailures(app, days, releaseId, metricsEnabled);
  const downloads = (adoptionM.data?.data?.time_breakdown ?? []).reduce(
    (acc, b) => acc + num(b.download_success),
    0,
  );
  const affectedUsers = num(activeM.data?.data?.total_active_devices);
  const errors = num(failuresM.data?.data?.total_failures);

  // Flatten the release's bundle files for the Files tab: the index file plus
  // the important/lazy split and any resource keys.
  const releaseFiles = useMemo(() => {
    const out: { kind: string; path: string; detail: string }[] = [];
    const pkg = release?.package as Record<string, unknown> | undefined;
    const idx = pkg?.index;
    if (idx && typeof idx === 'object') {
      const o = idx as Record<string, unknown>;
      out.push({ kind: 'index', path: String(o.file_path ?? '—'), detail: String(o.url ?? o.checksum ?? '') });
    }
    const pushKeys = (kind: string, v: unknown) => {
      if (Array.isArray(v)) for (const k of v) if (typeof k === 'string') out.push({ kind, path: k.split('@')[0] || k, detail: k });
    };
    pushKeys('important', pkg?.important);
    pushKeys('lazy', pkg?.lazy);
    if (Array.isArray(release?.resources)) {
      for (const r of release.resources) {
        if (typeof r === 'string') out.push({ kind: 'resource', path: r.split('@')[0] || r, detail: r });
        else if (r && typeof r === 'object') {
          const o = r as Record<string, unknown>;
          out.push({ kind: 'resource', path: String(o.file_path ?? '—'), detail: String(o.url ?? '') });
        }
      }
    }
    return out;
  }, [release]);

  // Release Config card mirrors airborne's `toServeReleaseConfig`: only
  // config + resources + a trimmed package (version/properties/index/
  // important/lazy) — NOT the whole release (no id/experiment/dimensions).
  const releaseConfig = useMemo(() => {
    if (!release) return null;
    const pkg = (release.package ?? {}) as Record<string, unknown>;
    const { version, properties, index, important, lazy } = pkg;
    return {
      config: release.config,
      resources: release.resources,
      package: { version, properties, index, important, lazy },
    };
  }, [release]);

  // Ramp is last-write-wins upstream: refetch right before opening so the
  // dialog's "current traffic" is the freshest value we can show.
  const openRamp = async () => {
    setRampFetching(true);
    try {
      const fresh = await refetch();
      if (fresh.isError) {
        toast.warning('Could not refresh current traffic — the value shown may be stale');
      }
      setRampFresh(!fresh.isError);
      const pct = fresh.data?.experiment?.traffic_percentage;
      setRampPercent(typeof pct === 'number' ? String(pct) : '');
      setRampBaseline(typeof pct === 'number' ? pct : null);
      setRampReason('');
      setRampOpen(true);
    } finally {
      setRampFetching(false);
    }
  };

  const submitRamp = () => {
    const pct = Number(rampPercent);
    if (rampPercent.trim() === '' || !Number.isInteger(pct) || pct < 0 || pct > 100) {
      toast.error('Traffic must be a whole number between 0 and 100');
      return;
    }
    rampMutation.mutate(
      {
        app: app!,
        releaseId: releaseId!,
        body: {
          trafficPercentage: pct,
          ...(rampReason.trim() ? { changeReason: rampReason.trim() } : {}),
          // Only guard when we actually refreshed successfully — sending a
          // stale baseline would 409 on a value the operator never saw.
          ...(rampFresh && rampBaseline != null
            ? { expectedTrafficPercentage: rampBaseline }
            : {}),
        },
      },
      { onSuccess: () => setRampOpen(false) },
    );
  };

  const openConclude = () => {
    setChosenVariant(experimentals[0] ?? '');
    setConcludeReason('');
    setConcludeOpen(true);
  };

  const submitConclude = async () => {
    if (!chosenVariant) {
      toast.error('Select an experimental variant to conclude with');
      return;
    }
    setConcludeOpen(false);
    const ok = await confirm({
      title: 'Conclude release',
      description: `Conclude this release with variant "${chosenVariant}"? All traffic will be served this variant.`,
      confirmLabel: 'Conclude',
    });
    if (!ok) return;
    concludeMutation.mutate({
      app: app!,
      releaseId: releaseId!,
      body: { chosenVariant, ...(concludeReason.trim() ? { changeReason: concludeReason.trim() } : {}) },
    });
  };

  const onRevert = async () => {
    if (!control) {
      toast.error('Control variant unavailable — cannot revert');
      return;
    }
    const ok = await confirm({
      title: 'Revert release',
      description: `Conclude this release with the CONTROL variant "${control}"? All users go back to the previous bundle.`,
      confirmLabel: 'Revert',
      variant: 'danger',
    });
    if (!ok) return;
    concludeMutation.mutate({
      app: app!,
      releaseId: releaseId!,
      body: { chosenVariant: control, changeReason: 'Revert to control' },
    });
  };

  const onDiscard = async () => {
    const ok = await confirm({
      title: 'Discard release',
      description: 'Discard this release? It stops being served and cannot be resumed.',
      confirmLabel: 'Discard',
      variant: 'danger',
    });
    if (!ok) return;
    discardMutation.mutate({ app: app!, releaseId: releaseId! });
  };

  // A failed release load scopes to the Overview tab only — the Analytics tab
  // reads a separate host and stays reachable (see the overview branch below).
  const releaseLoadFailed = !!error && !release;

  return (
    <div className="flex flex-col flex-1 w-full pb-12 space-y-4">
      {error && release && (
        <div className="rounded-lg border border-amber-200 bg-amber-50 dark:border-amber-900 dark:bg-amber-950/40 px-3 py-2 text-xs text-amber-700 dark:text-amber-300">
          Live refresh failed — showing the last loaded data.
        </div>
      )}
      {/* Header */}
      <div className="flex flex-col sm:flex-row sm:items-start justify-between gap-3">
        <div className="flex items-start gap-3 min-w-0">
          <Link
            to={`/airborne/${encodeURIComponent(app!)}/releases`}
            className="w-9 h-9 mt-0.5 rounded-lg border border-zinc-200 bg-white text-zinc-500 hover:text-zinc-800 hover:bg-zinc-50 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100 dark:hover:bg-zinc-800 flex items-center justify-center shrink-0"
            aria-label="Back to releases"
          >
            <ArrowLeft className="w-4 h-4" />
          </Link>
          <div className="min-w-0">
            <div className="flex items-center gap-2 flex-wrap min-w-0">
              <h1 className="text-lg sm:text-2xl font-bold text-zinc-900 dark:text-zinc-100 min-w-0 break-all">
                Release <span className="font-mono">{releaseId}</span>
              </h1>
              <button
                type="button"
                className="p-1 rounded text-zinc-400 hover:text-zinc-700 hover:bg-zinc-100 dark:text-zinc-500 dark:hover:text-zinc-200 dark:hover:bg-zinc-800 cursor-pointer shrink-0"
                onClick={() => {
                  copyToClipboard(releaseId!);
                  toast.success('Release id copied');
                }}
                aria-label="Copy release id"
              >
                <Copy className="w-3.5 h-3.5" />
              </button>
              <OtaStatusBadge status={status} size="md" />
            </div>
            <p className="text-sm text-zinc-500 dark:text-zinc-400 mt-1">
              {pkgVersion != null ? `Package version ${pkgVersion}` : 'OTA release'}
            </p>
          </div>
        </div>

        <div className="flex items-center gap-2 flex-wrap shrink-0">
          {/* Actions — gated by the caller's per-app OTA_* permission set */}
          {canCreate && (
            <>
              {!terminal && (
                <Button
                  variant="secondary"
                  size="sm"
                  className={secondaryBtnDark}
                  onClick={() =>
                    navigate(
                      `/airborne/${encodeURIComponent(app!)}/releases/${encodeURIComponent(releaseId!)}/edit`,
                    )
                  }
                >
                  Edit
                </Button>
              )}
              <Button
                variant="secondary"
                size="sm"
                className={secondaryBtnDark}
                onClick={() =>
                  navigate(
                    `/airborne/${encodeURIComponent(app!)}/releases/${encodeURIComponent(releaseId!)}/clone`,
                  )
                }
              >
                Clone
              </Button>
            </>
          )}
          {!terminal && canAct && (
            <>
              {perms.includes('OTA_RELEASE_RAMP') && (
                <Button variant="primary" size="sm" className={primaryBtnDark} loading={rampFetching} onClick={openRamp}>
                  Ramp
                </Button>
              )}
              {perms.includes('OTA_RELEASE_CONCLUDE') && (
                <Button
                  variant="success"
                  size="sm"
                  disabled={experimentals.length === 0}
                  loading={concludeMutation.isPending}
                  onClick={openConclude}
                >
                  Conclude
                </Button>
              )}
              {perms.includes('OTA_RELEASE_CONCLUDE') && (
                <Button
                  variant="secondary"
                  size="sm"
                  className={secondaryBtnDark}
                  disabled={!control}
                  loading={concludeMutation.isPending}
                  onClick={onRevert}
                >
                  Revert
                </Button>
              )}
              {perms.includes('OTA_RELEASE_DISCARD') && (
                <Button
                  variant="danger"
                  size="sm"
                  loading={discardMutation.isPending}
                  onClick={onDiscard}
                >
                  Discard
                </Button>
              )}
            </>
          )}
        </div>
      </div>

      {/* Segmented tab bar */}
      <div className="inline-flex items-center gap-1 self-start rounded-lg border border-zinc-200 bg-zinc-50 dark:border-zinc-800 dark:bg-zinc-900 p-1">
        {RELEASE_TABS.map((t) => (
          <button
            key={t}
            type="button"
            onClick={() => setTab(t)}
            className={cn(
              'px-3 py-1.5 rounded-md text-sm font-medium capitalize cursor-pointer transition-colors duration-150',
              tab === t
                ? 'bg-white text-zinc-900 shadow-sm dark:bg-zinc-800 dark:text-zinc-100'
                : 'text-zinc-500 hover:text-zinc-800 dark:text-zinc-400 dark:hover:text-zinc-200',
            )}
          >
            {t}
          </button>
        ))}
      </div>

      {tab === 'analytics' && <ReleaseAnalytics app={app!} releaseId={releaseId!} />}

      {/* Release-body-dependent tabs share the load/error guard. */}
      {tab !== 'analytics' && releaseLoadFailed && (
        <div className="py-16 text-center text-sm text-red-600 dark:text-red-400">
          Failed to load release. It may not exist for this app.
        </div>
      )}
      {tab !== 'analytics' && !releaseLoadFailed && isLoading && (
        <div className="space-y-4 dark:invert">
          <Skeleton className="h-28 w-full" />
          <Skeleton className="h-40 w-full" />
        </div>
      )}

      {/* ── Overview ─────────────────────────────────────────────── */}
      {tab === 'overview' && !releaseLoadFailed && !isLoading && (
        <div className="space-y-4">
          {/* Summary metrics */}
          <div className="grid grid-cols-2 lg:grid-cols-4 gap-3 sm:gap-4">
            <MetricTile
              label="Traffic %"
              value={effectiveTraffic != null ? `${effectiveTraffic}%` : '—'}
              icon={<Target className="w-5 h-5" />}
            />
            <MetricTile
              label="Affected Users"
              value={affectedUsers.toLocaleString()}
              icon={<Users className="w-5 h-5" />}
            />
            <MetricTile
              label="Downloads"
              value={downloads.toLocaleString()}
              icon={<Download className="w-5 h-5" />}
            />
            <MetricTile
              label="Errors"
              value={errors.toLocaleString()}
              icon={<AlertTriangle className="w-5 h-5" />}
            />
          </div>

          {/* Release Information */}
          <Card className={cardDark}>
            <CardHeader className="dark:border-zinc-800">
              <CardTitle className="dark:text-zinc-100">Release Information</CardTitle>
              <p className="text-sm text-zinc-500 dark:text-zinc-400 mt-0.5">
                Detailed information about this release
              </p>
            </CardHeader>
            <CardContent className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <InfoField label="Release ID">
                <span className="font-mono break-all">{releaseId}</span>
              </InfoField>
              <InfoField label="Package Version">
                <span className="font-mono">{pkgVersion != null ? String(pkgVersion) : '—'}</span>
              </InfoField>
              <InfoField label="Status">
                <OtaStatusBadge status={status} />
              </InfoField>
              <InfoField label="Created">{formatDate(release?.created_at)}</InfoField>
              <InfoField label="App">{app}</InfoField>
              {experiment?.config_version && (
                <InfoField label="Config Version">
                  <span className="font-mono break-all">{String(experiment.config_version)}</span>
                </InfoField>
              )}
            </CardContent>
          </Card>

          {/* Variants (needed for conclude) */}
          {(control || experimentals.length > 0) && (
            <Card className={cardDark}>
              <CardHeader className="dark:border-zinc-800">
                <CardTitle className="dark:text-zinc-100">Variants</CardTitle>
              </CardHeader>
              <CardContent>
                {control && <VariantRow variant={control} kind="control" />}
                {experimentals.map((v, i) => (
                  <VariantRow key={v || i} variant={v} kind="experimental" />
                ))}
              </CardContent>
            </Card>
          )}

          {/* Release Config (raw JSON + copy) */}
          <Card className={cardDark}>
            <CardHeader className="flex items-center justify-between dark:border-zinc-800">
              <CardTitle className="dark:text-zinc-100">Release Config</CardTitle>
              <Button
                variant="secondary"
                size="sm"
                className={secondaryBtnDark}
                onClick={() => {
                  copyToClipboard(JSON.stringify(releaseConfig, null, 2));
                  setConfigCopied(true);
                  window.setTimeout(() => setConfigCopied(false), 1500);
                }}
              >
                {configCopied ? <Check className="w-4 h-4" /> : <Copy className="w-4 h-4" />}
                {configCopied ? 'Copied' : 'Copy'}
              </Button>
            </CardHeader>
            <CardContent>
              <JsonView value={releaseConfig} className="max-h-[28rem]" />
            </CardContent>
          </Card>

          {/* Serve-config preview — what the SDK resolves for this app */}
          <Card className={cardDark}>
            <CardHeader className="dark:border-zinc-800">
              <CardTitle className="dark:text-zinc-100">Serve config preview</CardTitle>
              <p className="text-sm text-zinc-500 dark:text-zinc-400 mt-0.5">
                Resolve the config an SDK would receive, optionally for a dimension context.
              </p>
            </CardHeader>
            <CardContent className="space-y-3">
              <div className="flex items-end gap-2">
                <div className="flex-1 max-w-sm">
                  <Input
                    label="Dimension (optional)"
                    placeholder="k1=v1;k2=v2"
                    value={dimensionInput}
                    onChange={(e) => setDimensionInput(e.target.value)}
                    className={fieldDark}
                  />
                </div>
                <Button
                  variant="secondary"
                  size="sm"
                  className={secondaryBtnDark}
                  loading={serveQuery.isFetching}
                  onClick={runPreview}
                >
                  Preview
                </Button>
              </div>
              {serveQuery.isError && (
                <p className="text-xs text-red-600 dark:text-red-400">
                  Failed to fetch serve config. Check the dimension format (k1=v1;k2=v2).
                </p>
              )}
              {serveQuery.data != null && !serveQuery.isError && (
                <JsonView value={serveQuery.data} />
              )}
            </CardContent>
          </Card>
        </div>
      )}

      {/* ── Files ────────────────────────────────────────────────── */}
      {tab === 'files' && !releaseLoadFailed && !isLoading && (
        <Card className={cardDark}>
          <CardHeader className="dark:border-zinc-800">
            <CardTitle className="dark:text-zinc-100">Files</CardTitle>
            <p className="text-sm text-zinc-500 dark:text-zinc-400 mt-0.5">
              Bundle files served by this release.
            </p>
          </CardHeader>
          <CardContent className="p-0">
            {releaseFiles.length === 0 ? (
              <div className="py-16 text-center text-zinc-400 dark:text-zinc-500 text-sm">
                No file information on this release.
              </div>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-left">
                  <thead>
                    <tr className="bg-zinc-50 border-b border-zinc-200 dark:bg-zinc-800/50 dark:border-zinc-800 text-[11px] text-zinc-500 dark:text-zinc-500 font-medium uppercase tracking-wider">
                      <th className="py-3 px-4">Type</th>
                      <th className="py-3 px-4">Path</th>
                      <th className="py-3 px-4">Detail</th>
                    </tr>
                  </thead>
                  <tbody className="text-sm">
                    {releaseFiles.map((f, i) => (
                      <tr key={i} className="border-b border-zinc-100 dark:border-zinc-800">
                        <td className="py-3 px-4">
                          <Badge className="capitalize dark:bg-zinc-800 dark:border-zinc-700 dark:text-zinc-300">
                            {f.kind}
                          </Badge>
                        </td>
                        <td className="py-3 px-4 font-mono text-xs text-zinc-700 dark:text-zinc-300 break-all">
                          {f.path || '—'}
                        </td>
                        <td className="py-3 px-4 font-mono text-xs text-zinc-500 dark:text-zinc-400 break-all max-w-md">
                          {f.detail || '—'}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </CardContent>
        </Card>
      )}

      {/* ── Targeting ────────────────────────────────────────────── */}
      {tab === 'targeting' && !releaseLoadFailed && !isLoading && (
        <div className="space-y-4">
          <Card className={cardDark}>
            <CardHeader className="dark:border-zinc-800">
              <CardTitle className="dark:text-zinc-100">Targeting</CardTitle>
              <p className="text-sm text-zinc-500 dark:text-zinc-400 mt-0.5">
                Dimension rules that decide who receives this release.
              </p>
            </CardHeader>
            <CardContent>
              {Object.keys(dimensions).length === 0 ? (
                <p className="text-sm text-zinc-500 dark:text-zinc-400">
                  This release is untargeted — it applies to all users.
                </p>
              ) : (
                <div className="flex flex-wrap gap-1.5">
                  {Object.entries(dimensions).map(([k, v]) => (
                    <span
                      key={k}
                      className="inline-flex items-center rounded-md bg-zinc-100 dark:bg-zinc-800 px-2.5 py-1 text-xs font-mono text-zinc-700 dark:text-zinc-300"
                    >
                      {k} = {Array.isArray(v) ? v.join(', ') : String(v)}
                    </span>
                  ))}
                </div>
              )}
            </CardContent>
          </Card>

          {/* Ramp Configuration — mirrors airborne's Targeting card. Target
              Traffic (50%) and Rollout Strategy ("Linear") are static in
              airborne, not per-release data. */}
          <Card className={cardDark}>
            <CardHeader className="dark:border-zinc-800">
              <CardTitle className="dark:text-zinc-100">Ramp Configuration</CardTitle>
              <p className="text-sm text-zinc-500 dark:text-zinc-400 mt-0.5">
                Traffic ramping and rollout settings.
              </p>
            </CardHeader>
            <CardContent className="grid grid-cols-2 gap-6">
              <div className="space-y-1">
                <p className="text-sm font-medium text-zinc-700 dark:text-zinc-300">Current Traffic</p>
                <p className="text-2xl font-bold text-zinc-900 dark:text-zinc-100 tabular-nums">
                  {effectiveTraffic != null ? `${effectiveTraffic}%` : '—'}
                </p>
              </div>
              <div className="space-y-1">
                <p className="text-sm font-medium text-zinc-700 dark:text-zinc-300">Target Traffic</p>
                <p className="text-2xl font-bold text-zinc-900 dark:text-zinc-100 tabular-nums">50%</p>
              </div>
              <div className="space-y-1">
                <p className="text-sm font-medium text-zinc-700 dark:text-zinc-300">Rollout Strategy</p>
                <p className="text-sm text-zinc-500 dark:text-zinc-400">Linear</p>
              </div>
              <div className="space-y-1">
                <p className="text-sm font-medium text-zinc-700 dark:text-zinc-300">Status</p>
                <OtaStatusBadge status={status} />
              </div>
            </CardContent>
          </Card>
        </div>
      )}

      {/* Ramp dialog */}
      <Dialog open={rampOpen} onOpenChange={setRampOpen}>
        <DialogContent size="md" className={cn(isDark && dialogDark)}>
          <DialogHeader>
            <DialogTitle className="dark:text-zinc-100">Ramp traffic</DialogTitle>
            <DialogDescription className="dark:text-zinc-400">
              Current traffic ({rampFresh ? 'just refreshed' : 'last known'}):{' '}
              <b>{traffic != null ? `${traffic}%` : 'unknown'}</b>.
              Setting a new value overwrites it — last write wins.
            </DialogDescription>
          </DialogHeader>
          <DialogBody className="space-y-4">
            <Input
              label="New traffic percentage"
              type="number"
              min={0}
              max={100}
              value={rampPercent}
              onChange={(e) => setRampPercent(e.target.value)}
              required
              className={fieldDark}
            />
            <Textarea
              label="Change reason (optional)"
              rows={3}
              value={rampReason}
              onChange={(e) => setRampReason(e.target.value)}
              placeholder="Why is the traffic changing?"
              className={fieldDark}
            />
          </DialogBody>
          <DialogFooter className="dark:bg-zinc-900 dark:border-zinc-800">
            <Button variant="secondary" className={secondaryBtnDark} onClick={() => setRampOpen(false)}>
              Cancel
            </Button>
            <Button variant="primary" className={primaryBtnDark} loading={rampMutation.isPending} onClick={submitRamp}>
              Set traffic
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Conclude dialog */}
      <Dialog open={concludeOpen} onOpenChange={setConcludeOpen}>
        <DialogContent size="md" className={cn(isDark && dialogDark)}>
          <DialogHeader>
            <DialogTitle className="dark:text-zinc-100">Conclude release</DialogTitle>
            <DialogDescription className="dark:text-zinc-400">
              Pick the experimental variant to conclude with. To go back to control, use Revert instead.
            </DialogDescription>
          </DialogHeader>
          <DialogBody className="space-y-4">
            <SelectInput
              label="Experimental variant"
              options={experimentals.filter(Boolean).map((v) => ({ value: v, label: v }))}
              value={chosenVariant}
              onChange={(e) => setChosenVariant(e.target.value)}
              required
              className={fieldDark}
            />
            <Textarea
              label="Change reason (optional)"
              rows={3}
              value={concludeReason}
              onChange={(e) => setConcludeReason(e.target.value)}
              placeholder="Why is the release concluding?"
              className={fieldDark}
            />
          </DialogBody>
          <DialogFooter className="dark:bg-zinc-900 dark:border-zinc-800">
            <Button variant="secondary" className={secondaryBtnDark} onClick={() => setConcludeOpen(false)}>
              Cancel
            </Button>
            <Button variant="primary" className={primaryBtnDark} onClick={submitConclude}>
              Continue
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
