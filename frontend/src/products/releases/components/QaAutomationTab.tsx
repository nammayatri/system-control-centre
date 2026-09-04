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

interface ApiRow {
  key: string;
  name: string;
  method?: string;
  status?: number;
  error?: string;
  passed: boolean;
  requestBody?: unknown;
  responseBody?: unknown;
  assertions: Array<{ name: string; passed: boolean; error?: string }>;
}

interface SuiteGroup {
  key: string;
  name: string;
  passed: number;
  failed: number;
  apis: ApiRow[];
}

interface DirectoryGroup {
  key: string;
  name: string;
  suites: SuiteGroup[];
}

// Every event carries `directory` (NY/MSIL/YS) and `collection` (the suite
// file's name) — build the same Collection → Suite → API hierarchy the test
// dashboard itself shows, instead of one flat list of every failed line.
function groupEvents(events: QaEvent[]): DirectoryGroup[] {
  const dirs = new Map<string, DirectoryGroup>();
  const apiIndex = new Map<string, ApiRow>(); // `${directory}::${collection}::${name}` -> row

  const getSuite = (directory: string, collection: string): SuiteGroup => {
    let dir = dirs.get(directory);
    if (!dir) {
      dir = { key: directory, name: directory, suites: [] };
      dirs.set(directory, dir);
    }
    let suite = dir.suites.find((s) => s.key === collection);
    if (!suite) {
      suite = { key: collection, name: collection, passed: 0, failed: 0, apis: [] };
      dir.suites.push(suite);
    }
    return suite;
  };

  for (const ev of events) {
    const directory = ev.directory ?? '';
    const collection = ev.collection ?? '';
    if (ev.type === 'request') {
      const suite = getSuite(directory, collection);
      const key = `${directory}::${collection}::${ev.name}`;
      const httpFailed = !!ev.error || (typeof ev.status === 'number' && ev.status >= 400);
      const row: ApiRow = {
        key, name: ev.name, method: ev.method, status: ev.status, error: ev.error,
        passed: !httpFailed, requestBody: ev.requestBody, responseBody: ev.responseBody, assertions: [],
      };
      apiIndex.set(key, row);
      suite.apis.push(row);
    } else if (ev.type === 'assertion') {
      const key = `${directory}::${collection}::${ev.item}`;
      const row = apiIndex.get(key);
      if (row) {
        row.assertions.push({ name: ev.name, passed: ev.passed, error: ev.error ?? undefined });
        if (!ev.passed) row.passed = false;
      }
    } else if (ev.type === 'collection_result') {
      const suite = getSuite(directory, collection);
      suite.passed = ev.passed ?? 0;
      suite.failed = ev.failed ?? 0;
    }
  }

  return Array.from(dirs.values());
}

const ApiRowView: React.FC<{ api: ApiRow }> = ({ api }) => {
  const [expanded, setExpanded] = useState(false);
  return (
    <div className={cn('border rounded-lg text-xs overflow-hidden', api.passed ? 'border-zinc-200' : 'border-red-200 bg-red-50')}>
      <div
        className="flex items-center gap-2 px-2.5 py-1.5 cursor-pointer hover:bg-black/[0.02]"
        onClick={() => setExpanded((s) => !s)}
      >
        <span className={api.passed ? 'text-emerald-600' : 'text-red-600'}>{api.passed ? '✓' : '✗'}</span>
        {api.method && <span className="font-mono font-medium text-zinc-600">{api.method}</span>}
        <span className="font-mono">{api.name}</span>
        {api.status != null && (
          <span className={cn('ml-auto font-mono', api.status >= 400 ? 'text-red-600' : 'text-zinc-500')}>{api.status}</span>
        )}
      </div>
      {expanded && (
        <div className="px-2.5 pb-2.5 space-y-2 border-t border-zinc-100 pt-2">
          {api.error && <div className="text-red-600">{api.error}</div>}
          {api.assertions.length > 0 && (
            <div className="space-y-0.5">
              {api.assertions.map((a, i) => (
                <div key={i} className={a.passed ? 'text-emerald-600' : 'text-red-600'}>
                  {a.passed ? '✓' : '✗'} {a.name}{a.error && ` — ${a.error}`}
                </div>
              ))}
            </div>
          )}
          {api.requestBody != null && api.requestBody !== '' && (
            <div>
              <div className="text-zinc-500 font-medium mb-1">Request body</div>
              <pre className="bg-white border border-zinc-200 rounded p-2 overflow-x-auto whitespace-pre-wrap break-all">
                {typeof api.requestBody === 'string' ? api.requestBody : JSON.stringify(api.requestBody, null, 2)}
              </pre>
            </div>
          )}
          {api.responseBody != null && api.responseBody !== '' && (
            <div>
              <div className="text-zinc-500 font-medium mb-1">Response body</div>
              <pre className="bg-white border border-zinc-200 rounded p-2 overflow-x-auto whitespace-pre-wrap break-all">
                {typeof api.responseBody === 'string' ? api.responseBody : JSON.stringify(api.responseBody, null, 2)}
              </pre>
            </div>
          )}
        </div>
      )}
    </div>
  );
};

const SuiteGroupView: React.FC<{ suite: SuiteGroup }> = ({ suite }) => {
  const [expanded, setExpanded] = useState(false);
  const failed = suite.apis.some((a) => !a.passed);
  return (
    <div className="border border-zinc-200 rounded-lg overflow-hidden">
      <div
        className="flex items-center gap-2 px-3 py-1.5 cursor-pointer hover:bg-zinc-50 bg-zinc-50/50"
        onClick={() => setExpanded((s) => !s)}
      >
        <span className={cn('inline-block transition-transform duration-200 text-[10px] text-zinc-400', expanded ? 'rotate-90' : '')}>&#9654;</span>
        <span className="font-mono text-xs font-semibold text-zinc-700">{suite.name}</span>
        <Badge variant={failed ? 'danger' : 'success'} size="sm" className="ml-auto">
          {suite.passed}✓ {suite.failed}✗
        </Badge>
      </div>
      {expanded && (
        <div className="p-2 space-y-1.5 border-t border-zinc-100">
          {suite.apis.map((api) => <ApiRowView key={api.key} api={api} />)}
        </div>
      )}
    </div>
  );
};

const FailureDetail: React.FC<{ detail: any }> = ({ detail }) => {
  const [showRaw, setShowRaw] = useState(false);
  const events: QaEvent[] = Array.isArray(detail?.events) ? detail.events : [];

  if (events.length === 0) {
    return <p className="text-xs text-zinc-400">No detail cached yet — click Refresh to pull it from the test dashboard.</p>;
  }

  const directories = groupEvents(events);

  return (
    <div className="space-y-3">
      {directories.map((dir) => (
        <div key={dir.key}>
          <h4 className="text-xs font-semibold text-zinc-500 uppercase tracking-wider mb-1.5">{dir.name}</h4>
          <div className="space-y-1.5">
            {dir.suites.map((suite) => <SuiteGroupView key={suite.key} suite={suite} />)}
          </div>
        </div>
      ))}
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
