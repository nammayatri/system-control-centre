import { useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { AlertTriangle, Info } from 'lucide-react';
import { toast } from 'sonner';
import { Button } from '../../../shared/ui/button';
import { Card, CardContent } from '../../../shared/ui/card';
import { Input, SelectInput } from '../../../shared/ui/input';
import { devboxError } from '../api';
import { BranchField } from '../components/BranchField';
import { useBranchStatus, useCreateDevboxRelease, useDevboxReleases } from '../hooks';
import { APP_BUILDS, type DataSource, type DevboxRelease } from '../types';

// 'feat/fare-fix' → 'fare-fix' (same rule as the server's nameFromBranch).
function nameFromBranch(b: string): string {
  const last = b.split('/').pop() ?? '';
  return last.replace(/[^A-Za-z0-9_-]/g, '-').replace(/^-+|-+$/g, '').slice(0, 40);
}

function useDebounced<T>(value: T, ms = 400): T {
  const [v, setV] = useState(value);
  useEffect(() => {
    const t = setTimeout(() => setV(value), ms);
    return () => clearTimeout(t);
  }, [value, ms]);
  return v;
}

const DATA_OPTIONS = [
  { value: 'master', label: 'master' },
  { value: 'prod', label: 'prod' },
  { value: 'prod_international', label: 'prod_international' },
];

export default function DevboxNewRelease() {
  const navigate = useNavigate();
  const create = useCreateDevboxRelease();
  const [backendBranch, setBackendBranch] = useState('');
  const [ccBranch, setCcBranch] = useState('main');
  const [frontendBranch, setFrontendBranch] = useState('');
  const [appBuilds, setAppBuilds] = useState<string[]>([]);
  const [dataSource, setDataSource] = useState<DataSource>('master');
  const [dataVersion, setDataVersion] = useState('');
  const [workspace, setWorkspace] = useState('');
  const [nameTouched, setNameTouched] = useState(false);
  const [blocked, setBlocked] = useState<{ message: string; release?: DevboxRelease } | null>(null);

  // The caller's active count and the limit come with the list.
  const limits = useDevboxReleases('all', '', 1, 1);
  const mineActive = limits.data?.mineActive ?? 0;
  const maxActive = limits.data?.maxActive ?? 2;
  const full = mineActive >= maxActive;

  const debouncedBranch = useDebounced(backendBranch.trim());
  const branchStatus = useBranchStatus(debouncedBranch);
  const running = branchStatus.data?.active ?? null;

  // The name follows the branch until the person edits it.
  useEffect(() => {
    if (!nameTouched) setWorkspace(nameFromBranch(backendBranch.trim()));
  }, [backendBranch, nameTouched]);

  const hasApp = frontendBranch.trim().length > 0;
  useEffect(() => {
    if (!hasApp) setAppBuilds([]);
  }, [hasApp]);
  const toggleBuild = (key: string, on: boolean) =>
    setAppBuilds((cur) => (on ? [...cur.filter((k) => k !== key), key] : cur.filter((k) => k !== key)));

  const nameError = useMemo(() => {
    if (!workspace) return undefined;
    if (!/^[A-Za-z0-9_-]{1,40}$/.test(workspace)) return 'Use 1-40 letters, digits, - or _';
    return undefined;
  }, [workspace]);
  const versionError = dataVersion && !/^v\d+$/.test(dataVersion.trim()) ? 'Looks like v14' : undefined;
  const canSubmit = backendBranch.trim() && workspace && !nameError && !versionError && !running && !full && !create.isPending;

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setBlocked(null);
    try {
      const res = await create.mutateAsync({
        backendBranch: backendBranch.trim(),
        ccBranch: ccBranch.trim() || undefined,
        frontendBranch: frontendBranch.trim() || undefined,
        buildAndroid: false,
        buildIos: false,
        appBuilds,
        dataSource,
        dataVersion: dataVersion.trim() || undefined,
        workspace,
      });
      toast.success(`Release ${res.release.workspace} created · GitHub run started`);
      navigate(`/devbox/releases/${res.release.id}`);
    } catch (err) {
      const e = devboxError(err);
      setBlocked({ message: e.message, release: e.release });
      toast.error(e.message);
    }
  };

  return (
    <form onSubmit={submit} className="space-y-4">
      <div>
        <h1 className="text-xl font-bold tracking-tight text-zinc-900 dark:text-zinc-100">New devbox release</h1>
        <p className="text-sm text-zinc-500">
          Pick the branches to test together. Each branch is pinned to its latest commit when you create the release.
        </p>
      </div>

      {running && (
        <Banner tone="warn">
          <b className="font-mono">{running.backendBranch}</b> is already running as{' '}
          <span className="font-mono">{running.workspace}</span> ({running.createdBy}). Stop it before starting a new one.{' '}
          <button type="button" className="font-semibold underline" onClick={() => navigate(`/devbox/releases/${running.id}`)}>
            Open {running.workspace}
          </button>
        </Banner>
      )}
      {full && (
        <Banner tone="bad">
          You already have {mineActive} active releases (the limit is {maxActive}). Stop one of them first.{' '}
          <button type="button" className="font-semibold underline" onClick={() => navigate('/devbox/releases')}>
            See releases
          </button>
        </Banner>
      )}
      {blocked && !running && (
        <Banner tone="bad">
          {blocked.message}{' '}
          {blocked.release && (
            <button type="button" className="font-semibold underline" onClick={() => navigate(`/devbox/releases/${blocked.release!.id}`)}>
              Open {blocked.release.workspace}
            </button>
          )}
        </Banner>
      )}

      <div className="grid items-start gap-5 xl:grid-cols-[minmax(0,1fr)_360px]">
      <div className="min-w-0 space-y-4">
      <Card>
        <CardContent className="grid gap-4 p-5 sm:grid-cols-2">
          <BranchField
            id="devbox-backend"
            label="Backend branch (nammayatri)"
            repo="backend"
            value={backendBranch}
            onChange={setBackendBranch}
            placeholder="feat/fare-fix"
            required
            emptyHint="Pinned to its latest commit on create"
          />
          <BranchField
            id="devbox-cc"
            label="Control-centre branch"
            repo="cc"
            value={ccBranch}
            onChange={setCcBranch}
            placeholder="main"
            emptyHint="Leave empty for no control centre"
          />
          <div className="space-y-2">
            <BranchField
              id="devbox-frontend"
              label="App branch (ny-react-native)"
              repo="app"
              value={frontendBranch}
              onChange={setFrontendBranch}
              placeholder="optional"
              emptyHint="Optional: adds rider / driver app builds"
            />
            <div className="grid grid-cols-2 gap-x-4 gap-y-1.5 text-sm">
              {APP_BUILDS.map((b) => (
                <label key={b.key} className={`flex items-center gap-2 ${hasApp ? '' : 'text-zinc-400'}`}>
                  <input
                    id={`devbox-build-${b.key.replace(':', '-')}`}
                    type="checkbox"
                    checked={appBuilds.includes(b.key)}
                    disabled={!hasApp}
                    onChange={(e) => toggleBuild(b.key, e.target.checked)}
                  />
                  {b.label} <span className="text-xs text-zinc-400">({b.where})</span>
                </label>
              ))}
            </div>
            <p className="text-xs text-zinc-500">Built after the backend is ready, pointed at it. Phones need the office network to reach it.</p>
          </div>
          <div className="grid grid-cols-2 gap-3">
            <SelectInput
              id="devbox-data"
              label="Data"
              value={dataSource}
              onChange={(e) => setDataSource(e.target.value as DataSource)}
              options={DATA_OPTIONS}
            />
            <Input
              id="devbox-version"
              label="Version"
              value={dataVersion}
              onChange={(e) => setDataVersion(e.target.value)}
              placeholder="latest safe"
              error={versionError}
            />
          </div>
          <div className="sm:col-span-2">
            <Input
              id="devbox-name"
              label="Workspace name"
              value={workspace}
              onChange={(e) => {
                setNameTouched(true);
                setWorkspace(e.target.value);
              }}
              error={nameError}
              hint={nameError ? undefined : `Made from the backend branch; you can change it. Becomes the URL path :8888/${workspace || '…'}`}
            />
          </div>
        </CardContent>
      </Card>

      <div className="flex gap-2">
        <Button type="submit" disabled={!canSubmit} loading={create.isPending}>
          Create release
        </Button>
        <Button variant="outline" onClick={() => navigate('/devbox/releases')}>
          Cancel
        </Button>
      </div>
      </div>

      <Summary
        backendBranch={backendBranch.trim()}
        ccBranch={ccBranch.trim()}
        frontendBranch={frontendBranch.trim()}
        builds={APP_BUILDS.filter((b) => appBuilds.includes(b.key)).map((b) => b.label).join(', ')}
        data={`${dataSource} ${dataVersion.trim() || '(latest safe)'}`}
        workspace={workspace}
        mineAfter={mineActive + 1}
        maxActive={maxActive}
      />
      </div>
    </form>
  );
}

const AFTER_CREATE = [
  ['Preparing', 'pick the least-loaded dev-box with a front desk, register the workspace'],
  ['Sync', 'copy the pinned code to the dev-box'],
  ['Build', 'restore the build cache, compile what changed'],
  ['Start', 'start the services until rider and driver answer'],
  ['Data', 'load the chosen data'],
  ['Control centre', 'start it next to the backend'],
  ['Ready', 'links appear on the release page'],
];

// Right-hand panel: what this release will be, filled in as the form changes.
function Summary(p: {
  backendBranch: string;
  ccBranch: string;
  frontendBranch: string;
  builds: string;
  data: string;
  workspace: string;
  mineAfter: number;
  maxActive: number;
}) {
  const stopOn = new Date(Date.now() + 3 * 24 * 3600 * 1000).toLocaleDateString(undefined, { weekday: 'short', day: 'numeric', month: 'short' });
  const row = (k: string, v: React.ReactNode) => (
    <>
      <dt className="text-zinc-500">{k}</dt>
      <dd className="min-w-0 break-all font-mono text-xs text-zinc-800 dark:text-zinc-200">{v}</dd>
    </>
  );
  return (
    <aside className="space-y-4 xl:sticky xl:top-4">
      <Card>
        <CardContent className="space-y-3 p-5">
          <h2 className="text-[11px] font-medium uppercase tracking-wider text-zinc-500">This release</h2>
          <dl className="grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-2 text-sm">
            {row('Backend', p.backendBranch || <span className="text-zinc-400">pick a branch</span>)}
            {row('Control centre', p.ccBranch || '—')}
            {row('App', p.frontendBranch ? `${p.frontendBranch}${p.builds ? ` · ${p.builds}` : ' · no builds'}` : '—')}
            {row('Data', p.data)}
            {row('URL', `http://<dev-box>:8888/${p.workspace || '…'}`)}
            {row('Auto-stop', `${stopOn} (3 days)`)}
          </dl>
          <p className="border-t border-zinc-100 pt-3 text-sm text-zinc-600 dark:border-zinc-800 dark:text-zinc-400">
            Your active releases after this: <b className="text-zinc-900 dark:text-zinc-100">{Math.min(p.mineAfter, p.maxActive)} of {p.maxActive}</b>
          </p>
        </CardContent>
      </Card>
      <Card>
        <CardContent className="space-y-2 p-5">
          <h2 className="text-[11px] font-medium uppercase tracking-wider text-zinc-500">After you create</h2>
          <ol className="space-y-2">
            {AFTER_CREATE.map(([stage, what], i) => (
              <li key={stage} className="grid grid-cols-[22px_minmax(0,1fr)] gap-2 text-sm">
                <span className="grid h-5 w-5 place-items-center rounded-full bg-zinc-100 text-[11px] font-semibold text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">{i + 1}</span>
                <span>
                  <b className="font-semibold text-zinc-800 dark:text-zinc-200">{stage}</b>
                  <span className="text-zinc-500"> · {what}</span>
                </span>
              </li>
            ))}
          </ol>
          <p className="pt-1 text-xs text-zinc-500">Each step is a GitHub Actions step; the release page follows them live. About 10 minutes with a warm build cache.</p>
        </CardContent>
      </Card>
    </aside>
  );
}

function Banner({ tone, children }: { tone: 'warn' | 'bad' | 'info'; children: React.ReactNode }) {
  const Icon = tone === 'info' ? Info : AlertTriangle;
  return (
    <div
      className={
        tone === 'warn'
          ? 'flex gap-2 rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-200'
          : tone === 'bad'
            ? 'flex gap-2 rounded-lg border border-red-300 bg-red-50 p-3 text-sm text-red-900 dark:border-red-800 dark:bg-red-950 dark:text-red-200'
            : 'flex gap-2 rounded-lg border border-blue-200 bg-blue-50 p-3 text-sm text-blue-900 dark:border-blue-900 dark:bg-blue-950 dark:text-blue-200'
      }
    >
      <Icon className="mt-0.5 h-4 w-4 shrink-0" />
      <div>{children}</div>
    </div>
  );
}
