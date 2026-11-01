import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import type { APRelease } from '../releases/api';
import type { OtaCapableApp, OtaGroupResp, OtaPushRow } from '../releases/otaApi';
import { dispatchGroupOta, releaseOtaPush } from '../releases/otaApi';
import { useOtaDimensions, useOtaReleases } from '../airborne-ota/hooks';
import { brandLabel, platLabel } from './model';
import { Layer } from './ui';

const errMsg = (e: any, fallback: string) => e?.response?.data?.message || e?.message || fallback;
const appKey = (name: string, platform: string) => `${name}|${platform}`;
const PUSH_LABEL: Record<OtaPushRow['status'], string> = { DISPATCHED: 'Queued', RUNNING: 'Building bundle', BUNDLE_PUSHED: 'Bundle ready', FAILED: 'Failed' };

/** The release page's hot-push section: bundles built for this release and what's been released. */
export function HotPushLane({ ota, members, onRelease }: { ota: OtaGroupResp; members: APRelease[]; onRelease: (p: OtaPushRow) => void }) {
  if (!ota.rows.length && !ota.links.length) return null;
  const released = new Set(ota.links.map((l) => `${l.airborneAppRef}|${l.packageVersion}`));
  return (
    <section className="m2-panel" aria-label="Hot push">
      <div className="m2-secl"><h2 className="m2-h2">Hot push</h2><span className="m2-colh">JS bundles for apps from this release</span></div>
      <div className="m2-list">
        {ota.rows.map((p) => {
          const done = p.packageVersion != null && released.has(`${p.airborneAppRef}|${p.packageVersion}`);
          const member = members.find((m) => m.appGroup === p.appName && m.env === p.platform);
          return (
            <div key={p.id} className="m2-pushrow">
              <span style={{ minWidth: 0 }}>
                <span className="m2-ell" style={{ fontWeight: 500, display: 'block' }}>{brandLabel(p.appName)} {platLabel(p.platform)}{member ? <span className="m2-faint" style={{ fontWeight: 400 }}> · on {member.new_version}</span> : null}</span>
                {p.status === 'FAILED' && p.error && <span className="m2-brick m2-ell" style={{ display: 'block', fontSize: 11.5 }} title={p.error}>{p.error}</span>}
              </span>
              <span className="m2-mono m2-muted m2-ell" style={{ fontSize: 12 }}>{p.finalVersion ?? p.requestedBump}{p.packageVersion != null ? ` · pkg ${p.packageVersion}` : ''}</span>
              <span className={p.status === 'FAILED' ? 'm2-brick' : done ? 'm2-go' : 'm2-muted'} style={{ fontSize: 12.5 }} title={p.error ?? undefined}>
                {done ? 'Released' : PUSH_LABEL[p.status]}
              </span>
              <span style={{ display: 'flex', gap: 10, justifyContent: 'flex-end', alignItems: 'center' }}>
                {p.status === 'BUNDLE_PUSHED' && !done && <button type="button" className="m2-btn sm pri" onClick={() => onRelease(p)}>Release</button>}
                {p.runUrl && <a className="m2-lnk" href={p.runUrl} target="_blank" rel="noreferrer">CI run</a>}
              </span>
            </div>
          );
        })}
      </div>
    </section>
  );
}

/** Build fresh JS bundles for this release's apps (one CI dispatch). */
export function HotPushBuildSheet({ groupId, ota, onClose }: { groupId: string; ota: OtaGroupResp; onClose: () => void }) {
  const qc = useQueryClient();
  const eligible = ota.capableApps.filter((a) => a.pushEligible && !a.releaseBlocked);
  const [picked, setPicked] = useState<Set<string>>(() => new Set(eligible.map((a) => appKey(a.appName, a.platform))));
  const [bump, setBump] = useState<'patch' | 'minor' | 'major'>('patch');
  const [slack, setSlack] = useState(true);
  const [busy, setBusy] = useState(false);
  const chosen = eligible.filter((a) => picked.has(appKey(a.appName, a.platform)));

  const go = async () => {
    setBusy(true);
    try {
      // The endpoint takes app names × platforms; dispatch per platform so a
      // pick like "NY android + KS ios" never builds "NY ios".
      const byPlat = new Map<string, string[]>();
      chosen.forEach((a) => byPlat.set(a.platform, [...(byPlat.get(a.platform) ?? []), a.appName]));
      let n = 0;
      for (const [platform, apps] of byPlat) n += (await dispatchGroupOta(groupId, { versionBump: bump, apps, platforms: [platform], notifySlack: slack })).dispatched;
      toast.success(`Building ${n} bundle${n === 1 ? '' : 's'}`);
      qc.invalidateQueries({ queryKey: ['mobile-group-ota', groupId] });
      onClose();
    } catch (e) {
      toast.error(errMsg(e, 'Could not start the bundle build'));
      setBusy(false);
    }
  };

  const row = (a: OtaCapableApp) => {
    const k = appKey(a.appName, a.platform);
    const ok = a.pushEligible && !a.releaseBlocked;
    return (
      <div key={k}>
        <input type="checkbox" disabled={!ok} checked={ok && picked.has(k)} aria-label={`Include ${brandLabel(a.appName)} ${platLabel(a.platform)}`}
          onChange={() => setPicked((s) => { const n = new Set(s); n.has(k) ? n.delete(k) : n.add(k); return n; })} />
        <div style={{ minWidth: 0 }}>
          <div style={{ fontWeight: 500 }} className={ok ? '' : 'm2-faint'}>{brandLabel(a.appName)} {platLabel(a.platform)}</div>
          <div className="m2-muted" style={{ fontSize: 12, marginTop: 2 }}>
            {!ok ? (a.releaseBlocked ?? a.ineligibleReason ?? 'Not eligible') : a.superseded ? 'Superseded build · its release will target only phones on this version' : 'Ready for a new bundle'}
          </div>
        </div>
        <div />
      </div>
    );
  };

  return (
    <Layer onClose={busy ? undefined : onClose}>
      <div className="m2-scrim" onClick={busy ? undefined : onClose} />
      <aside className="m2-sheet" role="dialog" aria-modal="true" aria-labelledby="m2-hp-t">
        <div className="m2-shh">
          <div><h3 id="m2-hp-t">Hot push</h3><div className="m2-muted" style={{ marginTop: 2 }}>Build a new JS bundle for apps from this release</div></div>
          <button type="button" className="m2-btn quiet sm" onClick={onClose} disabled={busy}>Close</button>
        </div>
        <div className="m2-shb">
          <div className="m2-imp">{ota.capableApps.length ? ota.capableApps.map(row) : <div style={{ display: 'block' }} className="m2-muted">No app in this release supports hot push.</div>}</div>
          <div>
            <div style={{ fontWeight: 500, fontSize: 12.5, marginBottom: 6 }}>Bundle version bump</div>
            <div className="m2-seg" role="group" aria-label="Version bump" style={{ width: 'fit-content' }}>
              {(['patch', 'minor', 'major'] as const).map((b) => <button key={b} type="button" aria-pressed={bump === b} onClick={() => setBump(b)}>{b}</button>)}
            </div>
          </div>
          <label style={{ display: 'flex', gap: 8, alignItems: 'center', fontSize: 12.5 }}>
            <input type="checkbox" checked={slack} onChange={(e) => setSlack(e.target.checked)} /> Post to the releases Slack channel
          </label>
          <div className="m2-callout">Building doesn't reach users. Each bundle is released separately, with its own traffic %.</div>
        </div>
        <div className="m2-shf">
          <button type="button" className="m2-btn" onClick={onClose} disabled={busy}>Cancel</button>
          <button type="button" className="m2-btn pri" onClick={go} disabled={busy || !chosen.length}>{busy ? 'Starting…' : `Build ${chosen.length} bundle${chosen.length === 1 ? '' : 's'}`}</button>
        </div>
      </aside>
    </Layer>
  );
}

// Backend accepts 0–50%; 100% happens only via "conclude" in Airborne.
const TRAFFIC = [1, 5, 10, 25, 50];

/** Release one built bundle to users: traffic % and version targeting. */
export function HotPushReleaseSheet({ groupId, ota, push, nativeVersion, onClose }: { groupId: string; ota: OtaGroupResp; push: OtaPushRow; nativeVersion?: string; onClose: () => void }) {
  const qc = useQueryClient();
  const capable = ota.capableApps.find((a) => a.appName === push.appName && a.platform === push.platform);
  // "First release" is Airborne's own notion (no releases yet for the app), not
  // just this group's — same source v1 and the backend use.
  const relsQ = useOtaReleases(push.airborneAppRef, { page: 1, count: 1 });
  const firstUnknown = relsQ.isError;
  const firstRelease = !relsQ.isLoading && !firstUnknown && ((relsQ.data?.data ?? []) as unknown[]).length === 0;
  const dimsQ = useOtaDimensions(push.airborneAppRef);
  const verDim = ((dimsQ.data?.data ?? []) as { dimension?: string }[]).map((d) => d.dimension ?? '').find((d) => /version/i.test(d));
  const [pct, setPct] = useState(5);
  const [target, setTarget] = useState(!!capable?.superseded);
  const [busy, setBusy] = useState(false);
  const canTarget = !firstRelease && !!verDim && !!nativeVersion;
  const targetNote = firstRelease
    ? "An app's first hot push can't be targeted."
    : dimsQ.isLoading ? 'Checking Airborne targeting…'
    : dimsQ.isError ? "Couldn't read Airborne targeting, so this bundle targets every phone."
    : !verDim ? 'The Airborne workspace has no version dimension, so this bundle targets every phone.'
    : capable?.superseded ? 'Recommended: a newer build replaced this one, so its JS must not reach phones on the new version.'
    : 'Leave off to serve every phone on a compatible build.';

  const go = async () => {
    setBusy(true);
    try {
      await releaseOtaPush(push.id, {
        initialTrafficPercent: firstRelease ? undefined : pct,
        dimensions: target && canTarget ? { [verDim!]: nativeVersion } : undefined,
      });
      toast.success(firstRelease ? 'Released' : `Released to ${pct}%`);
      qc.invalidateQueries({ queryKey: ['mobile-group-ota', groupId] });
      onClose();
    } catch (e) {
      toast.error(errMsg(e, 'Release failed'));
      setBusy(false);
    }
  };

  return (
    <Layer onClose={busy ? undefined : onClose}>
      <div className="m2-scrim" onClick={busy ? undefined : onClose} />
      <aside className="m2-sheet" role="dialog" aria-modal="true" aria-labelledby="m2-hpr-t">
        <div className="m2-shh">
          <div>
            <h3 id="m2-hpr-t">Release bundle</h3>
            <div className="m2-muted" style={{ marginTop: 2 }}>{brandLabel(push.appName)} {platLabel(push.platform)} · {push.finalVersion ?? ''}{push.packageVersion != null ? ` · pkg ${push.packageVersion}` : ''}</div>
          </div>
          <button type="button" className="m2-btn quiet sm" onClick={onClose} disabled={busy}>Close</button>
        </div>
        <div className="m2-shb">
          {firstUnknown && <div className="m2-callout w">Couldn't check this app's Airborne history. If this is its first hot push, the release will be refused with a % set.</div>}
          {firstRelease ? (
            <div className="m2-callout w">This is the app's first hot push, so it goes to everyone (an Airborne rule for first releases).</div>
          ) : (
            <div>
              <div style={{ fontWeight: 500, fontSize: 12.5, marginBottom: 6 }}>Start at</div>
              <div className="m2-seg" role="group" aria-label="Traffic" style={{ width: 'fit-content' }}>
                {TRAFFIC.map((t) => <button key={t} type="button" aria-pressed={pct === t} onClick={() => setPct(t)}>{t}%</button>)}
              </div>
            </div>
          )}
          <label style={{ display: 'flex', gap: 8, alignItems: 'flex-start', fontSize: 12.5 }}>
            <input type="checkbox" checked={target && canTarget} disabled={!canTarget} onChange={(e) => setTarget(e.target.checked)} style={{ marginTop: 2 }} />
            <span>
              Only phones on <span className="m2-mono">{nativeVersion ?? 'this build'}</span>
              <span className="m2-muted" style={{ display: 'block' }}>
                {targetNote}
              </span>
            </span>
          </label>
          <div className="m2-callout w"><b>This reaches users.</b> Ramp or roll back later from Airborne.</div>
        </div>
        <div className="m2-shf">
          <button type="button" className="m2-btn" onClick={onClose} disabled={busy}>Cancel</button>
          <button type="button" className="m2-btn pri" onClick={go} disabled={busy || relsQ.isLoading}>{busy ? 'Releasing…' : firstRelease ? 'Release to everyone' : `Release to ${pct}%`}</button>
        </div>
      </aside>
    </Layer>
  );
}
