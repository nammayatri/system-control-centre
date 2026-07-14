import { useEffect, useState, useId } from 'react';
import { useQuery } from '@tanstack/react-query';
import { Sparkles, Loader2, ChevronDown, Copy, Check } from 'lucide-react';
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
      {renderWithMentions(text)}
    </div>
  );
}

/**
 * Render text with @author mentions in italics. Splits on the @handle token (a
 * capturing split keeps the delimiters), so the surrounding text stays plain,
 * escaped text — we never inject HTML. Odd indices are the captured mentions.
 */
function renderWithMentions(text: string) {
  return text.split(/(@[A-Za-z0-9_.-]+)/g).map((part, i) =>
    i % 2 === 1 ? (
      <em key={i} className="italic text-zinc-500">
        {part}
      </em>
    ) : (
      part
    ),
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
  app = '',
  surface = '',
  platform = '',
  branch,
  base = 'production',
  versionName = '',
  versionCode = '',
  combinedApps,
  defaultCollapsed = false,
  onSummary,
}: {
  app?: string;
  surface?: string;
  platform?: string;
  branch: string;
  base?: string;
  versionName?: string;
  versionCode?: string;
  // Start the panel collapsed (title bar only). Generation still runs; the
  // summary is one click away. `onSummary` fires regardless.
  defaultCollapsed?: boolean;
  // ≥2 entries switch the panel to the COMBINED endpoint: one changelog for the
  // whole selection — common changes + per-app extras (app/surface/platform
  // props are ignored in that mode). `version` shows next to the app in the header.
  combinedApps?: { app: string; surface: string; platform: string; version?: string }[];
  // Reports the current summary text (AI prose once ready, else the deterministic
  // changelog) up to the parent, so the create page can stash it for "send to
  // Slack". `short` is the AI synopsis — present only once ready; the create
  // page stores it on the release for the promote form's store-notes prefill.
  onSummary?: (text: string, short?: string) => void;
}) {
  const combined = (combinedApps?.length ?? 0) >= 2;
  const comboKey = combined
    ? combinedApps!
        .map((a) => `${a.app}|${a.surface}|${a.platform}|${a.version ?? ''}`)
        .sort()
        .join(',')
    : '';
  const enabled = combined ? !!branch : !!(app && surface && platform && branch);
  const q = useQuery({
    queryKey: combined
      ? ['mobile-changelog-ai-combined', comboKey, branch, base]
      : ['mobile-changelog-ai', app, surface, platform, branch, base, versionName, versionCode],
    queryFn: () =>
      combined
        ? mobileApi.changelogAiSummaryCombined(combinedApps!, branch, base)
        : mobileApi.changelogAiSummary(app, surface, platform, branch, base, versionName, versionCode),
    enabled,
    // Poll only while the detached generation is in flight; stop once ready/failed.
    refetchInterval: (query) => (query.state.data?.status === 'pending' ? 4000 : false),
    // Returning to the tab re-checks — the result may have landed while away.
    refetchOnWindowFocus: true,
    staleTime: 15 * 1000,
  });

  const [collapsed, setCollapsed] = useState(defaultCollapsed);
  const [copied, setCopied] = useState(false);
  const panelId = useId();
  const d = q.data;
  const isPending = d?.status === 'pending';
  // The full generated summary: short synopsis + the changelog prose.
  const copyText = [d?.summaryShort, d?.summaryLong].filter(Boolean).join('\n\n');

  // Surface the current summary text to the parent (for "send changelog to Slack").
  useEffect(() => {
    if (onSummary && d?.summaryLong) onSummary(d.summaryLong, d.summaryShort?.trim() || undefined);
  }, [onSummary, d?.summaryLong, d?.summaryShort]);

  const onCopy = async () => {
    if (!copyText) return;
    try {
      await navigator.clipboard.writeText(copyText);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      /* clipboard blocked (insecure context / permissions) — silently ignore */
    }
  };
  const isAi = d?.status === 'ready' && !!d.model;
  // "Generating…" covers the in-flight generation AND the very first fetch
  // (before any data), so the collapsed title bar always shows it's working.
  const generating = enabled && (isPending || (!d && (q.isLoading || q.isFetching)));
  const badge = generating
    ? { label: 'Generating…', cls: 'bg-violet-100 text-violet-700', spin: true }
    : !d?.available
      ? null
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
            <span className="truncate">
              {combined
                ? d?.available && d.usableCount != null && d.usableCount < combinedApps!.length
                  ? `Combined changelog — ${d.usableCount} of ${combinedApps!.length} apps`
                  : `Combined changelog — ${combinedApps!.length} apps, one summary`
                : 'Changelog summary'}
            </span>
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
          {/* Copy + Refresh controls (siblings of the title button, never nested).
              Refresh is meaningless mid-generation (the panel already polls); Copy
              stays available so the current text can be grabbed even while pending. */}
          {!collapsed && (
            <div className="flex shrink-0 items-center gap-1">
              {d?.available && copyText && (
                <button
                  type="button"
                  onClick={onCopy}
                  title={copied ? 'Copied' : 'Copy summary'}
                  aria-label={copied ? 'Copied' : 'Copy summary to clipboard'}
                  className="rounded p-1.5 text-violet-400 transition-colors hover:bg-violet-100 hover:text-violet-600"
                >
                  {copied ? <Check size={14} className="text-emerald-600" /> : <Copy size={14} />}
                </button>
              )}
              {!isPending && (
                <Button size="sm" variant="ghost" loading={q.isFetching} onClick={() => q.refetch()}>
                  Refresh
                </Button>
              )}
            </div>
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
