// Shared presentation helpers for the releases module: version / build-code /
// percent / age formatting, reused across list, detail, monitor, modal, and admin
// so the same value reads identically on every surface.

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
