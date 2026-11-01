import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import type { APRelease } from '../releases/api';
import { approveMobileRelease, mobileApi } from '../releases/api';
import { useAuth } from '../../core/auth/AuthContext';
import type { ActionKey } from './model';
import { ACTIONS, RAMP_STEPS, appName, fmtPct, isAndroid, nextRampStep, stageLabel, stageOfRelease } from './model';
import { Layer, Stamp } from './ui';

export type RowResult = { ok: boolean; text: string; at: number };

/** Per-app review before any store action: who moves, from what, to what. */
export function ReviewSheet({
  actionKey, releases, excludedNote, onClose, onDone,
}: {
  actionKey: ActionKey;
  releases: APRelease[];
  excludedNote?: string;
  onClose: () => void;
  onDone: (results: Record<string, RowResult>) => void;
}) {
  const A = ACTIONS[actionKey];
  const qc = useQueryClient();
  const { user } = useAuth();
  const [included, setIncluded] = useState<Set<string>>(() => new Set(releases.map((r) => r.id)));
  const [targets, setTargets] = useState<Record<string, number>>({});
  const [busy, setBusy] = useState(false);
  const incl = releases.filter((r) => included.has(r.id));
  const target = (r: APRelease) => targets[r.id] ?? nextRampStep(r.release_context?.rollout_percent);

  const toText = (r: APRelease) => {
    const pct = r.release_context?.rollout_percent;
    switch (actionKey) {
      case 'ramp': return null;
      case 'approve': return 'draft → approved';
      case 'dispatch': return 'approved → building';
      case 'submit': return 'internal → review';
      case 'confirm': return 'review → approved';
      case 'release': return isAndroid(r.env) ? 'held → 1%' : 'held → phased 7 days';
      case 'resume': return `paused → ${pct != null ? fmtPct(pct) : ''}%`;
      case 'pause': return `${pct != null ? fmtPct(pct) : ''}% → paused`;
      case 'releaseAll': return '→ 100%';
    }
  };

  async function runOne(r: APRelease): Promise<void> {
    switch (actionKey) {
      case 'approve': await approveMobileRelease(r.id, user?.email || 'local_admin'); return;
      case 'submit': await mobileApi.promote(r.id, { prReleaseNotes: r.release_context?.change_log || r.change_log || '' }); return;
      case 'confirm': await mobileApi.markApproved(r.id); return;
      case 'release': isAndroid(r.env) ? await mobileApi.rolloutSet(r.id, 1) : await mobileApi.releaseApproved(r.id); return;
      case 'ramp': await mobileApi.rolloutSet(r.id, target(r)); return;
      case 'resume': await mobileApi.rolloutResume(r.id); return;
      case 'pause': await mobileApi.rolloutHalt(r.id); return;
      case 'releaseAll': await mobileApi.rolloutReleaseAll(r.id); return;
      case 'dispatch': return; // batched below — one CI run for the whole selection
    }
  }

  async function go() {
    setBusy(true);
    const results: Record<string, RowResult> = {};
    const now = new Date().toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit' });
    if (actionKey === 'dispatch') {
      try {
        await mobileApi.dispatchReleases(incl.map((r) => r.id));
        incl.forEach((r) => (results[r.id] = { ok: true, text: `Build started · ${now}`, at: Date.now() }));
      } catch (e: any) {
        const msg = e?.response?.data?.message || e?.message || 'Dispatch failed';
        incl.forEach((r) => (results[r.id] = { ok: false, text: msg, at: Date.now() }));
      }
    } else {
      // Sequential on purpose: each store call is its own edit; parallel edits
      // on one console can collide.
      for (const r of incl) {
        try {
          await runOne(r);
          results[r.id] = { ok: true, text: `${A.done}${actionKey === 'ramp' ? ` to ${target(r)}%` : ''} · ${now}`, at: Date.now() };
        } catch (e: any) {
          results[r.id] = { ok: false, text: e?.response?.data?.message || e?.message || 'Failed', at: Date.now() };
        }
      }
    }
    ['mobile-group', 'mobile-groups', 'mobile-rollout', 'release', 'releases', 'store-monitor'].forEach((k) => qc.invalidateQueries({ queryKey: [k] }));
    const ok = Object.values(results).filter((x) => x.ok).length;
    (ok === incl.length ? toast.success : toast.error)(`${ok} of ${incl.length} ${A.done.toLowerCase()}`);
    setBusy(false);
    onDone(results);
  }

  const reachesUsers = ['release', 'ramp', 'resume', 'releaseAll'].includes(actionKey);
  return (
    <Layer onClose={busy ? undefined : onClose}>
      <div className="m2-scrim" onClick={busy ? undefined : onClose} />
      <aside className="m2-sheet" role="dialog" aria-modal="true" aria-labelledby="m2-rev-t">
        <div className="m2-shh">
          <div>
            <h3 id="m2-rev-t">{A.title}</h3>
            <div className="m2-muted" style={{ marginTop: 2 }}>{incl.length} app{incl.length === 1 ? '' : 's'} · review each one</div>
          </div>
          <button type="button" className="m2-btn quiet sm" onClick={onClose} disabled={busy}>Close</button>
        </div>
        <div className="m2-shb">
          <div className="m2-imp">
            {releases.map((r) => {
              const pct = r.release_context?.rollout_percent;
              return (
                <div key={r.id}>
                  <input
                    type="checkbox"
                    checked={included.has(r.id)}
                    onChange={() => setIncluded((s) => { const n = new Set(s); n.has(r.id) ? n.delete(r.id) : n.add(r.id); return n; })}
                    aria-label={`Include ${appName(r.appGroup, r.service, r.env)}`}
                  />
                  <div style={{ minWidth: 0 }}>
                    <div style={{ fontWeight: 500 }}>{appName(r.appGroup, r.service, r.env)} <Stamp version={r.new_version} code={r.release_context?.version_code} /></div>
                    <div className="m2-muted" style={{ fontSize: 12, marginTop: 2 }}>{stageLabel(stageOfRelease(r), r)}</div>
                  </div>
                  <div className="m2-mono" style={{ fontSize: 12, whiteSpace: 'nowrap', textAlign: 'right' }}>
                    {actionKey === 'ramp' ? (
                      <>
                        {pct != null ? fmtPct(pct) : 0}% →{' '}
                        <select
                          className="m2-mono"
                          style={{ fontSize: 12, border: '1px solid var(--m2-line2)', borderRadius: 4, background: 'var(--m2-surface)', color: 'var(--m2-fg)' }}
                          value={target(r)}
                          onChange={(e) => setTargets((t) => ({ ...t, [r.id]: Number(e.target.value) }))}
                          aria-label={`Target for ${appName(r.appGroup, r.service, r.env)}`}
                        >
                          {RAMP_STEPS.filter((s) => s > (pct ?? 0)).map((s) => <option key={s} value={s}>{s}</option>)}
                        </select>
                        %
                      </>
                    ) : toText(r)}
                  </div>
                </div>
              );
            })}
          </div>
          {excludedNote && <div className="m2-callout">{excludedNote}</div>}
          {actionKey === 'ramp' && <div className="m2-callout">Each app moves to its own next step. Nothing jumps further than shown.</div>}
          {actionKey === 'confirm' && <div className="m2-callout w">Confirm only after Play Console shows <b>Approved</b> for each app.</div>}
          {reachesUsers && <div className="m2-callout w"><b>This reaches users.</b> There is no store rollback; a bad build is fixed only by a newer one.</div>}
          {actionKey === 'pause' && <div className="m2-callout">New users stop getting this version. People who already updated keep it.</div>}
        </div>
        <div className="m2-shf">
          <button type="button" className="m2-btn" onClick={onClose} disabled={busy}>Cancel</button>
          <button type="button" className="m2-btn pri" onClick={go} disabled={busy || !incl.length}>
            {busy ? 'Working…' : `${A.verb} ${incl.length} app${incl.length === 1 ? '' : 's'}`}
          </button>
        </div>
      </aside>
    </Layer>
  );
}
