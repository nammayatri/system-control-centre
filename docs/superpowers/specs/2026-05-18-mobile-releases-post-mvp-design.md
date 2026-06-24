# Mobile Releases — Post-MVP Design (Consolidated)

> **⚠️ Superseded (2026-06-18) — store sync is now on-demand.** The `storeSyncLoop`
> background loop + `store_sync_enabled` / `store_sync_interval_minutes` flags this spec
> describes were **removed**. Store sync now refreshes **on demand** (UI ↻ / page open) via
> `refreshStoreStatusOne`, bounded per app by `store_refresh_cooldown_seconds` (one Play
> edit/app/refresh; ASC token + appId caches; single-flight for concurrency). Treat the
> store-sync sections below as historical. Current behaviour: `CLAUDE.md`
> § "Mobile store sync (on-demand)" and `docs/scc-deployment.md` §7.

| | |
|---|---|
| **Date** | 2026-05-18 (initial) — 2026-05-26 (latest) |
| **Author** | shivendra02shah@gmail.com (with assistant) |
| **Status** | Implemented (all 14 sections) |
| **Scope** | All mobile release features built after the MVP (`2026-05-11-mobile-releases-design.md`). Covers: mobile revert, branch picker, debug/release build types, latest build enrichment, periodic store sync, store-sync revert integration, platform filter, apps admin redesign, dispatch from summary page, Firebase Crashlytics deep-linking, changelog preview on create. |
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
13. [Post-Release Health Monitoring — Deep-Link to Firebase Crashlytics](#13-post-release-health-monitoring--deep-link-to-firebase-crashlytics)
14. [Changelog Preview on Create](#14-changelog-preview-on-create)
15. [Post-MVP hardening (edge-case audit)](#15-post-mvp-hardening-edge-case-audit)

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
| 5 | `version_code` rule | **`max(bad.version_code, live store code) + 1`, mandatory floor.** Operator can override higher; server validates against the floor (Play rejects codes ≤ the live store code). |
| 6 | iOS version computation | **Same patch-bump for `version_number`.** Build number auto-computed by fastlane. |
| 7 | **How is the rollback target chosen?** | **By version order, NOT creation time.** Candidates are ranked by the store's sequence key `(version_code, semver(version_name), created_at)`; the target is the highest *good* version strictly below the bad one. Creation time is only a tiebreaker — store-sync writes older versions at later times, so ordering by `created_at` mis-sequences releases (see §1 "Rollback target resolution" below). |
| 8 | Target version has no SCC build artifact? | **Surface a choice, never guess.** The version users were on may be a store-synced version SCC never built. The resolver returns `rebuild_lower` (rebuild from the nearest lower tagged version) or `manual_required` (operator supplies a source commit) instead of a dead-end error. |
| 9 | No version below the bad one at all? | **`NoPriorRelease`** — there is nothing to roll back to; operator creates a fresh release (optionally from a commit). |
| 10 | Reverting a release that is itself a revert? | **Allowed.** A revert is a real shipped build; the version-code floor prevents loops. Only an *already-reverted* release (`metadata.reverted_by` set) is blocked, to avoid duplicate rollbacks. |
| 11 | Previous good tag deleted? | **Fail with clear error**, suggesting a manual source commit. |
| 12 | Multi-app dispatch (siblings)? | **Per-app revert.** Each sibling reverted independently; resolution is scoped to `(app_group, service, env)`. |
| 13 | Bad release not COMPLETED? | **Revert disabled.** Use Abort for in-progress releases. |
| 14 | Two operators revert the same release at once? | **Blocked by `uq_release_tracker_revert_inflight`** — at most one active (non-terminal) revert per bad release. |
| 15 | Where do new columns live? | **Three nullable columns on `release_tracker`**: `commit_sha`, `source_ref`, `reverts_release_id`. |
| 16 | Changelog source? | **Auto-generated from GitHub Compare API.** Renders commit list as "Reverting these N commits." Operator can edit. |
| 17 | Workflow YAML changes? | **None.** Workflows already accept override inputs and check out whatever ref the dispatch carries. |
| 18 | Permission / approval? | **`AP_RELEASE_REVERT`** (existing); revert creates a normal `release_tracker` row with the standard approval lifecycle. |
| 19 | Bad release row change? | **`metadata.reverted_by = <revert-id>`** backfilled when the revert completes (not at create time — an aborted revert leaves it unmarked). |

### Rollback target resolution

This is the heart of revert and the one part most easily gotten wrong.

**Revert is a single operation: roll back to a strictly-lower good version.** The
target is the highest good version *below* the bad release; if nothing lower
exists, the revert is refused (you create a new release instead). This applies
uniformly — **store-sync rows are reverted the same way** (a store-sync row is
just another candidate/subject, ordered by version). There is intentionally **no
"re-assert the latest build"** path: reverting must never roll *forward* to a
higher version. (Earlier this was split into rollback vs. a store-drift re-assert
via `findPreviousGoodSCCRelease`; that re-assert was removed on 2026-06-02 because
reverting a store-synced version to a *newer* SCC build is not a revert.)

Ordering must use the key the store itself enforces — never `created_at`:

```
seqKey = (Android version_code, semver(version_name), created_at)
```

`version_code` is Play-enforced monotonic → authoritative on Android; `semver(version_name)` (integer-component compare, so `3.3.9 < 3.3.10`) covers iOS and breaks code ties; `created_at` only separates genuine re-releases. **Why not `created_at`:** store-sync writes a row for whatever the store currently shows *whenever the poller runs*, i.e. an older version at a later time. Ordering by creation time therefore mis-sequences releases — a real release with a newer store-sync row beside it looks like it has "nothing before it," and other interleavings roll back too far.

Resolution splits **target vs. source**, because the version users were on may have no SCC artifact:

| Plan (`resolveRollback`) | Meaning | Operator UX |
|--------------------------|---------|-------------|
| `Rollback t t` | target is tagged; source == target | one-click revert |
| `RebuildLower t s` | target has no artifact; nearest *lower* tagged version `s` does | confirm rebuilding from `s` |
| `NeedsManualSource t` | target has no artifact and nothing buildable below | supply a source commit |
| `NoPriorRelease` | bad is the lowest version | dead-end → create a new release |

The plan is surfaced on the `RevertDraft` wire type via four fields the FE renders:
`rdTargetReleaseId` / `rdTargetVersion` (the version users roll back **to** — display),
`rdBuildSourceKind` (`"tag"` | `"rebuild_lower"` | `"manual_required"`), and
`rdWarnings` (e.g. `"target_has_no_artifact"`, `"manual_source_required"`). For a
clean `Rollback` these collapse to the existing `rdPrevGood*` fields; for
`RebuildLower` the target and source differ (target = the higher unbuildable
version, `rdPrevGood*` = the lower buildable source).

The resolver (`Mobile/RevertResolver.hs`) is **pure** (no Beam/JSON) and unit-tested (§15.1 — `test/Main.hs` §30); `fetchRevertCandidates` supplies a bounded 50-row window (the B4 store-sync dedup index keeps it from filling) and the resolver picks by *version*, not by the SQL order. **Scaling seam:** `version_code` lives inside `release_context` JSON, so the window is sorted in Haskell; if one app ever exceeds the window, promote `version_code` to an indexed column and resolve with a single ordered `LIMIT 1`.

### Data model

```sql
ALTER TABLE release_tracker
  ADD COLUMN IF NOT EXISTS commit_sha         TEXT,
  ADD COLUMN IF NOT EXISTS source_ref         TEXT,
  ADD COLUMN IF NOT EXISTS reverts_release_id TEXT;

CREATE INDEX IF NOT EXISTS idx_rt_commit_sha ON release_tracker(commit_sha);
CREATE INDEX IF NOT EXISTS idx_rt_reverts_release_id ON release_tracker(reverts_release_id);

-- At most one ACTIVE revert per bad release (prevents double-revert races).
CREATE UNIQUE INDEX IF NOT EXISTS uq_release_tracker_revert_inflight
  ON release_tracker (reverts_release_id)
  WHERE reverts_release_id IS NOT NULL
    AND status IN ('CREATED','INPROGRESS','PAUSED','ABORTING','REVERTING','RESTARTING','PREPARING');
```

All columns nullable. Old rows stay NULL. `source_ref IS NULL` means "use main". (All of the above live in migration `0012-mobile-revert.sql`.)

### Endpoints

```
GET  /releases/:id/mobile-revert/draft               -> RevertDraft (preview)
POST /releases/:id/mobile-revert                      -> { revertReleaseId } (create)
GET  /releases/:id/mobile-revert/verify-commit?sha=  -> VerifyCommitResp (custom source)
GET  /releases/:id/mobile-revert/diff?source=        -> RevertDiffResp (live rolled-back commits)
```

All gated by `AP_RELEASE_REVERT`.

**Live commit diff.** The "Commits being rolled back" list is **not** frozen at the
draft's previous-good default — it tracks the build source the operator actually
selects. The FE re-queries `…/mobile-revert/diff?source=<ref>` whenever the
effective source changes (previous-good tag, a verified custom SHA, or a branch);
`mobileRevertDiffH` runs GitHub Compare between that `source` and the bad
release's tag (or `commit_sha`) and returns the commits present in the bad release
but not reachable from the source — i.e. exactly what a rebuild from that source
would drop. The draft's `rdCommits` remains the initial value for the
previous-good case.

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
| Queries | `backend/src/Products/Autopilot/Mobile/Queries/Tracker.hs` (`fetchRevertCandidates` [B6, replaced `findPreviousGoodMobileRelease`/`findPreviousGoodSCCRelease`], `insertMobileRevertTracker`, `markReleaseRevertedBy`, `isReverted`) + `Mobile/RevertResolver.hs` (B6, pure rollback resolver) |
| Workflow | `backend/src/Products/Autopilot/Mobile/Workflow.hs` (`source_ref` in dispatch, `commit_sha` in resolve-run, `markReleaseRevertedBy` in finalize) |
| Routes | `backend/src/Products/Autopilot/Mobile/Routes.hs` |
| Frontend: Revert page | `frontend/src/products/releases/pages/mobile/MobileRevert.tsx` |
| Frontend: Banners | `frontend/src/products/releases/pages/ReleaseSummary.tsx` |
| Frontend: List actions | `frontend/src/products/releases/pages/ListRelease.tsx` |

---

## 2. Store-Sync Rows in Revert

> **Updated 2026-06-02.** The original "store-sync re-assert" operation (revert a
> store-sync row → re-push the *latest* SCC build, even if higher) was **removed**.
> Reverting a store-synced version to a *newer* build is not a revert. Store-sync
> rows now go through the **same version-ordered rollback** as everything else (§1):
> the target must be a strictly-lower good version, or the revert is refused.

### Behaviour

Store-synced releases appear as COMPLETED rows but were never built by SCC (no
artifact of their own; Android rows derive a `tag_pushed` from the naming
convention, iOS rows don't). They play two roles in revert, both handled by the
§1 resolver:

1. **As the *subject* of a revert** — treated like any bad release: roll back to
   the highest good version *below* the store-synced version. If the nearest lower
   target is itself a store-sync row with no artifact, the resolver yields
   `RebuildLower` / `NeedsManualSource` (operator picks a lower SCC build or supplies
   a commit). If there is no lower version at all, the revert is refused with
   *"No good release below vX — revert needs a lower version."*
2. **As a *candidate*** in another row's rollback — included and ranked by version.

There is no separate store-sync code path: `draftForStoreSyncRevert` and
`findPreviousGoodSCCRelease` were deleted; both draft and create call
`resolveRollback`. `rdIsStoreSyncRevert` survives only as an FE banner hint
(`rtMode == STORE_SYNC`), not as a behaviour switch.

### Version-code floor (all reverts)

1. `fetchLatestBuildsForApp` called during draft generation.
2. `rdStoreVersion` / `rdStoreVersionCode` on `RevertDraft`.
3. Suggested code = `max(badCode, liveStoreCode) + 1`; server validates the same floor.

### Files

| File | Change |
|------|--------|
| `backend/src/Products/Autopilot/Mobile/Handlers/Revert.hs` | unified on `resolveRollback`; removed `draftForStoreSyncRevert`; `maxCode`, store-floor validation |
| `backend/src/Products/Autopilot/Mobile/Queries/Tracker.hs` | removed `findPreviousGoodSCCRelease` + `firstNonDebug` |
| `frontend/src/products/releases/api.ts` | `rdIsStoreSyncRevert`, `rdStoreVersion`, `rdStoreVersionCode` |
| `frontend/src/products/releases/pages/mobile/MobileRevert.tsx` | Store-sync banner hint, version info, floor-code validation |

---

## 3. Debug Build Exclusion from Revert

### Problem

Debug builds receive `debug-no-tag` as `tag_pushed` — no real Git tag. Using a debug build as a revert target would dispatch from a non-existent tag. Reverting debug builds has no operational value (test/beta, not production).

### Design

1. **Backend guard**: Both draft and create handlers reject debug releases with a clear error message.
2. **Candidate filtering**: `fetchRevertCandidates` drops debug rows (it fetches a bounded window and filters in Haskell, because the build type lives inside `release_context` JSONB — `isDebugBuildType (mbcBuildType ...)`).
3. **Frontend**: Revert button hidden when `release_context.build_type === 'debug'` in both `ListRelease.tsx` and `ReleaseSummary.tsx`.

### Files

| File | Change |
|------|--------|
| `backend/src/Products/Autopilot/Mobile/Queries/Tracker.hs` | `firstNonDebug` filter, `isDebugBuildType` import |
| `backend/src/Products/Autopilot/Mobile/Handlers/Revert.hs` | Debug-build guard in draft + create (via `mbcBuildType`) |
| `frontend/src/products/releases/pages/ListRelease.tsx` | `!isDebugBuild` condition |
| `frontend/src/products/releases/pages/ReleaseSummary.tsx` | `build_type` check |

---

## 4. Revert-of-a-Revert & Reverted-Row Skipping

> **Reworked 2026-06-01 (B6).** The original design *blocked* reverting any
> revert build (`rtRevertsReleaseId` guard). That was over-conservative: a revert
> is a real shipped build, and if it goes bad you must be able to roll it back.
> The block is removed; the version-ordered resolver (§1) naturally skips the
> already-reverted original, and the version-code floor prevents loops.

### Problem

Two distinct concerns, often conflated:

1. **Reverting a revert** (e.g. v3.3.26, created by reverting v3.3.25) must roll back to the correct *previous* version — **not** the original bad v3.3.25.
2. **Double-reverting one release** (creating two rollbacks of the same bad release) must be prevented.

### Design

1. **Revert-of-a-revert is allowed.** No `rtRevertsReleaseId` guard. The resolver ranks by version and skips reverted rows (below), so it picks the correct lower good version, never the original bad one. The `version_code` floor (`max(bad, store) + 1`) guarantees each revert moves forward, so chains can't loop.
2. **Already-reverted guard (server-side).** Draft and create reject a release whose `metadata` already contains `reverted_by` ("This release has already been reverted"). The `isReverted` helper parses metadata JSONB; `fetchRevertCandidates` also drops reverted rows from the candidate set.
3. **Concurrency guard.** `uq_release_tracker_revert_inflight` blocks a second *active* revert of the same bad release (two operators / double-submit).
4. **`markReleaseRevertedBy` at workflow finalize**: set only when the revert reaches COMPLETED. If aborted, the bad release stays unmarked (and thus revertable again).
5. **Frontend**: revert action shown for revert builds too; hidden only once a release is already reverted (`metadata.reverted_by`). REVERT badge shown via both `revertsReleaseId` and backend `release_context.revert`.

### Files

| File | Change |
|------|--------|
| `backend/src/Products/Autopilot/Mobile/Handlers/Revert.hs` | removed `rtRevertsReleaseId` block; added already-reverted guard (`isReverted`); manual-source guard |
| `backend/src/Products/Autopilot/Mobile/Workflow.hs` | `markReleaseRevertedBy` in `execFinalize` |
| `backend/src/Products/Autopilot/Mobile/Queries/Tracker.hs` | `isReverted` (exported); `fetchRevertCandidates` drops reverted rows |
| `backend/dev/migrations/system-control/0012-mobile-revert.sql` | `uq_release_tracker_revert_inflight` |
| `frontend/src/products/releases/pages/ListRelease.tsx` | dropped `isMobileRevertBuild` gate (revert-of-revert reachable); REVERT badge |
| `frontend/src/products/releases/pages/ReleaseSummary.tsx` | revert button gated on `!reverted_by`, REVERT badge |

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

**Endpoints:**
- `GET /releases/:id/mobile-revert/verify-commit?sha=...` — resolves/validates a SHA or branch, returns its commit details.
- `GET /releases/:id/mobile-revert/diff?source=...` — **live "commits being rolled back"** for the chosen source (see §1 "Live commit diff"). The page re-queries this whenever the source changes, so the rolled-back list reflects the *selected* commit/branch — not the static previous-good default. Without it, picking a custom commit left the list showing the (often empty) previous-good diff.

Both gated by `AP_RELEASE_REVERT`.

**Frontend:** Radio toggle between sources. Custom commit mode shows SHA input + Verify button; on verify, shows a green commit-detail card. The "Commits being rolled back" panel is driven by a `['mobile-revert-diff', id, effectiveSourceRef]` query (loading / unverified / empty / error states), and the "View full diff on GitHub" link uses the diff's `rdfBaseRef`/`rdfHeadRef`.

### Files

| File | Change |
|------|--------|
| `backend/src/Products/Autopilot/Mobile/Github.hs` | `createGitRef`, `getCommitInfo`, `CommitDetail` |
| `backend/src/Products/Autopilot/Mobile/Handlers/Revert.hs` | `rrSourceCommit` on `RevertReq`, `VerifyCommitResp`/`verifyCommitH`, `RevertDiffResp`/`mobileRevertDiffH` (live diff), commit verification in create |
| `backend/src/Products/Autopilot/Mobile/Routes.hs` | `verify-commit` + `diff` endpoints |
| `frontend/src/products/releases/api.ts` | `rrSourceCommit`, `verifyRevertCommit`, `getRevertDiff` / `RevertDiffResp` |
| `frontend/src/products/releases/pages/mobile/MobileRevert.tsx` | Source mode toggle, verify button, commit detail card, reactive rolled-back-commits diff |

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

Build type is a first-class field on the release context — `mbcBuildType :: Text` (`"debug"` or `"release"`) inside `MobileBuildContext`. The legacy `MobileDestination` ADT (and `mbcDestination`) was removed: the upload target (Firebase / TestFlight / Google Play / App Store) is fully derivable from build type + platform, so it's never stored.

```haskell
-- backend/src/Products/Autopilot/Mobile/Types.hs
isDebugBuildType :: Text -> Bool
isDebugBuildType = (== "debug")
```

The value is **set once at release creation** from the `mobile_build_type` server_config flag (see §7.1) and persisted on the context, so a release's build type reflects what it *was*, independent of the environment's current setting. Reads use `mbcBuildType`; the JSON key is `build_type`. `MobileBuildContext`'s `FromJSON` falls back to the old `destination` string (`Firebase`/`TestFlight` → `"debug"`) so rows written before the refactor still parse.

Each environment (master / production) has its own `app_catalog` seed with the appropriate `workflow_path`. Debug and release builds are separated by deployment, not by a column on the app row.

### 7.1 Build type is an environment invariant

`mobile_build_type` (`server_config`, product `autopilot`, default `"release"`) is set **once per deployment** via migration `0020-mobile-build-type-config.sql`:

| Environment | `SC_ENV` | `mobile_build_type` | Builds go to |
|-------------|----------|---------------------|--------------|
| master | `master` | `debug` | Firebase / TestFlight |
| production | `production` | `release` | Google Play / App Store |

It is **not** an editable runtime toggle: exposing it would let someone flip master to `"release"` and silently break the env-lock guarantee. It is therefore *not* registered in the config catalog (`Products/Autopilot/Config.hs`) and is hidden from the config UI (`isHiddenServerConfig` in `server-config-filter.ts`). It can only be changed via migration/DB. The create-release endpoint reads it server-side (`getMobileBuildType`) — the frontend never sends a build type or destination.

### Workflow stage differences

| Stage | Release build | Debug build |
|-------|--------------|-------------|
| ResolveVersion | Queries Play Console / ASC | Skips entirely |
| DispatchWorkflow | Full inputs (version + changelog) | Only `selected_apps` + `change_log` |
| ResolveRunId | Polls on `workflow_path` | Polls on `workflow_path` |
| MonitorMatrixJob | `{app}-Release` job name | `{app}-Debug` job name |
| ConfirmTag | Polls for the build's **exact** tag `{app}/prod/{platform}/v{version}+{code}` (`selectBuildTag` — §15/B7, not the lexically-first ref), bounded by `mobile_tag_confirm_timeout_minutes` (default 60 → `MBFailed "tag_timeout"` on expiry — §15/B3) | Writes `debug-no-tag`, advances immediately |
| Slack/complete | Normal | Normal |

### Frontend

- Build type is fixed per deployment and read from **`config.buildType`** (`'debug'`|`'release'`), returned in the auth `config` block on **both** `/auth/login` and `/auth/me`. It is sourced server-side from the **`mobile_build_type` server_config** (default `release`), NOT from the env label — so flipping a deployment debug↔release is a config change, no redeploy. `config.env` is a cosmetic label only; the FE never branches on it (`useAuth().buildType`, the `isDebugDeployment` helper). Shown as a static badge, not a toggle.
- DEBUG badge (amber) on list rows and detail page header — driven by `release_context.build_type === 'debug'` (no longer by destination strings).
- Version fields + version preview hidden for debug builds on create form.

### Files

| File | Change |
|------|--------|
| `backend/src/Products/Autopilot/Mobile/Types.hs` | `mbcBuildType :: Text`, `isDebugBuildType`; `MobileDestination`/`isDebugDestination` removed; `FromJSON` destination→build_type fallback |
| `backend/src/Products/Autopilot/RuntimeConfig.hs` | `getMobileBuildType` (reads `mobile_build_type`) |
| `backend/src/Products/Autopilot/Mobile/Workflow.hs` | Debug branches gate on `mbcBuildType == "debug"`, always uses `acWorkflowPath` |
| `backend/src/Products/Autopilot/Mobile/Handlers/Release.hs` | Reads build type from config; stamps `mbcBuildType`; matrix job name suffix |
| `backend/src/Products/Autopilot/Mobile/Handlers/Revert.hs` | Copies `mbcBuildType` from original; debug-revert guard on `isDebugBuildType` |
| `backend/dev/migrations/system-control/0020-mobile-build-type-config.sql` | Seeds `mobile_build_type` |
| `frontend/src/products/releases/types.ts` | `BuildType`; `MobileDestination`/`destinationFor` removed; `destination` dropped from request |
| `frontend/src/products/releases/pages/mobile/CreateMobileRelease.tsx` | Env-locked build type, static badge |
| `frontend/src/products/releases/pages/ListRelease.tsx` | DEBUG badge via `build_type` |
| `frontend/src/products/releases/pages/ReleaseSummary.tsx` | DEBUG badge + revert gating via `build_type` |

---

## 8. Latest Build Enrichment

### Problem

The app catalog API returned only static metadata. Operators had no visibility into what was last built — had to check GitHub or the store console.

### Design

Enrich `GET /mobile/apps` with the latest completed build per app, per build type (debug/release).

**Query:** `fetchLatestBuildsPerApp` selects COMPLETED MobileBuild rows newest-first and reduces in Haskell — parsing each `release_context` via the domain `MobileBuildContext` decoder and keeping the newest per (app, surface, platform, build_type). (Originally a `ROW_NUMBER() OVER (PARTITION BY …)` raw-SQL query; reworked in §15/B2 so a single corrupt row can't abort the whole query. A scoped `fetchLatestBuildsForApp` variant — §15/P2 — serves single-app callers.)

**Response additions:**

```haskell
data LatestBuildResp = LatestBuildResp
    { version, versionCode, tagPushed, commitSha, completedAt }
```

Build type per row comes from the SQL `COALESCE(mbContext ->> 'build_type', <legacy destination classification>)` — preferring the new `build_type` field, falling back to the old `destination` for pre-refactor rows. The unused `destination` field was dropped from the response.

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

| Platform | Source | Build type stamped |
|----------|--------|--------------------|
| Android release | `fetchPlayTracks` (production track) | `"release"` |
| iOS release | `fetchAscVersions` (TestFlight proxy) | `"release"` |
| Android debug | Not synced (always via SCC) | — |
| iOS debug | Not synced | — |

Synthetic rows always carry `mbcBuildType = "release"` — store sync only ever observes production store releases.

**Synthetic row:** `mode = 'STORE_SYNC'`, `created_by = 'store-sync'`, full `MobileBuildState` in `release_context`.

**Android tag derivation:** `{normalizeAppSegment(name)}/prod/android/v{version}+{code}` — enables commit diffs on revert.

**Release-only:** the loop is a hard no-op in a debug deployment — it checks `getMobileBuildType` and skips when `isDebugBuildType` is true, **regardless of `store_sync_enabled`**. This prevents production store data from being pulled into a debug DB even if the flag is mistakenly on.

**Configuration (all `server_config`, product `autopilot`):**

| Flag | Default | Purpose |
|------|---------|---------|
| `store_sync_enabled` | `false` | Master switch for the loop (only honored in a release env). |
| `store_sync_interval_minutes` | `30` | Poll interval. |
| `version_preview_enabled` | `true` (`false` in master, via `0019`) | Whether `POST /mobile/versions/preview` resolves next versions from Play Console / ASC. Returns empty when off. Inert in debug regardless (the create form skips preview for debug builds). |

These three are release-only knobs: they're registered under the **Mobile** config group and the frontend hides them in the debug env (`env === 'master'`, via `isReleaseOnlyServerConfig`).

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

## 13. Post-Release Health Monitoring — Deep-Link to Firebase Crashlytics

In-app crash/perf dashboards cannot be built — Firebase Crashlytics has no public read REST API (only GDPR deletion). Instead, SCC deep-links operators directly into the Firebase Console.

### What was implemented

- **DB:** `firebase_project_id` column on `app_catalog` (migration `0017`). Each app stores its own Firebase project ID (e.g. `namma-yatri`, `movingtech-155ad`).
- **Sidebar:** "Crashlytics" nav item in the Mobile Releases sidebar — opens Firebase Crashlytics in a new tab (generic `_` project placeholder).
- **ReleaseSummary:** Per-release "Crashlytics" button (filled orange, Flame icon) visible only for mobile releases. Deep-links to the specific app's crash issues with filters:
  - URL format: `https://console.firebase.google.com/project/{firebaseProjectId}/crashlytics/app/{platform}:{packageName}/issues?versions={version}%20({versionCode})&state=open&time=7d&types=crash&tag=all&sort=eventCount`
  - Falls back to generic Crashlytics page if `packageName` or `firebaseProjectId` is not configured.
- **Backend:** `firebaseProjectId` field added to `AppCatalogEntryResp`, `NewAppReq`, `PatchAppReq` — can be set via the PATCH `/mobile/apps/:id` endpoint.
- **Frontend types:** `firebaseProjectId: string | null` on `AppCatalogEntry`.

### Files changed

| Layer | File | Change |
|-------|------|--------|
| Migration | `0017-app-catalog-firebase-project.sql` | `ALTER TABLE app_catalog ADD COLUMN firebase_project_id TEXT` + seed UPDATEs |
| Backend | `Mobile/Types/Storage.hs` | `acFirebaseProjectId` field |
| Backend | `Mobile/Queries/AppCatalog.hs` | Insert, update, isNoop for new field |
| Backend | `Mobile/Handlers/AppCatalog.hs` | Resp/Req types + projections |
| Frontend | `releases/types.ts` | `firebaseProjectId` on `AppCatalogEntry` |
| Frontend | `releases/pages/ReleaseSummary.tsx` | Crashlytics deep-link button |
| Frontend | `products/registry.ts` | Sidebar nav item (`external: true`) |
| Frontend | `core/layout/ProductLayout.tsx` | External link rendering in sidebar |

**Future alternative (Android):** Google Play Developer Reporting API (`playdeveloperreporting.googleapis.com`) — crash rate, ANR rate, startup time. Free, uses existing Play Console credentials.

---

## 14. Changelog Preview on Create

### Problem

Operators creating a mobile release have no visibility into what commits will ship. They select a branch and apps, but must manually check GitHub to see what changed since the last release. This leads to vague changelogs and occasional surprise deployments of unintended changes.

### Design decisions

| # | Question | Decision |
|---|---|---|
| 1 | When to show the preview? | **After the operator selects an app AND a branch.** The preview fires as a TanStack Query with `enabled` gated on both params. |
| 2 | Base ref for comparison? | **Last completed release's `tag_pushed` (preferred) or `commit_sha` (fallback).** Found via `fetchLatestBuildsPerApp`. If no previous release exists, compare from the repo's default branch (first release scenario). |
| 3 | Head ref for comparison? | **The selected branch name.** GitHub Compare API accepts branch names directly. |
| 4 | Commit cap? | **50 commits.** GitHub Compare API returns up to 250. We cap at 50 client-side and show a "View full diff on GitHub" link for larger diffs. |
| 5 | Multi-app selection? | **Per-app parallel queries with tabs.** Each selected app fires its own `GET /mobile/changelog-preview` via `useQueries`. When 2+ apps are selected, a tab bar shows each app's label with commit count badge. Tabs let the operator see that different apps may have different base tags (e.g. customer-android last released at v3.3.25, driver-android at v3.3.20). |
| 6 | Auto-populate changelog? | **Not implemented in MVP.** Deferred — operators write changelogs manually. |
| 7 | Performance? | **Non-blocking.** Compare API takes ~500ms. Preview loads in background with `staleTime: 60_000` and `placeholderData: keepPreviousData`. Form is fully usable while loading. |
| 8 | Error handling? | **Graceful degradation.** GitHub API errors show "Couldn't load changelog" with retry button. The form remains submittable — the preview is informational only. |
| 9 | Schema changes? | **None.** Reuses existing `compareRefs` and `fetchLatestBuildsPerApp`. |
| 10 | Permission? | **`AP_RELEASE_CREATE`** — same as creating a release. |
| 11 | Debug builds? | **Hidden.** Changelog panel gated behind `!isDebug`. Debug builds don't produce real tags (`tag_pushed = "debug-no-tag"`), so the comparison base would be misleading. |
| 12 | Commit order? | **Newest first.** GitHub Compare API returns oldest-first; frontend reverses for developer convenience. Row numbers (1-indexed) added for easy reference. |
| 13 | Commit row enrichment? | **GitHub avatars, clickable SHA links, clickable PR links, author on the right.** Avatars loaded via `github.com/{login}.png?size=40` (lazy, hidden on error). PR URLs derived from commit URL (`/commit/{sha}` → `/pull/{number}`). |
| 14 | Revert page consistency? | **Revert commit list redesigned to match.** Same row layout, newest-first order, "View full diff on GitHub" link (compare URL from `prevGoodTag...lastCommitSha`). |

### Endpoint

```
GET /mobile/changelog-preview
    ?app=nammayatri
    &surface=customer
    &platform=android
    &branch=feature/my-branch
  -> ChangelogPreviewResp
```

Gated by `AP_RELEASE_CREATE`.

### Response shape

```haskell
data ChangelogPreviewResp = ChangelogPreviewResp
    { cpCommits     :: [CommitInfo]    -- reuses Compare.hs type, capped at 50
    , cpAheadBy     :: Int             -- total commits ahead
    , cpStatus      :: Text            -- "ahead", "behind", "identical", "diverged", "error"
    , cpBaseTag     :: Maybe Text      -- tag of the last completed release
    , cpBaseVersion :: Maybe Text      -- version string of the last completed release
    , cpCompareUrl  :: Maybe Text      -- GitHub compare URL for "View all" link
    } deriving (Generic, ToJSON)
```

### Data flow

```
User selects apps + branch
  → Frontend: useChangelogPreviews(changelogApps, branch)
      (fires N parallel queries via useQueries, one per selected app)
  → GET /mobile/changelog-preview?app=...&surface=...&platform=...&branch=...  (×N)
  → Handler (per app):
      1. Look up app_catalog entry for (app, surface, platform)
      2. fetchLatestBuildsPerApp → findLastReleaseBuild (filters buildType=="release", rejects "debug-no-tag")
      3. Determine base ref: tag_pushed (preferred) || commit_sha (fallback)
      4. compareRefs(creds, owner, repo, baseRef, branch)
      5. Cap commits at 50, build GitHub compare URL
  → Response: ChangelogPreviewResp (per app)
  → Frontend: render tabbed commit list panel (tabs when 2+ apps, plain when 1)
```

### Frontend UI

Always-visible panel below the branch picker on the Create Mobile Release form (hidden for debug builds):

- **Tab bar** (when 2+ apps selected): Each app's label + commit count badge. Click switches to that app's changelog.
- **Header**: "Commits since last release" with base tag/version → branch indicator and commit count
- **Commit row**: `# | GitHub avatar | SHA link | subject | PR# link | author (right-aligned)`
  - Newest-first order (reversed from API)
  - Row numbers for easy reference
  - GitHub avatars (20×20, lazy, hidden on error)
  - Clickable SHA → commit on GitHub
  - Clickable PR# → pull request on GitHub (derived from commit URL)
  - Author name right-aligned, truncated at 100px
- **Footer**: "View full diff on GitHub" link + "Showing N of M" when truncated
- **States**: Loading skeleton | Empty ("No new commits" / "No previous release") | Error | Data

### Revert page consistency

The "Commits being rolled back" section in `MobileRevert.tsx` was redesigned to match the same commit row layout:
- Newest-first order with row numbers
- Same avatar + SHA link + subject + PR# link + author layout
- "View full diff on GitHub" link at the bottom (compare URL from `prevGoodTag...lastCommitSha`, derived from commit URLs)

### Files

| Layer | File | Change |
|-------|------|--------|
| Backend | `Mobile/Handlers/Release.hs` | `ChangelogPreviewResp`, `changelogPreviewH`, `findLastReleaseBuild` |
| Backend | `Mobile/Github/Compare.hs` | Added `ToJSON` instance for `CommitInfo` |
| Backend | `Mobile/Queries/Tracker.hs` | Exported `appCatalogByKey` |
| Backend | `Mobile/Routes.hs` | `GET /mobile/changelog-preview` route + handler binding |
| Frontend | `releases/types.ts` | `CommitInfo`, `ChangelogPreviewResp` |
| Frontend | `releases/api.ts` | `mobileApi.changelogPreview(app, surface, platform, branch)` |
| Frontend | `releases/hooks.ts` | `useChangelogPreviews(apps, branch)` with `useQueries`, `ChangelogApp` type |
| Frontend | `releases/pages/mobile/CreateMobileRelease.tsx` | Per-app tabbed changelog panel, debug exclusion gate |
| Frontend | `releases/pages/mobile/MobileRevert.tsx` | Redesigned commit list (newest first, row layout, GitHub diff link) |

### What this reuses (no new modules)

| Existing code | From phase | Used for |
|---|---|---|
| `compareRefs` | Phase 1 (Mobile Revert) | GitHub Compare API call |
| `CommitInfo` | Phase 1 | Commit data structure |
| `fetchLatestBuildsPerApp` | Phase 4 (Latest Build Enrichment) | Find last completed release tag/SHA |
| `loadGhCredsSafe` | Phase 1 | GitHub App credentials |
| `findAppCatalogByKey` | Phase 4 | App catalog lookup |

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

[Firebase Observability] → Deep-link to Firebase Console (no in-app dashboards)
     Requires: app_catalog.firebase_project_id + package_name

[Changelog Preview on Create] ---> reuses compareRefs (Phase 1) + fetchLatestBuildsPerApp (Phase 4)
     No schema changes. Independent of all other phases.

[Platform Filter] (independent, frontend-only)
[Apps Admin Redesign] (independent, frontend-only)
[Dispatch from Summary] (independent, frontend-only)
```

---

## 15. Post-MVP hardening (edge-case audit)

A 2026-05-29 edge-case audit traced the full mobile lifecycle (create → approve →
dispatch → 7-stage workflow → finalize, plus revert, store sync, version
resolution) and reviewed each finding against backend conventions
(`withTransaction`, validate-before-write, partial unique indexes, `in_` batch
queries, Runner sweeps / wall-clock caps, sequential `Flow` handlers). This
section is the **self-contained record** of that audit — what shipped, and what
was deliberately *not* done and why. Where earlier sections describe the
pre-hardening behaviour, this supersedes them.

### 15.1 Shipped fixes

| Id | Original problem | Fix | Touches |
|----|------------------|-----|---------|
| **B1** | `createMobileReleasesH` inserted rows one-by-one with no transaction; a bad `appCatalogId` mid-list left committed orphan rows. | **Validate-first + atomic**: all ids checked in one `in_` batch (+ duplicate / empty-changelog guards) *before* any write; the N rows commit in one `withTransaction` (`insertReleaseTrackerRowsBatch`). `createOne` → pure `buildRow`. | `Handlers/Release.hs`, `Queries/AppCatalog.hs` (`findAppCatalogByIds`), `Queries/ReleaseTracker.hs`, `Queries/Tracker.hs` (`mkMobileTrackerRow`) |
| **B2** | `fetchLatestBuildsPerApp` cast `release_context::jsonb` / `version_code::int` in raw SQL across all rows — one corrupt row aborted the whole query and blanked every app's badge. | Parse `release_context` in **Haskell** via the domain `MobileBuildContext` `FromJSON` (incl. legacy `destination`→`build_type` fallback); unparseable rows are dropped, not fatal. | `Queries/AppCatalog.hs` |
| **B3** | `ConfirmTag` returned `StageWaiting` with no budget — if the build's tag never landed, the release was stuck in-flight forever. | **Wall-clock timeout** (`mobile_tag_confirm_timeout_minutes`, default 60; pure `tagConfirmTimedOut`, anchored on build-completion → build-start) → `MBFailed "tag_timeout"` → ABORTED. Mirrors `max_job_completion_hours`; release-only. | `Mobile/Workflow.hs`, `RuntimeConfig.hs`, `Config.hs` |
| **B4** | Store-sync read-compare-insert with no `ON CONFLICT` → duplicate synthetic COMPLETED rows under concurrent passes / replicas. | **Dedup**: partial unique index `uq_release_tracker_store_sync` on `(app_group, service, env, new_version) WHERE mode='STORE_SYNC'` (migration `0021`, with a one-time dedup DELETE) + `insertReleaseTrackerRowIfAbsent` (`ON CONFLICT DO NOTHING`). | `0021-store-sync-dedup.sql`, `Queries/ReleaseTracker.hs`, `StoreSync.hs` |
| **P2** | Revert (×2) + changelog-preview called `fetchLatestBuildsPerApp` (scan of *all* completed rows) to get one app's builds. | `fetchLatestBuildsForApp appGroup surface platform` — scoped SQL filter, shares the B2 reducer. | `Queries/AppCatalog.hs`, `Handlers/Revert.hs`, `Handlers/Release.hs` |
| **P3** | `createOne` did one `findAppCatalogById` per item (N+1). | Folded into **B1**'s `findAppCatalogByIds` batch. | — |
| **P4** | Dispatch ran `findReleaseTracker` + `loadAppCatalogFor` per release (2N queries). | Batch both: `findReleaseTrackersByIds` + one `listAppCatalog` map; `loadAndValidate`/`loadAppCatalogFor` → pure `validateForDispatch` (same errors, 2N→2). | `Queries/ReleaseTracker.hs`, `Handlers/Release.hs` |
| **B6** | Rollback resolved the "previous good release" by **`created_at`** (`findPreviousGoodMobileRelease`, cutoff `< bad.created_at`). But store-sync writes rows for *older* versions at *later* times, so creation time is not the release sequence — a real release with a newer store-sync row beside it became unrevertable ("No previous good release found"), and other interleavings rolled back to the wrong (too-low) version. | **Version-ordered resolver** — now the primary revert design (§1 "Rollback target resolution" + §4): rank by `(version_code, semver, created_at)`; split target/source; allow revert-of-a-revert; add the inflight-revert index. | `Mobile/RevertResolver.hs` (new), `Queries/Tracker.hs` (`fetchRevertCandidates`, `isReverted`), `Handlers/Revert.hs`, `0012-mobile-revert.sql` (inflight index), FE `ListRelease.tsx` |
| **B7** | `ConfirmTag` listed tags by a **broad prefix** (`{app}/prod/{platform}/v`) and bound the **first** ref. GitHub returns `matching-refs` in ascending lexicographic order, so once an app had more than one version under the prefix it grabbed the **oldest** tag (e.g. `v3.3.15+421` when the build pushed `v3.3.17+460`) — corrupting `tag_pushed`, and therefore any later revert's `source_ref`. | **Exact-tag match** (`selectBuildTag`): the fastlane workflows tag deterministically as `{normalize(app)}/prod/{platform}/v{version}+{code}` and SCC passes that version/code on dispatch (auto-detect skipped), so the tag is fully reconstructible — confirm *that* exact tag; if absent, fall through to the B3 wait/timeout (never bind a different tag). Also **aligned `normalizeAppSegment` with the shell `normalize_segment`** (preserve `._-`) so the expected tag matches for app names with those chars. | `Mobile/Workflow.hs` (`selectBuildTag`, `execConfirmTag`, `normalizeAppSegment`) |
| **B8** | Reverting a **store-sync** row "re-asserted" the *latest* SCC build (`findPreviousGoodSCCRelease`) — which could be a *higher* version than the row being reverted (rolling *forward*, not back). | **Removed re-assert.** All reverts now go through the version-ordered resolver: the target must be a *strictly-lower* good version, else the revert is refused. Deleted `draftForStoreSyncRevert` / `findPreviousGoodSCCRelease` / `firstNonDebug`. See §1 + §2. | `Handlers/Revert.hs`, `Queries/Tracker.hs`, FE `MobileRevert.tsx` |
| **B9** (security) | Mobile **secrets** (GitHub App RSA key, Play service-account JSON, App Store Connect `.p8` + ids) were stored in `server_config` and **returned in plaintext by `GET /server-config`** → visible to anyone with config-view and in the browser. | **Moved secrets to the environment** (`Core.Secrets`): `loadGhCreds`/`loadPlayCreds`/`loadAscCreds` read `SC_GITHUB_APP_*` / `SC_PLAY_SA_JSON_B64` / `SC_ASC_*` (base64 for the PEM/JSON blobs) — k8s Secret in prod, `local-mobile-secrets.env` in dev. Dropped the DB rows (migration `0022`). Never in the DB / config-API / FE now. | `Core/Secrets.hs` (new), `Github/Auth.hs`, `Versioning/Play.hs`, `Versioning/Apple.hs`, `0022`, seed, `flake.nix`, `setup-mobile-local.sh` |
| **B10** | Frontend derived debug/release by string-matching the **env label** (`env === 'master'`), so relabeling/adding an env needed a code change + redeploy. | **Build type from config.** Backend resolves `config.buildType` from the `mobile_build_type` server_config and returns it on `/auth/login` + `/auth/me`; the FE keys off `useAuth().buildType`, never the env label. Flip a deployment debug↔release via a config update — no redeploy. Removed the env-string helpers. | `Core/Auth/Routes.hs` (`resolveDeploymentConfig`), FE `AuthContext.tsx`, `lib/constants.ts`, `Configurations.tsx`, `CreateMobileRelease.tsx` |

Tests: `backend/test/Main.hs` §28 (MobileBuildContext legacy-destination fallback
+ malformed-row drop — B2), §29 (`tagConfirmTimedOut` predicate — B3), §30
(`resolveRollback` / `parseSemver` — B6: version-order beats time-order,
target-vs-source split, `NoPriorRelease`), and §31 (`selectBuildTag` — B7: picks
the build's exact tag, not the lexically-first ref). B1/P4 reject paths are
HTTP-level (→ `sc-test-api`); B4's migration was validated against a throwaway PG14.

### 15.2 Deliberately not done (with rationale)

| Finding | Verdict |
|---------|---------|
| `version_code` Int32 overflow on bump | **Dropped** — Google Play caps `versionCode` at 2,100,000,000, below `Int32` max (2,147,483,647); overflow can't occur while codes come from Play. |
| Concurrent version preview (parallelise per-app resolves) | **Dropped** — no `mapConcurrently`/`async` precedent; handlers are sequential `Flow`. Sequential is acceptable for this low-frequency, debounced call. |
| Empty/missing create-time `version_name` / Android `version_code` | **Not needed** — for release builds the workflow's `ResolveVersion` stage resolves these from the store *before* dispatch (authoritative); debug builds carry no version. Create-time values are preview-only. |
| `isNewerIos` treats any string change as newer | **By-design** — store sync mirrors the live store state; recording whatever the store shows is intended. |
| Dispatch mixing release groups | **No action** without product intent — regrouping by `(repo, workflow_path, surface, platform)` may be intended. |
| Sibling-abort coordination (one sibling fails mid-pipeline) | **Open product decision** — cascade-abort the dispatch group vs. independent siblings. |

### 15.3 Revert target resolution (B6) — record

The **design** now lives in §1 ("Rollback target resolution") and §4, which were
rewritten in place. This entry keeps only the audit trail.

**Symptom that triggered it.** Two OdishaYatri `customer` Android releases:
`3.3.17` (real SCC release, created 01:45) and `3.3.16` (a *store-sync* row,
created 01:58). `3.3.16` was revertable but `3.3.17` was not — even though
`3.3.17` is the higher version. Root cause: the rollback path ordered candidates
by `created_at` and required one *strictly older in time*; `3.3.16`'s row was
created **later**, so `3.3.17` had "nothing before it." With a third row
(`3.3.15` real @ 01:00) the time-order would also roll `3.3.17` back to `3.3.15`,
**skipping** `3.3.16`.

**Operator-confirmed decisions (2026-06-01):** surface the no-artifact choice (no
silent rebuild of a lower version); allow revert-of-a-revert (the version-code
floor prevents loops); enforce the already-reverted guard server-side.

**FE follow-up (not yet built):** the draft response now carries
`target` / `build_source` / `warnings`, but `MobileRevert.tsx` still renders the
single previous-good shape; surfacing the `rebuild_lower` / `manual_required`
choice in the UI is a pending frontend task. The manual-source path already works
via the existing custom-commit field.

---

## References

- Base MVP spec: `docs/superpowers/specs/2026-05-11-mobile-releases-design.md`
- Base MVP plan: `docs/superpowers/plans/2026-05-11-mobile-releases.md`
- Future scope: `docs/MOBILE_RELEASE_FUTURE_SCOPE.md`
- Roadmap: `docs/MOBILE_RELEASE_ROADMAP.md`
- DB schema: `docs/DATABASE.md`
