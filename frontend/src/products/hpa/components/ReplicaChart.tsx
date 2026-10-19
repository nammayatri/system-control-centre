import React, { useMemo, useRef, useState } from 'react';
import { cn } from '../../../lib/utils';
import { fmtClock, fmtDay, fmtTimeFull } from '../format';
import type { Apply, ScaleEvent, SeriesPoint } from '../types';

// Palette validated with the dataviz validator (light surface): blue / orange pass the
// CVD + normal-vision separation checks. "Desired" is also dashed, so identity is never colour-alone.
const CURRENT = '#2a78d6';
const DESIRED = '#eb6834';
const GRID = '#e4e4e7';
const INK = '#52514e';

const W = 900;
const M = { l: 44, r: 14, t: 10, b: 22 };

function niceMax(v: number): number {
  if (v <= 5) return 5;
  const p = Math.pow(10, Math.floor(Math.log10(v)));
  const n = v / p;
  return (n <= 1 ? 1 : n <= 2 ? 2 : n <= 5 ? 5 : 10) * p;
}

function yTicks(max: number): number[] {
  const step = max / 4;
  return [0, 1, 2, 3, 4].map((i) => Math.round(step * i * 10) / 10);
}

interface Props {
  points: SeriesPoint[];
  from: string;
  to: string;
  applies?: Apply[];
  scaleEvents?: ScaleEvent[];
  refreshing?: boolean;
}

/**
 * Replicas (current vs desired, with the min–max band) over time, and CPU
 * utilisation under it on a shared time axis. Two separate panels, never a
 * dual axis. Hover shows every value at the nearest sample; the table view
 * exposes the same numbers without hovering.
 */
export default function ReplicaChart({ points, from, to, applies = [], scaleEvents = [], refreshing }: Props) {
  const wrap = useRef<HTMLDivElement>(null);
  const [hover, setHover] = useState<number | null>(null);
  const [table, setTable] = useState(false);

  const t0 = new Date(from).getTime();
  const t1 = new Date(to).getTime();
  const x = (ms: number) => M.l + ((ms - t0) / Math.max(1, t1 - t0)) * (W - M.l - M.r);
  const inRange = (ms: number) => ms >= t0 && ms <= t1;

  // Points can lack a field (a metric that was not scraped at that moment). Gaps stay gaps; the limits carry forward.
  const pts = useMemo(() => {
    let lastMin = 0;
    let lastMax = 0;
    return points
      .map((p) => ({ ...p, ms: new Date(p.ts).getTime() }))
      .sort((a, b) => a.ms - b.ms)
      .filter((p) => p.current != null)
      .map((p) => {
        lastMin = p.min ?? lastMin;
        lastMax = p.max ?? lastMax;
        return { ...p, current: p.current as number, desired: p.desired ?? (p.current as number), min: lastMin, max: lastMax };
      });
  }, [points]);

  const repMax = niceMax(Math.max(1, ...pts.map((p) => Math.max(p.max, p.current, p.desired))));
  const hRep = 230;
  const hCpu = 110;
  const yRep = (v: number) => M.t + (1 - v / repMax) * (hRep - M.t - M.b);
  const cpuMax = Math.max(100, niceMax(Math.max(0, ...pts.map((p) => p.cpuPct ?? 0))));
  const yCpu = (v: number) => M.t + (1 - v / cpuMax) * (hCpu - M.t - M.b);

  const line = (f: (p: (typeof pts)[number]) => number | null, y: (v: number) => number) => {
    let d = '';
    let pen = false;
    for (const p of pts) {
      const v = f(p);
      if (v == null) { pen = false; continue; }
      d += `${pen ? 'L' : 'M'}${x(p.ms).toFixed(1)},${y(v).toFixed(1)}`;
      pen = true;
    }
    return d;
  };

  // min–max band as a step area
  const band = useMemo(() => {
    if (pts.length === 0) return '';
    const up = pts.map((p, i) => `${i ? 'L' : 'M'}${x(p.ms)},${yRep(p.max)}${i < pts.length - 1 ? `L${x(pts[i + 1].ms)},${yRep(p.max)}` : ''}`).join('');
    const down = [...pts].reverse().map((p, i, arr) => `L${x(p.ms)},${yRep(p.min)}${i < arr.length - 1 ? `L${x(arr[i + 1].ms)},${yRep(p.min)}` : ''}`).join('');
    return `${up}${down}Z`;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pts, t0, t1, repMax]);

  const span = t1 - t0;
  const xTicks = Array.from({ length: 6 }, (_, i) => t0 + (span * i) / 5);
  const label = (ms: number) => (span <= 36 * 3600 * 1000 ? fmtClock(new Date(ms).toISOString()) : fmtDay(new Date(ms).toISOString()));

  const onMove = (e: React.PointerEvent<SVGRectElement>) => {
    const box = e.currentTarget.getBoundingClientRect();
    const ms = t0 + ((e.clientX - box.left) / box.width) * span;
    let best = 0;
    for (let i = 1; i < pts.length; i++) if (Math.abs(pts[i].ms - ms) < Math.abs(pts[best].ms - ms)) best = i;
    setHover(pts.length ? best : null);
  };

  const windows = applies
    .map((a) => {
      const s = new Date(a.windowStart ?? a.createdAt).getTime();
      const live = !['RESTORED', 'ROLLED_BACK', 'FAILED', 'SKIPPED'].includes(a.status);
      const e = a.windowEnd ? new Date(a.windowEnd).getTime() : a.finishedAt ? new Date(a.finishedAt).getTime() : live ? t1 : s;
      return { a, s: Math.max(s, t0), e: Math.min(Math.max(e, s), t1) };
    })
    .filter((w) => w.e > w.s && !['SKIPPED', 'PENDING'].includes(w.a.status));

  const hp = hover != null ? pts[hover] : null;
  const eventMarks = scaleEvents
    .filter((ev) => ev.newSize != null && inRange(new Date(ev.lastTs).getTime()))
    .map((ev) => {
      const ms = new Date(ev.lastTs).getTime();
      const before = [...pts].reverse().find((p) => p.ms < ms && p.hpaName === ev.hpaName);
      return { ev, ms, up: before ? (ev.newSize as number) > before.current : null };
    });

  if (pts.length === 0) {
    return (
      <div className="rounded-lg border border-dashed border-zinc-300 bg-zinc-50 px-4 py-10 text-center text-sm text-zinc-500">
        No history returned for this range.
      </div>
    );
  }

  return (
    <div ref={wrap} className={cn('relative transition-opacity', refreshing && 'opacity-70')}>
      <div className="mb-2 flex flex-wrap items-center gap-x-5 gap-y-1 text-xs text-zinc-600">
        <Legend color={CURRENT} label="Current replicas" />
        <Legend color={DESIRED} label="Desired (HPA target)" dashed />
        <span className="inline-flex items-center gap-1.5"><span className="h-2.5 w-4 rounded-sm bg-zinc-200" />Min – max band</span>
        <span className="inline-flex items-center gap-1.5"><span className="h-2.5 w-4 rounded-sm" style={{ background: `${CURRENT}22`, border: `1px dashed ${CURRENT}` }} />Scheduled change active</span>
        <span className="inline-flex items-center gap-1.5">▲▼ Scale events</span>
        <button type="button" onClick={() => setTable((t) => !t)} className="ml-auto cursor-pointer rounded border border-zinc-300 px-2 py-0.5 text-zinc-600 hover:bg-zinc-50">
          {table ? 'Chart' : 'Table'}
        </button>
      </div>

      {table ? (
        <div className="max-h-72 overflow-auto rounded-lg border border-zinc-200">
          <table className="w-full text-xs">
            <thead className="sticky top-0 bg-zinc-50 text-left text-zinc-500">
              <tr><th className="px-3 py-1.5">Time</th><th>HPA</th><th>Current</th><th>Desired</th><th>Min</th><th>Max</th><th>CPU %</th></tr>
            </thead>
            <tbody>
              {[...pts].reverse().slice(0, 200).map((p) => (
                <tr key={p.ts + p.hpaName} className="border-t border-zinc-100">
                  <td className="px-3 py-1">{fmtTimeFull(p.ts)}</td><td>{p.hpaName}</td><td className="font-medium">{p.current}</td>
                  <td>{p.desired}</td><td>{p.min}</td><td>{p.max}</td><td>{p.cpuPct != null ? p.cpuPct.toFixed(0) : '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        <>
          <svg viewBox={`0 0 ${W} ${hRep}`} className="w-full" role="img" aria-label="Replica count over time">
            {yTicks(repMax).map((v) => (
              <g key={v}>
                <line x1={M.l} x2={W - M.r} y1={yRep(v)} y2={yRep(v)} stroke={GRID} strokeWidth={1} />
                <text x={M.l - 6} y={yRep(v) + 3.5} textAnchor="end" fontSize={10} fill={INK}>{v}</text>
              </g>
            ))}
            {windows.map((w) => (
              <rect key={w.a.id} x={x(w.s)} y={M.t} width={x(w.e) - x(w.s)} height={hRep - M.t - M.b} fill={`${CURRENT}14`} stroke={CURRENT} strokeDasharray="3 3" strokeWidth={0.8}>
                <title>{`${w.a.trigger === 'MANUAL' ? 'Manual' : 'Scheduled'} change · ${w.a.status}`}</title>
              </rect>
            ))}
            <path d={band} fill="#e4e4e7" opacity={0.7} />
            <path d={line((p) => p.desired, yRep)} fill="none" stroke={DESIRED} strokeWidth={2} strokeDasharray="5 4" strokeLinejoin="round" />
            <path d={line((p) => p.current, yRep)} fill="none" stroke={CURRENT} strokeWidth={2} strokeLinejoin="round" />
            {eventMarks.map(({ ev, ms, up }) => {
              const cx = x(ms);
              const cy = yRep(ev.newSize as number);
              const d = up === false ? `M${cx - 5},${cy - 4}L${cx + 5},${cy - 4}L${cx},${cy + 5}Z` : `M${cx - 5},${cy + 4}L${cx + 5},${cy + 4}L${cx},${cy - 5}Z`;
              return (
                <path key={ev.uid} d={d} fill={up === false ? '#52514e' : '#0b0b0b'} stroke="#fff" strokeWidth={1.5}>
                  <title>{`${fmtTimeFull(ev.lastTs)} · ${ev.reason}${ev.newSize != null ? ` → ${ev.newSize} replicas` : ''}\n${ev.message}`}</title>
                </path>
              );
            })}
            {xTicks.map((t) => (
              <text key={t} x={x(t)} y={hRep - 6} textAnchor="middle" fontSize={10} fill={INK}>{label(t)}</text>
            ))}
            {hp && (
              <g pointerEvents="none">
                <line x1={x(hp.ms)} x2={x(hp.ms)} y1={M.t} y2={hRep - M.b} stroke="#71717a" strokeWidth={1} />
                <circle cx={x(hp.ms)} cy={yRep(hp.current)} r={4} fill={CURRENT} stroke="#fff" strokeWidth={2} />
                <circle cx={x(hp.ms)} cy={yRep(hp.desired)} r={4} fill={DESIRED} stroke="#fff" strokeWidth={2} />
              </g>
            )}
            <rect x={M.l} y={M.t} width={W - M.l - M.r} height={hRep - M.t - M.b} fill="transparent" onPointerMove={onMove} onPointerLeave={() => setHover(null)} />
          </svg>

          <div className="mt-1 text-[11px] font-medium text-zinc-500">CPU utilisation (% of request)</div>
          <svg viewBox={`0 0 ${W} ${hCpu}`} className="w-full" role="img" aria-label="CPU utilisation over time">
            {[0, cpuMax / 2, cpuMax].map((v) => (
              <g key={v}>
                <line x1={M.l} x2={W - M.r} y1={yCpu(v)} y2={yCpu(v)} stroke={GRID} strokeWidth={1} />
                <text x={M.l - 6} y={yCpu(v) + 3.5} textAnchor="end" fontSize={10} fill={INK}>{Math.round(v)}</text>
              </g>
            ))}
            <path d={line((p) => p.cpuPct, yCpu)} fill="none" stroke={CURRENT} strokeWidth={2} strokeLinejoin="round" />
            {hp && hp.cpuPct != null && (
              <g pointerEvents="none">
                <line x1={x(hp.ms)} x2={x(hp.ms)} y1={M.t} y2={hCpu - M.b} stroke="#71717a" strokeWidth={1} />
                <circle cx={x(hp.ms)} cy={yCpu(hp.cpuPct)} r={4} fill={CURRENT} stroke="#fff" strokeWidth={2} />
              </g>
            )}
            <rect x={M.l} y={M.t} width={W - M.l - M.r} height={hCpu - M.t - M.b} fill="transparent" onPointerMove={onMove} onPointerLeave={() => setHover(null)} />
          </svg>

          {hp && (
            <div
              className="pointer-events-none absolute top-8 z-10 min-w-[170px] rounded-lg border border-zinc-200 bg-white px-3 py-2 text-xs shadow-lg"
              style={{ left: `${Math.min(78, Math.max(2, (x(hp.ms) / W) * 100 + 1))}%` }}
            >
              <div className="mb-1 text-zinc-500">{fmtTimeFull(hp.ts)}</div>
              <Row color={CURRENT} label="Current" value={String(hp.current)} />
              <Row color={DESIRED} label="Desired" value={String(hp.desired)} dashed />
              <div className="mt-1 text-zinc-500">min {hp.min} · max {hp.max}</div>
              {hp.cpuPct != null && <div className="text-zinc-500">CPU {hp.cpuPct.toFixed(0)}%{hp.memoryPct != null ? ` · mem ${hp.memoryPct.toFixed(0)}%` : ''}</div>}
            </div>
          )}
        </>
      )}
    </div>
  );
}

function Legend({ color, label, dashed }: { color: string; label: string; dashed?: boolean }) {
  return (
    <span className="inline-flex items-center gap-1.5">
      <svg width="22" height="8" aria-hidden><line x1="0" x2="22" y1="4" y2="4" stroke={color} strokeWidth="2" strokeDasharray={dashed ? '5 4' : undefined} /></svg>
      {label}
    </span>
  );
}

function Row({ color, label, value, dashed }: { color: string; label: string; value: string; dashed?: boolean }) {
  return (
    <div className="flex items-center justify-between gap-4">
      <span className="inline-flex items-center gap-1.5 text-zinc-600">
        <svg width="14" height="6" aria-hidden><line x1="0" x2="14" y1="3" y2="3" stroke={color} strokeWidth="2" strokeDasharray={dashed ? '4 3' : undefined} /></svg>
        {label}
      </span>
      <span className="text-sm font-semibold text-zinc-900">{value}</span>
    </div>
  );
}
