import React from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { ShieldCheck, ShieldAlert, AlertTriangle, Sparkles, Loader2, RefreshCw, Check, Info } from 'lucide-react';
import { Badge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { cn } from '../../../lib/utils';
import { fetchConfigReview, runConfigReview, acknowledgeConfigReview } from '../api';
import { fetchReleaseReview, runReleaseReview, acknowledgeReleaseReview, type ConfigReviewResp, type ConfigReviewVerdict } from '../../releases/api';

export type ReviewResource = 'configmap' | 'release';

const RESOURCE: Record<ReviewResource, {
  reviewKey: (id: string) => unknown[];
  detailKey: (id: string) => unknown[];
  fetch: (id: string) => Promise<ConfigReviewResp>;
  run: (id: string, force: boolean) => Promise<ConfigReviewResp>;
  ack: (id: string) => Promise<unknown>;
}> = {
  configmap: {
    reviewKey: (id) => ['configmap-review', id],
    detailKey: (id) => ['configmap-detail', id],
    fetch: fetchConfigReview,
    run: runConfigReview,
    ack: acknowledgeConfigReview,
  },
  release: {
    reviewKey: (id) => ['release-review', id],
    detailKey: (id) => ['release', id],
    fetch: fetchReleaseReview,
    run: runReleaseReview,
    ack: acknowledgeReleaseReview,
  },
};

export function useConfigReview(id: string, resource: ReviewResource = 'configmap') {
  const r = RESOURCE[resource];
  return useQuery({
    queryKey: r.reviewKey(id),
    queryFn: () => r.fetch(id),
    enabled: !!id,
    refetchInterval: (query) => (query.state.data?.available ? false : 5000),
  });
}

const VERDICT_META: Record<ConfigReviewVerdict, { label: string; variant: 'success' | 'warning' | 'danger'; Icon: typeof ShieldCheck }> = {
  SAFE: { label: 'Safe', variant: 'success', Icon: ShieldCheck },
  POTENTIALLY_BREAKING: { label: 'Potentially breaking', variant: 'warning', Icon: AlertTriangle },
  BREAKING: { label: 'Breaking', variant: 'danger', Icon: ShieldAlert },
};


const STATE_META: Record<string, { cls: string; Icon: typeof Info; spin?: boolean; label: string }> = {
  pending:     { cls: 'border-amber-200 bg-amber-50 text-amber-800',  Icon: Loader2,       spin: true, label: 'AI review in progress' },
  failed:      { cls: 'border-orange-300 bg-orange-50 text-orange-800', Icon: AlertTriangle,           label: 'AI review failed to run' },
  unavailable: { cls: 'border-yellow-300 bg-yellow-50 text-yellow-800', Icon: Info,                    label: 'AI review unavailable' },
};

export const ReviewStatusBanner: React.FC<{ review?: ConfigReviewResp; onView?: () => void }> = ({ review, onView }) => {
  if (!review || review.available) return null;
  const meta = review.state ? STATE_META[review.state] : undefined;
  if (!meta) return null;
  return (
    <div className={cn('mb-4 flex flex-col sm:flex-row sm:items-center sm:justify-between gap-2 rounded-xl border px-4 py-3', meta.cls)}>
      <div className="flex items-start gap-2.5 text-sm">
        <meta.Icon className={cn('w-4 h-4 mt-0.5 shrink-0', meta.spin && 'animate-spin')} />
        <span>
          <span className="font-medium">{meta.label}.</span>{' '}
          {review.reason ? `${review.reason} ` : ''}This does not block approval.
        </span>
      </div>
      {onView && (
        <Button size="sm" variant="outline" className="shrink-0" onClick={onView}>Details</Button>
      )}
    </div>
  );
};

/** Verdict badge — reused by the tracker warning banner too. */
export const VerdictBadge: React.FC<{ verdict: ConfigReviewVerdict; size?: 'sm' | 'md' }> = ({ verdict, size = 'sm' }) => {
  const m = VERDICT_META[verdict];
  if (!m) return null;
  return (
    <Badge variant={m.variant} size={size}>
      <m.Icon className="w-3.5 h-3.5" /> {m.label}
    </Badge>
  );
};

const fmtTs = (ts?: string | null) => {
  if (!ts) return '';
  const d = new Date(ts);
  if (isNaN(d.getTime())) return ts;
  return d.toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: true }) + ' IST';
};

const ConfigReviewPanel: React.FC<{ id: string; appGroup?: string; resource?: ReviewResource }> = ({ id, appGroup, resource = 'configmap' }) => {
  const qc = useQueryClient();
  const r = RESOURCE[resource];
  const { data, isLoading } = useConfigReview(id, resource);

  const invalidate = () => {
    qc.invalidateQueries({ queryKey: r.reviewKey(id) });
    // The approve-gate reads the tracker's metadata.ai_review — refresh it too.
    qc.invalidateQueries({ queryKey: r.detailKey(id) });
  };

  const rerun = useMutation({
    mutationFn: () => r.run(id, true),
    onSuccess: (d) => { qc.setQueryData(r.reviewKey(id), d); invalidate(); },
  });
  const ack = useMutation({
    mutationFn: () => r.ack(id),
    onSuccess: invalidate,
  });

  const d: ConfigReviewResp | undefined = data;
  const verdict = d?.verdict ?? undefined;

  return (
    <div className="p-4 sm:p-6 space-y-4">
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-2">
        <div className="flex items-center gap-2">
          <Sparkles className="w-4 h-4 text-violet-500" />
          <h3 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider">AI Config Review</h3>
          {verdict && <VerdictBadge verdict={verdict} />}
        </div>
        <PermissionGate product="autopilot" permission="AI_ASSESS" appGroup={appGroup}>
          <Button size="sm" variant="outline" loading={rerun.isPending} onClick={() => rerun.mutate()}>
            <RefreshCw className="w-3.5 h-3.5" /> {d?.available ? 'Re-run review' : 'Run review'}
          </Button>
        </PermissionGate>
      </div>

      {isLoading && !d && (
        <div className="flex items-center gap-2 text-sm text-zinc-500"><Loader2 className="w-4 h-4 animate-spin" /> Loading review…</div>
      )}

      {d && !d.available && (
        <div className="flex items-center gap-2 text-sm text-zinc-500">
          {rerun.isPending ? <Loader2 className="w-4 h-4 animate-spin" /> : null}
          {d.reason || 'No AI review has run for this config yet.'}
        </div>
      )}

      {d && d.available && (
        <>
          {d.blocksApproval && (
            <div className="rounded-lg border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-800">
              This change was flagged as <span className="font-semibold">potentially breaking</span>. Approval is blocked until an operator acknowledges the warning.
            </div>
          )}

          <div className="text-[11px] text-zinc-400 flex flex-wrap gap-x-4 gap-y-1">
            {d.model && <span>Model: <span className="text-zinc-500 font-medium">{d.model}</span></span>}
            {d.reviewedAt && <span>Reviewed: {fmtTs(d.reviewedAt)}</span>}
            {d.ackBy && <span>Acknowledged by {d.ackBy}{d.ackAt ? ` · ${fmtTs(d.ackAt)}` : ''}</span>}
          </div>

          {d.summary && (
            <div className="rounded-lg border border-zinc-200 bg-zinc-50 p-4 text-xs sm:text-sm text-zinc-800 whitespace-pre-wrap leading-relaxed">
              {d.summary}
            </div>
          )}

          {d.blocksApproval && (
            <PermissionGate product="autopilot" permission="CONFIG_EDIT" appGroup={appGroup}>
              <Button size="sm" variant="success" loading={ack.isPending} onClick={() => ack.mutate()}>
                <Check className="w-3.5 h-3.5" /> Acknowledge &amp; allow approval
              </Button>
            </PermissionGate>
          )}
        </>
      )}
    </div>
  );
};

export default ConfigReviewPanel;
