import { useEffect, useState, useId } from 'react';
import { useQuery } from '@tanstack/react-query';
import { Sparkles, Loader2, ChevronDown } from 'lucide-react';
import { Button } from '../../../shared/ui/button';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { mobileApi } from '../api';
import { cn } from '../../../lib/utils';

/**
 * Reveal-on-mount text: fades + slides its content in. Re-mounted (via `key`) on
 * content change, so the AI version reveals over the deterministic placeholder
 * instead of swapping abruptly. `dim` renders the provisional (pending) text at
 * reduced opacity; the AI version lands at full opacity. Honors reduced-motion.
 *
 * We deliberately animate the whole block (opacity + slight slide) rather than a
 * per-character typewriter: the changelog can be long, and a fade has no layout
 * reflow and reads cleanly at any length.
 */
function RevealText({ text, dim }: { text: string; dim?: boolean }) {
  const [shown, setShown] = useState(false);
  useEffect(() => {
    if (window.matchMedia?.('(prefers-reduced-motion: reduce)')?.matches) {
      setShown(true);
      return;
    }
    // Two rAFs so the element paints at opacity 0 before transitioning to target.
    let r2 = 0;
    const r1 = requestAnimationFrame(() => {
      r2 = requestAnimationFrame(() => setShown(true));
    });
    return () => {
      cancelAnimationFrame(r1);
      cancelAnimationFrame(r2);
    };
  }, []);
  return (
    <div
      className="whitespace-pre-wrap text-xs leading-relaxed text-zinc-700"
      style={{
        opacity: shown ? (dim ? 0.55 : 1) : 0,
        transform: shown ? 'translateY(0)' : 'translateY(6px)',
        transition: 'opacity 450ms ease, transform 450ms ease',
      }}
    >
      {text}
    </div>
  );
}

/**
 * Create-time changelog summary of the commit range being released.
 *
 * Generation runs DETACHED server-side (forkFlow), keyed by the commit range, so
 * it survives this request and the browser tab. The endpoint returns immediately
 * with `status` ('pending' | 'ready') and always a `summaryLong` (the deterministic
 * changelog while pending; the AI prose once ready). We render the placeholder at
 * once and poll lightly only while `pending`, plus refetch when the tab regains
 * focus — so switching tabs still lands the AI result. A badge shows the source
 * (AI · model / Auto-generated / Generating), and the AI version reveals with a
 * fade/slide so the swap feels intentional.
 */
export function MobileChangelogAiSummary({
  app,
  surface,
  platform,
  branch,
  base = 'production',
  versionName = '',
  versionCode = '',
}: {
  app: string;
  surface: string;
  platform: string;
  branch: string;
  base?: string;
  versionName?: string;
  versionCode?: string;
}) {
  const enabled = !!(app && surface && platform && branch);
  const q = useQuery({
    queryKey: ['mobile-changelog-ai', app, surface, platform, branch, base, versionName, versionCode],
    queryFn: () => mobileApi.changelogAiSummary(app, surface, platform, branch, base, versionName, versionCode),
    enabled,
    // Poll only while the detached generation is in flight; stop once ready/failed.
    refetchInterval: (query) => (query.state.data?.status === 'pending' ? 4000 : false),
    // Returning to the tab re-checks — the result may have landed while away.
    refetchOnWindowFocus: true,
    staleTime: 15 * 1000,
  });

  const [collapsed, setCollapsed] = useState(false);
  const panelId = useId();
  const d = q.data;
  const isPending = d?.status === 'pending';
  const isAi = d?.status === 'ready' && !!d.model;
  const badge = !d?.available
    ? null
    : isPending
      ? { label: 'Generating…', cls: 'bg-violet-100 text-violet-700', spin: true }
      : isAi
        ? { label: `AI · ${d.model}`, cls: 'bg-emerald-100 text-emerald-700', spin: false }
        : { label: 'Auto-generated', cls: 'bg-zinc-100 text-zinc-600', spin: false };

  return (
    <PermissionGate product="autopilot" permission="AI_SUMMARIZE">
      <div className="mb-3 overflow-hidden rounded-md border border-violet-100 bg-violet-50/40">
        <div className="flex items-center justify-between gap-2 px-3 py-2">
          {/* The whole title bar is the collapse toggle (click anywhere to
              hide/show). It's a real <button> so Enter/Space + focus work, with
              aria-expanded/-controls. Refresh is a SEPARATE sibling below — we
              never nest interactive controls inside a button. */}
          <button
            type="button"
            onClick={() => setCollapsed((c) => !c)}
            aria-expanded={!collapsed}
            aria-controls={panelId}
            className="group -m-1 flex min-w-0 flex-1 items-center gap-1.5 rounded p-1 text-xs font-medium text-violet-700 hover:bg-violet-100/50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-violet-300 transition-colors"
          >
            <ChevronDown
              size={14}
              className={cn(
                'shrink-0 text-violet-400 transition-transform duration-200 motion-reduce:transition-none',
                collapsed && '-rotate-90',
              )}
            />
            <Sparkles size={13} className="shrink-0" />
            <span className="truncate">Changelog summary</span>
            {badge && (
              <span className={cn('ml-0.5 inline-flex shrink-0 items-center gap-1 rounded px-1.5 py-0.5 text-[10px] font-semibold transition-colors', badge.cls)}>
                {badge.spin && <Loader2 size={9} className="animate-spin" />}
                {badge.label}
              </span>
            )}
            <span className="ml-auto pl-1 text-[10px] font-normal text-violet-400 group-hover:text-violet-500">
              {collapsed ? 'Show' : 'Hide'}
            </span>
          </button>
          {/* Refresh is meaningless mid-generation (the panel already polls) and
              while collapsed — hide it in both cases. */}
          {!isPending && !collapsed && (
            <Button size="sm" variant="ghost" loading={q.isFetching} onClick={() => q.refetch()}>
              Refresh
            </Button>
          )}
        </div>

        {/* Collapsible body. grid-rows 0fr↔1fr animates height with no JS
            measurement; the inner overflow-hidden clips during the transition.
            Stays mounted while collapsed so the detached generation keeps polling
            and the result is ready when re-opened. aria-hidden hides it from AT. */}
        <div
          id={panelId}
          aria-hidden={collapsed}
          className={cn(
            'grid transition-[grid-template-rows] duration-300 ease-out motion-reduce:transition-none',
            collapsed ? 'grid-rows-[0fr]' : 'grid-rows-[1fr]',
          )}
        >
          <div className="overflow-hidden">
            <div className="space-y-2 px-3 pb-3">
              {q.isLoading && !d && (
                <div className="flex items-center gap-2 text-xs text-zinc-500">
                  <Loader2 size={12} className="animate-spin" /> Loading…
                </div>
              )}

              {d && !d.available && <p className="text-xs text-zinc-500">{d.reason}</p>}

              {d && d.available && (
                <>
                  {isPending && (
                    <p className="flex items-center gap-1.5 text-[11px] text-violet-600">
                      <Loader2 size={11} className="animate-spin" />
                      AI summary is generating — showing the auto changelog meanwhile. It updates here even if you switch tabs.
                    </p>
                  )}
                  {/* Short 1-2 line synopsis (AI, only when ready) — sits above the full changelog */}
                  {d.summaryShort && (
                    <p className="flex gap-1.5 rounded bg-white/70 p-2 text-xs font-medium leading-relaxed text-zinc-800">
                      <Sparkles size={13} className="mt-0.5 shrink-0 text-violet-500" />
                      <span>{d.summaryShort}</span>
                    </p>
                  )}
                  {/* Full changelog: AI prose when ready, deterministic while pending.
                      Keyed on status+model so it re-reveals when the AI version lands. */}
                  {d.summaryLong && (
                    <RevealText key={`${d.status}:${d.model ?? ''}`} text={d.summaryLong} dim={isPending} />
                  )}
                </>
              )}
            </div>
          </div>
        </div>
      </div>
    </PermissionGate>
  );
}
