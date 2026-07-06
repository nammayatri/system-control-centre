-- Config rows the staged-rollout product needs but 0027 never seeded — without
-- them a fresh deployment silently runs with the feature OFF:
--
--   mobile_staged_rollout_enabled — gates every promote/rollout handler
--     (requireStaged) AND the store-sync reconcilers (isStagedRolloutEnabled);
--     the code default is FALSE, so an unseeded database disables the product.
--   mobile_tag_confirm_timeout_minutes — real store builds regularly exceed the
--     60-minute code default; 180 is the operationally proven value.
--
-- INSERT-if-absent only (0001's pattern): an operator's later value is never
-- overwritten on the boot-time replay. mobile_slack_channel stays unseeded on
-- purpose — the channel is deployment-specific and slack_enabled defaults off.
INSERT INTO server_config (name, type, value, enabled, product)
SELECT 'mobile_staged_rollout_enabled', 'bool', 'true', 1, 'autopilot'
WHERE NOT EXISTS (
    SELECT 1 FROM server_config WHERE name = 'mobile_staged_rollout_enabled' AND product = 'autopilot'
);

INSERT INTO server_config (name, type, value, enabled, product)
SELECT 'mobile_tag_confirm_timeout_minutes', 'int', '180', 1, 'autopilot'
WHERE NOT EXISTS (
    SELECT 1 FROM server_config WHERE name = 'mobile_tag_confirm_timeout_minutes' AND product = 'autopilot'
);
