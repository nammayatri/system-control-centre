import { useEffect, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import type { AppCatalogEntry } from '../../releases/types';
import type { TrackCell } from '../../releases/api';
import { STAGE_META, brandColor, brandKey, brandLabel, fmtPct, groupName, platLabel, roleLabel } from '../model';
import { usePins } from '../pins';
import { useFleet } from '../data';
import { Glyph, PinButton, ScopeToggle, Stamp } from '../ui';

const COLS: { surface: 'customer' | 'driver'; platform: 'android' | 'ios'; label: string }[] = [
  { surface: 'customer', platform: 'android', label: 'Customer · Android' },
  { surface: 'customer', platform: 'ios', label: 'Customer · iOS' },
  { surface: 'driver', platform: 'android', label: 'Driver · Android' },
  { surface: 'driver', platform: 'ios', label: 'Driver · iOS' },
];

export default function Apps() {
  const fleet = useFleet();
  const { inScope, scope } = usePins();
  const [sel, setSel] = useState<number | null>(null);
  const brands = [...new Set(fleet.apps.map((a) => brandKey(a.name)))]
    .filter((b) => fleet.apps.some((a) => brandKey(a.name) === b && inScope(a.id)))
    .sort();
  const find = (b: string, surface: string, platform: string) => fleet.apps.find((a) => brandKey(a.name) === b && a.surface === surface && a.platform === platform);
  const selected = fleet.apps.find((a) => a.id === sel);

  return (
    <div className="m2-page">
      <div className="m2-ph">
        <div>
          <h1 className="m2-h1">Apps</h1>
          <div className="m2-lede">What users have right now, and what's next. Pin any app to follow it on Home.</div>
        </div>
        <div className="m2-hctl"><ScopeToggle /></div>
      </div>

      {fleet.appsLoading ? <div className="m2-fold">Loading apps…</div> : !brands.length ? (
        <div className="m2-fold">{scope === 'pinned' ? 'No pinned apps yet. Switch to All apps to pin some.' : 'No apps in the catalog.'}</div>
      ) : (
        <div className="m2-mxwrap">
          <table className="m2-fleet">
            <thead>
              <tr>
                <th>Brand</th>
                {COLS.map((c) => <th key={c.label}>{c.label}</th>)}
              </tr>
            </thead>
            <tbody>
              {brands.map((b) => (
                <tr key={b}>
                  <td>
                    <div className="m2-happ">
                      <span className="m2-tick" style={{ height: 28, background: brandColor(b) }} />
                      <span style={{ fontWeight: 500 }}>{brandLabel(b)}</span>
                    </div>
                  </td>
                  {COLS.map((c) => {
                    const a = find(b, c.surface, c.platform);
                    return (
                      <td key={c.label}>
                        {a ? <FleetCell fleet={fleet} pinned={inScope(a.id)} a={a} selected={sel === a.id} onSelect={() => setSel(sel === a.id ? null : a.id)} /> : <span className="m2-faint">—</span>}
                      </td>
                    );
                  })}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {selected && <AppDetail fleet={fleet} a={selected} onClose={() => setSel(null)} />}
    </div>
  );
}

type Fleet = ReturnType<typeof useFleet>;

function FleetCell({ fleet, pinned, a, selected, onSelect }: { fleet: Fleet; pinned: boolean; a: AppCatalogEntry; selected: boolean; onSelect: () => void }) {
  const live = fleet.liveOf(a);
  const next = fleet.inFlight.get(a.id);
  const rolling = live.pct != null && live.pct < 100;
  const name = `${brandLabel(a.name)} ${roleLabel(a.surface)} ${platLabel(a.platform)}`;
  return (
    <div className="m2-fwrap">
      <button type="button" className="m2-fcell" aria-pressed={selected} onClick={onSelect}>
        {pinned ? (
          <>
            <span style={{ display: 'flex', gap: 6, alignItems: 'baseline', minWidth: 0 }}>
              <span className="m2-mono" style={{ fontSize: 12.5 }}>{live.version ?? '—'}</span>
              {rolling && <span className={`m2-mono ${live.paused ? 'm2-ochre' : 'm2-go'}`} style={{ fontSize: 11.5 }}>{live.paused ? 'paused ' : ''}{fmtPct(live.pct!)}%</span>}
            </span>
            {live.version && <span className="m2-vsplit" style={{ maxWidth: 150 }}>
              {rolling ? (
                <>
                  <i style={{ flex: live.pct!, background: live.paused ? 'var(--m2-ochre)' : 'var(--m2-go)' }} />
                  <i style={{ flex: 100 - live.pct!, background: 'var(--m2-line2)' }} />
                </>
              ) : <i style={{ flex: 1, background: 'var(--m2-line2)' }} />}
            </span>}
            <span className="m2-fl">
              {next ? <><Glyph stage={next.stage} size={12} />{next.m.version && <span className="m2-mono">{next.m.version}</span>} <span className="m2-ell">{STAGE_META[next.stage].label.toLowerCase()}</span></> : <span className="m2-faint">nothing in flight</span>}
            </span>
          </>
        ) : <span className="m2-faint">not pinned</span>}
      </button>
      <span className="m2-fpin"><PinButton appId={a.id} label={name} /></span>
    </div>
  );
}

function AppDetail({ fleet, a, onClose }: { fleet: Fleet; a: AppCatalogEntry; onClose: () => void }) {
  const ref = useRef<HTMLElement>(null);
  // The grid is long; bring the panel into view whenever a different app is picked.
  useEffect(() => { ref.current?.scrollIntoView({ behavior: 'smooth', block: 'nearest' }); }, [a.id]);
  const block = fleet.blockFor(a);
  const history = fleet.historyOf(a);
  const cell = (label: string, t: TrackCell | null | undefined) =>
    t?.version ? (
      <>
        <dt>{label}</dt>
        <dd style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
          <Stamp version={t.version} code={t.buildCode} />
          {t.displayLabel ?? t.status ?? ''}
          {t.rolloutPercent != null && t.rolloutPercent < 100 ? ` · ${fmtPct(t.rolloutPercent)}%` : ''}
        </dd>
      </>
    ) : null;
  return (
    <section ref={ref} className="m2-panel" aria-label="App detail" style={{ scrollMarginBottom: 24 }}>
      <div className="m2-ph">
        <div>
          <h2 className="m2-h1" style={{ fontSize: 16 }}>{brandLabel(a.name)} {roleLabel(a.surface)} {platLabel(a.platform)}</h2>
          <div className="m2-lede">{a.packageName ?? ''}{a.airborneAppRef ? ' · hot push supported' : ' · no hot push'}</div>
        </div>
        <div className="m2-hctl">
          <PinButton appId={a.id} label={a.name} />
          <button type="button" className="m2-btn quiet sm" onClick={onClose}>Close</button>
        </div>
      </div>
      <div className="m2-twocol">
        <div>
          <h3 className="m2-h3">Store</h3>
          <dl className="m2-facts">
            {cell('Production', block?.production)}
            {cell('In review', block?.incoming)}
            {cell(a.platform === 'ios' ? 'TestFlight' : 'Internal', a.platform === 'ios' ? block?.testflight : block?.internal)}
            {!block && <><dt>Store</dt><dd className="m2-faint">No store data yet</dd></>}
            {block?.syncStatus && !block.syncStatus.ok && <><dt>Last sync</dt><dd className="m2-ochre">{block.syncStatus.message ?? block.syncStatus.code}</dd></>}
          </dl>
        </div>
        <div>
          <h3 className="m2-h3">Releases</h3>
          {history.length ? (
            <div className="m2-list">
              {history.slice(0, 8).map(({ g, m, stage }) => (
                <Link key={m.releaseId} to={`/mobile-v2/releases/${g.groupId}`} className="m2-listrow">
                  <Glyph stage={stage} size={12} />
                  <span className="m2-ell">{groupName(g.label, g.createdAt, m.version)}</span>
                  <span className="m2-muted" style={{ fontSize: 12, whiteSpace: 'nowrap' }}>{STAGE_META[stage].label}</span>
                </Link>
              ))}
            </div>
          ) : <div className="m2-faint" style={{ fontSize: 12.5 }}>No releases through this dashboard yet.</div>}
        </div>
      </div>
    </section>
  );
}

