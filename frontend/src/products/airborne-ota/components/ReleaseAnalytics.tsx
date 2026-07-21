import { useMemo, useState } from 'react';
import { CheckCircle, Clock, Download, Info, RotateCcw, TrendingUp } from 'lucide-react';
import type { ComponentType } from 'react';
import {
  useOtaActiveDevices,
  useOtaAdoption,
  useOtaFailures,
  useOtaPerformance,
  useOtaVersions,
} from '../hooks';
import type { OtaAdoptionBucket, OtaAdoptionParams, OtaAnalyticsInterval } from '../types';
import { Card, CardContent, CardHeader, CardTitle } from '../../../shared/ui/card';
import { Button } from '../../../shared/ui/button';
import { Skeleton, TableSkeleton } from '../../../shared/ui/skeleton';
import { DateRangePicker } from './DateRangePicker';

const primaryBtnDark = 'bg-airborne border-airborne text-white hover:bg-airborne-hover';
const secondaryBtnDark =
  'dark:bg-zinc-900 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800';
const cardDark = 'dark:bg-zinc-900 dark:border-zinc-800';

// Series colors: green downloads/completed, blue applied/success, amber
// rollbacks initiated, red rollback failures.
const COLORS = {
  downloads: '#4ade80',
  applied: '#2563eb',
  rollbackInit: '#fbbf24',
  rollbackDone: '#4ade80',
  rollbackFail: '#ef4444',
};

// SVG chart frame (fixed viewBox, scaled to 100% width via preserveAspectRatio).
const W = 640;
const H = 200;
const PAD_L = 40;
const PAD_R = 12;
const PAD_T = 12;
const PAD_B = 28;
const plotW = W - PAD_L - PAD_R;
const plotH = H - PAD_T - PAD_B;

const n = (v: unknown): number => (typeof v === 'number' && isFinite(v) ? v : 0);

// ── Date helpers (day-precision, matching airborne's midnight-based window) ──
function ymd(d: Date): string {
  const p = (v: number) => String(v).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}
function parseYmd(s: string): number | null {
  if (!s) return null;
  const d = new Date(`${s}T00:00:00`);
  return isNaN(d.getTime()) ? null : d.getTime();
}
const DAY_MS = 86_400_000;

type PresetKey = '24h' | '7d' | '30d';
const PRESETS: { key: PresetKey; label: string; startFromToday: number }[] = [
  { key: '24h', label: 'Last 24 hours', startFromToday: 0 },
  { key: '7d', label: 'Last 7 days', startFromToday: 7 },
  { key: '30d', label: 'Last 30 days', startFromToday: 29 },
];

function slotLabel(slot: string, interval: OtaAnalyticsInterval): string {
  const d = new Date(slot);
  if (isNaN(d.getTime())) return slot;
  return interval === 'HOUR'
    ? d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
    : d.toLocaleDateString([], { month: 'short', day: 'numeric' });
}

// Round the axis top to a 1/2/5 * 10^n step so tick labels stay readable.
function niceMax(raw: number): number {
  if (raw <= 1) return 1;
  const pow = Math.pow(10, Math.floor(Math.log10(raw)));
  const norm = raw / pow;
  const nice = norm <= 1 ? 1 : norm <= 2 ? 2 : norm <= 5 ? 5 : 10;
  return nice * pow;
}

function fmtTick(v: number): string {
  if (v >= 1000) return `${v % 1000 === 0 ? v / 1000 : (v / 1000).toFixed(1)}k`;
  return String(Math.round(v));
}

const chartEmpty = (
  <div className="py-16 text-center text-zinc-400 dark:text-zinc-500 text-sm">
    No adoption data for this release/window
  </div>
);

interface Series {
  label: string;
  color: string;
  get: (b: OtaAdoptionBucket) => number;
}

function ChartGrid({ max, unit }: { max: number; unit?: string }) {
  const fractions = [0, 0.25, 0.5, 0.75, 1];
  return (
    <g>
      {fractions.map((f) => {
        const y = PAD_T + plotH - f * plotH;
        return (
          <line
            key={f}
            x1={PAD_L}
            x2={W - PAD_R}
            y1={y}
            y2={y}
            className="stroke-zinc-200 dark:stroke-zinc-800"
            strokeWidth={1}
          />
        );
      })}
      <text x={PAD_L - 6} y={PAD_T + plotH + 3} textAnchor="end" fontSize={9} className="fill-zinc-400 dark:fill-zinc-600">
        0
      </text>
      <text x={PAD_L - 6} y={PAD_T + 3} textAnchor="end" fontSize={9} className="fill-zinc-400 dark:fill-zinc-600">
        {fmtTick(max)}
        {unit ?? ''}
      </text>
    </g>
  );
}

function GroupedBarChart({
  buckets,
  series,
  interval,
  fixedMax,
  unit,
}: {
  buckets: OtaAdoptionBucket[];
  series: Series[];
  interval: OtaAnalyticsInterval;
  fixedMax?: number;
  unit?: string;
}) {
  const max = fixedMax ?? niceMax(Math.max(1, ...buckets.flatMap((b) => series.map((s) => s.get(b)))));
  const count = buckets.length;
  const groupW = plotW / Math.max(1, count);
  const innerW = Math.min(groupW * 0.72, 46);
  const gap = 2;
  const barW = Math.max(1, (innerW - gap * (series.length - 1)) / series.length);
  const labelEvery = Math.max(1, Math.ceil(count / 8));
  return (
    <svg viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="xMidYMid meet" className="w-full h-auto" role="img" aria-label="bar chart">
      <ChartGrid max={max} unit={unit} />
      {buckets.map((b, i) => {
        const cx = PAD_L + i * groupW + groupW / 2;
        const gx = cx - innerW / 2;
        return (
          <g key={i}>
            {series.map((s, si) => {
              const h = (Math.min(s.get(b), max) / max) * plotH;
              return (
                <rect
                  key={si}
                  x={gx + si * (barW + gap)}
                  y={PAD_T + plotH - h}
                  width={barW}
                  height={Math.max(0, h)}
                  fill={s.color}
                  rx={1}
                />
              );
            })}
            {i % labelEvery === 0 && (
              <text x={cx} y={H - PAD_B + 14} textAnchor="middle" fontSize={9} className="fill-zinc-500 dark:fill-zinc-500">
                {slotLabel(b.time_slot, interval)}
              </text>
            )}
          </g>
        );
      })}
    </svg>
  );
}

// Fixed 0..100 domain line: value(b) is a per-bucket percentage.
function RateChart({
  buckets,
  interval,
  value,
}: {
  buckets: OtaAdoptionBucket[];
  interval: OtaAnalyticsInterval;
  value: (b: OtaAdoptionBucket) => number;
}) {
  const count = buckets.length;
  const xFor = (i: number) => (count <= 1 ? PAD_L + plotW / 2 : PAD_L + (i / (count - 1)) * plotW);
  const pts = buckets.map((b, i) => {
    const rate = Math.max(0, Math.min(100, value(b)));
    return { x: xFor(i), y: PAD_T + plotH - (rate / 100) * plotH };
  });
  const labelEvery = Math.max(1, Math.ceil(count / 8));
  return (
    <svg viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="xMidYMid meet" className="w-full h-auto" role="img" aria-label="rate line chart">
      <ChartGrid max={100} unit="%" />
      {pts.length > 1 && (
        <polyline
          points={pts.map((p) => `${p.x.toFixed(1)},${p.y.toFixed(1)}`).join(' ')}
          fill="none"
          stroke={COLORS.applied}
          strokeWidth={2}
          strokeLinejoin="round"
          strokeLinecap="round"
        />
      )}
      {pts.map((p, i) => (
        <circle key={i} cx={p.x} cy={p.y} r={2.5} fill={COLORS.applied} />
      ))}
      {buckets.map((b, i) =>
        i % labelEvery === 0 ? (
          <text key={i} x={xFor(i)} y={H - PAD_B + 14} textAnchor="middle" fontSize={9} className="fill-zinc-500 dark:fill-zinc-500">
            {slotLabel(b.time_slot, interval)}
          </text>
        ) : null,
      )}
    </svg>
  );
}

function Legend({ items }: { items: { label: string; color: string }[] }) {
  return (
    <div className="flex items-center gap-4 flex-wrap mt-3">
      {items.map((it) => (
        <div key={it.label} className="flex items-center gap-1.5 text-xs text-zinc-500 dark:text-zinc-400">
          <span className="w-2.5 h-2.5 rounded-sm shrink-0" style={{ backgroundColor: it.color }} />
          {it.label}
        </div>
      ))}
    </div>
  );
}

// Airborne-style summary tile: title + icon, big value, description.
function MetricTile({
  title,
  value,
  description,
  icon: Icon,
}: {
  title: string;
  value: string;
  description: string;
  icon: ComponentType<{ className?: string }>;
}) {
  return (
    <div className="bg-white border border-zinc-200 dark:bg-zinc-900 dark:border-zinc-800 rounded-xl p-4 sm:p-5">
      <div className="flex items-start justify-between gap-2">
        <span className="text-sm text-zinc-500 dark:text-zinc-400">{title}</span>
        <Icon className="w-4 h-4 text-zinc-400 dark:text-zinc-500 shrink-0" />
      </div>
      <div className="text-2xl font-bold text-zinc-900 dark:text-zinc-100 mt-2 tabular-nums">{value}</div>
      <div className="text-xs text-zinc-500 dark:text-zinc-400 mt-1">{description}</div>
    </div>
  );
}

function UnavailableCard() {
  return (
    <Card className={cardDark}>
      <CardContent className="py-10 flex flex-col items-center text-center gap-2">
        <Info className="w-5 h-5 text-zinc-400 dark:text-zinc-500" />
        <div className="text-sm font-medium text-zinc-700 dark:text-zinc-200">
          Analytics isn't available for this environment.
        </div>
        <div className="text-xs text-zinc-500 dark:text-zinc-500">
          The analytics service may not be configured or is unreachable.
        </div>
      </CardContent>
    </Card>
  );
}

export function ReleaseAnalytics({ app, releaseId }: { app: string; releaseId: string }) {
  const today = ymd(new Date());
  const [startDate, setStartDate] = useState(() => ymd(new Date(Date.now() - 7 * DAY_MS)));
  const [endDate, setEndDate] = useState(() => today);

  // Which preset (if any) the current range matches — end must be today and the
  // start must equal the preset's start. Otherwise it's a custom range.
  const activePreset: PresetKey | null =
    endDate === today
      ? (PRESETS.find((p) => startDate === ymd(new Date(Date.now() - p.startFromToday * DAY_MS)))?.key ?? null)
      : null;

  const applyPreset = (p: (typeof PRESETS)[number]) => {
    setEndDate(today);
    setStartDate(ymd(new Date(Date.now() - p.startFromToday * DAY_MS)));
  };

  // Derive interval (HOUR ≤24h else DAY), day-count, and query params from the
  // selected window. Invalid (empty/reversed) ranges disable the queries.
  const { interval, days, params, valid } = useMemo(() => {
    const s = parseYmd(startDate);
    const e = parseYmd(endDate);
    const ok = s != null && e != null && s <= e;
    const startMs = ok ? s : 0;
    const endMs = ok ? e : 0;
    const iv: OtaAnalyticsInterval = endMs - startMs <= 24 * 3_600_000 ? 'HOUR' : 'DAY';
    const p: OtaAdoptionParams = {
      interval: iv,
      start_date: String(startMs),
      end_date: String(endMs),
      date: String(endMs),
      release_id: releaseId,
    };
    return {
      interval: iv,
      days: Math.max(1, Math.round((endMs - startMs) / DAY_MS)),
      params: p,
      valid: ok,
    };
  }, [startDate, endDate, releaseId]);

  const adoption = useOtaAdoption(app, params, valid);
  const active = useOtaActiveDevices(app, days, valid);
  const performance = useOtaPerformance(app, days, releaseId, valid);
  const versions = useOtaVersions(app, days, valid);
  const failures = useOtaFailures(app, days, releaseId, valid);

  // All core endpoints hit the same analytics host — all-error means the host is
  // down/unconfigured (calm "unavailable" state). Performance is excluded: it's
  // a stub upstream and its tile degrades to 0 on its own. A single endpoint
  // failing must NOT blank the sections that did load.
  const allError = adoption.isError && active.isError && versions.isError && failures.isError;
  const loading =
    valid && (adoption.isLoading || active.isLoading || versions.isLoading || failures.isLoading);

  const buckets = adoption.data?.data?.time_breakdown ?? [];
  const totals = buckets.reduce(
    (acc, b) => ({
      updateChecks: acc.updateChecks + n(b.update_checks),
      downloadSuccess: acc.downloadSuccess + n(b.download_success),
      applySuccess: acc.applySuccess + n(b.apply_success),
      rollbacks: acc.rollbacks + n(b.rollbacks_initiated),
    }),
    { updateChecks: 0, downloadSuccess: 0, applySuccess: 0, rollbacks: 0 },
  );
  const totalDevices = n(active.data?.data?.total_active_devices);
  const checkRate = (totals.updateChecks / (totalDevices || 1)) * 100;
  const avgDownloadMs = n(performance.data?.data?.avg_download_time_ms);

  const tiles: {
    title: string;
    value: string;
    description: string;
    icon: ComponentType<{ className?: string }>;
  }[] = [
    { title: 'Total Devices', value: totalDevices.toLocaleString(), description: 'Total active devices', icon: TrendingUp },
    {
      title: 'Check for Update Rate',
      value: `${checkRate.toFixed(1)}%`,
      description: 'Percentage of devices checking for updates',
      icon: Clock,
    },
    {
      title: 'Average Download Time',
      value: `${avgDownloadMs.toFixed(1)}ms`,
      description: 'Average time taken to download updates',
      icon: Clock,
    },
    { title: 'Downloads', value: totals.downloadSuccess.toLocaleString(), description: 'Successful downloads', icon: Download },
    {
      title: 'Applied Updates',
      value: totals.applySuccess.toLocaleString(),
      description: 'Successfully applied updates',
      icon: CheckCircle,
    },
    { title: 'Rollbacks', value: totals.rollbacks.toLocaleString(), description: 'Total rollbacks', icon: RotateCcw },
  ];

  const versionDist = versions.data?.data?.[0];
  const versionRows = versionDist?.versions ?? [];
  const totalVersionDevices = versionDist?.total_devices;
  const failureData = failures.data?.data;
  const totalFailures = n(failureData?.total_failures);
  const commonErrors = failureData?.common_errors ?? [];

  const hasRollbacks = buckets.some(
    (b) => n(b.rollbacks_initiated) + n(b.rollbacks_completed) + n(b.rollback_failures) > 0,
  );

  return (
    <div className="space-y-6">
      {/* Header */}
      <div>
        <h2 className="text-xl sm:text-2xl font-bold text-zinc-900 dark:text-zinc-100">Analytics Dashboard</h2>
        <p className="text-sm text-zinc-500 dark:text-zinc-400 mt-1">
          View analytics and metrics for your updates and deployments
        </p>
      </div>

      {/* Range selector: presets + custom start/end */}
      <div className="flex items-center gap-2 sm:gap-3 flex-wrap">
        {PRESETS.map((p) => (
          <Button
            key={p.key}
            size="sm"
            variant={activePreset === p.key ? 'primary' : 'secondary'}
            className={activePreset === p.key ? primaryBtnDark : secondaryBtnDark}
            onClick={() => applyPreset(p)}
          >
            {p.label}
          </Button>
        ))}
        <div className="flex items-center gap-2 flex-wrap">
          <span className="text-sm text-zinc-500 dark:text-zinc-400">Custom:</span>
          <DateRangePicker
            start={startDate}
            end={endDate}
            max={today}
            onChange={(s, e) => {
              setStartDate(s);
              setEndDate(e);
            }}
          />
        </div>
      </div>
      <div className="-mt-3 flex items-center gap-2 text-xs text-zinc-500 dark:text-zinc-400 min-w-0">
        {!valid ? (
          <span className="text-red-600 dark:text-red-400">Start date must be on or before the end date.</span>
        ) : (
          <>
            <span>{interval === 'HOUR' ? 'hourly' : 'daily'}</span>
            <span className="text-zinc-300 dark:text-zinc-700">•</span>
            <span className="font-mono truncate max-w-[16rem]" title={releaseId}>
              {releaseId}
            </span>
          </>
        )}
      </div>

      {allError ? (
        <UnavailableCard />
      ) : loading ? (
        <div className="space-y-4">
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3 sm:gap-4">
            {Array.from({ length: 6 }).map((_, i) => (
              <Card key={i} className={cardDark}>
                <CardContent className="py-4">
                  <Skeleton className="h-4 w-28 dark:bg-zinc-800" />
                  <Skeleton className="h-7 w-16 mt-3 dark:bg-zinc-800" />
                  <Skeleton className="h-3 w-32 mt-2 dark:bg-zinc-800" />
                </CardContent>
              </Card>
            ))}
          </div>
          <Card className={cardDark}>
            <CardContent className="p-0">
              <div className="dark:invert">
                <TableSkeleton rows={4} cols={5} />
              </div>
            </CardContent>
          </Card>
        </div>
      ) : (
        <div className="space-y-6">
          {/* 6 metric tiles */}
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3 sm:gap-4">
            {tiles.map((t) => (
              <MetricTile key={t.title} title={t.title} value={t.value} description={t.description} icon={t.icon} />
            ))}
          </div>

          {/* Charts: Adoption Over Time | Update Success Rate */}
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
            <Card className={cardDark}>
              <CardHeader className="dark:border-zinc-800">
                <CardTitle className="dark:text-zinc-100">Update Adoption Over Time</CardTitle>
              </CardHeader>
              <CardContent>
                {buckets.length === 0 ? (
                  chartEmpty
                ) : (
                  <>
                    <GroupedBarChart
                      buckets={buckets}
                      interval={interval}
                      series={[
                        { label: 'Downloads', color: COLORS.downloads, get: (b) => n(b.download_success) },
                        { label: 'Applied', color: COLORS.applied, get: (b) => n(b.apply_success) },
                      ]}
                    />
                    <Legend
                      items={[
                        { label: 'Downloads', color: COLORS.downloads },
                        { label: 'Applied', color: COLORS.applied },
                      ]}
                    />
                  </>
                )}
              </CardContent>
            </Card>

            <Card className={cardDark}>
              <CardHeader className="dark:border-zinc-800">
                <CardTitle className="dark:text-zinc-100">Update Success Rate</CardTitle>
              </CardHeader>
              <CardContent>
                {buckets.length === 0 ? (
                  chartEmpty
                ) : (
                  <RateChart
                    buckets={buckets}
                    interval={interval}
                    value={(b) => {
                      const denom = n(b.download_success) + n(b.download_failures);
                      return denom > 0 ? (n(b.download_success) / denom) * 100 : 0;
                    }}
                  />
                )}
              </CardContent>
            </Card>
          </div>

          {/* Charts: Time to Adoption | Rollback Activity */}
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
            <Card className={cardDark}>
              <CardHeader className="dark:border-zinc-800">
                <CardTitle className="dark:text-zinc-100">Time to Adoption</CardTitle>
              </CardHeader>
              <CardContent>
                {buckets.length === 0 ? (
                  chartEmpty
                ) : (
                  <GroupedBarChart
                    buckets={buckets}
                    interval={interval}
                    fixedMax={100}
                    unit="%"
                    series={[
                      {
                        label: 'Adoption rate',
                        color: COLORS.applied,
                        get: (b) => {
                          const uc = n(b.update_checks);
                          return uc > 0 ? (n(b.apply_success) / uc) * 100 : 0;
                        },
                      },
                    ]}
                  />
                )}
              </CardContent>
            </Card>

            <Card className={cardDark}>
              <CardHeader className="dark:border-zinc-800">
                <CardTitle className="dark:text-zinc-100">Rollback Activity</CardTitle>
              </CardHeader>
              <CardContent>
                {buckets.length === 0 ? (
                  chartEmpty
                ) : !hasRollbacks ? (
                  <div className="py-16 text-center text-zinc-400 dark:text-zinc-500 text-sm">
                    No rollbacks in this window
                  </div>
                ) : (
                  <>
                    <GroupedBarChart
                      buckets={buckets}
                      interval={interval}
                      series={[
                        { label: 'Initiated', color: COLORS.rollbackInit, get: (b) => n(b.rollbacks_initiated) },
                        { label: 'Completed', color: COLORS.rollbackDone, get: (b) => n(b.rollbacks_completed) },
                        { label: 'Failures', color: COLORS.rollbackFail, get: (b) => n(b.rollback_failures) },
                      ]}
                    />
                    <Legend
                      items={[
                        { label: 'Initiated', color: COLORS.rollbackInit },
                        { label: 'Completed', color: COLORS.rollbackDone },
                        { label: 'Failures', color: COLORS.rollbackFail },
                      ]}
                    />
                  </>
                )}
              </CardContent>
            </Card>
          </div>

          {/* Additional SCC insights (beyond airborne's dashboard) */}
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
            <Card className={cardDark}>
              <CardHeader className="dark:border-zinc-800 flex items-center justify-between gap-3">
                <CardTitle className="dark:text-zinc-100">Version distribution</CardTitle>
                {totalVersionDevices != null && (
                  <span className="text-xs text-zinc-500 dark:text-zinc-400 tabular-nums">
                    {totalVersionDevices.toLocaleString()} devices
                  </span>
                )}
              </CardHeader>
              <CardContent>
                {versionRows.length === 0 ? (
                  <div className="py-16 text-center text-zinc-400 dark:text-zinc-500 text-sm">
                    No version data in this window.
                  </div>
                ) : (
                  <div className="space-y-2.5">
                    {versionRows.map((v, i) => (
                      <div key={v.js_version ?? i} className="flex items-center gap-3">
                        <span
                          className="font-mono text-xs text-zinc-700 dark:text-zinc-300 w-24 shrink-0 truncate"
                          title={v.js_version}
                        >
                          {v.js_version || '—'}
                        </span>
                        <div className="flex-1 h-2.5 rounded-full bg-zinc-100 dark:bg-zinc-800 overflow-hidden">
                          <div
                            className="h-full rounded-full bg-airborne"
                            style={{ width: `${Math.max(0, Math.min(100, n(v.percentage)))}%` }}
                          />
                        </div>
                        <span className="text-xs text-zinc-500 dark:text-zinc-400 w-28 shrink-0 text-right tabular-nums">
                          {n(v.device_count).toLocaleString()} ({n(v.percentage).toFixed(1)}%)
                        </span>
                      </div>
                    ))}
                  </div>
                )}
              </CardContent>
            </Card>

            <Card className={cardDark}>
              <CardHeader className="dark:border-zinc-800 flex items-center justify-between gap-3">
                <CardTitle className="dark:text-zinc-100">Update failures</CardTitle>
                <span className="text-xs text-zinc-500 dark:text-zinc-400 tabular-nums">
                  {totalFailures.toLocaleString()} total
                </span>
              </CardHeader>
              <CardContent className="p-0">
                {commonErrors.length === 0 ? (
                  <div className="py-16 text-center text-zinc-400 dark:text-zinc-500 text-sm">
                    No failures reported in this window.
                  </div>
                ) : (
                  <div className="overflow-x-auto">
                    <table className="w-full text-left">
                      <thead>
                        <tr className="bg-zinc-50 border-b border-zinc-200 dark:bg-zinc-800/50 dark:border-zinc-800 text-[11px] text-zinc-500 dark:text-zinc-500 font-medium uppercase tracking-wider">
                          <th className="py-3 px-4">Error code</th>
                          <th className="py-3 px-4">Count</th>
                          <th className="py-3 px-4">Share</th>
                        </tr>
                      </thead>
                      <tbody className="text-sm">
                        {commonErrors.map((e, i) => (
                          <tr key={e.error_code ?? i} className="border-b border-zinc-100 dark:border-zinc-800">
                            <td className="py-3 px-4 font-mono text-xs text-zinc-700 dark:text-zinc-300">
                              {e.error_code || '—'}
                            </td>
                            <td className="py-3 px-4 font-mono text-xs text-zinc-700 dark:text-zinc-300">
                              {n(e.count).toLocaleString()}
                            </td>
                            <td className="py-3 px-4 font-mono text-xs text-zinc-700 dark:text-zinc-300">
                              {n(e.percentage).toFixed(1)}%
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                )}
              </CardContent>
            </Card>
          </div>
        </div>
      )}
    </div>
  );
}
