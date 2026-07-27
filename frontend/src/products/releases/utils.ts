// Shared presentation helpers for the releases module: version / build-code /
// percent / age formatting, reused across list, detail, monitor, modal, and admin
// so the same value reads identically on every surface.

/** One stage after alias resolution; fields are undefined only when truly absent
 *  from the source row, so callers can apply their own context-appropriate default. */
export interface RawStrategyStage {
  rolloutPercent: number | undefined;
  cooloffMinutes: number | undefined;
  podCount: number | undefined;
}

// Parses a stored rollout/revert `deployment_config` strategy value into a flat
// list of stages. Handles double/triple-escaped JSON strings (DB round-trips can
// stack an extra layer of stringification) and the legacy single-object wrapper
// shape `[{cluster, rollouts: [...]}]` predating multi-stage support.
//
// The wrapper is only unwrapped when unambiguous — exactly one element, a nested
// `rollouts` array, and no flat `rolloutPercent` of its own — so a real multi-stage
// flat array is never collapsed just because a corrupted first element happens to
// carry a stray `rollouts` key (this exact corruption has occurred in production:
// an old wrapper object merged with new flat fields on save). Both the release
// form (read path) and the deployment-config edit modal (read+write path) must
// call this so their shape handling can't drift apart again.
export function parseStrategyStages(raw: unknown): RawStrategyStage[] {
  let parsed: any = raw;
  for (let i = 0; i < 3 && typeof parsed === 'string'; i++) {
    try {
      parsed = JSON.parse(parsed);
    } catch {
      return [];
    }
  }
  if (!Array.isArray(parsed) || parsed.length === 0) return [];

  const first = parsed[0];
  const isLegacyWrapper =
    parsed.length === 1 &&
    first &&
    typeof first === 'object' &&
    Array.isArray(first.rollouts) &&
    first.rolloutPercent === undefined;
  const list = isLegacyWrapper ? first.rollouts : parsed;
  if (!Array.isArray(list)) return [];

  return list.map((r: any) => ({
    rolloutPercent: r?.rolloutPercent ?? r?.rollout,
    cooloffMinutes: r?.cooloffMinutes ?? r?.cooloff,
    podCount: r?.podCount ?? r?.pods ?? r?.podPercent,
  }));
}

/** A build code rendered consistently as `+460` (empty when absent). */
export function formatBuildCode(code: number | null | undefined): string {
  return code != null ? `+${code}` : '';
}

// Display label for a release version, with the build number appended for mobile
// builds that carry one (e.g. "3.3.17 +460"). The version code is mobile-only, so
// its presence is the signal; backend rows fall back to just the version string.
export function versionWithBuild(release: {
  new_version?: string;
  release_context?: { version_code?: number | null } | null;
}): string {
  const v = release.new_version || '';
  const code = release.release_context?.version_code;
  return v && code != null ? `${v} ${formatBuildCode(code)}` : v;
}

/** A rollout %, trimmed to 1 decimal (10 → "10", 12.5 → "12.5"). */
export function formatRolloutPercent(pct: number): string {
  return `${Math.round(pct * 10) / 10}`;
}

/** Relative "time ago" from an ISO timestamp ("never" when null). */
export function relativeAge(iso: string | null): string {
  if (!iso) return 'never';
  const s = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000));
  if (s < 60) return `${s}s ago`;
  const m = Math.round(s / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.round(m / 60);
  if (h < 24) return `${h}h ago`;
  return `${Math.round(h / 24)}d ago`;
}

// An INPROGRESS tracker row spans build → store review → rollout; label it by
// the backend phase tag (release_context.display_phase) instead of "in progress".
const PHASE_LABELS: Record<string, string> = {
  building: 'building',
  internal_held: 'internal (held)',
  in_review: 'in review',
  approved: 'approved (held)',
  rolling_out: 'rolling out',
  halted: 'halted',
  live: 'live',
};

/** Human phase label for an in-flight row ("in flight" when the tag is unknown). */
export function inFlightPhaseLabel(release: {
  release_context?: { display_phase?: string } | null;
}): string {
  return PHASE_LABELS[release.release_context?.display_phase ?? ''] ?? 'in flight';
}
