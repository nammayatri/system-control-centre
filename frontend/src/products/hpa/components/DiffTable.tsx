import type { DiffEntry } from '../types';

const show = (v: unknown) => (v === undefined || v === null ? '—' : typeof v === 'string' ? v : JSON.stringify(v));

/** "metrics[0].resource.target.averageUtilization" → readable label. */
export function prettyPath(path: string): string {
  const m = path.match(/^metrics\[(\d+)\]\.(\w+)\.(?:target\.)?(.*)$/);
  if (m) return `metric #${Number(m[1]) + 1} · ${m[3] || m[2]}`;
  return path.replace(/^behavior\./, 'behavior · ').replace(/\./g, ' · ');
}

export default function DiffTable({ diff, empty = 'No changes' }: { diff: DiffEntry[]; empty?: string }) {
  if (diff.length === 0) return <div className="text-xs text-zinc-500">{empty}</div>;
  return (
    <table className="w-full text-xs">
      <tbody>
        {diff.map((d) => (
          <tr key={d.path} className="border-t border-zinc-100 first:border-0">
            <td className="py-1 pr-3 font-medium text-zinc-700" title={d.path}>{prettyPath(d.path)}</td>
            <td className="py-1 pr-2 text-right font-mono text-red-700 line-through decoration-red-300">{show(d.old)}</td>
            <td className="w-5 py-1 text-center text-zinc-400">→</td>
            <td className="py-1 font-mono font-semibold text-emerald-700">{show(d.new)}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

/** Flatten two JSON values into a path diff (client-side, for ledger rows that carry both specs). */
export function diffJson(a: unknown, b: unknown, path = ''): DiffEntry[] {
  if (a && b && typeof a === 'object' && typeof b === 'object' && !Array.isArray(a) && !Array.isArray(b)) {
    const keys = [...new Set([...Object.keys(a as object), ...Object.keys(b as object)])].sort();
    return keys.flatMap((k) => diffJson((a as any)[k], (b as any)[k], path ? `${path}.${k}` : k));
  }
  if (Array.isArray(a) && Array.isArray(b)) {
    const n = Math.max(a.length, b.length);
    return Array.from({ length: n }, (_, i) => diffJson(a[i], b[i], `${path}[${i}]`)).flat();
  }
  return JSON.stringify(a) === JSON.stringify(b) ? [] : [{ path, old: a ?? null, new: b ?? null }];
}
