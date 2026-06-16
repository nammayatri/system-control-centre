// The Mobile tab's configs, split into display sub-categories. This is the single
// source of truth — MOBILE_SERVER_CONFIG_NAMES is derived from it, so adding a key
// here is enough. (Mobile secrets — GitHub App / Play / App Store Connect /
// SC_AI_API_KEY — are NOT here: they live in env, never server_config.)
export const MOBILE_CONFIG_CATEGORIES: { name: string; keys: string[] }[] = [
  {
    name: 'Build & Dispatch',
    keys: ['mobile_dispatch_enabled', 'mobile_tag_confirm_timeout_minutes'],
  },
  {
    name: 'Store Sync',
    keys: ['store_sync_enabled', 'store_sync_interval_minutes', 'version_preview_enabled'],
  },
  {
    // Promote-to-review + staged rollout (mobile_staged_rollout_enabled gates the feature).
    name: 'Release Review & Rollout',
    keys: [
      'mobile_staged_rollout_enabled',
      'review_poll_interval_sec',
      'review_poll_timeout_days',
      'android_review_rollout_fraction',
    ],
  },
  {
    // AI (Grid) changelog summaries.
    name: 'AI Changelog',
    keys: ['ai_enabled', 'ai_base_url', 'ai_model', 'ai_allowed_host_suffix', 'ai_temperature', 'ai_cache_ttl_hours'],
  },
];

// Flat set of every config key on the Mobile tab (derived from the categories above).
export const MOBILE_SERVER_CONFIG_NAMES = new Set<string>(
  MOBILE_CONFIG_CATEGORIES.flatMap(c => c.keys),
);

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
