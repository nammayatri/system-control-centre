import { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import type { APRelease, MobileGroupListItem } from '../../releases/api';
import type { AppCatalogEntry } from '../../releases/types';
import { useMobileApps, useMobileGroup, useMobileGroups, useMobileRollout } from '../../releases/hooks';
import { usePermissions } from '../../../core/auth/PermissionsContext';
import type { ActionKey, Stage } from '../model';
import {
  ACTIONS, COLUMNS, PERM_FOR, appOrder, RAMP_STEPS, STAGE_COLOR, STAGE_META, STAGE_ORDER, appName, brandColor, brandKey, brandLabel,
  catalogFor, columnOf, eligibleFor, fmtPct, groupName, groupNameOf, isAndroid, nextAction, platLabel, roleLabel, stageLabel, stageOfMember, stageOfRelease,
} from '../model';
import { usePins } from '../pins';
import { Glyph, PinButton, PlatformTag, ScopeToggle, Stamp } from '../ui';
import { ReviewSheet } from '../ReviewSheet';
import { HotPushBuildSheet, HotPushLane, HotPushReleaseSheet } from '../HotPush';
import type { OtaPushRow } from '../../releases/otaApi';
import { useGroupOta } from '../../releases/otaApi';
import type { RowResult } from '../ReviewSheet';

export default function Releases() {
  const { groupId } = useParams();
  const navigate = useNavigate();
  const groupsQ = useMobileGroups();
  const appsQ = useMobileApps();
  const { inScope, scope } = usePins();
  const apps = appsQ.data;

  const groups = useMemo(() => {
    const all = groupsQ.data?.groups ?? [];
    if (scope === 'all') return all;
    return all.filter((g) => g.members.some((m) => inScope(catalogFor(apps, m.app, m.surface, m.platform)?.id)));
  }, [groupsQ.data, scope, inScope, apps]);

  const selected = groupId ?? groups[0]?.groupId;

  return (
    <div className="m2-split">
      <nav className="m2-rlist" aria-label="Releases">
        {groupsQ.isLoading && <div className="m2-fold" style={{ padding: 14 }}>Loading releases…</div>}
        {!groupsQ.isLoading && !groups.length && (
          <div className="m2-fold" style={{ padding: 14 }}>{scope === 'pinned' ? 'None of your pinned apps are in a release.' : 'No releases yet.'}</div>
        )}
        {groups.map((g) => (
          <ReleaseListItem key={g.groupId} g={g} apps={apps} current={g.groupId === selected} onOpen={() => navigate(`/mobile-v2/releases/${g.groupId}`)} />
        ))}
      </nav>
      <div style={{ minWidth: 0 }}>{selected ? <ReleaseDetail key={selected} groupId={selected} apps={apps} allGroups={groupsQ.data?.groups ?? []} /> : null}</div>
    </div>
  );
}

function ReleaseListItem({ g, apps, current, onOpen }: { g: MobileGroupListItem; apps?: AppCatalogEntry[]; current: boolean; onOpen: () => void }) {
  const { inScope, scope } = usePins();
  const mine = g.members.filter((m) => inScope(catalogFor(apps, m.app, m.surface, m.platform)?.id));
  const shown = mine.length ? mine : g.members;
  const stages = shown.map(stageOfMember).sort((a, b) => STAGE_ORDER.indexOf(a) - STAGE_ORDER.indexOf(b));
  const allLive = g.members.every((m) => ['live', 'superseded'].includes(stageOfMember(m)));
  return (
    <button type="button" className="m2-ritem" aria-current={current} onClick={onOpen}>
      <span style={{ display: 'flex', justifyContent: 'space-between', gap: 8, fontWeight: 600 }}>
        <span className="m2-ell">{groupNameOf(g)}</span>
        <span className="m2-faint m2-mono" style={{ fontWeight: 400, fontSize: 11.5 }}>
          {new Date(g.createdAt).toLocaleDateString('en-IN', { day: 'numeric', month: 'short' })}
        </span>
      </span>
      <span className="m2-muted" style={{ fontSize: 12 }}>
        {g.members.length} app{g.members.length === 1 ? '' : 's'}{scope === 'pinned' ? ` · ${mine.length} pinned` : ''} · {allLive ? 'all live' : g.sourceRef ?? ''}
      </span>
      <span className="m2-strip">{stages.map((s, i) => <i key={i} style={{ background: STAGE_COLOR[s] }} />)}</span>
    </button>
  );
}

const BULK_KEYS: ActionKey[] = ['approve', 'dispatch', 'submit', 'confirm', 'release', 'ramp', 'resume', 'pause'];

/** A newer release that carries the same app and has reached users. */
type Sup = { version: string; groupId: string; name: string; rest: number };

function ReleaseDetail({ groupId, apps, allGroups }: { groupId: string; apps?: AppCatalogEntry[]; allGroups: MobileGroupListItem[] }) {
  const q = useMobileGroup(groupId);
  const otaQ = useGroupOta(groupId);
  const [hotBuild, setHotBuild] = useState(false);
  const [hotRelease, setHotRelease] = useState<OtaPushRow | null>(null);
  const { inScope, scope } = usePins();
  const { hasPermission } = usePermissions();
  const [open, setOpen] = useState<string | null>(null);
  const [sel, setSel] = useState<Set<string>>(new Set());
  const [showOthers, setShowOthers] = useState(false);
  const [results, setResults] = useState<Record<string, RowResult>>({});
  const [sheet, setSheet] = useState<{ key: ActionKey; releases: APRelease[]; note?: string } | null>(null);
  // Row results are transient: successes show 30 s, failures 2 min, then the
  // row's next step comes back. A light tick re-renders while any are live.
  const [, tick] = useState(0);
  const liveResults = Object.fromEntries(Object.entries(results).filter(([, x]) => Date.now() - x.at < (x.ok ? 30_000 : 120_000)));
  const anyLive = Object.keys(liveResults).length > 0;
  useEffect(() => {
    if (!anyLive) return;
    const t = setInterval(() => tick((n) => n + 1), 5_000);
    return () => clearInterval(t);
  }, [anyLive]);

  if (q.isLoading) return <div className="m2-fold">Loading release…</div>;
  if (q.isError || !q.data) return <div className="m2-fold">Couldn't load this release.</div>;
  const g = q.data;
  const members = g.members;
  const catId = (r: APRelease) => catalogFor(apps, r.appGroup, r.service, r.env)?.id;
  const mine = members.filter((r) => inScope(catId(r)));
  const others = members.filter((r) => !inScope(catId(r)));
  const shown = scope === 'all' || showOthers ? members : mine;
  const byBrand = new Map<string, APRelease[]>();
  [...shown].sort((x, y) => brandKey(x.appGroup).localeCompare(brandKey(y.appGroup)) || appOrder(x.service, x.env) - appOrder(y.service, y.env)).forEach((r) => { const b = brandKey(r.appGroup); byBrand.set(b, [...(byBrand.get(b) ?? []), r]); });
  const can = (key: ActionKey, r: APRelease) => hasPermission('mobile', PERM_FOR[key], `${r.appGroup}/${r.env}`);
  const selected = members.filter((r) => sel.has(r.id));
  const version = members.find((r) => r.new_version)?.new_version;
  // Superseded: a NEWER release of the same app is rolling out or live. The old
  // build can't be released again; hot push still serves whoever runs it.
  const supOf = (r: APRelease): Sup | undefined => {
    for (const ng of allGroups) {
      if (ng.groupId === g.groupId || new Date(ng.createdAt) <= new Date(g.createdAt)) continue;
      const m = ng.members.find((x) => x.app === r.appGroup && x.surface === r.service && x.platform === r.env && ['rolling', 'paused', 'live'].includes(stageOfMember(x)));
      if (m) return { version: m.version, groupId: ng.groupId, name: groupNameOf(ng), rest: stageOfMember(m) === 'live' ? 0 : 100 - (m.rolloutPercent ?? 0) };
    }
    return undefined;
  };

  const openSheet = (key: ActionKey, list: APRelease[]) => {
    const ok = list.filter((r) => eligibleFor(key, r) && can(key, r));
    const skipped = list.length - ok.length;
    setSheet({ key, releases: ok, note: skipped ? `${skipped} selected app${skipped > 1 ? 's' : ''} left out: not at a stage where "${ACTIONS[key].verb.toLowerCase()}" applies, or no permission.` : undefined });
  };
  const toggleSel = (id: string) => setSel((s) => { const n = new Set(s); n.has(id) ? n.delete(id) : n.add(id); return n; });

  return (
    <div className="m2-page">
      <div className="m2-ph">
        <div>
          <h1 className="m2-h1">{groupName(g.label, g.createdAt, version)}</h1>
          <div className="m2-lede">
            {members[0]?.sourceRef && <><span className="m2-mono">{members[0].sourceRef}</span> · </>}
            {members.length} app{members.length === 1 ? '' : 's'} · started by {g.createdBy}
          </div>
        </div>
        <div className="m2-hctl">
          <ScopeToggle />
          {otaQ.data?.available && otaQ.data.capableApps.length > 0 && <button type="button" className="m2-btn" onClick={() => setHotBuild(true)}>Hot push</button>}
          <Link className="m2-btn" to="/mobile-v2/new">New release</Link>
        </div>
      </div>

      <div className="m2-mxwrap">
      <div className="m2-mx" role="table" aria-label="Apps by stage">
        <div className="m2-mhead" role="row">
          <span />
          <span className="m2-colh">App</span>
          <span className="m2-colh">Version</span>
          {COLUMNS.map((c, i) => (
            <button key={c} type="button" className="m2-colbtn" title={`Select every app at ${c}`}
              onClick={() => setSel((s) => { const n = new Set(s); shown.filter((r) => columnOf(stageOfRelease(r), r) === i).forEach((r) => n.add(r.id)); return n; })}>
              {c}
            </button>
          ))}
          <span />
        </div>
        {[...byBrand.entries()].map(([b, list]) => (
          <div key={b}>
            <div className="m2-mbrand"><span className="m2-tick" style={{ height: 12, background: brandColor(b) }} />{brandLabel(b)}</div>
            {list.map((r) => (
              <MatrixRow
                key={r.id}
                r={r}
                catalog={catalogFor(apps, r.appGroup, r.service, r.env)}
                open={open === r.id}
                selected={sel.has(r.id)}
                other={!inScope(catId(r))}
                result={liveResults[r.id]}
                sup={supOf(r)}
                canAct={(k) => can(k, r)}
                onToggleOpen={() => setOpen((o) => (o === r.id ? null : r.id))}
                onToggleSel={() => toggleSel(r.id)}
                onAction={(k) => openSheet(k, [r])}
              />
            ))}
          </div>
        ))}
        {!shown.length && <div className="m2-fold" style={{ paddingLeft: 26 }}>None of your pinned apps are in this release.</div>}
        {scope === 'pinned' && others.length > 0 && (
          <button type="button" className="m2-foldbtn" onClick={() => setShowOthers((v) => !v)}>
            {showOthers ? 'Hide' : '+'} {others.length} other app{others.length > 1 ? 's' : ''}
          </button>
        )}
      </div>
      </div>

      {otaQ.data?.available && <HotPushLane ota={otaQ.data} members={members} onRelease={setHotRelease} />}

      {selected.length > 0 && (
        <div className="m2-abar" role="toolbar" aria-label="Actions for selected apps">
          <span style={{ whiteSpace: 'nowrap', fontWeight: 500, marginRight: 4 }}>{selected.length} selected</span>
          {BULK_KEYS.map((k) => [k, selected.filter((r) => eligibleFor(k, r)).length] as const)
            .filter(([, n]) => n > 0)
            .map(([k, n], i) => (
              <button key={k} type="button" className={`m2-btn sm ${i === 0 ? 'pri' : ''}`} onClick={() => openSheet(k, selected)}>{ACTIONS[k].verb} {n}</button>
            ))}
          <button type="button" className="m2-btn sm" onClick={() => setSel(new Set())}>Clear</button>
        </div>
      )}

      {hotBuild && otaQ.data && <HotPushBuildSheet groupId={groupId} ota={otaQ.data} onClose={() => setHotBuild(false)} />}
      {hotRelease && otaQ.data && (
        <HotPushReleaseSheet
          groupId={groupId}
          ota={otaQ.data}
          push={hotRelease}
          nativeVersion={members.find((m) => m.appGroup === hotRelease.appName && m.env === hotRelease.platform)?.new_version}
          onClose={() => setHotRelease(null)}
        />
      )}
      {sheet && (
        <ReviewSheet
          actionKey={sheet.key}
          releases={sheet.releases}
          excludedNote={sheet.note}
          onClose={() => setSheet(null)}
          onDone={(res) => { setResults((x) => ({ ...x, ...res })); setSheet(null); setSel(new Set()); }}
        />
      )}
    </div>
  );
}

function MatrixRow({
  r, catalog, open, selected, other, result, sup: supIn, canAct, onToggleOpen, onToggleSel, onAction,
}: {
  r: APRelease; catalog?: AppCatalogEntry; open: boolean; selected: boolean; other: boolean; result?: RowResult; sup?: Sup;
  canAct: (k: ActionKey) => boolean; onToggleOpen: () => void; onToggleSel: () => void; onAction: (k: ActionKey) => void;
}) {
  const stage = stageOfRelease(r);
  const cur = columnOf(stage, r);
  const broken = STAGE_META[stage].broken;
  const sup = supIn && ['ready', 'review', 'approved', 'live'].includes(stage) ? supIn : undefined;
  const n = sup ? null : nextAction(r, stage);
  const lcls = broken ? 'b' : stage === 'paused' || stage === 'review' ? 'o' : stage === 'rolling' ? 'g' : '';
  const label = `${roleLabel(r.service)} ${platLabel(r.env)}`;
  return (
    <>
      <div className={`m2-mrow ${selected ? 'sel' : ''} ${open ? 'open' : ''} ${other ? 'other' : ''}`} role="row">
        <span style={{ paddingLeft: 6 }}>
          <input type="checkbox" checked={selected} onChange={onToggleSel} aria-label={`Select ${appName(r.appGroup, r.service, r.env)}`} />
        </span>
        <div className="m2-appc">
          <button type="button" className="m2-appopen" onClick={onToggleOpen} aria-expanded={open}>
            <span className="m2-ell">{roleLabel(r.service)}</span>
            <PlatformTag platform={r.env} />
          </button>
          <PinButton appId={catalog?.id} label={appName(r.appGroup, r.service, r.env)} />
        </div>
        <span className="m2-stc"><Stamp version={r.new_version} code={r.release_context?.version_code} /></span>
        {COLUMNS.map((_, i) => {
          let cls = 'm2-cell m2-stc';
          if (i === 0) cls += ' first';
          if (i === COLUMNS.length - 1) cls += ' last';
          if (i < cur) cls += ' past';
          if (i === cur) cls += ' cur';
          return (
            <div key={i} className={cls} role="cell">
              {i === cur ? (
                <>
                  <span className="mk"><Glyph stage={stage} /></span>
                  <span className={`lb ${sup ? '' : lcls}`}>{sup ? `Superseded by ${sup.version}` : stageLabel(stage, r)}</span>
                </>
              ) : i > cur ? <span className="tk" /> : null}
            </div>
          );
        })}
        <div className="m2-actc">
          {result ? (
            <span className={`m2-res ${result.ok ? 'ok' : 'bad'}`} title={result.text}>{result.ok ? '✓' : '✕'} {result.text}</span>
          ) : n && canAct(n.key) ? (
            <>
              <span className="m2-due">{n.label}</span>
              <button type="button" className={`m2-btn sm m2-rowact ${['dispatch', 'submit', 'release'].includes(n.key) ? 'pri' : ''}`} onClick={() => onAction(n.key)}>{n.label}</button>
            </>
          ) : null}
        </div>
      </div>
      {open && <ExpandedRow r={r} stage={stage} catalog={catalog} sup={sup} canAct={canAct} onAction={onAction} />}
    </>
  );
}

function ExpandedRow({ r, stage, catalog, sup, canAct, onAction }: { r: APRelease; stage: Stage; catalog?: AppCatalogEntry; sup?: Sup; canAct: (k: ActionKey) => boolean; onAction: (k: ActionKey) => void }) {
  const isRelease = r.release_context?.build_type !== 'debug';
  const roQ = useMobileRollout(r.id, isRelease && ['review', 'rejected', 'approved', 'rolling', 'paused', 'ready'].includes(stage));
  const ro = roQ.data;
  const pct = ro?.rdRolloutPercent ?? r.release_context?.rollout_percent ?? null;
  const n = sup ? null : nextAction(r, stage);
  const runId = r.release_context?.external_run_id;
  const repo = catalog?.githubRepo;

  let left: React.ReactNode;
  if (sup) {
    left = (
      <>
        <h3>Superseded</h3>
        <div style={{ fontSize: 12.5 }}>
          Replaced by <Link className="m2-lnk" to={`/mobile-v2/releases/${sup.groupId}`}>{sup.name.includes(sup.version) ? sup.name : `${sup.name} · ${sup.version}`}</Link>. This build can't be released again.
        </div>
        <div className="m2-muted" style={{ fontSize: 12.5, marginTop: 6 }}>
          {stage !== 'live' ? 'It never reached users.' : sup.rest > 0 ? `Hot push still reaches the ${sup.rest}% of users on this build.` : 'Everyone has moved to the newer build.'}
        </div>
      </>
    );
  } else if (stage === 'rolling' || stage === 'paused') {
    left = (
      <>
        <h3>Rollout</h3>
        {isAndroid(r.env) && pct != null ? (
          <>
            <div className="m2-railro">
              <div className="bg" />
              <div className={`fill ${stage === 'paused' ? 'p' : ''}`} style={{ width: `${(Math.log10(Math.max(pct, 1)) / 2) * 100}%` }} />
              {RAMP_STEPS.map((s) => <span key={s} className="tkx" style={{ left: `${(Math.log10(s) / 2) * 100}%` }} />)}
            </div>
            <div className="m2-raillb">{RAMP_STEPS.map((s) => <span key={s} style={{ left: `${(Math.log10(s) / 2) * 100}%` }}>{s}</span>)}</div>
            <div className="m2-mono m2-muted" style={{ fontSize: 11.5, marginTop: 4 }}>{r.new_version} · {fmtPct(pct)}% │ the rest are on the previous version</div>
          </>
        ) : (
          <div style={{ fontSize: 12.5 }}>Apple phased release · 7 days, automatic updates only. People can still update by hand.</div>
        )}
        <div className="m2-faint" style={{ fontSize: 11.5, marginTop: 10 }}>Crash-free and ANR comparison will show here once the health feed is connected.</div>
      </>
    );
  } else if (stage === 'failed') {
    left = (
      <>
        <h3>Build failed</h3>
        <div style={{ fontSize: 12.5 }}>{r.release_context?.display_label ?? 'The CI run failed.'}</div>
        {runId && repo && <div style={{ marginTop: 8 }}><a className="m2-lnk" href={`https://github.com/${repo}/actions/runs/${runId}`} target="_blank" rel="noreferrer">Open CI run</a></div>}
      </>
    );
  } else if (stage === 'rejected') {
    left = (
      <>
        <h3>Rejected by the store</h3>
        <div className="m2-quote">{ro?.rdReviewRejectReason ?? 'No reason was recorded.'}</div>
      </>
    );
  } else if (stage === 'review') {
    left = (
      <>
        <h3>{isAndroid(r.env) ? 'Play review' : 'App Store review'}</h3>
        <div style={{ fontSize: 12.5 }}>
          {isAndroid(r.env) ? 'Google does not report review status. Confirm once Play Console shows it approved.' : `In review${ro?.rdReviewSubmittedAt ? ` since ${new Date(ro.rdReviewSubmittedAt).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}` : ''}. Usually 24 to 48 h.`}
        </div>
      </>
    );
  } else if (stage === 'ready') {
    left = (
      <>
        <h3>On internal testing</h3>
        <div style={{ fontSize: 12.5 }}>{ro?.rdPromotable === false ? `Can't be submitted: ${ro.rdPromoteBlock ?? 'blocked'}${ro.rdPromoteBlockVersion ? ` (${ro.rdPromoteBlockVersion})` : ''}.` : 'Submitting sends it to production review.'}</div>
      </>
    );
  } else {
    left = (
      <>
        <h3>{STAGE_META[stage].label}</h3>
        <div className="m2-muted" style={{ fontSize: 12.5 }}>{r.release_context?.display_label ?? ''}</div>
      </>
    );
  }

  return (
    <div className="m2-exp">
      <div>
        {left}
        <div className="m2-acts">
          {n && canAct(n.key) && <button type="button" className="m2-btn sm pri" onClick={() => onAction(n.key)}>{n.label}</button>}
          {stage === 'rolling' && canAct('pause') && <button type="button" className="m2-btn sm" onClick={() => onAction('pause')}>Pause</button>}
          {stage === 'rolling' && !isAndroid(r.env) && canAct('releaseAll') && <button type="button" className="m2-btn sm" onClick={() => onAction('releaseAll')}>Release to everyone</button>}
        </div>
      </div>
      <div>
        <h3>Details</h3>
        <dl className="m2-facts">
          <dt>Version</dt><dd><Stamp version={r.new_version} code={r.release_context?.version_code} /></dd>
          {r.sourceRef && <><dt>Branch</dt><dd className="m2-mono">{r.sourceRef}{r.commitSha ? ` @ ${r.commitSha.slice(0, 7)}` : ''}</dd></>}
          {runId && <><dt>CI run</dt><dd className="m2-mono">{repo ? <a className="m2-lnk" href={`https://github.com/${repo}/actions/runs/${runId}`} target="_blank" rel="noreferrer">#{runId}</a> : `#${runId}`}</dd></>}
          {ro?.rdStoreTrack && <><dt>Store track</dt><dd>{ro.rdStoreTrack}</dd></>}
          <dt>Owner</dt><dd>{r.release_manager || '—'}</dd>
          <dt>v1 page</dt><dd><a className="m2-lnk" href={`/mobile/releases/${r.id}`}>Open in v1</a></dd>
        </dl>
      </div>
    </div>
  );
}
