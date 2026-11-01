import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { fetchFleetActivity } from '../../releases/api';
import { brandLabel, platLabel } from '../model';
import { usePins } from '../pins';
import { useFleet } from '../data';
import { ScopeToggle } from '../ui';

const DAYS = [1, 7, 30];
const humanAction = (a: string) => a.toLowerCase().replace(/_/g, ' ').replace(/^\w/, (c) => c.toUpperCase());

/** Everything that happened: people, CI and the store sync, newest first. */
export default function Log() {
  const [days, setDays] = useState(7);
  const { inScope, scope } = usePins();
  const { apps } = useFleet();
  const q = useQuery({
    queryKey: ['mr2-activity', days],
    queryFn: () => fetchFleetActivity({ days, limit: 200 }),
    refetchInterval: 60_000,
  });
  // Activity rows carry app name + platform (no surface): an app matches if any
  // catalog entry with that name/platform is in scope.
  const rows = (q.data?.rows ?? []).filter(
    (r) => scope === 'all' || !r.app || apps.some((a) => a.name === r.app && (!r.platform || a.platform === r.platform) && inScope(a.id)),
  );
  return (
    <div className="m2-page">
      <div className="m2-ph">
        <div>
          <h1 className="m2-h1">Log</h1>
          <div className="m2-lede">Every action by people, CI and the store sync.</div>
        </div>
        <div className="m2-hctl">
          <div className="m2-seg" role="group" aria-label="Time range">
            {DAYS.map((d) => (
              <button key={d} type="button" aria-pressed={days === d} onClick={() => setDays(d)}>{d === 1 ? '24 h' : `${d} days`}</button>
            ))}
          </div>
          <ScopeToggle />
        </div>
      </div>
      {q.isLoading ? <div className="m2-fold">Loading…</div> : q.isError ? <div className="m2-fold">Couldn't load the log.</div> : (
        <div className="m2-mxwrap">
          <div className="m2-log" style={{ minWidth: 820 }}>
            {rows.map((r) => (
              <div key={r.id} className="m2-logrow">
                <span className="m2-mono m2-faint" style={{ fontSize: 11.5 }}>
                  {new Date(r.at).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}
                </span>
                <span className="m2-muted m2-ell">{r.actor || 'System'}</span>
                <span className={`m2-ell ${/fail|reject|error|abort/i.test(r.action) ? 'm2-brick' : ''}`}>{humanAction(r.action)}{r.version ? <span className="m2-faint"> · {r.version}</span> : null}</span>
                <span className="m2-ell m2-muted" style={{ textAlign: 'right' }}>
                  {r.app ? `${brandLabel(r.app)}${r.platform ? ` ${platLabel(r.platform)}` : ''}` : ''}
                  {r.groupId && <> · <Link className="m2-lnk" to={`/mobile-v2/releases/${r.groupId}`}>release</Link></>}
                </span>
              </div>
            ))}
            {!rows.length && <div className="m2-fold">Nothing in this window.</div>}
          </div>
        </div>
      )}
    </div>
  );
}
