export const MOBILE_SERVER_CONFIG_NAMES = new Set([
  'mobile_dispatch_enabled',
  'mobile_run_poll_seconds',
  'github_app_id',
  'github_app_private_key',
  'github_app_installation_id',
  'play_console_service_account_json',
  'app_store_connect_issuer_id',
  'app_store_connect_key_id',
  'app_store_connect_private_key_p8',
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

// Configs that only apply to release/production envs. Store sync polls
// production stores and version preview fetches store versions — both are
// inert in a debug env, so hide them there (env === 'master').
export const RELEASE_ONLY_SERVER_CONFIG_NAMES = new Set([
  'store_sync_enabled',
  'store_sync_interval_minutes',
  'version_preview_enabled',
]);

export const isReleaseOnlyServerConfig = (name: string): boolean =>
  RELEASE_ONLY_SERVER_CONFIG_NAMES.has(name);
