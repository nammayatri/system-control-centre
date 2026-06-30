import { useMemo, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { Rocket, Flag, ChevronDown, ChevronRight, X } from 'lucide-react';
import { Button } from '../../../shared/ui/button';
import { Badge } from '../../../shared/ui/badge';
import { usePermissions } from '../../../core/auth/PermissionsContext';
import { useReleases } from '../hooks';
import { mobileApi, type APRelease, type BulkActionResp } from '../api';
import {
  stageOf,
  lifecycleFromRelease,
  type Stage,
  type MobileLifecycle,
} from './mobileStage';
import { PlatformBadge } from './PlatformBadge';
import { RolloutBar } from './RolloutBar';
import { surfaceKeyOf, surfaceMeta } from './surfaces';
import { BrandLogo } from './BrandLogo';
import { versionWithBuild } from '../utils';

/**
 * Bulk promote / rollout panel for the App Release Monitor page. The two actions
 * target different tracks, so the panel splits them into two clearly-labelled
 * sections — making it obvious *which version on which platform* each action hits,
 * and that **only internal / TestFlight builds are promoted**:
 *
 *   ① Ready to promote — Android internal / iOS TestFlight builds → submit to review
 *   ② Rolling out (Android) — set / bump the Play production rollout %
 *
 * Each section's action lives in its header (above the apps); rows are grouped by
 * app name and laid out two-per-row (no scroll). Rollout takes a single % inline,
 * applied to every selected app. The backend (POST /mobile/bulk/{promote,rollout})
 * reuses the single-item handlers and returns a per-app verdict, so partial failures
 * surface per app. Renders nothing when there's nothing to act on.
 */
const BULK_WINDOW_DAYS = 30;
// Bulk promote is temporarily hidden — flip to true to bring the section back.
const PROMOTE_ENABLED = false;

// Humanise a raw app_group ("ManaYatriPartner") into a card-style label
// ("Mana Yatri"): split camelCase, drop the surface suffix (the surface is shown
// separately), collapse whitespace.
function humanizeAppName(appGroup: string): string {
  return (
    appGroup
      .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
      .replace(/\s*(Partner|Driver|Customer|Consumer)\b/gi, '')
      .replace(/\s+/g, ' ')
      .trim() || appGroup
  );
}

interface Eligible {
  r: APRelease;
  stage: Stage;
  lc: MobileLifecycle;
  rolloutPercent: number | null;
  rolloutStatus: string | null;
  mbStatus: string;
}

// What the backend's `rolloutSetH` will accept a "set rollout %" for:
//   • a native SCC rollout — mb_wf_status MBReviewApproved / MBRollingOut, OR
//   • an OBSERVED Play-console rollout SCC can adopt — rollout_status rolling_out /
//     halted (mirrored onto a store-sync snapshot).
// A finished release (rollout_status completed / none) is excluded either way.
const ROLLABLE_MB_STATES = new Set(['MBReviewApproved', 'MBRollingOut']);
const ADOPTABLE_ROLLOUT_STATES = new Set(['rolling_out', 'halted']);
const isRollable = (e: Eligible) =>
  e.r.env === 'android' &&
  (ROLLABLE_MB_STATES.has(e.mbStatus) || (e.rolloutStatus != null && ADOPTABLE_ROLLOUT_STATES.has(e.rolloutStatus)));

// Group the same brand together (then by surface / platform) so a brand's consumer
// + driver variants sit next to each other in the two-per-row grid.
const byApp = (a: Eligible, b: Eligible) =>
  humanizeAppName(a.r.appGroup).localeCompare(humanizeAppName(b.r.appGroup)) ||
  a.r.service.localeCompare(b.r.service) ||
  a.r.env.localeCompare(b.r.env);

export function MobileBulkPanel() {
  const { hasPermission } = usePermissions();
  const canPromote = hasPermission('autopilot', 'RELEASE_PROMOTE');
  const canRollout = hasPermission('autopilot', 'RELEASE_ROLLOUT');

  // A stable 30-day window captures every in-flight (recently-updated) release
  // needing action. Memoised so the query key doesn't churn every render.
  const [range] = useState(() => {
    const to = new Date();
    const from = new Date(to.getTime() - BULK_WINDOW_DAYS * 24 * 60 * 60 * 1000);
    return { from: from.toISOString(), to: to.toISOString() };
  });
  const { data: releases = [] } = useReleases(range.from, range.to, 'mobile');
  const qc = useQueryClient();

  const { promotable, rollable } = useMemo(() => {
    const elig: Eligible[] = releases.map((r) => {
      const lc = lifecycleFromRelease(r);
      return {
        r,
        stage: stageOf(lc),
        lc,
        rolloutPercent: lc.rolloutPercent ?? null,
        rolloutStatus: lc.rolloutStatus ?? null,
        mbStatus: lc.mbStatus,
      };
    });
    // Promote shows only the LATEST internal / TestFlight build per app — one row
    // per (app, surface, platform), keeping the most recently-synced version so an
    // older snapshot can't be promoted by mistake.
    const latest = new Map<string, Eligible>();
    for (const e of elig.filter((x) => x.stage === 'promote')) {
      const key = `${e.r.appGroup}|${e.r.service}|${e.r.env}`;
      const cur = latest.get(key);
      if (!cur || (e.r.date_created ?? '') > (cur.r.date_created ?? '')) latest.set(key, e);
    }
    return {
      promotable: [...latest.values()].sort(byApp),
      rollable: elig.filter(isRollable).sort(byApp),
    };
  }, [releases]);

  const [open, setOpen] = useState(true);
  const [sel, setSel] = useState<Set<string>>(new Set());
  const [showPromote, setShowPromote] = useState(false);
  const [rolloutPct, setRolloutPct] = useState('0');
  const [busy, setBusy] = useState(false);

  const selPromote = promotable.filter((e) => sel.has(e.r.id)).map((e) => e.r);
  const selRollout = rollable.filter((e) => sel.has(e.r.id)).map((e) => e.r);

  const showPromoteSection = PROMOTE_ENABLED && canPromote && promotable.length > 0;
  const showRolloutSection = canRollout && rollable.length > 0;
  const total = (showPromoteSection ? promotable.length : 0) + (showRolloutSection ? rollable.length : 0);

  if (total === 0 || (!showPromoteSection && !showRolloutSection)) return null;

  const toggle = (id: string) =>
    setSel((p) => {
      const n = new Set(p);
      n.has(id) ? n.delete(id) : n.add(id);
      return n;
    });
  const setMany = (ids: string[], on: boolean) =>
    setSel((p) => {
      const n = new Set(p);
      ids.forEach((id) => (on ? n.add(id) : n.delete(id)));
      return n;
    });
  const done = () => {
    setSel(new Set());
    setShowPromote(false);
    // Reflect immediately everywhere: the bulk panel's own list, the releases list
    // page (['releases', …]), and any open detail / rollout panel
    // (['release', id] / ['mobile-rollout', id]). Broad prefixes — bulk touches many.
    void qc.invalidateQueries({ queryKey: ['releases'] });
    void qc.invalidateQueries({ queryKey: ['release'] });
    void qc.invalidateQueries({ queryKey: ['mobile-rollout'] });
    // The App Monitor reads store_status (not release_tracker); rolloutSetH mirrors
    // the % there too, so refetch the monitor to reflect it without a live re-poll.
    void qc.invalidateQueries({ queryKey: ['store-monitor'] });
  };

  const applyRollout = async () => {
    const p = Number(rolloutPct);
    if (!(p > 0 && p <= 100)) {
      toast.error('Percent must be in (0, 100].');
      return;
    }
    setBusy(true);
    try {
      const res = await mobileApi.bulkRollout(selRollout.map((r) => ({ briReleaseId: r.id, briPercent: p })));
      reportBulk(res, 'Rollout', selRollout);
      done();
    } catch (e) {
      toast.error(e instanceof Error ? e.message : 'Bulk rollout failed');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="rounded-xl border border-zinc-200 bg-white">
      <button
        onClick={() => setOpen((o) => !o)}
        aria-expanded={open}
        className="flex w-full items-center justify-between px-4 py-3 text-left"
      >
        <span className="flex items-center gap-2 text-sm font-semibold text-zinc-800">
          {open ? <ChevronDown size={15} /> : <ChevronRight size={15} />}
          Bulk actions
          <Badge variant="muted">{total} actionable</Badge>
        </span>
        {sel.size > 0 && <span className="text-xs text-zinc-500">{sel.size} selected</span>}
      </button>

      {open && (
        <div className="border-t border-zinc-100 px-4 py-4">
          {showPromoteSection && (
            <BulkSection
              title="Ready to promote"
              hint="Internal / TestFlight builds → submit to store review"
              rows={promotable}
              selected={sel}
              onToggleAll={(on) => setMany(promotable.map((e) => e.r.id), on)}
              onToggle={toggle}
              renderRight={(e) => <Badge variant="info">{e.r.env === 'ios' ? 'TestFlight' : 'Internal'}</Badge>}
              action={
                <Button size="sm" variant="secondary" disabled={selPromote.length === 0} onClick={() => setShowPromote(true)}>
                  <Rocket size={13} /> Promote ({selPromote.length})
                </Button>
              }
            />
          )}

          {showPromoteSection && showRolloutSection && <div className="my-5 border-t border-zinc-200" />}

          {showRolloutSection && (
            <BulkSection
              title="Rolling out · Android"
              hint="Set or bump the Google Play production rollout %"
              rows={rollable}
              selected={sel}
              onToggleAll={(on) => setMany(rollable.map((e) => e.r.id), on)}
              onToggle={toggle}
              renderRight={(e) => {
                // The one canonical backend displayStatus (release_context.display_*),
                // so "Halted · X%" / "Rolling out · X%" / "Approved · held" read
                // identically everywhere.
                const ctx = e.r.release_context;
                const ds =
                  ctx?.display_label && ctx?.display_variant
                    ? { label: ctx.display_label, variant: ctx.display_variant }
                    : null;
                const inFlight = e.rolloutStatus === 'rolling_out' || e.rolloutStatus === 'halted';
                return (
                  <span className="flex shrink-0 items-center gap-2">
                    {inFlight && e.rolloutPercent != null && (
                      <RolloutBar
                        pct={e.rolloutPercent}
                        halted={e.rolloutStatus === 'halted'}
                        showLabel={false}
                        className="w-16"
                      />
                    )}
                    {ds ? (
                      <Badge variant={ds.variant}>{ds.label}</Badge>
                    ) : (
                      <Badge variant="success">Approved · held</Badge>
                    )}
                  </span>
                );
              }}
              action={
                <div className="flex items-center gap-1.5">
                  <input
                    type="number"
                    min={1}
                    max={100}
                    value={rolloutPct}
                    onChange={(e) => setRolloutPct(e.target.value)}
                    className="w-16 rounded border border-zinc-300 px-2 py-1 text-xs"
                    aria-label="Rollout percent to apply"
                  />
                  <span className="text-xs text-zinc-500">%</span>
                  <Button size="sm" disabled={selRollout.length === 0 || busy} onClick={applyRollout}>
                    <Flag size={13} /> {busy ? 'Applying…' : `Set rollout % (${selRollout.length})`}
                  </Button>
                </div>
              }
            />
          )}
        </div>
      )}

      {showPromote && <BulkPromoteModal apps={selPromote} onClose={() => setShowPromote(false)} onDone={done} />}
    </div>
  );
}

// ── A labelled section: header (title + action + select-all) above the app grid ──
function BulkSection({
  title,
  hint,
  rows,
  selected,
  onToggle,
  onToggleAll,
  renderRight,
  action,
}: {
  title: string;
  hint: string;
  rows: Eligible[];
  selected: Set<string>;
  onToggle: (id: string) => void;
  onToggleAll: (on: boolean) => void;
  renderRight: (e: Eligible) => React.ReactNode;
  action: React.ReactNode;
}) {
  const allOn = rows.every((e) => selected.has(e.r.id));
  return (
    <section>
      <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
        <div className="flex items-baseline gap-2">
          <h3 className="text-xs font-semibold uppercase tracking-wide text-zinc-700">{title}</h3>
          <span className="text-[11px] text-zinc-400">{hint}</span>
        </div>
        <div className="flex items-center gap-3">
          {action}
          <label className="flex cursor-pointer items-center gap-1.5 text-[11px] text-zinc-500">
            <input type="checkbox" className="cursor-pointer" checked={allOn} onChange={() => onToggleAll(!allOn)} />
            Select all
          </label>
        </div>
      </div>
      <ul className="grid grid-cols-1 gap-x-8 gap-y-1 xl:grid-cols-2" role="list">
        {rows.map((e) => {
          const meta = surfaceMeta(e.r.service);
          return (
            <li key={e.r.id} className="min-w-0">
              <label className="flex cursor-pointer items-center gap-2.5 rounded-md border border-transparent px-2 py-1.5 hover:border-zinc-200 hover:bg-zinc-50">
                <input
                  type="checkbox"
                  className="shrink-0 cursor-pointer"
                  checked={selected.has(e.r.id)}
                  onChange={() => onToggle(e.r.id)}
                  aria-label={`Select ${humanizeAppName(e.r.appGroup)} ${meta.label} ${e.r.env}`}
                />
                <span className="flex min-w-0 flex-1 items-center gap-1.5">
                  <BrandLogo
                    brand={humanizeAppName(e.r.appGroup)}
                    surface={surfaceKeyOf(e.r.service) === 'driver' ? 'driver' : undefined}
                    size="sm"
                  />
                  <span className="truncate text-sm font-medium text-zinc-800">{humanizeAppName(e.r.appGroup)}</span>
                  <span className="hidden shrink-0 text-xs text-zinc-500 sm:inline">{meta.label}</span>
                  <PlatformBadge platform={e.r.env} isMobile />
                </span>
                <span className="flex shrink-0 items-center gap-2.5">
                  <span className="hidden font-mono text-xs text-zinc-500 sm:inline">{versionWithBuild(e.r)}</span>
                  {renderRight(e)}
                </span>
              </label>
            </li>
          );
        })}
      </ul>
    </section>
  );
}

// Show the per-app verdict from a bulk response as a toast. `apps` (the apps the
// action was applied to) maps each failed release id back to a readable app label.
function reportBulk(res: BulkActionResp, verb: string, apps: APRelease[]) {
  if (res.barFailed === 0) {
    toast.success(`${verb}: all ${res.barSucceeded} succeeded`);
    return;
  }
  const labelOf = new Map(apps.map((r) => [r.id, appRowLabel(r)]));
  const failed = res.barResults.filter((x) => !x.birOk);
  toast.error(
    `${verb}: ${res.barSucceeded} ok, ${res.barFailed} failed — ` +
      failed.map((f) => `${labelOf.get(f.birReleaseId) ?? f.birReleaseId.slice(0, 8)}: ${f.birMessage}`).join('; '),
    { duration: 8000 },
  );
}

const appRowLabel = (r: APRelease) => `${humanizeAppName(r.appGroup)} · ${surfaceMeta(r.service).label} · ${r.env}`;

function BulkPromoteModal({ apps, onClose, onDone }: { apps: APRelease[]; onClose: () => void; onDone: () => void }) {
  const [busy, setBusy] = useState(false);
  const submit = async () => {
    setBusy(true);
    try {
      // Notes omitted → the server fills each app's store "What's New" / changelog.
      const res = await mobileApi.bulkPromote(apps.map((r) => ({ bpiReleaseId: r.id })));
      reportBulk(res, 'Promote', apps);
      onDone();
    } catch (e) {
      toast.error(e instanceof Error ? e.message : 'Bulk promote failed');
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" onClick={onClose}>
      <div className="w-full max-w-md rounded-lg bg-white p-5 shadow-xl" role="dialog" aria-modal onClick={(e) => e.stopPropagation()}>
        <div className="mb-3 flex items-center justify-between">
          <h3 className="text-sm font-semibold text-zinc-800">
            Promote {apps.length} build{apps.length > 1 ? 's' : ''} to review
          </h3>
          <button onClick={onClose} className="text-zinc-400 hover:text-zinc-700" aria-label="Close">
            <X size={16} />
          </button>
        </div>
        <p className="mb-3 text-xs text-zinc-500">
          Each internal / TestFlight build is submitted with its current store "What's New" / changelog. Nothing goes live
          until you roll it out.
        </p>
        <ul className="mb-4 max-h-48 space-y-1 overflow-auto text-xs text-zinc-700">
          {apps.map((r) => (
            <li key={r.id} className="flex justify-between rounded bg-zinc-50 px-2 py-1">
              <span>{appRowLabel(r)}</span>
              <span className="font-mono text-zinc-500">{versionWithBuild(r)}</span>
            </li>
          ))}
        </ul>
        <div className="flex justify-end gap-2">
          <Button size="sm" variant="ghost" onClick={onClose} disabled={busy}>Cancel</Button>
          <Button size="sm" onClick={submit} disabled={busy}>
            <Rocket size={13} /> {busy ? 'Promoting…' : 'Promote all'}
          </Button>
        </div>
      </div>
    </div>
  );
}
