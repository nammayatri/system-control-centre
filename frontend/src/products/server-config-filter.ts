// Config keys that belong to the Mobile tab. (Mobile secrets — GitHub App / Play /
// App Store Connect — are NOT here: they live in env, never server_config.)
export const MOBILE_SERVER_CONFIG_NAMES = new Set([
  'mobile_dispatch_enabled',
  'mobile_tag_confirm_timeout_minutes',
  'store_sync_enabled',
  'store_sync_interval_minutes',
  'version_preview_enabled',
]);

export const isMobileServerConfig = (name: string): boolean =>
  MOBILE_SERVER_CONFIG_NAMES.has(name);

// Configs that are surfaced by the backend (as unregistered DB rows) but must
// not appear in either config tab. mobile_build_type is a per-environment
// invariant set via migration — not an editable runtime toggle.
export const HIDDEN_SERVER_CONFIG_NAMES = new Set([
  'mobile_build_type',
]);

export const isHiddenServerConfig = (name: string): boolean =>
  HIDDEN_SERVER_CONFIG_NAMES.has(name);

// Configs that only apply to release deployments. Store sync polls production
// stores and version preview fetches store versions — both are inert when
// buildType is 'debug', so hide them there (see useAuth().buildType).
export const RELEASE_ONLY_SERVER_CONFIG_NAMES = new Set([
  'store_sync_enabled',
  'store_sync_interval_minutes',
  'version_preview_enabled',
]);

export const isReleaseOnlyServerConfig = (name: string): boolean =>
  RELEASE_ONLY_SERVER_CONFIG_NAMES.has(name);
