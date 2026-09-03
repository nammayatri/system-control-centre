import React, { useState } from 'react';
import { Badge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { useConfirm } from '../../../shared/ui/confirm-dialog';
import { cn } from '../../../lib/utils';
import { useQaRuns, useTriggerQaRun, useRefreshQaRun } from '../hooks';
import type { QaAutomationRun } from '../api';

// ny-qa-automation regression runs (NY/MSIL/YS) triggered against a test
// dashboard, either automatically on COMPLETED or via the button here.
// Live progress streams on the dashboard itself (the stored deep link);
// this tab is the results record — status, pass/fail, and (once refreshed)
// the dashboard's own per-request failure detail.

const formatDate = (d?: string) => {
  if (!d) return '-';
  const date = new Date(d);
  if (isNaN(date.getTime())) return '-';
  return (
    date.toLocaleString('en-IN', {
      timeZone: 'Asia/Kolkata',
      month: 'short',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      hour12: true,
    }) + ' IST'
  );
};

const statusVariant = (status: string): 'info' | 'success' | 'danger' | 'warning' | 'default' => {
  switch (status) {
    case 'RUNNING':
      return 'info';
    case 'PASSED':
      return 'success';
    case 'FAILED':
    case 'ERROR':
      return 'danger';
    case 'STOPPED':
      return 'warning';
    default:
      return 'default';
  }
};

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type QaEvent = { type: string; [key: string]: any };

const isFailureEvent = (ev: QaEvent): boolean =>
  (ev.type === 'request' && (ev.error || (typeof ev.status === 'number' && ev.status >= 400))) ||
  (ev.type === 'assertion' && ev.passed === false);

const FailureDetail: React.FC<{ detail: any }> = ({ detail }) => {
  const [showRaw, setShowRaw] = useState(false);
  const events: QaEvent[] = Array.isArray(detail?.events) ? detail.events : [];
  const failures = events.filter(isFailureEvent);

  if (events.length === 0) {
    return <p className="text-xs text-zinc-400">No detail cached yet — click Refresh to pull it from the test dashboard.</p>;
  }

  return (
    <div className="space-y-2">
      {failures.length === 0 ? (
        <p className="text-xs text-emerald-600">No failures.</p>
      ) : (
        failures.map((ev, i) => (
          <div key={i} className="border border-red-200 bg-red-50 rounded-lg p-3 text-xs">
            <div className="font-mono font-semibold text-red-700">
              {ev.type === 'assertion' ? `✗ ${ev.name}` : `✗ ${ev.method ?? ''} ${ev.name}${ev.status ? ` — HTTP ${ev.status}` : ''}`}
            </div>
            {ev.error && <div className="mt-1 text-red-600">{ev.error}</div>}
            {ev.url && <div className="mt-1 text-zinc-500 break-all">{ev.url}</div>}
            {ev.requestBody && (
              <>
                <div className="mt-2 text-zinc-500 font-medium">Request body</div>
                <pre className="mt-1 bg-white border border-zinc-200 rounded p-2 overflow-x-auto whitespace-pre-wrap break-all">{ev.requestBody}</pre>
              </>
            )}
            {ev.responseBody && (
              <>
                <div className="mt-2 text-zinc-500 font-medium">Response body</div>
                <pre className="mt-1 bg-white border border-zinc-200 rounded p-2 overflow-x-auto whitespace-pre-wrap break-all">{ev.responseBody}</pre>
              </>
            )}
          </div>
        ))
      )}
      <button className="text-[11px] text-violet-600 hover:underline" onClick={() => setShowRaw((s) => !s)}>
        {showRaw ? 'Hide raw event log' : `Show raw event log (${events.length} events)`}
      </button>
      {showRaw && (
        <pre className="text-[11px] font-mono bg-zinc-50 text-zinc-800 border border-zinc-200 p-3 rounded-lg overflow-x-auto max-h-72 whitespace-pre-wrap break-all">
          {JSON.stringify(events, null, 2)}
        </pre>
      )}
    </div>
  );
};

const RunRow: React.FC<{ run: QaAutomationRun; releaseId: string }> = ({ run, releaseId }) => {
  const [expanded, setExpanded] = useState(false);
  const refresh = useRefreshQaRun(releaseId);

  return (
    <div className="border border-zinc-200 rounded-lg overflow-hidden">
      <div
        className="flex flex-wrap items-center gap-3 px-3 py-2 cursor-pointer hover:bg-zinc-50 transition-colors"
        onClick={() => setExpanded((s) => !s)}
      >
        <span className={cn('inline-block transition-transform duration-200 text-xs text-zinc-400', expanded ? 'rotate-90' : '')}>&#9654;</span>
        <Badge variant={statusVariant(run.status)} size="sm">{run.status}</Badge>
        <Badge variant={run.triggerSource === 'AUTO' ? 'purple' : 'blue'} size="sm">{run.triggerSource}</Badge>
        {run.releaseVersion && <span className="font-mono text-xs text-zinc-500">{run.releaseVersion}</span>}
        <span className="text-xs text-zinc-500">{(run.passed ?? 0)}✓ {(run.failed ?? 0)}✗</span>
        <span className="text-xs text-zinc-400 ml-auto">{formatDate(run.createdAt)}</span>
        {run.testDashboardUrl && (
          <a
            href={run.testDashboardUrl}
            target="_blank"
            rel="noopener"
            onClick={(e) => e.stopPropagation()}
            className="text-xs font-semibold text-violet-600 hover:underline"
          >
            Open in Test Dashboard ↗
          </a>
        )}
        <Button
          size="sm"
          variant="outline"
          loading={refresh.isPending}
          onClick={(e) => { e.stopPropagation(); refresh.mutate(run.runId); }}
        >
          Refresh
        </Button>
      </div>
      {expanded && (
        <div className="px-3 py-3 border-t border-zinc-100 bg-zinc-50">
          <FailureDetail detail={run.detail} />
        </div>
      )}
    </div>
  );
};

export const QaAutomationTab: React.FC<{ releaseId: string; appGroup?: string }> = ({ releaseId }) => {
  const { data: runs, isLoading } = useQaRuns(releaseId);
  const trigger = useTriggerQaRun();
  const confirmAction = useConfirm();

  const handleTrigger = async () => {
    const ok = await confirmAction({
      title: 'Trigger QA Automation',
      description: 'Run the configured NY/MSIL/YS QA suites against this app group\'s test dashboard, tagged to this release\'s version?',
      confirmLabel: 'Trigger',
      variant: 'primary',
    });
    if (!ok) return;
    try {
      const result = await trigger.mutateAsync(releaseId);
      if (result.testDashboardUrl) window.open(result.testDashboardUrl, '_blank', 'noopener');
    } catch {
      // trigger's own onError toast already reported it
    }
  };

  return (
    <div className="p-4 sm:p-6">
      <div className="flex items-center justify-between mb-4">
        <h3 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider">QA Automation</h3>
        <Button size="sm" loading={trigger.isPending} onClick={handleTrigger}>
          Trigger QA Run
        </Button>
      </div>
      {isLoading ? (
        <p className="text-sm text-zinc-400">Loading…</p>
      ) : !runs || runs.length === 0 ? (
        <p className="text-sm text-zinc-400">
          No QA runs yet for this release. Trigger one above, or it fires automatically on completion if configured for this app group.
        </p>
      ) : (
        <div className="space-y-2">
          {runs.map((run) => (
            <RunRow key={run.runId} run={run} releaseId={releaseId} />
          ))}
        </div>
      )}
    </div>
  );
};
