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
]);

export const isMobileServerConfig = (name: string): boolean =>
  MOBILE_SERVER_CONFIG_NAMES.has(name);
