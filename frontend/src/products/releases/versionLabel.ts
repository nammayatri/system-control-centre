/**
 * Display label for a release version, with the build number (version code)
 * appended for mobile builds that carry one — e.g. "3.3.17 (460)".
 *
 * The version code is mobile-only (a backend release's `release_context` is
 * K8s-shaped and has none), so its presence is the signal: backend releases and
 * mobile rows without a code fall back to just the version string.
 */
export function versionWithBuild(release: {
  new_version?: string;
  release_context?: { version_code?: number | null } | null;
}): string {
  const v = release.new_version || '';
  const code = release.release_context?.version_code;
  return v && code != null ? `${v} (${code})` : v;
}
