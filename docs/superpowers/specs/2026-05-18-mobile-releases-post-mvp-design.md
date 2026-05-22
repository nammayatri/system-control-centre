# Mobile Releases — Post-MVP Design (Consolidated)

| | |
|---|---|
| **Date** | 2026-05-18 (initial) — 2026-05-22 (latest) |
| **Author** | shivendra02shah@gmail.com (with assistant) |
| **Status** | Implemented |
| **Scope** | All mobile release features built after the MVP (`2026-05-11-mobile-releases-design.md`). Covers: mobile revert, branch picker, debug/release build types, latest build enrichment, periodic store sync, store-sync revert integration, platform filter, apps admin redesign, dispatch from summary page. |
| **Base spec** | `docs/superpowers/specs/2026-05-11-mobile-releases-design.md` (untouched) |
| **Source plan** | `docs/superpowers/plans/2026-05-18-mobile-releases-post-mvp.md` |

---

## Table of contents

1. [Mobile Revert](#1-mobile-revert)
2. [Store-Sync Revert Integration](#2-store-sync-revert-integration)
3. [Debug Build Exclusion from Revert](#3-debug-build-exclusion-from-revert)
4. [Revert-Build Exclusion & Reverted-Row Skipping](#4-revert-build-exclusion--reverted-row-skipping)
5. [Custom Commit Source for Revert](#5-custom-commit-source-for-revert)
6. [Branch Picker & Server-Side Search](#6-branch-picker--server-side-search)
7. [Debug & Release Build Types](#7-debug--release-build-types)
8. [Latest Build Enrichment](#8-latest-build-enrichment)
9. [Periodic Store Sync Job](#9-periodic-store-sync-job)
10. [Platform Filter on Release List](#10-platform-filter-on-release-list)
11. [Apps Admin Table Redesign](#11-apps-admin-table-redesign)
12. [Dispatch Button on Release Summary](#12-dispatch-button-on-release-summary)

---

## 1. Mobile Revert

### Problem

Mobile releases ship to production with no rollback path. The workflow's rollback hook is a no-op, and the dispatch ref was hardcoded to `"main"`. Operators had to manually trigger builds via GitHub Actions with no audit trail.

### Design decisions

| # | Question | Decision |
|---|---|---|
| 1 | What does "revert" mean? | **Forward-fix.** Ship the old code under a new, higher version. Bad v1.2.3+456 + previous good v1.2.2+450 -> revert ships v1.2.4+457 with the same commit as v1.2.2. |
| 2 | How to dispatch a specific commit? | **Via the existing release tag.** GitHub `workflow_dispatch.ref` only accepts branch/tag names. SCC dispatches with `ref = "refs/tags/<previous-good-tag>"`. |
| 3 | Does the operator see or type a tag? | **No.** Tags are implementation detail. Modal shows version + short SHA. |
| 4 | Default version-bump rule | **Patch bump.** `bumpPatch("1.2.3") = "1.2.4"`. Operator can override upward. |
| 5 | `version_code` rule | **Bad release's code + 1, mandatory floor.** Operator can override higher; server validates `new_code > bad.version_code`. |
| 6 | iOS version computation | **Same patch-bump for `version_number`.** Build number auto-computed by fastlane. |
| 7 | No previous good release? | **Revert button disabled.** Operator falls back to manual release. |
| 8 | Previous good is itself a revert? | **Use it anyway.** `reverts_release_id` chain self-documents. |
| 9 | Previous good tag deleted? | **Fail with clear error.** |
| 10 | Multi-app dispatch (siblings)? | **Per-app revert.** Each sibling reverted independently. |
| 11 | Bad release not COMPLETED? | **Revert disabled.** Use Abort for in-progress releases. |
| 12 | Where do new columns live? | **Three nullable columns on `release_tracker`**: `commit_sha`, `source_ref`, `reverts_release_id`. |
| 13 | Changelog source? | **Auto-generated from GitHub Compare API.** Renders commit list as "Reverting these N commits." Operator can edit. |
| 14 | Workflow YAML changes? | **None.** Workflows already accept override inputs and check out whatever ref the dispatch carries. |
| 15 | Permission? | **`AP_RELEASE_REVERT`** — existing permission. |
| 16 | Approval required? | **Yes.** Revert creates a normal `release_tracker` row with standard lifecycle. |
| 17 | Bad release row change? | **Yes.** `metadata.reverted_by = <revert-id>` backfilled when revert completes. |

### Data model

```sql
ALTER TABLE release_tracker
  ADD COLUMN IF NOT EXISTS commit_sha         TEXT,
  ADD COLUMN IF NOT EXISTS source_ref         TEXT,
  ADD COLUMN IF NOT EXISTS reverts_release_id TEXT;

CREATE INDEX IF NOT EXISTS idx_rt_commit_sha ON release_tracker(commit_sha);
CREATE INDEX IF NOT EXISTS idx_rt_reverts_release_id ON release_tracker(reverts_release_id);
```

All nullable. Old rows stay NULL. `source_ref IS NULL` means "use main".

### Endpoints

```
GET  /releases/:id/mobile-revert/draft   -> RevertDraft (preview)
POST /releases/:id/mobile-revert         -> { revertReleaseId } (create)
```

Both gated by `AP_RELEASE_REVERT`.

### Workflow dispatch change

`Mobile/Workflow.hs::stageDispatchWorkflow` reads `rtSourceRef`:

```haskell
let ref = fromMaybe "main" (rtSourceRef rt)
```

### Commit SHA capture

`stageResolveRunId` extracts `head_sha` from the GH run response and writes it to `release_tracker.commit_sha` in the same UPDATE.

### Changelog generation

`Mobile/Changelog.hs::renderRevertChangelog` produces markdown from Compare API commit list:

```
Revert of v{bad} -- rolling back to v{prevGood} code (commit {sha})
Rolling back the following {N} commits introduced in v{bad}:
* {message subject} (#{pr-number}) -- @{author}
Released as v{newVersion} (code {newCode}) for store version-code compatibility.
```

### Deviations from initial spec

1. **Full page instead of modal.** The revert UI is `/releases/:id/revert` — the changelog preview was too large for a modal on mobile screens.
2. **`metadata.reverted_by` set on workflow completion**, not at create time — prevents marking the bad release as "reverted" if the revert build is aborted.

### Files

| Area | Files |
|------|-------|
| Migration | `backend/dev/migrations/system-control/0012-mobile-revert.sql` |
| GitHub Compare | `backend/src/Products/Autopilot/Mobile/Github/Compare.hs` |
| Changelog | `backend/src/Products/Autopilot/Mobile/Changelog.hs` |
| Revert handlers | `backend/src/Products/Autopilot/Mobile/Handlers/Revert.hs` |
| Queries | `backend/src/Products/Autopilot/Mobile/Queries/Tracker.hs` (`findPreviousGoodMobileRelease`, `insertMobileRevertTracker`, `markReleaseRevertedBy`) |
| Workflow | `backend/src/Products/Autopilot/Mobile/Workflow.hs` (`source_ref` in dispatch, `commit_sha` in resolve-run, `markReleaseRevertedBy` in finalize) |
| Routes | `backend/src/Products/Autopilot/Mobile/Routes.hs` |
| Frontend: Revert page | `frontend/src/products/releases/pages/mobile/MobileRevert.tsx` |
| Frontend: Banners | `frontend/src/products/releases/pages/ReleaseSummary.tsx` |
| Frontend: List actions | `frontend/src/products/releases/pages/ListRelease.tsx` |

---

## 2. Store-Sync Revert Integration

### Problem

Store-synced releases appear as COMPLETED rows but have no Git tag (Android rows derive one from naming convention; iOS rows don't). Without special handling, `findPreviousGoodMobileRelease` would return a store-sync row as the "previous good" — breaking revert since there's no tag to dispatch from.

### Design

**Store-sync aware revert:**

1. **Derived Git tag on Android store-sync rows.** Store sync now derives `tag_pushed` using `{normalizeAppSegment(name)}/prod/android/v{version}+{code}`.
2. **Previous good = last SCC-dispatched release.** Handler calls `findPreviousGoodSCCRelease` (excludes `mode = 'STORE_SYNC'` rows).
3. **Commit diff when both tags exist.** If both bad and good tags are present, GitHub Compare returns real commits. Otherwise falls back to a simple changelog.
4. **Frontend banner.** Amber info box on revert page. Dynamic — checks actual commit data rather than just `isStoreSyncRevert` flag.

**Smarter version code suggestions (all reverts):**

1. `fetchLatestBuildsPerApp` called during draft generation.
2. `rdStoreVersion` and `rdStoreVersionCode` added to `RevertDraft`.
3. Suggested code = `max(badCode, storeCode) + 1`.
4. Server-side validation uses same floor.

### Files

| File | Change |
|------|--------|
| `backend/src/Products/Autopilot/Mobile/Queries/Tracker.hs` | `findPreviousGoodSCCRelease` |
| `backend/src/Products/Autopilot/Mobile/Handlers/Revert.hs` | `draftForSCCRevert`/`draftForStoreSyncRevert`, `maxCode`, store-aware validation |
| `frontend/src/products/releases/api.ts` | `rdIsStoreSyncRevert`, `rdStoreVersion`, `rdStoreVersionCode` |
| `frontend/src/products/releases/pages/mobile/MobileRevert.tsx` | Store-sync banner, version info, floor-code validation |

---

## 3. Debug Build Exclusion from Revert

### Problem

Debug builds receive `debug-no-tag` as `tag_pushed` — no real Git tag. Using a debug build as a revert target would dispatch from a non-existent tag. Reverting debug builds has no operational value (test/beta, not production).

### Design

1. **Backend guard**: Both draft and create handlers reject debug releases with a clear error message.
2. **Query filtering**: `findPreviousGoodMobileRelease` and `findPreviousGoodSCCRelease` skip debug-destination rows. Queries fetch up to 20 candidates and filter in Haskell via `firstNonDebug` (parses target state JSONB, checks `isDebugDestination`).
3. **Frontend**: Revert button hidden when `destination === 'Firebase' || 'TestFlight'` in both `ListRelease.tsx` and `ReleaseSummary.tsx`.

### Files

| File | Change |
|------|--------|
| `backend/src/Products/Autopilot/Mobile/Queries/Tracker.hs` | `firstNonDebug` filter, `isDebugDestination` import |
| `backend/src/Products/Autopilot/Mobile/Handlers/Revert.hs` | Debug-build guard in draft + create |
| `frontend/src/products/releases/pages/ListRelease.tsx` | `!isDebugBuild` condition |
| `frontend/src/products/releases/pages/ReleaseSummary.tsx` | Destination check |

---

## 4. Revert-Build Exclusion & Reverted-Row Skipping

### Problem

Without this, reverting a revert build (e.g. v3.3.26, created by reverting v3.3.25) would pick v3.3.25 as "previous good" — the original bad release. The operator would unknowingly rebuild the bad code.

### Design

1. **Backend guard**: Draft and create handlers check `rtRevertsReleaseId` — if set, reject with "This release was created by a revert and cannot be reverted further."
2. **Query filtering**: `firstNonDebug` also skips rows where `metadata` contains `reverted_by`. New `isReverted` helper parses metadata JSONB.
3. **`markReleaseRevertedBy` moved to workflow finalize**: Only set when revert reaches COMPLETED status. If aborted, bad release stays unmarked.
4. **Frontend**: Revert button hidden for revert builds (`revertsReleaseId` present). REVERT badge shown via both `revertsReleaseId` and backend `release_context.revert`.

### Files

| File | Change |
|------|--------|
| `backend/src/Products/Autopilot/Mobile/Handlers/Revert.hs` | `rtRevertsReleaseId` guard, removed `markReleaseRevertedBy` (moved to workflow) |
| `backend/src/Products/Autopilot/Mobile/Workflow.hs` | `markReleaseRevertedBy` in `execFinalize` |
| `backend/src/Products/Autopilot/Mobile/Queries/Tracker.hs` | `isReverted` helper |
| `frontend/src/products/releases/pages/ListRelease.tsx` | `isMobileRevertBuild` flag, REVERT badge |
| `frontend/src/products/releases/pages/ReleaseSummary.tsx` | `!revertsTarget` on revert button, REVERT badge |

---

## 5. Custom Commit Source for Revert

### Problem

The previous good release is not always the right revert target. Operators may want to build from a specific commit (hotfix, or several releases back). GitHub `workflow_dispatch` only accepts branch/tag names — not raw SHAs.

### Design

Two build source modes on the revert page:

1. **Previous good release** (default) — builds from the last SCC release's tag.
2. **Custom commit** — operator enters a SHA. SCC creates a temporary lightweight tag (`scc-revert/<releaseId>`) at that commit via GitHub API, then dispatches targeting that tag.

**New GitHub helpers:**
- `createGitRef` — `POST /repos/{owner}/{repo}/git/refs`
- `getCommitInfo` — `GET /repos/{owner}/{repo}/commits/{sha}` — resolves/validates, returns full SHA + subject + author + URL.

**New endpoint:** `GET /releases/:id/mobile-revert/verify-commit?sha=...` (gated by `AP_RELEASE_REVERT`)

**Frontend:** Radio toggle between sources. Custom commit mode shows SHA input + Verify button. On verify, shows green card with commit details. Validation requires hex format AND successful verification.

### Files

| File | Change |
|------|--------|
| `backend/src/Products/Autopilot/Mobile/Github.hs` | `createGitRef`, `getCommitInfo`, `CommitDetail` |
| `backend/src/Products/Autopilot/Mobile/Handlers/Revert.hs` | `rrSourceCommit` on `RevertReq`, `VerifyCommitResp`/`verifyCommitH`, commit verification in create |
| `backend/src/Products/Autopilot/Mobile/Routes.hs` | `verify-commit` endpoint |
| `frontend/src/products/releases/api.ts` | `rrSourceCommit`, `verifyRevertCommit` |
| `frontend/src/products/releases/pages/mobile/MobileRevert.tsx` | Source mode toggle, verify button, commit detail card |

---

## 6. Branch Picker & Server-Side Search

### Problem

Workflow dispatch ref was hardcoded to `"main"`. No UI for operators to select a different branch. The initial branch picker fetched 100 branches client-side, which didn't scale for repos with 500+ branches.

### Design — Branch picker (initial)

- Searchable combobox on Create Mobile Release form
- `GET /mobile/branches` endpoint using `listBranches` from GitHub API
- `sourceRef` on `CreateMobileReleasesReq`, persisted on tracker row
- `"main"` selected by default; NULL stored in DB for main (backward compatible)
- Non-main branches show a warning banner
- Release Summary shows "Source Branch" when set

### Design — Server-side search (enhancement)

- `GET /mobile/branches?q=...` uses GitHub's `matching-refs` API: `GET /repos/{owner}/{repo}/git/matching-refs/heads/{query}`
- Prefix-based search, results converted from refs format to branch names
- Empty/absent query returns `listBranches` with `main`/`master` pinned at top
- Frontend: 300ms debounced search, minimum 2 characters
- `useMobileBranches(search?)` with `placeholderData: keepPreviousData` (TanStack Query v5 syntax)

### Files

| File | Change |
|------|--------|
| `backend/src/Products/Autopilot/Mobile/Github.hs` | `BranchInfo`, `listBranches`, `searchBranches`, `BranchRefItem` |
| `backend/src/Products/Autopilot/Mobile/Handlers/Release.hs` | `sourceRef` on request, `listBranchesH` with `Maybe Text` query, `pinMain` |
| `backend/src/Products/Autopilot/Mobile/Queries/Tracker.hs` | `insertMobileTracker` persists `mSourceRef` |
| `backend/src/Products/Autopilot/Mobile/Routes.hs` | `GET /mobile/branches` with `QueryParam "q" Text` |
| `frontend/src/products/releases/types.ts` | `BranchInfo`, `sourceRef` on request |
| `frontend/src/products/releases/api.ts` | `mobileApi.listBranches(q?)` |
| `frontend/src/products/releases/hooks.ts` | `useMobileBranches(search?)`, `placeholderData: keepPreviousData` |
| `frontend/src/products/releases/pages/mobile/CreateMobileRelease.tsx` | Debounced server-side search combobox |
| `frontend/src/products/releases/pages/ReleaseSummary.tsx` | Source Branch field |

---

## 7. Debug & Release Build Types

### Problem

SCC's mobile workflow was built for production releases only. No way to trigger debug (internal testing) builds — operators had to use GitHub Actions directly.

### Design

Build type is determined from `MobileDestination`:

```haskell
data MobileDestination = MBGooglePlay | MBFirebase | MBTestFlight | MBAppStore

isDebugDestination :: MobileDestination -> Bool
isDebugDestination MBFirebase   = True
isDebugDestination MBTestFlight = True
isDebugDestination _            = False
```

**`app_catalog.debug_workflow_path`** — nullable column. If NULL, falls back to `workflow_path`.

### Workflow stage differences

| Stage | Release build | Debug build |
|-------|--------------|-------------|
| ResolveVersion | Queries Play Console / ASC | Skips entirely |
| DispatchWorkflow | Full inputs to release workflow | Only `selected_apps` + `change_log` to debug workflow |
| ResolveRunId | Polls on release workflow path | Polls on debug workflow path |
| MonitorMatrixJob | `{app}-Release` job name | `{app}-Debug` job name |
| ConfirmTag | Polls for tag | Writes `debug-no-tag`, advances immediately |
| Slack/complete | Normal | Normal |

### Frontend

- Build Type toggle on Create form maps to destination via `destinationFor(buildType, platform)`
- DEBUG badge (amber) on list rows and detail page header
- Version fields hidden for debug builds on create form

### Files

| File | Change |
|------|--------|
| `backend/src/Products/Autopilot/Mobile/Types.hs` | `isDebugDestination` |
| `backend/src/Products/Autopilot/Mobile/Types/Storage.hs` | `acDebugWorkflowPath` |
| `backend/src/Products/Autopilot/Mobile/Workflow.hs` | Debug early-returns in 5 stages |
| `backend/src/Products/Autopilot/Mobile/Handlers/Release.hs` | Matrix job name suffix |
| `backend/src/Products/Autopilot/Mobile/Handlers/Revert.hs` | Matrix job name suffix |
| `backend/src/Products/Autopilot/Mobile/Handlers/AppCatalog.hs` | `debugWorkflowPath` in response + PATCH |
| `backend/src/Products/Autopilot/Mobile/Queries/AppCatalog.hs` | `debugWorkflowPath` in INSERT/UPDATE |
| `frontend/src/products/releases/types.ts` | `BuildType`, `destinationFor` |
| `frontend/src/products/releases/pages/mobile/CreateMobileRelease.tsx` | Build type toggle |
| `frontend/src/products/releases/pages/ListRelease.tsx` | DEBUG badge |
| `frontend/src/products/releases/pages/ReleaseSummary.tsx` | DEBUG badge |

---

## 8. Latest Build Enrichment

### Problem

The app catalog API returned only static metadata. Operators had no visibility into what was last built — had to check GitHub or the store console.

### Design

Enrich `GET /mobile/apps` with the latest completed build per app, per build type (debug/release).

**Query:** `fetchLatestBuildsPerApp` uses `ROW_NUMBER() OVER (PARTITION BY ...)` to find the most recent COMPLETED row per (app, surface, platform, build_type).

**Response additions:**

```haskell
data LatestBuildResp = LatestBuildResp
    { version, versionCode, destination, tagPushed, commitSha, completedAt }
```

Added `latestReleaseBuild` and `latestDebugBuild` to `AppCatalogEntryResp`.

**Frontend UI:**

| Page | Component | Display |
|------|-----------|---------|
| Create Mobile Release | `LatestBuildBadge` | Color-coded badge per app card |
| Mobile Apps Admin | `BuildCell` | Two columns: Latest Release + Latest Debug |
| Release Summary | `PrevBuildBadge` | Latest builds line in Mobile Build section |

### Files

| File | Change |
|------|--------|
| `backend/src/Products/Autopilot/Mobile/Queries/AppCatalog.hs` | `LatestBuildRow`, `fetchLatestBuildsPerApp` |
| `backend/src/Products/Autopilot/Mobile/Handlers/AppCatalog.hs` | `LatestBuildResp`, enriched response |
| `frontend/src/products/releases/types.ts` | `LatestBuild` type |
| `frontend/src/products/releases/pages/mobile/CreateMobileRelease.tsx` | `LatestBuildBadge` |
| `frontend/src/products/releases/pages/mobile/MobileAppsAdmin.tsx` | `BuildCell`, two new columns |
| `frontend/src/products/releases/pages/ReleaseSummary.tsx` | `PrevBuildBadge` |

---

## 9. Periodic Store Sync Job

### Problem

Apps released outside SCC (hotfixes, manual fastlane runs) make latest-build data stale. Also serves as the backfill mechanism on first run.

### Design

**Module:** `Products/Autopilot/Mobile/StoreSync.hs`

- `storeSyncLoop :: Flow ()` — long-running background loop with error recovery
- `runStoreSync :: Flow ()` — single sync pass

**Scheduling:** Forked via `forkFlow` in both `RUNNER` and `SERVER` modes.

**Store API clients (reused):**

| Platform | Source | Destination |
|----------|--------|-------------|
| Android release | `fetchPlayTracks` (production track) | `MBGooglePlay` |
| iOS release | `fetchAscVersions` (TestFlight proxy) | `MBAppStore` |
| Android debug | Not synced (always via SCC) | — |
| iOS debug | Not synced | — |

**Synthetic row:** `mode = 'STORE_SYNC'`, `created_by = 'store-sync'`, full `MobileBuildState` in `release_context`.

**Android tag derivation:** `{normalizeAppSegment(name)}/prod/android/v{version}+{code}` — enables commit diffs on revert.

**Configuration:** `store_sync_enabled` (default false) and `store_sync_interval_minutes` (default 30) in `server_config`.

**Error handling:** Per-app failures logged and skipped. Idempotent: same version = no insert.

### Files

| File | Change |
|------|--------|
| `backend/src/Products/Autopilot/Mobile/StoreSync.hs` | New module |
| `backend/src/Products/Autopilot/RuntimeConfig.hs` | `isStoreSyncEnabled`, `getStoreSyncIntervalMinutes` |
| `backend/src/Products/Autopilot/Runner.hs` | `forkFlow storeSyncLoop` |
| `backend/app/Main.hs` | `forkFlow storeSyncLoop` in SERVER mode |
| `backend/dev/migrations/system-control/0015-store-sync-config.sql` | Config seeds |

---

## 10. Platform Filter on Release List

### Problem

When viewing mobile releases, the list mixes Android and iOS rows with no way to narrow by platform.

### Design

New `platformFilter` state (`''` | `'android'` | `'ios'`) in `ListRelease.tsx`. A dropdown renders conditionally when `category === 'mobile'`. Filtering matches `release.env` (which stores `acPlatform` for mobile rows). Resets automatically when category changes away from mobile. Both desktop and mobile responsive layouts include the dropdown.

### Files

| File | Change |
|------|--------|
| `frontend/src/products/releases/pages/ListRelease.tsx` | `platformFilter` state, conditional dropdown, platform match in `filteredReleases`, auto-reset |

---

## 11. Apps Admin Table Redesign

### Problem

The Mobile Apps admin table had 10 columns, required horizontal scrolling, and didn't visually distinguish platforms or enabled/disabled status.

### Design

1. **Platform badges**: Green pill with Android icon, gray pill with Apple icon.
2. **Compact columns (10 -> 7)**: Merged Name + Surface into "App". Merged Repo + Release Workflow + Debug Workflow into "Workflows" (filename only, full path on hover). Removed Repo column.
3. **Enabled apps sorted to top**: `useMemo` sort — enabled first, then alphabetical by display label. Disabled rows at 50% opacity.
4. **No horizontal scroll**: Compact columns eliminate overflow.

### Files

| File | Change |
|------|--------|
| `frontend/src/products/releases/pages/mobile/MobileAppsAdmin.tsx` | `PlatformBadge`, `wfShort`, `useMemo` sort, redesigned 7-column table, mobile card view |

---

## 12. Dispatch Button on Release Summary

### Problem

The only way to dispatch an approved mobile release was via the Release Group Detail page's bulk action. Operators viewing an individual release summary had Approve but no Dispatch.

### Design

New Dispatch button on `ReleaseSummary.tsx` when `status === 'CREATED' && isMobile && is_approved`. Calls `useDispatchMobileReleases` with the single release ID. Gated by `AP_MOBILE_DISPATCH` permission. Uses confirmation dialog.

`useDispatchMobileReleases` enhanced with success toast and `['release']` cache invalidation.

### Files

| File | Change |
|------|--------|
| `frontend/src/products/releases/pages/ReleaseSummary.tsx` | `useDispatchMobileReleases` + `Send` icon, Dispatch button |
| `frontend/src/products/releases/hooks.ts` | Success toast + `['release']` invalidation |

---

## Dependency chain

```
[Mobile Revert] ---> [Store-Sync Revert Integration]
     |                         |
     +--> [Debug Build Exclusion]
     +--> [Revert-Build Exclusion]
     +--> [Custom Commit Source]

[Branch Picker] ---> [Server-Side Search]

[Debug/Release Build Types] (independent)

[Latest Build Enrichment] ---> [Periodic Store Sync] ---> [Revert Integration]

[Platform Filter] (independent, frontend-only)
[Apps Admin Redesign] (independent, frontend-only)
[Dispatch from Summary] (independent, frontend-only)
```

---

## References

- Base MVP spec: `docs/superpowers/specs/2026-05-11-mobile-releases-design.md`
- Base MVP plan: `docs/superpowers/plans/2026-05-11-mobile-releases.md`
- Future scope: `docs/MOBILE_RELEASE_FUTURE_SCOPE.md`
- Roadmap: `docs/MOBILE_RELEASE_ROADMAP.md`
- DB schema: `docs/DATABASE.md`
