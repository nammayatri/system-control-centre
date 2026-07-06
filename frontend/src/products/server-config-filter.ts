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
    keys: [ 'version_preview_enabled', 'store_refresh_cooldown_seconds'],
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
  {
    // Slack notifications. slack_enabled is the global toggle (shared with the
    // Backend tab — see SHARED_SERVER_CONFIG_NAMES); mobile_slack_channel is the
    // channel the post-build changelog is posted to.
    name: 'Slack',
    keys: ['mobile_slack_channel', 'slack_enabled'],
  },
];

// Configs surfaced on EVERY config tab (both Backend and Mobile). slack_enabled is
// the single global Slack toggle — it gates backend release notifications AND is
// relevant to mobile changelog posts — so it must be editable from both tabs.
export const SHARED_SERVER_CONFIG_NAMES = new Set<string>([
  'slack_enabled',
]);

export const isSharedServerConfig = (name: string): boolean =>
  SHARED_SERVER_CONFIG_NAMES.has(name);

// Mobile-ONLY config keys, which drive the tab filter. Derived from the categories
// above MINUS the shared ones: a shared key lives on both tabs, so it must not be
// treated as mobile-only (or the Backend-tab filter would exclude it).
export const MOBILE_SERVER_CONFIG_NAMES = new Set<string>(
  MOBILE_CONFIG_CATEGORIES.flatMap(c => c.keys).filter(k => !SHARED_SERVER_CONFIG_NAMES.has(k)),
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
