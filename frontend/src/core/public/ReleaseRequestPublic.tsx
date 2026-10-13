/**
 * Public, READ-ONLY review page for a release-bot request (no VPN, no login).
 *
 * Access is by an unguessable per-request link token (?t=), validated server-side;
 * the API returns only the redacted review view (diffs + flags — never apply
 * payloads). Approving/rejecting happens on the Xyne card, not here, so this page
 * has no write surface at all.
 *
 * Deliberately uses plain fetch, not apiClient: apiClient's 401 handler wipes auth
 * state and redirects to /login, which is wrong for a page that must work logged-out.
 */
import { useCallback, useEffect, useState } from 'react';
import { useParams, useSearchParams } from 'react-router-dom';
import { API_BASE_URL } from '../../lib/constants';

type DiffLine = { t: 'ctx' | 'add' | 'del'; text: string };
type Hunk = { oldStart: number; newStart: number; lines: DiffLine[] };
type FileDiff = { name: string; hunks: Hunk[]; added: number; removed: number };

interface SvcResult {
  service: string;
  oldVersion?: string | null;
  baseCommit?: string | null;
  diffUrl?: string | null;
  dhallHits: string[];
  changedFileCount: number;
  verified: boolean;
  reason?: string | null;
}
interface EnvChange { service: string; envVar: string; state: string; diff?: FileDiff | null; error?: string | null }
interface CmChange { name: string; namespace: string; diffs: FileDiff[] }
interface SvcCoverage {
  service: string;
  deployment?: string | null;
  configMaps: { name: string; status: string }[];
  secrets: string[];
  envVar?: { name: string; state: string } | null;
  error?: string | null;
}
interface Coverage { services: SvcCoverage[]; unmappedDhall: string[]; complete: boolean }
interface Analysis {
  repo: string; env: string; branch?: string | null; commit: string; shortCommit: string;
  services: SvcResult[]; envChanges: EnvChange[]; configMaps: CmChange[];
  secretFiles: string[]; secretUnverifiable: boolean; blockers: string[]; needsApproval: boolean;
  coverage?: Coverage;
}
interface RequestView {
  id: string; state: string; requester?: string | null; repo?: string | null; env?: string | null;
  branch?: string | null; commit?: string | null; expiresAt?: string | null;
  buildResult?: string | null; buildUrl?: string | null; approver?: string | null; analysis?: Analysis | null;
}

const STATE_LABEL: Record<string, string> = {
  AWAITING_APPROVAL: 'Awaiting approval',
  APPROVED: 'Approved — waiting for build',
  BUILDING: 'Building',
  APPLYING: 'Applying',
  APPLYING_CONFIG: 'Applying config',
  COMPLETED: 'Completed',
  REJECTED: 'Rejected',
  EXPIRED: 'Expired',
  FAILED: 'Failed',
  DENIED: 'Denied',
  INFO_ONLY: 'Needs more info',
  RECEIVED: 'Received',
};
const FINAL = new Set(['COMPLETED', 'REJECTED', 'EXPIRED', 'FAILED', 'DENIED', 'INFO_ONLY']);

function DiffBlock({ diff }: { diff: FileDiff }) {
  return (
    <div className="mb-4 overflow-hidden rounded-md border border-zinc-200">
      <div className="flex items-center justify-between bg-zinc-50 px-3 py-2 text-[13px] font-medium text-zinc-800">
        <span className="break-all">{diff.name}</span>
        <span className="ml-3 shrink-0 font-mono text-xs">
          <span className="text-emerald-700">+{diff.added}</span>{' '}
          <span className="text-red-700">−{diff.removed}</span>
        </span>
      </div>
      <div className="overflow-x-auto bg-white font-mono text-[12px] leading-5">
        {diff.hunks.length === 0 && <div className="px-3 py-2 text-zinc-500">No textual changes.</div>}
        {diff.hunks.map((h, hi) => (
          <div key={hi} className="border-t border-zinc-100 first:border-t-0">
            <div className="bg-sky-50 px-3 py-0.5 text-sky-800">
              @@ −{h.oldStart} +{h.newStart} @@
            </div>
            {h.lines.map((l, li) => (
              <div
                key={li}
                className={
                  'whitespace-pre px-3 ' +
                  (l.t === 'add' ? 'bg-emerald-50 text-emerald-900' : l.t === 'del' ? 'bg-red-50 text-red-900' : 'text-zinc-700')
                }
              >
                {(l.t === 'add' ? '+' : l.t === 'del' ? '-' : ' ') + l.text}
              </div>
            ))}
          </div>
        ))}
      </div>
    </div>
  );
}

const COVERAGE_LABEL: Record<string, { text: string; cls: string }> = {
  changed: { text: 'checked — changed', cls: 'text-amber-800' },
  unchanged: { text: 'checked — no change', cls: 'text-emerald-800' },
  not_triggered: { text: 'not affected by this release', cls: 'text-zinc-500' },
  not_tracked: { text: 'NOT checked (no rule covers it)', cls: 'text-red-700 font-medium' },
  ignored: { text: 'ignored (auto-mounted)', cls: 'text-zinc-400' },
};

function CoveragePanel({ cv }: { cv: Coverage }) {
  return (
    <div className="mb-4 rounded-md border border-zinc-200">
      <div className={`px-3 py-2 text-[13px] font-medium ${cv.complete ? 'bg-emerald-50 text-emerald-900' : 'bg-amber-50 text-amber-900'}`}>
        {cv.complete
          ? 'Coverage complete — every configmap the deployment references was checked.'
          : 'Coverage INCOMPLETE — review the items marked NOT checked before approving.'}
      </div>
      {cv.services.map((s) => (
        <div key={s.service} className="border-t border-zinc-100 px-3 py-2 text-[13px]">
          <div className="font-medium text-zinc-900">
            {s.service} {s.deployment && <span className="font-mono text-xs text-zinc-500">({s.deployment})</span>}
          </div>
          {s.error && <div className="text-red-700">Could not read the deployment: {s.error}</div>}
          {s.envVar && <div className="text-zinc-700">env <span className="font-mono">{s.envVar.name}</span>: {s.envVar.state.replace('_', ' ')}</div>}
          {s.configMaps.filter((c) => c.status !== 'ignored').map((c) => {
            const l = COVERAGE_LABEL[c.status] || { text: c.status, cls: '' };
            return <div key={c.name} className="text-zinc-700">configmap <span className="font-mono">{c.name}</span>: <span className={l.cls}>{l.text}</span></div>;
          })}
          {s.secrets.length > 0 && <div className="text-zinc-500">secrets referenced (values never read): <span className="font-mono">{s.secrets.join(', ')}</span></div>}
        </div>
      ))}
      {cv.unmappedDhall.length > 0 && (
        <div className="border-t border-zinc-100 px-3 py-2 text-[13px] text-red-700">dhall changed but no rule watches it: <span className="font-mono">{cv.unmappedDhall.join(', ')}</span></div>
      )}
    </div>
  );
}

function Flag({ tone, children }: { tone: 'warn' | 'bad' | 'ok'; children: React.ReactNode }) {
  const cls =
    tone === 'bad' ? 'border-red-200 bg-red-50 text-red-900'
    : tone === 'warn' ? 'border-amber-200 bg-amber-50 text-amber-900'
    : 'border-emerald-200 bg-emerald-50 text-emerald-900';
  return <div className={`mb-2 rounded-md border px-3 py-2 text-[13px] ${cls}`}>{children}</div>;
}

export default function ReleaseRequestPublic() {
  const { id } = useParams<{ id: string }>();
  const [params] = useSearchParams();
  const token = params.get('t') || '';
  const [data, setData] = useState<RequestView | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    if (!id || !token) {
      setError('This link is incomplete.');
      setLoading(false);
      return;
    }
    try {
      const res = await fetch(`${API_BASE_URL}/public/release-requests/${encodeURIComponent(id)}?t=${encodeURIComponent(token)}`, {
        headers: { Accept: 'application/json' },
        cache: 'no-store',
        credentials: 'omit',
      });
      if (!res.ok) {
        setError(res.status === 404 ? 'This link is invalid or no longer available.' : `Could not load (HTTP ${res.status}).`);
        setData(null);
      } else {
        setData(await res.json());
        setError(null);
      }
    } catch {
      setError('Could not reach the server.');
    } finally {
      setLoading(false);
    }
  }, [id, token]);

  useEffect(() => { load(); }, [load]);
  useEffect(() => {
    if (!data || FINAL.has(data.state)) return;
    const t = setInterval(load, 30000);
    return () => clearInterval(t);
  }, [data, load]);

  // Keep the review page out of search indexes / link previews.
  useEffect(() => {
    const m = document.createElement('meta');
    m.name = 'robots';
    m.content = 'noindex,nofollow';
    document.head.appendChild(m);
    return () => { document.head.removeChild(m); };
  }, []);

  if (loading) return <div className="p-8 text-sm text-zinc-500">Loading…</div>;
  if (error || !data) return <div className="mx-auto max-w-xl p-8 text-sm text-zinc-700">{error || 'Not found.'}</div>;

  const a = data.analysis;
  const stateLabel = STATE_LABEL[data.state] || data.state;
  const changedEnv = (a?.envChanges || []).filter((e) => e.state === 'changed' && e.diff);
  const envProblems = (a?.envChanges || []).filter((e) => !['changed', 'unchanged', 'not_triggered'].includes(e.state));

  return (
    <div className="mx-auto max-w-5xl px-4 py-6 sm:px-6">
      <div className="mb-1 text-xs uppercase tracking-wide text-zinc-500">System Control Centre · release review (read-only)</div>
      <h1 className="mb-1 text-xl font-semibold text-zinc-900">
        {data.repo}{data.branch ? ` / ${data.branch}` : ''} @ <span className="font-mono">{(data.commit || '').slice(0, 7)}</span>
        {data.env ? <span className="ml-2 rounded bg-zinc-100 px-2 py-0.5 text-xs font-medium text-zinc-700">{data.env}</span> : null}
      </h1>
      <div className="mb-4 flex flex-wrap items-center gap-x-4 gap-y-1 text-[13px] text-zinc-600">
        <span><b className="text-zinc-800">{stateLabel}</b></span>
        {data.requester && <span>requested by {data.requester}</span>}
        {data.approver && <span>decided by {data.approver}</span>}
        {data.expiresAt && !FINAL.has(data.state) && <span>expires {new Date(data.expiresAt).toLocaleString()}</span>}
        {data.buildResult && (
          <span>
            build:{' '}
            {data.buildUrl ? <a className="text-sky-700 underline" href={data.buildUrl} target="_blank" rel="noopener noreferrer">{data.buildResult}</a> : data.buildResult}
          </span>
        )}
        <button onClick={load} className="ml-auto rounded border border-zinc-300 px-2 py-0.5 text-xs hover:bg-zinc-50">Refresh</button>
      </div>

      {data.state === 'AWAITING_APPROVAL' && (
        <Flag tone="warn">This page is read-only. Approve or reject on the Xyne card — approving applies exactly the changes shown below.</Flag>
      )}

      {a && (
        <>
          {a.secretFiles.length > 0 && (
            <Flag tone="bad">
              <b>Secret file changed</b> — update the secret before rollout: <span className="font-mono">{a.secretFiles.join(', ')}</span>
            </Flag>
          )}
          {a.secretUnverifiable && <Flag tone="warn">Could not fully verify whether secret files changed (the commit diff was incomplete).</Flag>}
          {a.blockers.map((b, i) => <Flag key={i} tone="bad">Cannot auto-apply: {b}</Flag>)}
          {envProblems.map((e, i) => (
            <Flag key={i} tone="bad">{e.service} · {e.envVar}: {e.state}{e.error ? ` — ${e.error}` : ''}</Flag>
          ))}
          {!a.needsApproval && a.blockers.length === 0 && <Flag tone="ok">No ConfigMap or env changes — nothing to review beyond the code diff.</Flag>}

          {a.coverage && (
            <>
              <h2 className="mb-2 mt-5 text-sm font-semibold text-zinc-900">Coverage</h2>
              <CoveragePanel cv={a.coverage} />
            </>
          )}

          <h2 className="mb-2 mt-5 text-sm font-semibold text-zinc-900">Services</h2>
          <div className="mb-4 overflow-x-auto rounded-md border border-zinc-200">
            <table className="w-full text-left text-[13px]">
              <thead className="bg-zinc-50 text-zinc-600">
                <tr><th className="px-3 py-2">Service</th><th className="px-3 py-2">Deployed</th><th className="px-3 py-2">→ New</th><th className="px-3 py-2">Changed files</th><th className="px-3 py-2">dhall</th></tr>
              </thead>
              <tbody>
                {a.services.map((s) => (
                  <tr key={s.service} className="border-t border-zinc-100">
                    <td className="px-3 py-2 font-medium text-zinc-900">{s.service}</td>
                    <td className="px-3 py-2 font-mono">{s.baseCommit || s.oldVersion || '—'}</td>
                    <td className="px-3 py-2 font-mono">{a.shortCommit}</td>
                    <td className="px-3 py-2">
                      {s.verified ? s.changedFileCount : <span className="text-red-700">unverified</span>}
                      {s.diffUrl && <> · <a className="text-sky-700 underline" href={s.diffUrl} target="_blank" rel="noopener noreferrer">GitHub diff</a></>}
                    </td>
                    <td className="px-3 py-2">{s.dhallHits.length ? <span className="text-amber-800">{s.dhallHits.join(', ')}</span> : '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          {a.configMaps.length > 0 && (
            <>
              <h2 className="mb-2 mt-5 text-sm font-semibold text-zinc-900">ConfigMap changes</h2>
              {a.configMaps.map((c) => (
                <div key={c.name} className="mb-3">
                  <div className="mb-1 text-[13px] text-zinc-600">
                    <span className="font-mono">{c.name}</span> <span className="text-zinc-400">({c.namespace})</span>
                  </div>
                  {c.diffs.map((d) => <DiffBlock key={d.name} diff={d} />)}
                </div>
              ))}
            </>
          )}

          {changedEnv.length > 0 && (
            <>
              <h2 className="mb-2 mt-5 text-sm font-semibold text-zinc-900">Deployment env changes (base64-decoded)</h2>
              {changedEnv.map((e) => <DiffBlock key={e.service + e.envVar} diff={e.diff as FileDiff} />)}
            </>
          )}
        </>
      )}
    </div>
  );
}
