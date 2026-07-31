# Mobile product split — autopilot (BE-only) vs mobile (builds + OTA)

**Date:** 2026-07-31 · **Status:** IMPLEMENTED (phases 1–6, branch db-changes)
**Decisions (frozen):** slug = `mobile` · existing product-level autopilot grants are **mirrored** onto mobile · `mobile/*` wildcard rows **collapse** into product-level mobile grants (wildcard machinery deleted).
**Implementation deltas:** wire names are `MB_`-prefixed (constructor == wire, OTA pattern) per user decision; a ninth verb `MB_RELEASE_ABORT` + `POST /mobile/releases/:id/abort` (MobileBuild-only, per-app scoped) was added so scoped mobile grants can cancel their own builds — mobile counts are 9 MB + 9 OTA = 18, Viewer 2, Manager 15. Migration landed as `0049-mobile-product-split.sql`, verified idempotent against the dev DB (mirror + greatest-role-wins collapse + re-slug/re-point all exercised).

## Goal

Split the single `autopilot` product into two grantable products so product-level
grants mean what admins expect:

| Product | Slug | Universe |
|---|---|---|
| Autopilot | `autopilot` | BE only: BE release lifecycle, config, stagger, AI (BE), force-unlock |
| Mobile (incl. OTA) | `mobile` | `MB_*` mobile verbs + the **entire `OTA_*` family** |
| Airborne OTA | `airborne-ota` | unchanged: route namespace + tile only, never grantable; alias → `mobile` |

Post-split, a scoped mobile grant **cannot** confer BE access *structurally*
(BE verbs don't exist in mobile's universe; BE gates check a slug the person
has no rows for) — closing today's two soft leaks (auto-Viewer BE visibility,
deployment-fallback opening BE route gates).

## Verb partition (from the route audit, 2026-07-31)

- **Move out of `AutopilotPermission`** (only non-mobile occurrence is their own
  `KnownPermission` instance): `AP_MOBILE_DISPATCH`, `AP_MOBILE_APP_MANAGE`,
  `AP_RELEASE_PROMOTE`, `AP_RELEASE_ROLLOUT`.
- **Shared — stay in autopilot AND get MB twins** (real BE usage):
  `RELEASE_VIEW` (21 BE sites), `RELEASE_CREATE` (13), `RELEASE_REVERT` (11),
  `AI_SUMMARIZE` (3).
- **BE-only — untouched** (21 verbs): RELEASE_UPDATE/APPROVE/DISCARD/DELETE/
  PAUSE/RESUME/ABORT, PRODUCT/SERVICE_CONFIG_*, CONFIG_*, FORCE_UNLOCK,
  MANAGE_STAGGER, AB_VALIDATION_EDIT, AI_ASK/ASSESS/AUDIT_VIEW.

**New `MobilePermission` ADT (8 constructors).** Wire text == constructor
(the OTA-family pattern: ADT constructor, DB strings and frontend names are
the identical `MB_`-prefixed spelling — self-disambiguating from autopilot's
prefix-stripped BE verbs in raw queries, audit rows and override UI):

```
MB_RELEASE_VIEW · MB_RELEASE_CREATE · MB_RELEASE_PROMOTE · MB_RELEASE_ROLLOUT
MB_RELEASE_REVERT · MB_MOBILE_DISPATCH · MB_MOBILE_APP_MANAGE · MB_AI_SUMMARIZE
```

Consequence: pre-split strings on migrated rows are REWRITTEN (not just
re-slugged) — see Phase 4 — and Phase 5 frontend checks use the `MB_*`
strings.

**Behavioral change (deliberate):** `allPermissions Autopilot` **drops the OTA
family** (it moves to Mobile). An autopilot role no longer confers OTA; the
mirror migration preserves continuity for existing grantees.

## Phase 1 — types (backend)

1. **New module** `src/Products/Mobile/Types/Permission.hs`: the ADT above +
   one `KnownPermission` instance per constructor (`permissionProduct = "mobile"`,
   name = prefix-stripped). Template: `Products/AirborneOta/Types/Permission.hs`.
   **Add to `scc.cabal` exposed-modules.**
2. `Products/Types.hs`:
   - `ProductSlug`: add `Mobile`; `productSlugToText Mobile = "mobile"`;
     `textToProductSlug "mobile" = Just Mobile`.
   - `Permission` union: add `MobilePerm MobilePermission`;
     `permissionToText (MobilePerm p)` strips `MB_`.
   - `allPermissions Mobile = map MobilePerm [minBound..] <> map OtaPerm [minBound..]`
   - `allPermissions Autopilot = map AutopilotPerm [minBound..]` (OTA family removed).
   - `isViewPerm (MobilePerm p) = p == MB_RELEASE_VIEW`.
   - `isManagerRestrictedPerm (MobilePerm p) = p == MB_MOBILE_APP_MANAGE`
     (OTA restrictions unchanged; autopilot's list drops the moved AP_MOBILE_APP_MANAGE).
3. `Products/Autopilot/Types/Permission.hs`: **delete** the 4 moved constructors
   (+ their KnownPermission instances). Every remaining reference becomes a
   compile error — that is the sweep's todo list.

## Phase 2 — route re-gate (backend, mechanical)

Rule: after this phase, `grep -r "'AP_" src/Products/Autopilot/Mobile/` returns
**zero**. All 47 gates in `Mobile/Routes.hs` flip `'AP_X` → `'MB_X`
(16 VIEW · 6 CREATE · 6 ROLLOUT · 5 PROMOTE · 4 REVERT · 4 DISPATCH ·
4 APP_MANAGE · 2 AI_SUMMARIZE). Plus:

- `Mobile/Auth.hs` — `requireAppPerm` / `requireAppPermAll` / `requireProductPerm`
  re-typed to `MobilePermission`.
- In-handler checks: `Handlers/{Ota,Release,Revert,Rollout,AppCatalog}.hs`,
  `Provenance.hs`.
- `Handlers/Ota.hs`: per-ref scope lists become
  `[("airborne-ota", ref), ("mobile", "<name>/<platform>")]`.
- `AirborneOta/Routes.hs` `accessH`: `computeEffectivePermissionsForAppGroups … "autopilot"`
  → `"mobile"` (and any other `"autopilot"` literals in the airborne tree).

## Phase 3 — auth core (backend)

- `Core/Auth/Protected.hs`:
  - `aliasGrantSlugs "airborne-ota" = ["mobile"]`.
  - **Product-level alias fix** (already drafted, uncommitted in the working
    tree): `checkPersonPermission`'s fallback also consults product-level access
    under alias slugs — a product-level mobile Admin opens `/airborne/*` with
    zero scoped rows. Lands with this phase.
- `Core/Auth/Queries.hs`: **delete** `mobileWildcard` + the wildcard branch in
  `deploymentRowFor` and the batched variant (collapse decision — no wildcard
  rows exist post-migration).
- `ensureDefaultProductAccess` needs no code change (slug flows from the admin
  request) but now targets `mobile` Viewer for mobile scoped grants — the
  migration MUST seed mobile system roles or the ensure silently no-ops.

## Phase 4 — data migration

`backend/dev/migrations/system-control/00XX-mobile-product-split.sql`
(next free number at implementation time) + same section added to the dev seed.
**Prod is hand-applied via Cloud SQL Studio: plain DML/DDL only, NO dollar
quoting.** All statements idempotent.

1. **Seed mobile system roles** (permissions NULL — derived from the ADT):
   `INSERT INTO sc_role (product_slug, name, description, is_system_role)
    VALUES ('mobile','Admin',…,true),('mobile','Manager',…,true),('mobile','Viewer',…,true)
    ON CONFLICT (product_slug, name) DO NOTHING;`
2. **Mirror product-level grants** (system roles map by name):
   `INSERT INTO sc_person_product_access (person_id, product_slug, role_id)
    SELECT pa.person_id, 'mobile', r_new.id
    FROM sc_person_product_access pa
    JOIN sc_role r_old ON r_old.id = pa.role_id AND r_old.product_slug='autopilot' AND r_old.is_system_role
    JOIN sc_role r_new ON r_new.product_slug='mobile' AND r_new.name = r_old.name
    ON CONFLICT (person_id, product_slug) DO NOTHING;`
   Custom autopilot roles: create a mobile twin holding the mobile/OTA subset of
   `permissions[]` — mapping old spellings to the MB_ wire names
   (`MOBILE_DISPATCH`→`MB_MOBILE_DISPATCH`, `MOBILE_APP_MANAGE`→`MB_MOBILE_APP_MANAGE`,
   `RELEASE_PROMOTE`→`MB_RELEASE_PROMOTE`, `RELEASE_ROLLOUT`→`MB_RELEASE_ROLLOUT`,
   `RELEASE_VIEW/CREATE/REVERT`→`MB_…`, `AI_SUMMARIZE`→`MB_AI_SUMMARIZE`,
   `OTA_*` unchanged) — only when non-empty; mirror those grants to the twins.
   Dead mobile/OTA strings left inside autopilot custom roles are harmless
   (not in autopilot's universe).
3. **Collapse wildcards** (BEFORE re-slug, so `LIKE '%/%'` doesn't catch them):
   upsert product-level mobile grant per `(person, 'autopilot', 'mobile/*', role)`
   row with **greatest-role-wins** (rank Admin>Manager>Viewer via CASE on
   conflict), then `DELETE` the wildcard rows.
4. **Re-slug per-app scoped rows**:
   `UPDATE sc_person_deployment_access SET product_slug='mobile'
    WHERE product_slug='autopilot' AND app_group LIKE '%/%';`
   (Safe by the invariant that BE deployment names never contain `/`.)
5. **Move overrides** — only unambiguous verbs, re-slug AND rename:
   `UPDATE sc_person_permission_override
    SET product_slug='mobile', permission_action='MB_' || permission_action
    WHERE product_slug='autopilot'
      AND permission_action IN ('MOBILE_DISPATCH','MOBILE_APP_MANAGE',
                                'RELEASE_PROMOTE','RELEASE_ROLLOUT');`
   plus `OTA_*` overrides re-slug only (names unchanged):
   `UPDATE sc_person_permission_override SET product_slug='mobile'
    WHERE product_slug='autopilot' AND permission_action LIKE 'OTA\_%';`
   Shared-verb overrides (`RELEASE_VIEW/CREATE/REVERT`, `AI_SUMMARIZE`) stay on
   autopilot (BE intent presumed) — run an inspect SELECT first and eyeball.
6. Legacy per-ref `airborne-ota` deployment rows: untouched (accessH still
   unions them; alias keeps them working).

## Phase 5 — frontend (~10 files)

- `products/registry.ts`: mobile-releases ProductDefinition `slug: 'mobile'`,
  `viewPermission: 'MB_RELEASE_VIEW'` (BE def keeps `autopilot`); add `'mobile'`
  to the three slug-keyed iconMaps (ProductLayout, Sidebar, LauncherPage) and
  any slug-keyed lookups/React keys.
- Re-slug AND re-name 11 `hasPermission('autopilot', …)` sites in 5 mobile
  files — both arguments change: `('autopilot','MOBILE_DISPATCH',…)` →
  `('mobile','MB_MOBILE_DISPATCH',…)`:
  `MobileBulkPanel`, `CreateMobileRelease`, `ReleaseGroupDetail`,
  `MobileReleaseSummary`, `StoreReleaseCockpit` (`CreateRelease.tsx` is BE — untouched).
- `core/auth/PermissionsContext.tsx`: `otaAliasHas` reads `permMap['mobile']` /
  `deploymentPermMap['mobile']`; **delete** the `'mobile/*'` wildcard branch.
- `core/admin/pages/UserDetail.tsx`: ACCESS_SURFACES mobile → `productSlug: 'mobile'`;
  product dropdown offers `mobile` ("Mobile Releases (incl. OTA)") and relabels
  autopilot ("Autopilot — backend"); remove any `mobile/*` option.
- `core/admin/pages/AccessControl.tsx`, `airborne-ota/pages/OtaAppOverview.tsx`,
  `products/README.md`: slug/label touch-ups.
- Admin product/role/permission lists need no code: they derive from the ADT
  via `/admin/products*` endpoints.

## Phase 6 — tests, docs, verification

- `test/Main.hs`: new derived-count assertions — mobile: 17 total (8 MB + 9 OTA),
  Viewer 2 (`MB_RELEASE_VIEW`+`OTA_VIEW`), Manager 14 (17 − APP_MANAGE −
  OTA_RELEASE_DISCARD − OTA_APP_MANAGE); autopilot: shrinks by 4 moved + 9 OTA.
- Docs: `docs/OTA_MOBILE_RELEASE_INTEGRATION.md` §RBAC + root `CLAUDE.md`
  (product list, unified-grant wording) + memory note.
- **Manual matrix** (authed curls + UI), each row against BE pages / mobile pages / OTA:
  1. autopilot Admin only → BE full · mobile hidden/403 · OTA hidden.
  2. mobile Admin only (product-level, zero scoped rows) → BE hidden/403 ·
     mobile full · **OTA dashboard opens** (exercises the Phase-3 gate fix).
  3. mobile scoped `NammaYatri/android` Admin only → NY builds+OTA only ·
     BE zero (auto-Viewer lands on mobile) · other apps hidden.
  4. Pre-split product-level autopilot grantee (mirrored) → behavior identical
     to pre-split everywhere.
  5. Superadmin → everything.
  6. BE regression: create/approve/BE-rollout, config pages, stagger untouched.
- `grep -r "'AP_" src/Products/Autopilot/Mobile/` → 0;
  `grep -rn "mobile/\*" src/` → 0 (code); `sc-build` -Wall clean; `sc-test`.

## Rollout order (prod)

File layout (post-restructure): migration `0049` carries ONLY the mobile
system-role seed (the first-time-deployment requirement); the one-off grant
transform for existing environments lives in
`backend/scripts/prod-mobile-product-split.sql` (idempotent operator runbook,
Cloud SQL Studio-safe).

1. **Pre-deploy (additive, old binary unaffected):** apply `0049`, then the
   script's §1–§2 (twins + mirror). Old code never reads slug `mobile`.
2. **Deploy** backend + frontend together.
3. **Immediately after:** the script's §3–§5 (collapse, re-slug, overrides).
   Between 2 and 3, scoped-only users are briefly degraded (their rows still
   say `autopilot`); product-level users are covered by the pre-applied
   mirror. Keep the window to minutes.
4. Users re-login once (stale permission maps in localStorage).

## Sizing

~14 backend files edited (incl. `scc.cabal`, tests) + 2 new (ADT module,
migration) + ~10 frontend + 2 docs ≈ **28 files**; ~2–2.5 days including the
verification matrix. Design-heavy: `Products/Types.hs`, the new ADT,
`Core/Auth/Protected.hs`, the migration. Everything else is compiler- or
grep-verified sweep.
