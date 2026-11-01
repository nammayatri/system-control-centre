import { useState } from 'react';
import { Link } from 'react-router-dom';
import type { AppCatalogEntry } from '../../releases/types';
import type { Stage } from '../model';
import { STAGE_META, STAGE_ORDER, brandColor, brandLabel, fmtPct, groupName, platLabel, roleLabel } from '../model';
import { usePins } from '../pins';
import { useFleet } from '../data';
import type { InFlight, Live } from '../data';
import { Glyph, PinButton, PinIcon, PinsSheet, Stamp } from '../ui';

const NEEDS: { stage: Stage; title: string }[] = [
  { stage: 'failed', title: 'Build failed' },
  { stage: 'rejected', title: 'Rejected by the store' },
  { stage: 'paused', title: 'Rollout paused' },
  { stage: 'approved', title: 'Approved, ready to release' },
  { stage: 'ready', title: 'Ready to submit' },
  { stage: 'draft', title: 'Draft waiting for you' },
];

export default function Home() {
  const fleet = useFleet();
  const { pins } = usePins();
  const [pinsOpen, setPinsOpen] = useState(false);
  const { apps, inFlight, monitor } = fleet;

  const pinned = apps.filter((a) => pins.has(a.id));
  const needs = pinned
    .map((a) => ({ a, f: inFlight.get(a.id) }))
    .filter((x): x is { a: AppCatalogEntry; f: InFlight } => !!x.f && NEEDS.some((n) => n.stage === x.f!.stage))
    .sort((x, y) => NEEDS.findIndex((n) => n.stage === x.f.stage) - NEEDS.findIndex((n) => n.stage === y.f.stage));
  const order = (a: AppCatalogEntry) => { const s = inFlight.get(a.id)?.stage; return s ? STAGE_ORDER.indexOf(s) : 99; };

  if (fleet.appsLoading) return <div className="m2-fold">Loading apps…</div>;

  if (!pinned.length) {
    return (
      <div className="m2-page">
        <div className="m2-ph"><div><h1 className="m2-h1">Home</h1><div className="m2-lede">Pin the apps you look after. Home shows how they're doing.</div></div></div>
        <div className="m2-setup">
          <div style={{ fontWeight: 600 }}>Pick your apps</div>
          <div className="m2-muted">You can change this any time.</div>
          <div><button type="button" className="m2-btn pri" onClick={() => setPinsOpen(true)}>Choose apps to pin</button></div>
        </div>
        {pinsOpen && <PinsSheet apps={apps} onClose={() => setPinsOpen(false)} />}
      </div>
    );
  }

  return (
    <div className="m2-page">
      <div className="m2-ph">
        <div>
          <h1 className="m2-h1">Home</h1>
          <div className="m2-lede">{pinned.length} pinned apps · {needs.length ? `${needs.length} need${needs.length === 1 ? 's' : ''} you` : 'nothing needs you'}</div>
        </div>
        <div className="m2-hctl">
          <button type="button" className="m2-btn quiet" onClick={() => setPinsOpen(true)}><PinIcon />Manage pins</button>
          <Link className="m2-btn pri" to="/mobile-v2/new">New release</Link>
        </div>
      </div>

      {needs.length > 0 && (
        <section className="m2-needs" aria-label="Needs you">
          <div className="m2-secl" style={{ paddingBottom: 4 }}><h2 className="m2-h2">Needs you</h2></div>
          {needs.slice(0, 5).map(({ a, f }) => (
            <div key={a.id} className="m2-nrow">
              <Glyph stage={f.stage} />
              <span className="t">{NEEDS.find((n) => n.stage === f.stage)?.title}</span>
              <span className="m2-muted m2-ell">
                {brandLabel(a.name)} {roleLabel(a.surface)} {platLabel(a.platform)} {f.m.version && <Stamp version={f.m.version} code={f.m.versionCode} />}
              </span>
              <Link className="m2-btn sm" to={`/mobile-v2/releases/${f.g.groupId}`}>Open</Link>
            </div>
          ))}
          {needs.length > 5 && <div className="m2-fold" style={{ paddingTop: 8 }}>+{needs.length - 5} more · <Link className="m2-lnk" to="/mobile-v2/releases">see releases</Link></div>}
        </section>
      )}

      <section style={{ display: 'grid', gap: 8 }}>
        <div className="m2-secl"><h2 className="m2-h2">Your pinned apps</h2><span className="m2-colh">what users have right now</span></div>
        <div className="m2-htable">
          <div className="m2-hrow" style={{ padding: '8px 0' }}>
            <span className="m2-colh">App</span><span className="m2-colh">Users have</span><span className="m2-colh">Next</span><span />
          </div>
          {[...pinned].sort((x, y) => order(x) - order(y)).map((a) => <AppRow key={a.id} a={a} live={fleet.liveOf(a)} next={inFlight.get(a.id)} />)}
        </div>
        {monitor && !monitor.available && <div className="m2-faint" style={{ fontSize: 12 }}>Live store data isn't available on this deployment ({monitor.reason ?? 'debug build'}).</div>}
      </section>

      {pinsOpen && <PinsSheet apps={apps} onClose={() => setPinsOpen(false)} />}
    </div>
  );
}

function AppRow({ a, live, next }: { a: AppCatalogEntry; live: Live; next?: InFlight }) {
  const { version, code, pct, paused } = live;
  const rolling = pct != null && pct < 100;
  return (
    <div className="m2-hrow">
      <div className="m2-happ">
        <span className="m2-tick" style={{ height: 28, background: brandColor(a.name) }} />
        <div style={{ minWidth: 0 }}>
          <div style={{ fontWeight: 500 }}>{brandLabel(a.name)}</div>
          <div className="m2-faint" style={{ fontSize: 12 }}>{roleLabel(a.surface)} · {platLabel(a.platform)}</div>
        </div>
      </div>
      <div style={{ display: 'grid', gap: 6, minWidth: 0 }}>
        <div style={{ display: 'flex', gap: 8, alignItems: 'baseline', flexWrap: 'wrap' }}>
          <Stamp version={version} code={code} />
          {rolling ? (
            <span className={`m2-mono ${paused ? 'm2-ochre' : 'm2-go'}`} style={{ fontSize: 12 }}>{paused ? 'paused ' : ''}{fmtPct(pct!)}%</span>
          ) : version ? <span className="m2-faint" style={{ fontSize: 12 }}>everyone</span> : null}
        </div>
        {rolling && (
          <div className="m2-vsplit">
            <i style={{ flex: pct!, background: paused ? 'var(--m2-ochre)' : 'var(--m2-go)' }} />
            <i style={{ flex: 100 - pct!, background: 'var(--m2-line2)' }} />
          </div>
        )}
      </div>
      <div>
        {next ? (
          <Link to={`/mobile-v2/releases/${next.g.groupId}`} style={{ display: 'inline-flex', gap: 6, alignItems: 'center', color: 'var(--m2-fg)', textDecoration: 'none' }}>
            <Glyph stage={next.stage} size={12} />
            {next.m.version && <span className="m2-mono">{next.m.version}</span>}
            <span className="m2-muted">{STAGE_META[next.stage].label.toLowerCase()}</span>
            <span className="m2-faint">· {groupName(next.g.label, next.g.createdAt, next.m.version)}</span>
          </Link>
        ) : <span className="m2-faint" style={{ fontSize: 12 }}>nothing in flight</span>}
      </div>
      <PinButton appId={a.id} label={`${brandLabel(a.name)} ${roleLabel(a.surface)} ${platLabel(a.platform)}`} />
    </div>
  );
}
