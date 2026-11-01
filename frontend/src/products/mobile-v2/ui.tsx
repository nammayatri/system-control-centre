import { useEffect, useState } from 'react';
import type { ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { cn } from '../../lib/utils';
import { useMr2Theme } from './theme';
import type { AppCatalogEntry } from '../releases/types';
import type { Stage } from './model';
import { appOrder, brandColor, brandKey, brandLabel, platLabel, roleLabel } from './model';
import { usePins } from './pins';
import type { Scope } from './pins';

/** Status glyph: shape + color, never color alone. */
export function Glyph({ stage, size = 14 }: { stage: Stage; size?: number }) {
  const p = { className: 'm2-g', width: size, height: size, viewBox: '0 0 14 14', 'aria-hidden': true } as const;
  switch (stage) {
    case 'draft':
      return <svg {...p}><circle cx="7" cy="7" r="5.25" fill="none" stroke="var(--m2-line2)" strokeWidth="1.5" strokeDasharray="2 2" /></svg>;
    case 'building':
      return (
        <svg {...p}>
          <circle cx="7" cy="7" r="5.25" fill="none" stroke="var(--m2-line2)" strokeWidth="1.5" />
          <path className="m2-spin" d="M7 1.75a5.25 5.25 0 0 1 5.25 5.25" fill="none" stroke="var(--m2-muted)" strokeWidth="1.5" strokeLinecap="round" />
        </svg>
      );
    case 'ready':
    case 'distributed':
      return <svg {...p}><rect x="2.25" y="2.25" width="9.5" height="9.5" rx="1" fill="none" stroke="var(--m2-fg)" strokeWidth="1.5" /></svg>;
    case 'review':
      return (
        <svg {...p}>
          <circle cx="7" cy="7" r="5.25" fill="none" stroke="var(--m2-ochre)" strokeWidth="1.5" />
          <path d="M7 1.75a5.25 5.25 0 0 1 0 10.5z" fill="var(--m2-ochre)" />
        </svg>
      );
    case 'approved':
      return (
        <svg {...p}>
          <circle cx="7" cy="7" r="6" fill="var(--m2-fg)" />
          <path d="M4.4 7.2l1.8 1.8 3.5-3.6" fill="none" stroke="var(--m2-bg)" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      );
    case 'rolling':
      return (
        <svg {...p}>
          <circle cx="7" cy="7" r="6" fill="var(--m2-go-wash)" stroke="var(--m2-go)" strokeWidth="1.5" />
          <circle cx="7" cy="7" r="2.5" fill="var(--m2-go)" />
        </svg>
      );
    case 'paused':
      return (
        <svg {...p}>
          <rect x="3" y="2.5" width="2.6" height="9" rx=".6" fill="var(--m2-ochre)" />
          <rect x="8.4" y="2.5" width="2.6" height="9" rx=".6" fill="var(--m2-ochre)" />
        </svg>
      );
    case 'failed':
    case 'rejected':
      return (
        <svg {...p}>
          <path d="M7 1l6 6-6 6-6-6z" fill="var(--m2-brick)" />
          <path d="M7 4.3v3.3" stroke="#fff" strokeWidth="1.4" strokeLinecap="round" />
          <circle cx="7" cy="9.7" r=".8" fill="#fff" />
        </svg>
      );
    case 'aborted':
      return <svg {...p}><path d="M3.5 3.5l7 7M10.5 3.5l-7 7" stroke="var(--m2-faint)" strokeWidth="1.5" strokeLinecap="round" /></svg>;
    case 'superseded':
      return <svg {...p}><circle cx="7" cy="7" r="4" fill="none" stroke="var(--m2-faint)" strokeWidth="1.5" /></svg>;
    default:
      return <svg {...p}><circle cx="7" cy="7" r="3" fill="var(--m2-faint)" /></svg>;
  }
}

export function Stamp({ version, code }: { version?: string | null; code?: number | null }) {
  if (!version) return <span className="m2-faint">—</span>;
  return (
    <span className="m2-stamp">
      {version}
      {code != null && <i> ({code})</i>}
    </span>
  );
}

export const PlatformTag = ({ platform }: { platform: string }) => <span className="m2-tag">{platform === 'ios' ? 'iOS' : 'AND'}</span>;

const PIN_PATH = 'M9.8 2.2l4 4-2 .6-2.6 2.6.3 2.8-1 1-2.4-2.4L3 14l-1-1 3.2-3.1L2.8 7.5l1-1 2.8.3 2.6-2.6z';
export function PinIcon({ size = 14 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinejoin="round" aria-hidden="true">
      <path d={PIN_PATH} />
    </svg>
  );
}

export function PinButton({ appId, label }: { appId?: number; label: string }) {
  const { pins, toggle } = usePins();
  if (appId == null) return null;
  const on = pins.has(appId);
  return (
    <button type="button" className="m2-pin" aria-pressed={on} aria-label={`${on ? 'Unpin' : 'Pin'} ${label}`} title={on ? 'Unpin' : 'Pin'} onClick={() => toggle(appId)}>
      <PinIcon />
    </button>
  );
}

export function ScopeToggle() {
  const { pins, scope, setScope } = usePins();
  const opt = (s: Scope, l: string) => (
    <button type="button" aria-pressed={scope === s} onClick={() => setScope(s)}>
      {l}
    </button>
  );
  return (
    <div className="m2-seg" role="group" aria-label="Which apps to show">
      {opt('pinned', `Pinned · ${pins.size}`)}
      {opt('all', 'All apps')}
    </div>
  );
}

/** Overlay root: portals to <body> (so the scrim covers the app sidebar too)
 * while keeping v2's theme tokens. */
export function Layer({ children, onClose }: { children: ReactNode; onClose?: () => void }) {
  const { isDark } = useMr2Theme();
  useEffect(() => {
    if (!onClose) return;
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [onClose]);
  return createPortal(<div className={cn('mr2 mr2-layer', isDark && 'mr2-dark')}>{children}</div>, document.body);
}

/** Right-side panel listing every app with a pin switch. */
export function PinsSheet({ apps, onClose }: { apps: AppCatalogEntry[]; onClose: () => void }) {
  const { pins, toggle, clear } = usePins();
  const [q, setQ] = useState('');
  const match = (a: AppCatalogEntry) => !q || `${brandLabel(a.name)} ${roleLabel(a.surface)} ${platLabel(a.platform)}`.toLowerCase().includes(q.toLowerCase());
  const brands = [...new Set(apps.map((a) => brandKey(a.name)))].sort();
  return (
    <Layer onClose={onClose}>
      <div className="m2-scrim" onClick={onClose} />
      <aside className="m2-sheet" role="dialog" aria-modal="true" aria-labelledby="m2-pins-t">
        <div className="m2-shh">
          <div>
            <h3 id="m2-pins-t">Pinned apps</h3>
            <div className="m2-muted" style={{ marginTop: 2 }}>{pins.size} pinned</div>
          </div>
          <button type="button" className="m2-btn quiet sm" onClick={onClose}>Done</button>
        </div>
        <div className="m2-shb">
          <input className="m2-inp" placeholder="Search apps" value={q} onChange={(e) => setQ(e.target.value)} autoFocus />
          {brands.map((b) => {
            const list = apps.filter((a) => brandKey(a.name) === b && match(a)).sort((x, y) => appOrder(x.surface, x.platform) - appOrder(y.surface, y.platform));
            if (!list.length) return null;
            return (
              <div key={b}>
                <div className="m2-mbrand" style={{ padding: '4px 0 6px' }}>
                  <span className="m2-tick" style={{ height: 12, background: brandColor(b) }} />
                  {brandLabel(b)}
                </div>
                {list.map((a) => (
                  <label key={a.id} className="m2-pinrow">
                    <span>{roleLabel(a.surface)} · {platLabel(a.platform)}</span>
                    <span className="m2-faint m2-mono" style={{ fontSize: 11.5 }}>{a.latestProdBuild?.version ?? ''}</span>
                    <input type="checkbox" className="m2-sw" checked={pins.has(a.id)} onChange={() => toggle(a.id)} aria-label={`Pin ${brandLabel(a.name)} ${roleLabel(a.surface)} ${platLabel(a.platform)}`} />
                  </label>
                ))}
              </div>
            );
          })}
        </div>
        <div className="m2-shf">
          <button type="button" className="m2-lnk" style={{ marginRight: 'auto' }} onClick={clear}>Unpin all</button>
          <button type="button" className="m2-btn pri" onClick={onClose}>Done</button>
        </div>
      </aside>
    </Layer>
  );
}
