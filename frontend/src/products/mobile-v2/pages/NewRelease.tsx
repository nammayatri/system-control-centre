import { useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { toast } from 'sonner';
import { useAuth } from '../../../core/auth/AuthContext';
import { useCreateMobileReleases, useMobileApps, useMobileBranches, usePreviewVersions } from '../../releases/hooks';
import type { AppCatalogEntry, CreateMobileReleasesItem } from '../../releases/types';
import { appOrder, brandColor, brandKey, brandLabel, platLabel, roleLabel } from '../model';
import { usePins } from '../pins';

type Edit = { name: string; code: string };

/** One page: name + branch, apps, versions, notes → creates the release as drafts. */
export default function NewRelease() {
  const navigate = useNavigate();
  const { buildType } = useAuth();
  const isDebug = buildType === 'debug';
  const appsQ = useMobileApps();
  const { pins } = usePins();
  const apps = (appsQ.data ?? []).filter((a) => a.enabled);
  const [label, setLabel] = useState('');
  const [branch, setBranch] = useState('main');
  const [picked, setPicked] = useState<Set<number>>(new Set());
  const [edits, setEdits] = useState<Record<number, Edit>>({});
  const [notes, setNotes] = useState('');
  const branchesQ = useMobileBranches(branch.length > 1 ? branch : undefined);
  const ids = useMemo(() => [...picked].sort((a, b) => a - b), [picked]);
  const previewQ = usePreviewVersions(isDebug ? [] : ids);
  const create = useCreateMobileReleases();

  // Pre-select pinned apps once the catalog arrives.
  useEffect(() => {
    if (appsQ.data && picked.size === 0) setPicked(new Set(apps.filter((a) => pins.has(a.id)).map((a) => a.id)));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [appsQ.data]);

  // Fill suggested versions from the stores; never overwrite a typed value.
  useEffect(() => {
    const previews = previewQ.data?.previews ?? [];
    if (!previews.length) return;
    setEdits((prev) => {
      const next = { ...prev };
      for (const p of previews) {
        if (next[p.appCatalogId]) continue;
        next[p.appCatalogId] = { name: p.nextVersionName ?? p.nextVersionNumber ?? '', code: p.nextVersionCode != null ? String(p.nextVersionCode) : '' };
      }
      return next;
    });
  }, [previewQ.data]);

  const brands = [...new Set(apps.map((a) => brandKey(a.name)))].sort();
  const toggle = (id: number) => setPicked((s) => { const n = new Set(s); n.has(id) ? n.delete(id) : n.add(id); return n; });
  const previewErr = (id: number) => previewQ.data?.previews.find((p) => p.appCatalogId === id)?.err;
  const selectedApps = apps.filter((a) => picked.has(a.id)).sort((x, y) => brandKey(x.name).localeCompare(brandKey(y.name)) || appOrder(x.surface, x.platform) - appOrder(y.surface, y.platform));

  const problems: string[] = [];
  if (!picked.size) problems.push('Pick at least one app.');
  if (!notes.trim()) problems.push('Add release notes.');
  if (!isDebug) {
    for (const a of selectedApps) {
      const e = edits[a.id];
      if (!e?.name.trim()) { problems.push(`${brandLabel(a.name)} ${roleLabel(a.surface)} ${platLabel(a.platform)} needs a version.`); break; }
      if (a.platform === 'android' && !/^\d+$/.test(e.code.trim())) { problems.push(`${brandLabel(a.name)} ${roleLabel(a.surface)} Android needs a build number.`); break; }
    }
  }

  const submit = () => {
    const items: CreateMobileReleasesItem[] = selectedApps.map((a) =>
      isDebug ? { appCatalogId: a.id, versionName: null, versionCode: null }
        : { appCatalogId: a.id, versionName: edits[a.id]?.name.trim() || null, versionCode: a.platform === 'android' ? Number(edits[a.id]?.code) : null },
    );
    create.mutate(
      { releaseGroupLabel: label.trim() || undefined, changeLog: notes.trim(), sourceRef: branch.trim() || null, items },
      {
        onSuccess: (resp) => { toast.success(`Created ${resp.releases.length} draft${resp.releases.length === 1 ? '' : 's'}`); navigate(`/mobile-v2/releases/${resp.releaseGroupId}`); },
        onError: (e: any) => toast.error(e?.response?.data?.message || e?.message || 'Could not create the release'),
      },
    );
  };

  return (
    <div className="m2-page">
      <div className="m2-ph">
        <div><h1 className="m2-h1">New release</h1><div className="m2-lede">Check it once, then create. Builds start when you approve the drafts.</div></div>
        <button type="button" className="m2-btn quiet" onClick={() => navigate('/mobile-v2/releases')}>Cancel</button>
      </div>
      <div className="m2-nr">
        <div style={{ display: 'grid', gap: 22, minWidth: 0 }}>
          <section className="m2-nsec">
            <h2>Name and branch</h2>
            <div className="m2-row2">
              <label className="m2-fld">Release name<input className="m2-inp" value={label} onChange={(e) => setLabel(e.target.value)} placeholder="e.g. Diwali fares" /></label>
              <label className="m2-fld">Branch
                <input className="m2-inp m2-mono" list="m2-branches" value={branch} onChange={(e) => setBranch(e.target.value)} />
                <datalist id="m2-branches">{(branchesQ.data ?? []).slice(0, 30).map((b) => <option key={b.name} value={b.name} />)}</datalist>
              </label>
            </div>
          </section>

          <section className="m2-nsec">
            <h2>Apps <span className="m2-colh">{picked.size} selected · one CI run</span></h2>
            <div className="m2-chips">
              <button type="button" onClick={() => setPicked(new Set(apps.filter((a) => pins.has(a.id)).map((a) => a.id)))}>Pinned · {pins.size}</button>
              <button type="button" onClick={() => setPicked(new Set())}>Clear</button>
            </div>
            {appsQ.isLoading ? <div className="m2-fold">Loading apps…</div> : (
              <div className="m2-picks">
                {brands.map((b) => (
                  <div key={b} className="m2-pickb">
                    <div style={{ display: 'flex', gap: 8, alignItems: 'center', fontSize: 12, fontWeight: 600, marginBottom: 4 }}>
                      <span className="m2-tick" style={{ height: 12, background: brandColor(b) }} />{brandLabel(b)}
                    </div>
                    {apps.filter((a) => brandKey(a.name) === b).sort((x, y) => appOrder(x.surface, x.platform) - appOrder(y.surface, y.platform)).map((a: AppCatalogEntry) => (
                      <label key={a.id} className="m2-pk">
                        <input type="checkbox" checked={picked.has(a.id)} onChange={() => toggle(a.id)} />
                        <span className="m2-ell">{roleLabel(a.surface)} {platLabel(a.platform)}{pins.has(a.id) ? <span className="m2-faint"> · pinned</span> : null}</span>
                        <span className="m2-mono m2-faint" style={{ fontSize: 11 }}>{a.latestProdBuild?.version ?? ''}</span>
                      </label>
                    ))}
                  </div>
                ))}
              </div>
            )}
          </section>

          {!isDebug && (
            <section className="m2-nsec">
              <h2>Versions <span className="m2-colh">suggested from each store</span></h2>
              {previewQ.isError && <div className="m2-ochre" style={{ fontSize: 12.5 }}>Couldn't get suggestions from the stores. Enter each version yourself.</div>}
              {selectedApps.length ? (
                <table className="m2-vt">
                  <colgroup><col /><col style={{ width: 110 }} /><col style={{ width: 130 }} /><col style={{ width: 110 }} /></colgroup>
                  <thead><tr><th>App</th><th>Live</th><th>Version</th><th>Build</th></tr></thead>
                  <tbody>
                    {selectedApps.map((a) => {
                      const e = edits[a.id] ?? { name: '', code: '' };
                      const set = (k: keyof Edit, v: string) => setEdits((x) => ({ ...x, [a.id]: { ...e, [k]: v } }));
                      const err = previewErr(a.id);
                      return (
                        <tr key={a.id}>
                          <td className="m2-ell">{brandLabel(a.name)} {roleLabel(a.surface)} {platLabel(a.platform)}{err ? <span className="m2-ochre" style={{ fontSize: 11.5 }}> · {err}</span> : null}</td>
                          <td className="m2-mono m2-faint m2-ell">{a.latestProdBuild?.version ?? '—'}</td>
                          <td><input className="m2-inp" value={e.name} onChange={(ev) => set('name', ev.target.value)} placeholder={previewQ.isFetching ? '…' : ''} aria-label="Version" /></td>
                          <td>{a.platform === 'android'
                            ? <input className="m2-inp" value={e.code} onChange={(ev) => set('code', ev.target.value)} inputMode="numeric" aria-label="Build number" />
                            : <span className="m2-faint" style={{ fontSize: 12 }}>set by CI</span>}</td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              ) : <div className="m2-faint" style={{ fontSize: 12.5 }}>Pick apps above.</div>}
            </section>
          )}

          <section className="m2-nsec">
            <h2>Release notes <span className="m2-colh">sent to the stores and the build</span></h2>
            <textarea className="m2-inp" value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="What changed for users" aria-label="Release notes" />
          </section>
        </div>

        <aside className="m2-sum" aria-label="Summary">
          <div style={{ fontWeight: 600 }} className="m2-ell">{label.trim() || 'Untitled release'}</div>
          <div className="r"><span className="m2-muted">Apps</span><span>{picked.size}</span></div>
          <div className="r"><span className="m2-muted">Branch</span><span className="m2-mono m2-ell" style={{ maxWidth: 170 }}>{branch || '—'}</span></div>
          <div className="r"><span className="m2-muted">Build type</span><span>{isDebug ? 'Debug' : 'Release'}</span></div>
          {problems.length > 0 && <div className="m2-faint" style={{ fontSize: 12 }}>{problems[0]}</div>}
          <button type="button" className="m2-btn pri" style={{ justifyContent: 'center' }} disabled={problems.length > 0 || create.isPending} onClick={submit}>
            {create.isPending ? 'Creating…' : `Create ${picked.size || ''} draft${picked.size === 1 ? '' : 's'}`}
          </button>
          <div className="m2-faint" style={{ fontSize: 11.5 }}>Nothing builds or reaches users yet. Approve the drafts on the release page to start the CI run.</div>
        </aside>
      </div>
    </div>
  );
}
