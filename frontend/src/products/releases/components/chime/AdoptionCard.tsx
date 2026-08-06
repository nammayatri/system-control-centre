import { useMemo } from 'react';
import { useQuery } from '@tanstack/react-query';
import { ChartBarIcon } from '@phosphor-icons/react';
import { chimeApi, type ChimeVersionUsers } from '../../api';
import { useOtaAccess } from '../../../airborne-ota/hooks';
import { cn } from '../../../../lib/utils';

// Adoption (Chime) — renders EXACTLY what GET /chime/versions/users returns:
// the approximate distinct-user count on one bundle version, plus its own
// metadata (version, window, source, updated_at). Campaign-funnel KPIs live
// on the CampaignCard — never duplicated here. Labels come from the
// response, not hardcoded; a Chime 404 (folded to recorded:false) is the
// empty state, not an error.

export interface AdoptionCardProps {
  /** Composite airborne ref `<org>~<app>`. */
  appRef: string;
  /** Store package id; null disables the query (empty state shows). */
  pkg: string | null;
  os: 'android' | 'ios';
  /** Bundle identity devices report — package tag preferred, else version. */
  version: string | null;
  variant: 'panel' | 'compact';
  className?: string;
}

const nf = (n: number | undefined | null) => (n == null ? '—' : n.toLocaleString('en-US'));

export function AdoptionCard({ appRef, pkg, os, version, variant, className }: AdoptionCardProps) {
  const access = useOtaAccess();
  const hasView = useMemo(
    () => (access.data?.apps.find((a) => a.appRef === appRef)?.permissions ?? []).includes('OTA_VIEW'),
    [access.data, appRef],
  );

  const adoptionQ = useQuery({
    queryKey: ['chime-adoption', appRef, pkg, version, os],
    queryFn: () => chimeApi.adoption(appRef, { pkg: pkg!, version: version!, os }),
    enabled: hasView && !!pkg && !!version,
    retry: false,
    staleTime: 60_000,
  });
  const adoption: ChimeVersionUsers | null | undefined = adoptionQ.data?.data;
  const recorded = !!adoption && adoption.recorded !== false && adoption.active_users != null;

  if (!hasView) return null;

  const windowLabel =
    adoption?.window_hours != null
      ? adoption.window_hours % 24 === 0
        ? `${adoption.window_hours / 24} days`
        : `${adoption.window_hours}h`
      : '7 days';

  const badge = (
    <span
      className="bg-violet-50 border border-violet-200 text-violet-700 text-[9px] font-bold px-1.5 py-px rounded uppercase"
      title="HyperLogLog estimate (~1% error at scale)"
    >
      Chime · ~approx
    </span>
  );

  // Metadata line built ONLY from fields present in the response.
  const meta = recorded
    ? [
        adoption?.version ? `v${adoption.version}` : null,
        `window: ${windowLabel}`,
        adoption?.source ? `source: ${adoption.source}` : null,
        adoption?.updated_at ? `as of ${new Date(adoption.updated_at).toLocaleTimeString()}` : null,
      ]
        .filter(Boolean)
        .join(' · ')
    : null;

  const empty = (pad: string) => (
    <div
      className={`border border-dashed border-zinc-300 bg-zinc-50/50 rounded flex items-center justify-center ${pad} text-center text-zinc-400 text-[10px] gap-1`}
    >
      <ChartBarIcon size={13} weight="duotone" aria-hidden="true" /> No adoption recorded yet — counts appear once
      devices report a download.
    </div>
  );

  if (variant === 'compact') {
    return (
      <div className={className}>
        <div className="flex items-center justify-between mb-1.5">
          <span className="text-[9px] font-bold uppercase tracking-widest text-zinc-400">Adoption · {windowLabel}</span>
          {badge}
        </div>
        {recorded ? (
          <div className="bg-zinc-50 border border-zinc-100 rounded p-2 flex items-baseline justify-between gap-2">
            <span>
              <span className="block text-[8px] text-zinc-400 font-medium uppercase">Active users</span>
              <span className="font-mono font-bold text-zinc-900 text-sm">~{nf(adoption?.active_users)}</span>
            </span>
            {meta && <span className="text-[9px] text-zinc-400 text-right">{meta}</span>}
          </div>
        ) : (
          empty('py-3 px-3')
        )}
      </div>
    );
  }

  return (
    <div className={cn('bg-white rounded-lg border border-zinc-200 p-4 flex flex-col gap-3', className)}>
      <div className="flex items-center justify-between">
        <span className="eyebrow flex items-center gap-1">
          <ChartBarIcon size={12} weight="bold" className="text-violet-500" aria-hidden="true" /> Adoption ·{' '}
          {windowLabel}
        </span>
        {badge}
      </div>
      {recorded ? (
        <div className="flex-1 flex flex-col justify-center">
          <span className="text-[10px] text-zinc-400 font-medium uppercase">Active users on this bundle</span>
          <span className="font-mono font-bold text-zinc-900 text-3xl leading-tight">
            ~{nf(adoption?.active_users)}
          </span>
        </div>
      ) : (
        empty('flex-1 px-4 py-8')
      )}
      {meta && (
        <div className="mt-auto border-t border-zinc-100 pt-2">
          <span className="text-[9px] text-zinc-400">{meta} · counts ~1%</span>
        </div>
      )}
    </div>
  );
}
