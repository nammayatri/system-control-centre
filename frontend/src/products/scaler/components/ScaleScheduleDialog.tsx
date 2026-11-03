import { useEffect, useMemo, useState } from 'react';
import { Button } from '../../../shared/ui/button';
import { Dialog, DialogBody, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '../../../shared/ui/dialog';
import { cn } from '../../../lib/utils';
import { WEEKDAYS, describeKind, fromLocalInput, toLocalInput } from '../../hpa/format';
import Step from '../../hpa/components/Step';
import { useSaveSchedule } from '../hooks';
import type { InstanceState, ScaleChange, Schedule, ScheduleKind, Target } from '../types';
import { ChangeFields, PreviewBox, modeOf, type PreviewState } from './ChangeFields';

const input = 'h-9 w-full rounded-lg border border-zinc-300 bg-white px-3 text-sm focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-400';

interface Props {
  open: boolean;
  onOpenChange: (o: boolean) => void;
  target: Target;
  state: InstanceState | null;
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

const EMPTY: ScaleChange = { blockScaleIn: false, shrinkOnEnd: false };

export default function ScaleScheduleDialog({ open, onOpenChange, target, state, existing }: Props) {
  const [name, setName] = useState('');
  const [mode, setMode] = useState<Mode>('WEEKLY');
  const [days, setDays] = useState<number[]>([1, 2, 3, 4, 5, 6, 7]);
  const [startTime, setStartTime] = useState('05:30');
  const [durHours, setDurHours] = useState(16);
  const [durMins, setDurMins] = useState(0);
  const [offset, setOffset] = useState(330);
  const [onceStart, setOnceStart] = useState('');
  const [onceEnd, setOnceEnd] = useState('');
  const [permanent, setPermanent] = useState(false);
  const [change, setChange] = useState<ScaleChange>(EMPTY);
  const [preview, setPreview] = useState<PreviewState>({ ready: false, blocking: [] });
  const canBlock = modeOf(target, state) !== 'CLUSTER_DISABLED' && !!target.autoscalerJob;

  // Re-seed whenever the dialog opens (for a new schedule or a different existing one).
  useEffect(() => {
    if (!open) return;
    setName(existing?.name ?? '');
    const k = existing?.timing;
    setMode(k?.kind ?? 'WEEKLY');
    if (k?.kind === 'WEEKLY') {
      setDays(k.days); setStartTime(k.startTime); setDurHours(Math.floor(k.durationMinutes / 60)); setDurMins(k.durationMinutes % 60); setOffset(k.utcOffsetMinutes);
    } else if (k?.kind === 'ONCE') {
      setOnceStart(toLocalInput(k.startAt)); setOnceEnd(toLocalInput(k.endAt)); setPermanent(!k.endAt);
    } else {
      const soon = new Date(Date.now() + 3600_000);
      setOnceStart(toLocalInput(soon.toISOString())); setOnceEnd(toLocalInput(new Date(soon.getTime() + 2 * 3600_000).toISOString())); setPermanent(false);
      setDays([1, 2, 3, 4, 5, 6, 7]); setStartTime('05:30'); setDurHours(16); setDurMins(0); setOffset(330);
    }
    setChange(existing?.change ?? { ...EMPTY, blockScaleIn: canBlock });
  }, [open, existing, canBlock]);

  const durationMinutes = durHours * 60 + durMins;
  const { timing, problems } = useMemo<{ timing?: ScheduleKind; problems: string[] }>(() => {
    if (mode === 'WEEKLY') {
      const p: string[] = [];
      if (days.length === 0) p.push('Pick at least one day.');
      if (durationMinutes < 1 || durationMinutes > 1440) p.push('Duration must be between 1 minute and 24 hours.');
      return { timing: { kind: 'WEEKLY', days: [...days].sort(), startTime, durationMinutes, utcOffsetMinutes: offset }, problems: p };
    }
    const startAt = fromLocalInput(onceStart);
    const endAt = permanent ? null : fromLocalInput(onceEnd);
    const p: string[] = [];
    if (!startAt) p.push('Choose when the change starts.');
    if (!permanent && !endAt) p.push('Choose when it ends, or tick "hold until I restore it".');
    if (startAt && endAt && endAt <= startAt) p.push('The end must be after the start.');
    if (endAt && new Date(endAt).getTime() <= Date.now()) p.push('The end is in the past.');
    return { timing: startAt ? { kind: 'ONCE', startAt, endAt } : undefined, problems: p };
  }, [mode, days, startTime, durationMinutes, offset, onceStart, onceEnd, permanent]);

  const save = useSaveSchedule(() => onOpenChange(false));
  const noTarget = change.units == null && change.replicas == null;
  const whyNot =
    name.trim().length === 0 ? 'Give the schedule a name.'
    : problems.length > 0 ? problems[0]
    : noTarget ? 'Choose the capacity to scale up to.'
    : !preview.ready ? 'Checking against the live target…'
    : preview.blocking.length > 0 ? preview.blocking[0]
    : '';
  const canSave = whyNot === '' && !!timing && !save.isPending;

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent size="2xl">
        <DialogHeader>
          <DialogTitle>{existing ? 'Edit schedule' : 'New schedule'} · {target.name}</DialogTitle>
          <DialogDescription>
            Scale this up before a busy period, optionally stopping its autoscaler from shrinking it during that time. Resizing at a quiet hour avoids the disruption of resizing during traffic.
          </DialogDescription>
        </DialogHeader>
        <DialogBody className="space-y-7">
          <Step n={1} title="Name it" help="Something your team will recognise.">
            <input className={cn(input, 'font-normal')} value={name} maxLength={100} placeholder="e.g. Daytime peak capacity" onChange={(e) => setName(e.target.value)} />
          </Step>

          <Step n={2} title="When should it apply?" help="The resize happens when the window opens, so pick a start before the traffic arrives.">
            <div className="mb-3 inline-flex rounded-lg border border-zinc-300 p-0.5 text-xs">
              {(['WEEKLY', 'ONCE'] as Mode[]).map((m) => (
                <button key={m} type="button" onClick={() => setMode(m)} className={cn('cursor-pointer rounded-md px-3 py-1.5 font-medium', mode === m ? 'bg-zinc-900 text-white' : 'text-zinc-600 hover:bg-zinc-100')}>
                  {m === 'WEEKLY' ? 'Repeats every week' : 'Just once'}
                </button>
              ))}
            </div>
            {mode === 'WEEKLY' ? (
              <div className="space-y-3">
                <div>
                  <div className="mb-1 text-xs font-medium text-zinc-700">On these days</div>
                  <div className="flex flex-wrap gap-1.5">
                    {WEEKDAYS.map((d, i) => {
                      const n = i + 1; const on = days.includes(n);
                      return (
                        <button key={d} type="button" aria-pressed={on} onClick={() => setDays(on ? days.filter((x) => x !== n) : [...days, n])}
                          className={cn('h-8 w-12 cursor-pointer rounded-lg border text-xs font-medium', on ? 'border-sky-600 bg-sky-50 text-sky-800' : 'border-zinc-300 text-zinc-600 hover:bg-zinc-50')}>{d}</button>
                      );
                    })}
                  </div>
                </div>
                <div className="grid grid-cols-3 gap-3">
                  <label className="text-xs font-medium text-zinc-700">Start at
                    <input type="time" className={cn(input, 'mt-1 font-normal')} value={startTime} onChange={(e) => setStartTime(e.target.value)} />
                  </label>
                  <label className="text-xs font-medium text-zinc-700">Keep it for
                    <div className="mt-1 flex items-center gap-1 font-normal">
                      <input type="number" min={0} max={24} className={input} value={durHours} onChange={(e) => setDurHours(Number(e.target.value))} /><span className="text-zinc-500">h</span>
                      <input type="number" min={0} max={59} className={input} value={durMins} onChange={(e) => setDurMins(Number(e.target.value))} /><span className="text-zinc-500">min</span>
                    </div>
                  </label>
                  <label className="text-xs font-medium text-zinc-700">Time zone
                    <select className={cn(input, 'mt-1 font-normal')} value={offset} onChange={(e) => setOffset(Number(e.target.value))}>
                      {OFFSETS.map((o) => <option key={o.minutes} value={o.minutes}>{o.label}</option>)}
                      {!OFFSETS.some((o) => o.minutes === offset) && <option value={offset}>UTC offset {offset} min</option>}
                    </select>
                  </label>
                </div>
                <p className="text-[11px] text-zinc-500">The start time is in the time zone you pick. It can run past midnight. Daylight-saving changes are not applied.</p>
              </div>
            ) : (
              <div className="space-y-3">
                <div className="grid grid-cols-2 gap-3">
                  <label className="text-xs font-medium text-zinc-700">Starts (your computer's time)
                    <input type="datetime-local" className={cn(input, 'mt-1 font-normal')} value={onceStart} onChange={(e) => setOnceStart(e.target.value)} />
                  </label>
                  <label className={cn('text-xs font-medium text-zinc-700', permanent && 'opacity-40')}>Ends
                    <input type="datetime-local" disabled={permanent} className={cn(input, 'mt-1 font-normal')} value={onceEnd} onChange={(e) => setOnceEnd(e.target.value)} />
                  </label>
                </div>
                <label className="flex cursor-pointer items-center gap-2 text-xs text-zinc-700">
                  <input type="checkbox" checked={permanent} onChange={(e) => setPermanent(e.target.checked)} /> Don't end it automatically (I'll restore it by hand)
                </label>
              </div>
            )}
            {problems.length > 0 && <ul className="mt-2 list-disc pl-5 text-xs text-red-700">{problems.map((p) => <li key={p}>{p}</li>)}</ul>}
          </Step>

          <Step n={3} title="What should change?" help="Only the capacity you ask for is changed. Nothing is ever shrunk unless you tick the box.">
            <ChangeFields target={target} state={state} value={change} onChange={setChange} />
          </Step>

          <Step n={4} title="Review" help="This is checked against the live target as you type.">
            <div className="space-y-3">
              {timing && <div className="rounded-lg bg-zinc-50 px-3 py-2 text-xs text-zinc-700">{describeKind(timing)}</div>}
              <PreviewBox target={target} change={change} timing={timing} onState={setPreview} />
            </div>
          </Step>
        </DialogBody>
        <DialogFooter>
          {whyNot && <span className="mr-auto self-center text-xs text-zinc-500">{whyNot}</span>}
          <Button variant="secondary" onClick={() => onOpenChange(false)}>Cancel</Button>
          <Button disabled={!canSave} loading={save.isPending}
            onClick={() => timing && save.mutate({ id: existing?.id, body: { targetKind: target.kind, targetId: target.id, name: name.trim(), timing, change } })}>
            {existing ? 'Save changes' : 'Create schedule'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
