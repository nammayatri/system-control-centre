import { useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { AlertTriangle, Info } from 'lucide-react';
import { toast } from 'sonner';
import { Button } from '../../../shared/ui/button';
import { Card, CardContent } from '../../../shared/ui/card';
import { Input, SelectInput } from '../../../shared/ui/input';
import { devboxError } from '../api';
import { useBranchStatus, useCreateDevboxRelease } from '../hooks';
import type { DataSource, DevboxRelease } from '../types';

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
  const [buildAndroid, setBuildAndroid] = useState(false);
  const [buildIos, setBuildIos] = useState(false);
  const [dataSource, setDataSource] = useState<DataSource>('master');
  const [dataVersion, setDataVersion] = useState('');
  const [workspace, setWorkspace] = useState('');
  const [nameTouched, setNameTouched] = useState(false);
  const [blocked, setBlocked] = useState<{ message: string; release?: DevboxRelease } | null>(null);

  const debouncedBranch = useDebounced(backendBranch.trim());
  const branchStatus = useBranchStatus(debouncedBranch);
  const running = branchStatus.data?.active ?? null;

  // The name follows the branch until the person edits it.
  useEffect(() => {
    if (!nameTouched) setWorkspace(nameFromBranch(backendBranch.trim()));
  }, [backendBranch, nameTouched]);

  const hasApp = frontendBranch.trim().length > 0;
  useEffect(() => {
    if (!hasApp) {
      setBuildAndroid(false);
      setBuildIos(false);
    }
  }, [hasApp]);

  const nameError = useMemo(() => {
    if (!workspace) return undefined;
    if (!/^[A-Za-z0-9_-]{1,40}$/.test(workspace)) return 'Use 1-40 letters, digits, - or _';
    return undefined;
  }, [workspace]);
  const versionError = dataVersion && !/^v\d+$/.test(dataVersion.trim()) ? 'Looks like v14' : undefined;
  const canSubmit = backendBranch.trim() && workspace && !nameError && !versionError && !running && !create.isPending;

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setBlocked(null);
    try {
      const res = await create.mutateAsync({
        backendBranch: backendBranch.trim(),
        ccBranch: ccBranch.trim() || undefined,
        frontendBranch: frontendBranch.trim() || undefined,
        buildAndroid,
        buildIos,
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
    <form onSubmit={submit} className="max-w-3xl space-y-4">
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

      <Card>
        <CardContent className="grid gap-4 p-5 sm:grid-cols-2">
          <Input
            id="devbox-backend"
            label="Backend branch (nammayatri)"
            value={backendBranch}
            onChange={(e) => setBackendBranch(e.target.value)}
            placeholder="feat/fare-fix"
            required
            hint="Pinned to its latest commit on create"
          />
          <Input
            id="devbox-cc"
            label="Control-centre branch"
            value={ccBranch}
            onChange={(e) => setCcBranch(e.target.value)}
            placeholder="main"
            hint="Leave empty for no control centre"
          />
          <div className="space-y-2">
            <Input
              id="devbox-frontend"
              label="App branch (ny-react-native)"
              value={frontendBranch}
              onChange={(e) => setFrontendBranch(e.target.value)}
              placeholder="optional"
            />
            <div className="flex flex-wrap gap-4 text-sm">
              <label className="flex items-center gap-2">
                <input id="devbox-android" type="checkbox" checked={buildAndroid} disabled={!hasApp} onChange={(e) => setBuildAndroid(e.target.checked)} />
                Android build
              </label>
              <label className="flex items-center gap-2">
                <input id="devbox-ios" type="checkbox" checked={buildIos} disabled={!hasApp} onChange={(e) => setBuildIos(e.target.checked)} />
                iOS build (TestFlight)
              </label>
            </div>
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

      <Banner tone="info">
        Runs on the least-loaded dev-box with a front desk. Stops by itself after the lifetime set in server config (3 days by default). You can have at most 2 active releases.
      </Banner>

      <div className="flex gap-2">
        <Button type="submit" disabled={!canSubmit} loading={create.isPending}>
          Create release
        </Button>
        <Button variant="outline" onClick={() => navigate('/devbox/releases')}>
          Cancel
        </Button>
      </div>
    </form>
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
