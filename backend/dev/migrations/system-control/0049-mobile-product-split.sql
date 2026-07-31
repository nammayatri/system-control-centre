-- 0049: mobile product split — system roles for the new 'mobile' product
-- (docs/superpowers/plans/2026-07-31-mobile-product-split.md)
--
-- autopilot is BACKEND-ONLY; the 'mobile' product owns mobile builds + the
-- whole OTA family (MB_* + OTA_*, derived from the Haskell ADTs at runtime —
-- the permissions column stays at its default and is ignored for system
-- roles). This migration is the FIRST-TIME-DEPLOYMENT requirement only:
-- fresh environments need these roles; nothing else.
--
-- Upgrading an EXISTING environment (grants minted before the split) also
-- needs the one-off data transform — mirror product grants, collapse the
-- retired mobile/* wildcard, re-slug per-app rows, move overrides. That is a
-- deliberate, sequenced operator step, NOT an auto-applied migration:
--   backend/scripts/prod-mobile-product-split.sql
-- (On a fresh database it would be a pure no-op; on prod its ordering
-- relative to the binary deploy matters — see the script's header.)

INSERT INTO sc_role (product_slug, name, description, is_system_role) VALUES
  ('mobile', 'Admin',   'Full access to mobile builds + OTA', true),
  ('mobile', 'Manager', 'Operate mobile builds + OTA (no app catalog manage, no OTA discard)', true),
  ('mobile', 'Viewer',  'Read-only access to mobile builds + OTA', true)
ON CONFLICT (product_slug, name) DO NOTHING;
