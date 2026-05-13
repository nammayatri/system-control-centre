import { useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { AlertTriangle, Smartphone, Apple, Cpu } from 'lucide-react';
import {
  useMobileApps,
  usePreviewVersions,
  useCreateMobileReleases,
} from '../../hooks';
import type {
  AppCatalogEntry,
  CreateMobileReleasesItem,
  CreateMobileReleasesReq,
  MobileDestination,
  VersionPreviewItem,
} from '../../types';
import { Button } from '../../../../shared/ui/button';
import { Textarea, SelectInput } from '../../../../shared/ui/input';
import { Skeleton } from '../../../../shared/ui/skeleton';
import { cn } from '../../../../lib/utils';
import { toast } from 'sonner';

// Per-app form state — version overrides keyed by appCatalogId.
type VersionEdit = { versionName: string; versionCode: string };

const DEBOUNCE_MS = 500;

const PlatformIcon = ({ platform }: { platform: string }) =>
  platform === 'ios'
    ? <Apple className="w-4 h-4 text-zinc-500" />
    : <Cpu className="w-4 h-4 text-emerald-600" />;

export default function CreateMobileRelease() {
  const navigate = useNavigate();
  const { data: apps, isLoading: appsLoading, error: appsError } = useMobileApps();

  // Filter to enabled apps only — disabled apps live in the catalog but
  // shouldn't be selectable for new releases.
  const enabledApps: AppCatalogEntry[] = useMemo(
    () => (apps || []).filter((a) => a.enabled),
    [apps],
  );

  const [selectedIds, setSelectedIds] = useState<number[]>([]);
  // Debounced selection feeds the preview query so toggling several apps in
  // quick succession only fires one preview call.
  const [debouncedIds, setDebouncedIds] = useState<number[]>([]);

  useEffect(() => {
    const t = setTimeout(() => setDebouncedIds(selectedIds), DEBOUNCE_MS);
    return () => clearTimeout(t);
  }, [selectedIds]);

  const previewQuery = usePreviewVersions(debouncedIds);
  const previews: VersionPreviewItem[] = previewQuery.data?.previews ?? [];

  const [versionEdits, setVersionEdits] = useState<Record<number, VersionEdit>>({});
  const [changeLog, setChangeLog] = useState('');
  const [destination, setDestination] = useState<MobileDestination>('GooglePlay');

  // When a fresh preview lands, prefill any unedited rows with the suggested
  // version. Don't clobber values the user has already typed.
  useEffect(() => {
    if (!previews.length) return;
    setVersionEdits((prev) => {
      const next = { ...prev };
      for (const p of previews) {
        if (!next[p.appCatalogId]) {
          next[p.appCatalogId] = {
            versionName: p.nextVersionName ?? '',
            versionCode: p.nextVersionCode != null ? String(p.nextVersionCode) : '',
          };
        }
      }
      return next;
    });
  }, [previews]);

  const previewById = useMemo(() => {
    const m = new Map<number, VersionPreviewItem>();
    for (const p of previews) m.set(p.appCatalogId, p);
    return m;
  }, [previews]);

  const toggleApp = (id: number) => {
    setSelectedIds((prev) =>
      prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id],
    );
  };

  const setVersionField = (id: number, field: keyof VersionEdit, value: string) => {
    setVersionEdits((prev) => ({
      ...prev,
      [id]: { ...(prev[id] || { versionName: '', versionCode: '' }), [field]: value },
    }));
  };

  const createMutation = useCreateMobileReleases();

  // Submission validity: at least one app, every selected app has a non-empty
  // version name and a numeric code, and a non-empty changelog.
  const validation = useMemo(() => {
    if (selectedIds.length === 0) return { ok: false, reason: 'Select at least one app' };
    if (!changeLog.trim()) return { ok: false, reason: 'Change log is required' };
    for (const id of selectedIds) {
      const v = versionEdits[id];
      if (!v?.versionName.trim()) {
        return { ok: false, reason: 'All selected apps need a version name' };
      }
      if (v.versionCode.trim() === '' || !/^\d+$/.test(v.versionCode.trim())) {
        return { ok: false, reason: 'All selected apps need a numeric version code' };
      }
    }
    return { ok: true as const };
  }, [selectedIds, versionEdits, changeLog]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!validation.ok) {
      toast.error(validation.reason);
      return;
    }
    const items: CreateMobileReleasesItem[] = selectedIds.map((id) => {
      const v = versionEdits[id];
      return {
        appCatalogId: id,
        versionName: v.versionName.trim(),
        versionCode: parseInt(v.versionCode, 10),
      };
    });
    const req: CreateMobileReleasesReq = {
      changeLog: changeLog.trim(),
      destination,
      items,
    };
    try {
      const resp = await createMutation.mutateAsync(req);
      toast.success(
        `Created ${resp.releases.length} release${resp.releases.length === 1 ? '' : 's'}`,
      );
      navigate(`/release-groups/${resp.releaseGroupId}`);
    } catch {
      // toast surfaced inside the hook — nothing else to do here.
    }
  };

  return (
    <div className="flex flex-col flex-1 w-full pb-12">
      <form onSubmit={handleSubmit} className="space-y-4 sm:space-y-6 max-w-4xl">

        {/* ─── Apps card ─────────────────────────────── */}
        <section className="bg-white rounded-xl border border-zinc-200">
          <header className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100">
            <h2 className="text-base sm:text-lg font-semibold text-zinc-900">
              Apps
              <span className="ml-2 text-xs font-normal text-zinc-500">
                {selectedIds.length} selected
              </span>
            </h2>
            <p className="text-xs text-zinc-500 mt-0.5">
              Pick the apps to release. Versions auto-fill from the latest live
              version.
            </p>
          </header>
          <div className="p-4 sm:p-6">
            {appsLoading ? (
              <div className="space-y-2">
                <Skeleton className="h-12 w-full" />
                <Skeleton className="h-12 w-full" />
                <Skeleton className="h-12 w-full" />
              </div>
            ) : appsError ? (
              <div className="text-sm text-red-600">
                Failed to load apps. Refresh to retry.
              </div>
            ) : enabledApps.length === 0 ? (
              <div className="text-sm text-zinc-500">
                No enabled apps in the catalog.{' '}
                <a href="/mobile/apps" className="underline text-zinc-700">
                  Manage apps
                </a>
                .
              </div>
            ) : (
              <ul className="space-y-2">
                {enabledApps.map((app) => {
                  const checked = selectedIds.includes(app.id);
                  return (
                    <li key={app.id}>
                      <label
                        className={cn(
                          'flex items-center gap-3 px-3 py-2.5 rounded-lg border cursor-pointer transition-colors',
                          checked
                            ? 'border-zinc-900 bg-zinc-50'
                            : 'border-zinc-200 hover:bg-zinc-50',
                        )}
                      >
                        <input
                          type="checkbox"
                          checked={checked}
                          onChange={() => toggleApp(app.id)}
                          className="rounded border-zinc-300 accent-zinc-900"
                        />
                        <PlatformIcon platform={app.platform} />
                        <div className="min-w-0 flex-1">
                          <div className="text-sm font-medium text-zinc-900 truncate">
                            {app.displayLabel || app.name}
                          </div>
                          <div className="text-xs text-zinc-500 truncate">
                            {app.surface} · {app.platform}
                          </div>
                        </div>
                      </label>
                    </li>
                  );
                })}
              </ul>
            )}
          </div>
        </section>

        {/* ─── Versions card ─────────────────────────── */}
        {selectedIds.length > 0 && (
          <section className="bg-white rounded-xl border border-zinc-200">
            <header className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100 flex items-center justify-between gap-3">
              <h2 className="text-base sm:text-lg font-semibold text-zinc-900">
                Versions
              </h2>
              {previewQuery.isFetching && (
                <span className="text-xs text-zinc-400">Loading suggestions…</span>
              )}
            </header>
            <div className="p-4 sm:p-6 space-y-3">
              {selectedIds.map((id) => {
                const app = enabledApps.find((a) => a.id === id);
                if (!app) return null;
                const preview = previewById.get(id);
                const v = versionEdits[id] || { versionName: '', versionCode: '' };
                return (
                  <div
                    key={id}
                    className="grid grid-cols-1 sm:grid-cols-[1fr_auto_auto] gap-3 items-end"
                  >
                    <div>
                      <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">
                        {app.displayLabel || app.name}
                        <span className="text-zinc-400 ml-1.5 normal-case font-normal tracking-normal">
                          ({app.surface} {app.platform})
                        </span>
                      </label>
                      <input
                        type="text"
                        value={v.versionName}
                        onChange={(e) => setVersionField(id, 'versionName', e.target.value)}
                        placeholder={preview?.nextVersionName || '2.5.1'}
                        className="w-full h-10 sm:h-9 border border-zinc-300 rounded-lg px-3 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400"
                      />
                    </div>
                    <div className="sm:w-32">
                      <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">
                        Code
                      </label>
                      <input
                        type="number"
                        value={v.versionCode}
                        onChange={(e) => setVersionField(id, 'versionCode', e.target.value)}
                        placeholder={preview?.nextVersionCode != null ? String(preview.nextVersionCode) : '12345'}
                        className="w-full h-10 sm:h-9 border border-zinc-300 rounded-lg px-3 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400"
                      />
                    </div>
                    <div className="text-xs text-zinc-400 pb-2">
                      {preview?.source && !preview.err && (
                        <span>auto · {preview.source}</span>
                      )}
                      {preview?.err && (
                        <span className="inline-flex items-center gap-1 text-amber-700">
                          <AlertTriangle className="w-3.5 h-3.5" />
                          {preview.err}
                        </span>
                      )}
                    </div>
                  </div>
                );
              })}
            </div>
          </section>
        )}

        {/* ─── Change log ───────────────────────────── */}
        <section className="bg-white rounded-xl border border-zinc-200">
          <header className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100">
            <h2 className="text-base sm:text-lg font-semibold text-zinc-900">
              Change log
            </h2>
          </header>
          <div className="p-4 sm:p-6">
            <Textarea
              value={changeLog}
              onChange={(e) => setChangeLog(e.target.value)}
              placeholder="Describe what's in this release…"
              rows={5}
              required
            />
          </div>
        </section>

        {/* ─── Destination ──────────────────────────── */}
        <section className="bg-white rounded-xl border border-zinc-200">
          <header className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100">
            <h2 className="text-base sm:text-lg font-semibold text-zinc-900">
              Destination
            </h2>
          </header>
          <div className="p-4 sm:p-6 max-w-xs">
            <SelectInput
              value={destination}
              onChange={(e) => setDestination(e.target.value as MobileDestination)}
              options={[
                { value: 'GooglePlay', label: 'Google Play' },
                { value: 'Firebase', label: 'Firebase' },
              ]}
            />
          </div>
        </section>

        {/* ─── Actions ──────────────────────────────── */}
        <div className="flex flex-col-reverse sm:flex-row sm:justify-end gap-2 sm:gap-3 pt-2">
          <Button
            type="button"
            variant="secondary"
            onClick={() => navigate('/releases?category=mobile')}
          >
            Cancel
          </Button>
          {/* Note: "Save & approve" intentionally omitted in MVP — the bulk
              approve action lives on the release group page. */}
          <Button
            type="submit"
            loading={createMutation.isPending}
            disabled={!validation.ok}
          >
            <Smartphone className="w-4 h-4" />
            {createMutation.isPending ? 'Creating…' : 'Save as draft'}
          </Button>
        </div>
      </form>
    </div>
  );
}
