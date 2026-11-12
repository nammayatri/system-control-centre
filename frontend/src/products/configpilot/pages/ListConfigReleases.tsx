import React, { useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { RefreshCw, Search } from 'lucide-react';
import { fetchAPReleases } from '../../releases/api';
import { StatusBadge } from '../../releases/components/StatusBadge';
import { TableSkeleton } from '../../../shared/ui/skeleton';
import { currentRolloutPercent, parseConfigReleaseMeta } from '../types';

const RANGES = [
  { label: 'Last 24 hours', days: 1 },
  { label: 'Last 7 days', days: 7 },
  { label: 'Last 30 days', days: 30 },
];

const formatIST = (iso: string) => {
  if (!iso) return '-';
  const d = new Date(iso);
  return isNaN(d.getTime()) ? '-' : d.toLocaleString('en-IN', { timeZone: 'Asia/Kolkata' }) + ' IST';
};

const ListConfigReleases: React.FC = () => {
  const navigate = useNavigate();
  const [days, setDays] = useState(7);
  const [search, setSearch] = useState('');

  const { data: releases = [], isLoading, isFetching, refetch } = useQuery({
    queryKey: ['config-releases', days],
    queryFn: () => {
      const to = new Date();
      const from = new Date(to.getTime() - days * 24 * 60 * 60 * 1000);
      return fetchAPReleases(from.toISOString(), to.toISOString(), 'configpilot');
    },
    refetchInterval: 30000,
  });

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    if (!q) return releases;
    return releases.filter(r => {
      const meta = parseConfigReleaseMeta(r);
      return (
        r.id.toLowerCase().includes(q) ||
        r.appGroup.toLowerCase().includes(q) ||
        r.service.toLowerCase().includes(q) ||
        r.description.toLowerCase().includes(q) ||
        r.release_manager.toLowerCase().includes(q) ||
        meta.city.toLowerCase().includes(q) ||
        meta.items.some(i => i.configType.toLowerCase().includes(q))
      );
    });
  }, [releases, search]);

  return (
    <div className="flex flex-col flex-1 w-full">
      <div className="bg-white border border-zinc-200 rounded-xl">
        <div className="p-3 sm:p-4 flex flex-col md:flex-row md:items-center gap-2 md:gap-3 border-b border-zinc-100">
          <div className="relative md:flex-none">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-zinc-400" />
            <input
              type="text"
              placeholder="Search config releases..."
              value={search}
              onChange={e => setSearch(e.target.value)}
              className="pl-9 pr-4 h-10 sm:h-9 w-full md:w-72 border border-zinc-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent"
            />
          </div>
          <select
            value={days}
            onChange={e => setDays(Number(e.target.value))}
            className="h-10 sm:h-9 border border-zinc-300 rounded-lg px-3 text-sm bg-white text-zinc-600"
          >
            {RANGES.map(r => <option key={r.days} value={r.days}>{r.label}</option>)}
          </select>
          <div className="hidden md:block flex-1" />
          <button
            onClick={() => refetch()}
            aria-label="Refresh"
            className="h-10 w-10 sm:h-9 sm:w-9 flex items-center justify-center border border-zinc-300 rounded-lg hover:bg-zinc-50 text-zinc-500 cursor-pointer"
          >
            <RefreshCw className={`h-4 w-4 ${isFetching ? 'animate-spin' : ''}`} />
          </button>
        </div>

        {isLoading ? (
          <div className="p-4"><TableSkeleton /></div>
        ) : filtered.length === 0 ? (
          <div className="p-10 text-center text-sm text-zinc-400">No config releases in this range.</div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm text-left min-w-[860px]">
              <thead>
                <tr className="bg-zinc-50 border-b border-zinc-200 text-[12px] text-zinc-500 font-medium uppercase tracking-wider">
                  {['Release', 'Target', 'Configs', 'Status', 'Progress', 'Created by', 'Created'].map(h => (
                    <th key={h} className="px-4 py-3">{h}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {filtered.map((r, i) => {
                  const meta = parseConfigReleaseMeta(r);
                  const pct = currentRolloutPercent(r);
                  return (
                    <tr
                      key={r.id}
                      onClick={() => navigate(`/backend/config-releases/${r.id}`)}
                      className={`border-b border-zinc-100 hover:bg-zinc-100 cursor-pointer ${i % 2 === 1 ? 'bg-zinc-50' : 'bg-white'}`}
                    >
                      <td className="px-4 py-3">
                        <div className="font-mono text-xs text-zinc-700">{r.id.slice(0, 8)}</div>
                        <div className="text-xs text-zinc-400 truncate max-w-[220px]">{r.description || '-'}</div>
                      </td>
                      <td className="px-4 py-3 text-zinc-600">
                        <div>{meta.side === 'BAP' ? 'Rider' : 'Driver'} · {meta.city || '-'}</div>
                        <div className="text-xs text-zinc-400">{r.appGroup}/{r.service}</div>
                      </td>
                      <td className="px-4 py-3 text-zinc-600">
                        {meta.items.length} {meta.items.length === 1 ? 'config' : 'configs'}
                        <div className="text-xs text-zinc-400 truncate max-w-[220px]">{meta.items.map(i => i.configType).join(', ')}</div>
                      </td>
                      <td className="px-4 py-3"><StatusBadge status={r.status} /></td>
                      <td className="px-4 py-3 w-40">
                        <div className="text-xs text-zinc-600 mb-1">{pct}% · step {r.rollout_history.length}/{r.rollout_strategy.length}</div>
                        <div className="h-1.5 bg-zinc-100 rounded-full overflow-hidden">
                          <div className="h-full bg-zinc-700" style={{ width: `${pct}%` }} />
                        </div>
                      </td>
                      <td className="px-4 py-3 text-zinc-600">{r.release_manager || '-'}</td>
                      <td className="px-4 py-3 text-zinc-500 whitespace-nowrap">{formatIST(r.date_created)}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
};

export default ListConfigReleases;
