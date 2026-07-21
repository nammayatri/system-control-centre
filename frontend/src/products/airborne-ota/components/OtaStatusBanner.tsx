import { AlertCircle, AlertTriangle } from 'lucide-react';
import { useOtaHealth } from '../hooks';
import { cn, timeAgo } from '../../../lib/utils';

const barBase = 'w-full px-4 py-2 text-xs sm:text-sm flex items-center gap-2';
const dangerCls =
  'bg-red-50 text-red-800 border-b border-red-200 dark:bg-red-950/40 dark:text-red-300 dark:border-red-900';
const warningCls =
  'bg-amber-50 text-amber-800 border-b border-amber-200 dark:bg-amber-950/40 dark:text-amber-300 dark:border-amber-900';

function Bar({ tone, children }: { tone: 'danger' | 'warning'; children: React.ReactNode }) {
  const Icon = tone === 'danger' ? AlertTriangle : AlertCircle;
  return (
    <div
      role={tone === 'danger' ? 'alert' : 'status'}
      className={cn(barBase, tone === 'danger' ? dangerCls : warningCls)}
    >
      <Icon className="w-4 h-4 shrink-0" />
      <span>{children}</span>
    </div>
  );
}

// Full-width upstream-health strip for the registry Banner slot. Renders at
// most one bar, most-severe first. The health endpoint never throws upstream,
// so `status` names the cause rather than collapsing everything to "down".
export function OtaStatusBanner() {
  const health = useOtaHealth();

  // Don't flash a banner on first paint.
  if (health.isLoading) return null;

  // The health call itself failed (SCC-side/network) — we know nothing.
  if (health.isError) {
    return <Bar tone="danger">Airborne status can't be loaded right now.</Bar>;
  }

  const status = health.data?.status;
  const keepalive = health.data?.keepalive;
  const keepaliveFailed = keepalive?.state === 'failed';

  // Setup state, not an outage — previously this showed as "unreachable".
  if (status === 'not-configured') {
    return (
      <Bar tone="warning">
        Airborne isn't configured in this environment — the service-account credentials
        (SC_AIRBORNE_PAT_*) aren't set, so releases and config can't load.
      </Bar>
    );
  }

  if (status === 'down') {
    return (
      <Bar tone="danger">
        Airborne is unreachable — releases, config and analytics can't be loaded right now.
      </Bar>
    );
  }

  // The host answers but the authenticated path is broken. Airborne's own
  // health check is a static 200, so this is what a real outage looks like.
  if (status === 'degraded') {
    return (
      <Bar tone="danger">
        Airborne is reachable but the authenticated connection is failing — releases and config
        won't load.
        {keepaliveFailed ? ' The service-account credential is failing to renew; re-enrol the PAT.' : ''}
      </Bar>
    );
  }

  // Everything works today, but the daily re-issue is failing: the credential
  // will stop working. This is the only warning before a full-product 401.
  if (keepaliveFailed) {
    return (
      <Bar tone="warning">
        Airborne service-account credential is failing to renew (last attempt{' '}
        {timeAgo(keepalive?.at)}). Releases still work for now, but the connection will drop —
        re-enrol the PAT.
      </Bar>
    );
  }

  // Analytics is a separate host: configured=false is not an alarm, only a
  // configured-but-down probe is a soft warning.
  const analytics = health.data?.analytics;
  if (analytics?.configured && analytics.ok === false) {
    return (
      <Bar tone="warning">
        Airborne analytics is unavailable — the Analytics tab won't load. Everything else works.
      </Bar>
    );
  }

  return null;
}
