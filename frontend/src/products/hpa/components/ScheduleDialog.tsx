import { useEffect, useMemo, useState } from 'react';
import { Button } from '../../../shared/ui/button';
import { Dialog, DialogBody, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '../../../shared/ui/dialog';
import { cn } from '../../../lib/utils';
import { useSaveSchedule } from '../hooks';
import { WEEKDAYS, fromLocalInput, toLocalInput } from '../format';
import { DEFAULT_HEALTH_POLICY, type HealthPolicy, type HpaChange, type HpaSpec, type Schedule, type ScheduleKind } from '../types';
import ChangeForm from './ChangeForm';
import HealthPolicyFields from './HealthPolicyFields';
import PreviewPanel, { type PreviewState } from './PreviewPanel';

const input = 'h-9 w-full rounded-lg border border-zinc-300 bg-white px-3 text-sm focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-400';

interface Props {
  open: boolean;
  onOpenChange: (o: boolean) => void;
  product: string;
  service: string;
  /** A serving HPA's spec: supplies "now" hints and the metrics that can be overridden. */
  reference: HpaSpec | null;
  existing?: Schedule;
}

type Mode = 'WEEKLY' | 'ONCE';
const OFFSETS: { label: string; minutes: number }[] = [
  { label: 'IST (UTC+05:30)', minutes: 330 },
  { label: 'UTC', minutes: 0 },
  { label: 'GST (UTC+04:00)', minutes: 240 },
  { label: 'SGT (UTC+08:00)', minutes: 480 },
  { label: 'PST (UTC-08:00)', minutes: -480 },
];

export default function ScheduleDialog({ open, onOpenChange, product, service, reference, existing }: Props) {
  const [name, setName] = useState('');
  const [mode, setMode] = useState<Mode>('WEEKLY');
  const [days, setDays] = useState<number[]>([1, 2, 3, 4, 5]);
  const [startTime, setStartTime] = useState('10:00');
  const [durHours, setDurHours] = useState(2);
  const [durMins, setDurMins] = useState(0);
  const [offset, setOffset] = useState(330);
  const [onceStart, setOnceStart] = useState('');
  const [onceEnd, setOnceEnd] = useState('');
  const [permanent, setPermanent] = useState(false);
  const [change, setChange] = useState<HpaChange>({});
  const [policy, setPolicy] = useState<HealthPolicy>(DEFAULT_HEALTH_POLICY);
  const [showPolicy, setShowPolicy] = useState(false);
  const [preview, setPreview] = useState<PreviewState>({ ready: false, blocking: [], allNoop: false });

  // Re-seed whenever the dialog opens (for a new schedule or a different existing one).
  useEffect(() => {
    if (!open) return;
    setName(existing?.name ?? '');
    const k = existing?.kind;
    setMode(k?.kind ?? 'WEEKLY');
    if (k?.kind === 'WEEKLY') {
      setDays(k.days); setStartTime(k.startTime); setDurHours(Math.floor(k.durationMinutes / 60)); setDurMins(k.durationMinutes % 60); setOffset(k.utcOffsetMinutes);
    } else if (k?.kind === 'ONCE') {
      setOnceStart(toLocalInput(k.startAt)); setOnceEnd(toLocalInput(k.endAt)); setPermanent(!k.endAt);
    } else {
      const soon = new Date(Date.now() + 3600_000);
      setOnceStart(toLocalInput(soon.toISOString())); setOnceEnd(toLocalInput(new Date(soon.getTime() + 2 * 3600_000).toISOString())); setPermanent(false);
      setDays([1, 2, 3, 4, 5]); setStartTime('10:00'); setDurHours(2); setDurMins(0); setOffset(330);
    }
    setChange(existing?.change ?? {});
    setPolicy({ ...DEFAULT_HEALTH_POLICY, ...(existing?.healthPolicy ?? {}) });
    setShowPolicy(false);
  }, [open, existing]);

  const durationMinutes = durHours * 60 + durMins;
  const { kind, problems } = useMemo<{ kind?: ScheduleKind; problems: string[] }>(() => {
    if (mode === 'WEEKLY') {
      const p: string[] = [];
      if (days.length === 0) p.push('Pick at least one day.');
      if (durationMinutes < 1 || durationMinutes > 1440) p.push('Duration must be between 1 minute and 24 hours.');
      return { kind: { kind: 'WEEKLY', days: [...days].sort(), startTime, durationMinutes, utcOffsetMinutes: offset }, problems: p };
    }
    const startAt = fromLocalInput(onceStart);
    const endAt = permanent ? null : fromLocalInput(onceEnd);
    const p: string[] = [];
    if (!startAt) p.push('Choose when the change starts.');
    if (!permanent && !endAt) p.push('Choose when it ends, or tick "hold until I restore it".');
    if (startAt && endAt && endAt <= startAt) p.push('The end must be after the start.');
    if (endAt && new Date(endAt).getTime() <= Date.now()) p.push('The end is in the past.');
    return { kind: startAt ? { kind: 'ONCE', startAt, endAt } : undefined, problems: p };
  }, [mode, days, startTime, durationMinutes, offset, onceStart, onceEnd, permanent]);

  const save = useSaveSchedule(() => onOpenChange(false));
  const canSave = name.trim().length > 0 && !!kind && problems.length === 0 && preview.ready && preview.blocking.length === 0 && (!!existing || !preview.allNoop) && !save.isPending;

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent size="2xl">
        <DialogHeader>
          <DialogTitle>{existing ? 'Edit schedule' : 'New schedule'} · {service}</DialogTitle>
          <DialogDescription>
            Changes the serving HPA for a time window and puts the original values back when it ends. If a release moves traffic to a new HPA meanwhile, the change follows it.
          </DialogDescription>
        </DialogHeader>
        <DialogBody className="space-y-5">
          <label className="block text-xs font-semibold text-zinc-700">Name
            <input className={cn(input, 'mt-1 font-normal')} value={name} maxLength={100} placeholder="e.g. Weekday morning peak" onChange={(e) => setName(e.target.value)} />
          </label>

          <div>
            <div className="mb-1.5 text-xs font-semibold text-zinc-700">When</div>
            <div className="mb-3 inline-flex rounded-lg border border-zinc-300 p-0.5 text-xs">
              {(['WEEKLY', 'ONCE'] as Mode[]).map((m) => (
                <button key={m} type="button" onClick={() => setMode(m)} className={cn('cursor-pointer rounded-md px-3 py-1.5 font-medium', mode === m ? 'bg-zinc-900 text-white' : 'text-zinc-600 hover:bg-zinc-100')}>
                  {m === 'WEEKLY' ? 'Repeats weekly' : 'One-off window'}
                </button>
              ))}
            </div>

            {mode === 'WEEKLY' ? (
              <div className="space-y-3">
                <div className="flex flex-wrap gap-1.5">
                  {WEEKDAYS.map((d, i) => {
                    const n = i + 1; const on = days.includes(n);
                    return (
                      <button key={d} type="button" aria-pressed={on} onClick={() => setDays(on ? days.filter((x) => x !== n) : [...days, n])}
                        className={cn('h-8 w-12 cursor-pointer rounded-lg border text-xs font-medium', on ? 'border-sky-600 bg-sky-50 text-sky-800' : 'border-zinc-300 text-zinc-600 hover:bg-zinc-50')}>{d}</button>
                    );
                  })}
                </div>
                <div className="grid grid-cols-3 gap-3">
                  <label className="text-xs text-zinc-600">Starts at
                    <input type="time" className={cn(input, 'mt-1')} value={startTime} onChange={(e) => setStartTime(e.target.value)} />
                  </label>
                  <label className="text-xs text-zinc-600">Lasts
                    <div className="mt-1 flex items-center gap-1">
                      <input type="number" min={0} max={24} className={input} value={durHours} onChange={(e) => setDurHours(Number(e.target.value))} /><span className="text-zinc-500">h</span>
                      <input type="number" min={0} max={59} className={input} value={durMins} onChange={(e) => setDurMins(Number(e.target.value))} /><span className="text-zinc-500">m</span>
                    </div>
                  </label>
                  <label className="text-xs text-zinc-600">Time zone
                    <select className={cn(input, 'mt-1')} value={offset} onChange={(e) => setOffset(Number(e.target.value))}>
                      {OFFSETS.map((o) => <option key={o.minutes} value={o.minutes}>{o.label}</option>)}
                      {!OFFSETS.some((o) => o.minutes === offset) && <option value={offset}>UTC offset {offset} min</option>}
                    </select>
                  </label>
                </div>
                <p className="text-[11px] text-zinc-500">Fixed offset, no daylight-saving adjustment. A window may run past midnight.</p>
              </div>
            ) : (
              <div className="space-y-3">
                <div className="grid grid-cols-2 gap-3">
                  <label className="text-xs text-zinc-600">Starts (your local time)
                    <input type="datetime-local" className={cn(input, 'mt-1')} value={onceStart} onChange={(e) => setOnceStart(e.target.value)} />
                  </label>
                  <label className={cn('text-xs text-zinc-600', permanent && 'opacity-40')}>Ends
                    <input type="datetime-local" disabled={permanent} className={cn(input, 'mt-1')} value={onceEnd} onChange={(e) => setOnceEnd(e.target.value)} />
                  </label>
                </div>
                <label className="flex cursor-pointer items-center gap-2 text-xs text-zinc-700">
                  <input type="checkbox" checked={permanent} onChange={(e) => setPermanent(e.target.checked)} /> Hold until I restore it by hand
                </label>
              </div>
            )}
            {problems.length > 0 && <ul className="mt-2 list-disc pl-5 text-xs text-red-700">{problems.map((p) => <li key={p}>{p}</li>)}</ul>}
          </div>

          <div>
            <div className="mb-2 text-xs font-semibold text-zinc-700">What changes</div>
            <ChangeForm reference={reference} value={change} onChange={setChange} />
          </div>

          <div>
            <button type="button" className="cursor-pointer text-xs font-semibold text-zinc-700 hover:underline" onClick={() => setShowPolicy((s) => !s)}>
              {showPolicy ? '▾' : '▸'} Health check &amp; auto-rollback
            </button>
            {showPolicy && <div className="mt-2"><HealthPolicyFields value={policy} onChange={setPolicy} /></div>}
          </div>

          <div>
            <div className="mb-2 text-xs font-semibold text-zinc-700">Preview</div>
            <PreviewPanel product={product} service={service} change={change} kind={kind} kindProblems={problems} onState={setPreview} />
            {preview.allNoop && !existing && <div className="mt-2 text-xs text-amber-800">Every serving HPA already has these values, so this schedule would do nothing.</div>}
          </div>
        </DialogBody>
        <DialogFooter>
          <Button variant="secondary" onClick={() => onOpenChange(false)}>Cancel</Button>
          <Button disabled={!canSave} loading={save.isPending}
            onClick={() => kind && save.mutate({ id: existing?.id, body: { product, service, name: name.trim(), kind, change, healthPolicy: policy } })}>
            {existing ? 'Save changes' : 'Create schedule'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
