# Mobile Releases in System Control Centre — Design

| | |
|---|---|
| **Date** | 2026-05-11 (Android MVP); 2026-05-13 (iOS extension) |
| **Author** | shailesh.techcourse@gmail.com (with assistant) — iOS extension by shivendra02shah@gmail.com |
| **Status** | Android MVP shipped; iOS extension proposed |
| **Scope (MVP)** | ✅ Customer Android — `fastlane-android.yaml`, 10 apps. **(shipped on `feat/mobile-releases`)** |
| **Scope (Phase 2)** | 🆕 iOS surfaces (customer + provider) — `fastlane.yaml` (consumer) / `provider-prod-ios-gen.yaml` (driver). New `Mobile/Versioning/Apple.hs` for ASC version resolution. No new destinations, no new statuses, no new columns — strict Android-flow mirror. |

## 1. Problem

The System Control Centre (SCC) today orchestrates backend microservice deploys onto Kubernetes via the Autopilot product: tracker rows, RBAC, immutable audit log, resumable workflow engine, runtime feature flags, Slack notifications.

Mobile (React Native) releases for the Namma Yatri family of apps live entirely outside SCC. Each release is triggered manually from the GitHub Actions UI on `nammayatri/ny-react-native`, against four workflow files (consumer/provider × android/ios), with self-hosted runners (`rasmalai-new`, `kotravai`, `ios-release`) doing the actual build + fastlane upload to Play Store / App Store.

Result: no central tracker, no per-action RBAC, no unified audit log, no single dashboard answering "what version is currently live for app X". Backend has all of that via Autopilot.

Goal: bring mobile releases under SCC, presenting them in the same UI alongside backend releases.

## 2. Decisions made (Q&A summary)

| # | Question | Decision |
|---|---|---|
| 1 | SCC's role vs existing GH Actions | **Trigger + track + gate.** SCC dispatches workflows, polls runs, owns approvals. GH Actions remains the build worker. |
| 2 | Release row granularity | **One row per (app, surface, platform, version).** |
| 3 | How "region" is modelled | **Baked into the app.** Each region has its own distinct app (NammaYatri, ManaYatri, etc.); no separate region dimension. |
| 4 | Workflow shape (already exists) | One file per (surface, platform); each accepts `selected_apps` CSV; matrix expansion builds many apps in one run. |
| 5 | Row ↔ run mapping | **Many rows share one run.** SCC bundles selected rows by (surface, platform) into one `workflow_dispatch`; per-row status tracked via matrix-job names. |
| 6 | Lifecycle gates | **Create → Approve → Dispatch → InProgress → Complete.** Mirrors Autopilot's `createReleaseH`/`approveReleaseH`/`triggerReleaseH`. |
| 7 | MVP surface | **Consumer Android only** (`fastlane-android.yaml`). Other surfaces phase in after. |
| 8 | App catalog source | **Manual SCC table** (`app_catalog`), seeded from `catalyst.yaml`. |
| Arch | Architecture approach | **Approach A — extend existing tables, single product slug.** Per user direction: "It is supposed to be a single tool for releases." |
| Auto-version | Where Play API is called | **Move into SCC.** New module `Mobile/Versioning.hs`. Workflow's existing auto-detect step is bypassed when `inputs.version_name` + `inputs.version_code` are passed. |
| GH auth | Authentication mechanism | **GitHub App.** Stored as App ID + private key + installation ID in `server_config`; SCC mints short-lived installation tokens. |
| **iOS-1** | **iOS version source** | **App Store Connect API.** Existing `Mobile/Versioning.hs` becomes a thin dispatcher over `Versioning/Play.hs` (renamed from today's content) + new `Versioning/Apple.hs` (App Store Connect client). JWT auth with ES256 + a `.p8` private key — **inlined into `Versioning/Apple.hs`** to match Play's shape (Play also signs its JWT inline in the same file). No separate auth module. ES256 is signed natively via `cryptonite`'s ECDSA P-256 (`Web.JWT` only does RS/HS); PKCS#8 .p8 keys are parsed with `asn1-encoding`; ASN.1 ECDSA signatures are converted to JWS raw `R‖S` wire format inline. No new package dependency. `Stage 1 (ResolveVersion)` calls the dispatcher — branching lives inside `Versioning.hs`, not in each caller. |
| **iOS-2** | **iOS destinations** | **Extend `MobileDestination` with `MBTestFlight` and `MBAppStore`.** Important nuance: `MobileDestination` is **metadata only** — neither the Android workflow nor the iOS workflow reads it (verified by grep). But SCC's own create API (`CreateMobileReleasesReq.destination`) requires the field. Without iOS variants, iOS callers would be forced to pass `MBGooglePlay`/`MBFirebase` as placeholders, which corrupts the audit log. Adding the two iOS variants gives iOS callers correct values to pass and lets the UI render an appropriate dropdown per platform. The workflow continues to ignore the field — SCC is not gating any behavior on it. If the team later wants the iOS workflow to read this and route between TestFlight/AppStore lanes, the field is already in place. |
| **iOS-3** | **iOS app identifier** | Repurpose `package_name` to hold either an Android package name (`in.juspay.nammayatri`) or an iOS bundle id (`in.juspay.nammayatri.ios`). The Versioning module is the only thing that interprets it. **No new `asc_app_id` column** — SCC looks up the App Store Connect numeric app id at runtime via `GET /v1/apps?filter[bundleId]=<bundle_id>`, mirroring the iOS workflow's own approach (`fastlane.yaml:304-312`). Avoids per-row drift between SCC's catalog and ASC. |
| **iOS-4** | **TestFlight processing wait** | Apple processes uploaded builds asynchronously (5–30 min for TestFlight). **SCC does not wait for it.** SCC dispatches whatever iOS workflow `app_catalog.workflow_path` points to, observes the matrix-job conclusion + pushed tag, and stops. iOS `MBCompleted` therefore means "uploaded to ASC, Apple processing pending" — not "live in TestFlight." Android `MBCompleted` retains its existing meaning ("live on Play"). The semantic asymmetry is honest: Android upload is sync from fastlane's perspective, iOS upload is async on Apple's side. Considered two alternatives — (a) require `pilot upload --skip_waiting_for_build_processing=false` in the iOS GH workflow so fastlane blocks until VALID, (b) add an SCC-side `ConfirmAppStoreProcessing` poll stage — both rejected for v1: (a) breaks the "GH workflow is the worker, SCC doesn't dictate workflow internals" principle from §2 row 1; (b) adds an SCC stage + ASC build-state polling. UI surfaces the asymmetry via a footnote on iOS rows: *"Apple processing typically takes 5–30 min before this build appears in TestFlight."* Promote to (b) later if observability becomes important. |
| **iOS-5** | **Workflow contract** | The iOS GH workflow (`fastlane.yaml`, plus `provider-prod-ios-gen.yaml` for driver) accepts a **different `inputs` shape from Android**: `{selected_apps, change_log, version_number, notify_slack, payload}` — note **`version_number` is a single field**, NOT separate `version_name` + `version_code` (Apple convention: one semver string + a build number that the workflow computes internally via `fastlane fetch_build_number`). SCC's `DispatchWorkflow` stage therefore branches on `acPlatform`: Android rows send the existing payload; iOS rows send `version_number` (single field) and omit version_name/version_code. SCC dispatches via `app_catalog.workflow_path` — no other contract differences. |
| **iOS-6** | **Build artifact** | iOS produces an `.ipa`; uploaded by fastlane/altool inside the GH workflow. SCC never touches the binary, exactly like Android. |

## 3. Architecture overview

**Same product slug** (`autopilot`). Frontend label of the product is renamed `"Backend Releases"` → `"Releases"`; two `PRODUCT_REGISTRY` entries share the slug to render two dashboard tiles ("Backend Releases" and "Mobile Releases").

**Module placement (backend):**

```
backend/src/Products/Autopilot/Mobile/
  Types.hs                    MobileBuildContext, MobileBuildTargetState, MobileBuildWFStatus,
                              MobileDestination (+ MBTestFlight, MBAppStore for iOS — metadata only, not read by workflow)
  Github.hs                   GH App auth, workflow_dispatch, list runs, jobs, refs
  Github/Auth.hs              GH App JWT + installation token cache
  Versioning.hs               Thin dispatcher: branches on AppCatalog.platform.
                              Re-exports the public surface of both backends.
  Versioning/Play.hs          ← Renamed from old Versioning.hs. Play Console client (Android)
                                — JWT (RS256) + OAuth exchange + API calls + creds loader, all inline.
  Versioning/Apple.hs         NEW — App Store Connect client (iOS version resolution only)
                                — JWT (ES256) + API calls + creds loader, all inline. Matches Play's shape.
                                No separate Auth.hs; no IORef caching (ASC calls are low-frequency).
  Workflow.hs                 mobileBuildSpec :: WorkflowSpec ReleaseState.
                              Stage 1 calls Versioning.resolveNextVersion (one entry point).
  Routes.hs                   Servant endpoints for mobile-specific actions
  Handlers/{AppCatalog,Release,Versions,Live}.hs   HTTP handlers
  Queries/{AppCatalog,Tracker}.hs                  DB queries
```

`Mobile/Versioning.hs` becomes the **single entry point** for version resolution. Callers pass `acPlatform` and `acPackageName` directly (rather than the whole `AppCatalog` record) so the dispatcher stays orthogonal to the catalog schema. The return type is a discriminated `VersionResolution` sum — Android needs both name + code, iOS needs only a single version number, so a fixed tuple would force one of the surfaces to carry a dead field.

```haskell
-- Mobile/Versioning.hs (~25 lines)
module Products.Autopilot.Mobile.Versioning
  ( VersionResolution(..)
  , resolveNextVersion       -- the dispatcher
  , module Play              -- legacy re-exports during the transition
  , module Apple
  ) where
import qualified Products.Autopilot.Mobile.Versioning.Play  as Play
import qualified Products.Autopilot.Mobile.Versioning.Apple as Apple

data VersionResolution
    = AndroidVersion { vName :: Text, vCode :: Int32 }
    | IosVersion     { vNumber :: Text }

resolveNextVersion :: MonadFlow m => Text -> Text -> m (Either Text VersionResolution)
resolveNextVersion platform pkgName = case platform of
  "android" -> fmap (uncurry AndroidVersion) <$> Play.resolve pkgName
  "ios"     -> fmap IosVersion              <$> Apple.resolve  pkgName
  other     -> pure (Left ("unsupported platform: " <> other))
```

Both callers (`Mobile/Workflow.hs:execResolveVersion` and `Mobile/Handlers/Versions.hs:previewVersionsH`) collapse to one call — no per-caller platform branching. **There is no SCC-side polling of ASC build state**; fastlane handles that wait inside the iOS GH workflow (see §2 iOS-4).

**Reuse vs. extend vs. add (Android MVP — shipped):**

| Reused | Extended | Net-new |
|---|---|---|
| `release_tracker`, `release_events` tables | `ReleaseCategory` ADT (+ `MobileBuild`) | `app_catalog` table |
| `Core/Workflow/Engine.hs` (resumable stages) | `TargetState` (+ `MobileBuildState`) | GitHub App HTTP client |
| `Core/Http/Client.hs` (pooled, retried) | `AutopilotPermission` (+ 2 perms) | Play Console API client |
| `Core/Auth/Protected` RBAC | `releaseContext` JSON shape | `mobileBuildSpec` workflow |
| Existing runner loop in `Products/Autopilot/Runner.hs` | `Workflow/Factory.hs` dispatch | Two new columns on `release_tracker` |
| Slack notifier, Beam ORM, Flow monad | Frontend `PRODUCT_REGISTRY` | Frontend pages: `CreateMobileRelease`, `ReleaseGroupDetail`, `MobileAppsAdmin`, `LiveReleases` |

**Reuse vs. extend vs. add (iOS extension — proposed):**

| Reused | Extended | Net-new |
|---|---|---|
| Every Android-side module above (the iOS path is additive — nothing is rewritten) | `Mobile/Versioning.hs` becomes a **dispatcher**; existing Play code moves to `Mobile/Versioning/Play.hs` (rename) | `Mobile/Versioning/Apple.hs` (App Store Connect version-resolution client — ES256 JWT signer + API client + creds loader, all inline, matching `Versioning/Play.hs`'s shape) |
| `release_tracker`, `app_catalog`, `release_events` schema — **no new columns** (`asc_app_id` is looked up at runtime via bundle id, not stored per-row) | `app_catalog` seed (append 10 iOS rows to `0011-mobile-releases.sql` in place) | Three new `server_config` secrets: `app_store_connect_issuer_id`, `app_store_connect_key_id`, `app_store_connect_private_key_p8` (appended to `system-control-seed.sql`) |
| `Mobile/Workflow.hs` engine, lock pattern, **all 7 existing stages** (no new stage, no new status) | `execResolveVersion` calls `Versioning.resolveNextVersion` (dispatcher branches on platform); `execDispatchWorkflow` branches on platform too — Android sends `version_name`+`version_code`, iOS sends `version_number` | — |
| `MobileBuildWFStatus` ADT (**no changes** — no new fine-grained statuses needed) | `MobileDestination` ADT (+ `MBTestFlight`, `MBAppStore`); `Mobile/Handlers/Versions.hs:previewVersionsH` collapses to a single dispatcher call; response shape on iOS rows is `{ next_version_number, source: "app_store_connect" }` (single field) | — |
| `Mobile/Github.hs` + `Github/Auth.hs` (workflow dispatch identical for iOS — same `workflow_dispatch` endpoint, just different `inputs` shape) | `Mobile/Workflow.hs:execDispatchWorkflow` (platform-aware payload assembly) | iOS GH workflows (`fastlane.yaml` consumer, `provider-prod-ios-gen.yaml` driver) — authored in `nammayatri/ny-react-native`, **out of SCC scope**. SCC dispatches whatever workflow the catalog row names. The workflow already auto-detects from ASC as a fallback (its inline Python — `fastlane.yaml:261-346`), so if SCC's `Versioning/Apple.hs` fails for any reason (creds missing, network glitch), the workflow takes over — same robustness Android already has. |
| `AP_RELEASE_*`, `AP_MOBILE_*` permissions (no new perms needed) | `CreateMobileRelease`: per-platform version-field label ("Version Number" for iOS, "Version Name + Code" for Android); preview source label `app_store_connect` | — |
| All frontend pages (rows with `platform='ios'` already render) | — | — |

**Explicitly deferred:**
- catalyst.yaml live-sync (manual catalog suffices for slow-changing 10-app set)
- Tag webhook backflow (poll-based completion is sufficient)
- Play Store / App Store staged rollouts (10% → 50% → 100%) — workflows do 100% today
- OTA / Airborne integration in SCC (workflow already handles it)
- Renaming `ProductSlug.Autopilot` → `Releases` (cleanup for later)
- ~~Provider surfaces, iOS surfaces (phase 2+)~~  → **iOS surfaces now in scope (this extension); provider iOS follows same pattern, just different `app_catalog` rows.**

## 4. Data model

### 4.1 Schema changes

**Two columns on `release_tracker`** (nullable; populated for `MobileBuild` rows only):

```sql
ALTER TABLE release_tracker
  ADD COLUMN dispatch_id    TEXT,
  ADD COLUMN external_run_id TEXT;
CREATE INDEX release_tracker_dispatch_id_idx     ON release_tracker(dispatch_id);
CREATE INDEX release_tracker_external_run_id_idx ON release_tracker(external_run_id);
```

`external_run_id` is named generically so the same column serves any future external CI integration.

**New table `app_catalog`:**

```sql
CREATE TABLE app_catalog (
  id              SERIAL PRIMARY KEY,
  name            TEXT NOT NULL,        -- catalyst name, e.g. "NammaYatri"
  surface         TEXT NOT NULL,        -- "customer" | "driver"
  platform        TEXT NOT NULL,        -- "android" | "ios"
  github_repo     TEXT NOT NULL,        -- "nammayatri/ny-react-native"
  workflow_path   TEXT NOT NULL,        -- ".github/workflows/fastlane-android.yaml" or ".../fastlane.yaml"
  package_name    TEXT,                 -- Android: "in.juspay.nammayatri" (Play package_name)
                                        -- iOS:     "in.juspay.nammayatri.ios" (bundle id)
  display_label   TEXT,                 -- "Namma Yatri (Customer Android)"
  enabled         BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (name, surface, platform)
);
```

**iOS additions appended to `0011-mobile-releases.sql` in place:**

**No `ALTER TABLE` and no new column.** The iOS extension adds only `INSERT` statements for the 10 iOS catalog rows. The ASC numeric app id is resolved at runtime via `GET /v1/apps?filter[bundleId]=<bundle_id>` — same approach as the iOS workflow's own auto-detect (`fastlane.yaml:304-312`). The `package_name` column carries the iOS bundle id for iOS rows and the Play package name for Android rows; no second identifier column is needed.

MVP seed (already shipped): 10 customer Android apps (Cumta, NammaYatri, ManaYatri, Yatri, OdishaYatri, YatriSathi, KeralaSavaari, Bridge, BharatTaxi, Lynx).

iOS extension seed (this proposal): mirror rows for the same 10 apps with `platform='ios'`, `workflow_path='.github/workflows/fastlane.yaml'`, `enabled=false` (admin enables per app during Phase 2 dogfood). Full SQL in §8.3.

### 4.2 Existing-column mapping for `MobileBuild` rows

| Column | Backend uses for | Mobile uses for |
|---|---|---|
| `app_group` | "Beckn", "rider-app" | App name, e.g. `"NammaYatri"` |
| `service` | "user-service" | Surface: `"customer"` or `"driver"` |
| `env` | "prod", "staging" | Platform: `"android"` or `"ios"` |
| `category` | `BackendService` etc. | `MobileBuild` (new) |
| `mode` | `AUTO` / `MANUAL` | `MANUAL` for MVP |
| `oldVersion` / `newVersion` | image tags | Semver, e.g. `"2.5.0"` |
| `rolloutStrategy` / `rolloutHistory` | rollout steps | NULL for MVP |
| `releaseContext` (JSON) | K8s / Config target spec | `MobileBuildContext` (below) |

Naming awkwardness — `service` literally storing `"customer"` — is a known cost of Approach A. Acceptable for MVP; revisit when the codebase next does a generic-naming pass (the same pattern that renamed `product` → `app_group`).

### 4.3 `releaseContext` JSON for mobile rows

```json
{
  "kind": "mobile_build",
  "version_code": 12345,
  "change_log": "Bug fixes and performance improvements",
  "destination": "GooglePlay",
  "release_group_id": "8c0e3f...",
  "matrix_job_name": "NammaYatri-Release",
  "ota_namespace": "nammayatriv2",
  "tag_pushed": null
}
```

`tag_pushed` is filled when the run completes; `matrix_job_name` is set at dispatch time so the runner can map GH `/jobs` responses back to the row; `release_group_id` is for UI cohesion only (no column needed since dispatch_id carries the load-bearing query). If we ever need fast lookup by `release_group_id` (e.g., a "find my batch" search), promote it to a column — straightforward additive migration.

### 4.4 New types (Haskell)

```haskell
-- Products/Autopilot/Types/Workflow.hs
data ReleaseCategory
  = BackendService | BackendScheduler | BackendConfig | VSEdit
  | MobileBuild                         -- NEW
  deriving (Eq, Show, Read, Generic, Enum, Bounded)

-- Products/Autopilot/Types/Target.hs
data TargetState
  = K8sState K8sDeploymentState
  | ConfigState ConfigDeploymentState
  | MobileBuildState MobileBuildTargetState   -- NEW

-- Products/Autopilot/Mobile/Types.hs (new module)
data MobileBuildTargetState = MobileBuildTargetState
  { mbWfStatus         :: MobileBuildWFStatus
  , mbContext          :: MobileBuildContext
  , mbExternalRunId    :: Maybe Text
  , mbMatrixJobStatus  :: Maybe Text       -- "queued" | "in_progress" | "success" | "failure"
  , mbBuildStartedAt   :: Maybe UTCTime
  , mbBuildCompletedAt :: Maybe UTCTime
  }

data MobileBuildWFStatus
  = MBInit
  | MBVersionResolved
  | MBDispatched
  | MBRunIdResolved
  | MBBuilding              -- duration depends on what the GH workflow does; SCC doesn't model the ASC processing wait
  | MBSubmittedToStore
  | MBTagPushed
  | MBCompleted
  | MBFailed Text
  | MBAborting
  | MBAborted
  deriving (Eq, Show, Read, Generic)

-- Mobile/Types.hs
data MobileDestination
  = MBGooglePlay      -- Android, production track
  | MBFirebase        -- Android, App Distribution
  | MBTestFlight      -- NEW — iOS beta channel
  | MBAppStore        -- NEW — iOS production (App Store)
  deriving (Eq, Show, Read, Generic, Enum, Bounded)

-- NOTE: This field is METADATA only. Neither GH workflow reads it (verified
-- by grep over fastlane-android.yaml and fastlane.yaml — zero matches for
-- "destination"). The release type (alpha/beta/production) on both platforms
-- is set by Catalyst's matrix output internal to the workflow. SCC's
-- `CreateMobileReleasesReq` does require this field though, so iOS callers
-- need MBTestFlight/MBAppStore to avoid passing wrong Android labels.
```

User-facing `ReleaseStatus` reuses existing values (`CREATED → INPROGRESS → COMPLETED|ABORTED|USER_ABORTED`); `validateStatusTransition` unchanged.

**No new fine-grained status for iOS.** SCC doesn't model the ASC processing wait. The iOS GH workflow may or may not block on it (workflow author's choice); either way SCC observes the matrix job and stops at the existing terminal statuses. iOS `MBCompleted` means "uploaded to ASC" if the workflow doesn't wait, or "live in TestFlight" if it does — see §2 iOS-4 and the UI footnote that surfaces this to users.

## 5. Lifecycle & runner

### 5.1 Coarse user-facing lifecycle

```
CREATED ──approve──▶ CREATED(approved) ──dispatch──▶ INPROGRESS ──┬─▶ COMPLETED
                                                                  ├─▶ ABORTED
                                                                  └─▶ USER_ABORTED
```

### 5.2 Fine-grained `MobileBuildWFStatus` progression

```
MBInit
  └─▶ MBVersionResolved        (Android: Play API; iOS: App Store Connect API)
       └─▶ MBDispatched         (workflow_dispatch returned 204)
            └─▶ MBRunIdResolved (matched GH run by created_at + actor)
                 └─▶ MBBuilding (matrix job = in_progress; for iOS, fastlane is also
                      │          for iOS this may end after upload or after ASC validates,
                      │          depending on what the iOS workflow chooses to wait for)
                      └─▶ MBSubmittedToStore (fastlane upload OK + ASC VALID for iOS)
                           └─▶ MBTagPushed (annotated tag observed on repo)
                                └─▶ MBCompleted

  Failure paths from each step → MBFailed <reason> → ReleaseStatus = ABORTED
  User-abort path: MBAborting → MBAborted (calls GH /runs/:id/cancel)
```

Identical shape for Android and iOS. The duration of `MBBuilding` may differ depending on what the iOS workflow does — whether fastlane blocks on ASC processing or returns right after upload is the workflow author's choice, not SCC's. Either way, SCC just watches the matrix job; the poll interval (`mobile_run_poll_seconds`, default 30) is fine for both. Note: if the iOS workflow does NOT wait for ASC, `MBCompleted` for iOS means "uploaded to ASC, processing pending" — see §2 iOS-4.

### 5.3 Runner: extend existing loop, add one workflow spec

The existing `Products/Autopilot/Runner.runnerPollLoop` already dispatches by `ReleaseCategory` via `Workflow/Factory.getWorkflowForCategory`. We add one match arm:

```haskell
getWorkflowForCategory :: ReleaseCategory -> WorkflowExecutor
getWorkflowForCategory = \case
  BackendService    -> runWorkflowSpec backendServiceSpec
  BackendScheduler  -> runWorkflowSpec backendSchedulerSpec
  BackendConfig     -> runWorkflowSpec backendConfigSpec
  VSEdit            -> notImplementedWorkflow "VSEdit"
  MobileBuild       -> runWorkflowSpec mobileBuildSpec   -- NEW
```

The poll loop, job picking (`pickJobs`, priority sort, per-`appGroup` cap), startup recovery (`runnerStartupRecovery` flips orphan INPROGRESS rows to recoverable), and `forkFlow` worker pattern are reused as-is.

### 5.4 `mobileBuildSpec` — stages

Each stage uses `Core/Workflow/Engine.hs`'s checkpoint-and-resume pattern. `stageGuard` is a pure predicate over persisted state, so runner restarts skip completed stages.

| # | Stage | Action | Skip-guard |
|---|---|---|---|
| # | Stage | Action | Skip-guard |
|---|---|---|---|
| 1 | `ResolveVersion` | Call `Mobile.Versioning.resolveNextVersion ac` — the dispatcher branches on `acPlatform` internally (Play Console for Android, App Store Connect for iOS). Persist `version_name` + `version_code` (Android) / `buildNumber` (iOS) in `targetState`. | `mbWfStatus >= MBVersionResolved` |
| 2 | `GroupForDispatch` | Identify sibling rows with same `(workflow_path, surface, platform, dispatch_id)`; acquire row-level lock on lowest-id sibling | `external_run_id IS NOT NULL` |
| 3 | `DispatchWorkflow` | POST `/actions/workflows/.../dispatches`. **Payload branches on `acPlatform`:** Android sends `{selected_apps, version_name, version_code, change_log, payload}`; iOS sends `{selected_apps, version_number, change_log, payload}` (single `version_number` field — Apple convention; the build number is computed by the iOS workflow's `fastlane fetch_build_number`). `notify_slack` defaults to `true` in both workflows so SCC omits it. The Github HTTP call itself is identical for both platforms — only the `inputs` shape differs. | `mbWfStatus >= MBDispatched` |
| 4 | `ResolveRunId` | Poll `/actions/workflows/.../runs?event=workflow_dispatch` until a run matches by actor + `created_at` window; save `external_run_id` to all sibling rows | `external_run_id IS NOT NULL` |
| 5 | `PollMatrixJobs` | Every `mobile_run_poll_seconds` (default 30) call `/runs/:id/jobs`; for each row's `mbcMatrixJobName` (currently `<acName>-Release`), update `mbMatrixJobStatus`; emit `MATRIX_JOB_UPDATED` event. iOS rows may linger here longer if the workflow chooses to wait on ASC processing — same poll loop, just runs as long as the matrix job runs. **Caveat:** iOS jobs are named `<target>-<release_type>` (Catalyst-driven) rather than `<name>-Release`. If Catalyst's iOS production matrix uses `release_type=Release`, the equality match coincidentally works; if not, the fix is to switch to a prefix-match on `<acName>-`. Don't preemptively change — verify in the E2E dogfood. | All rows in dispatch are terminal |
| 6 | `ConfirmTag` | Once matrix job = success, list refs matching `${app-segment}/prod/${platform}/v*` and confirm version tag was pushed; backfill `newVersion` from tag | `tag_pushed IS NOT NULL` (in `mbContext`) |
| 7 | `Finalize` | Set `ReleaseStatus = COMPLETED` (or `ABORTED` on failure); emit `STATUS_UPDATED`; trigger Slack thread reply | `status` is terminal |

**No new SCC stage for iOS.** SCC dispatches the iOS workflow as-is and observes the matrix job + pushed tag exactly like Android. Whether the workflow waits for ASC processing internally is the team's choice (it's a workflow-internal detail, see §2 iOS-4). SCC's existing 7 stages run unchanged.

### 5.5 Dispatch grouping

User-action "dispatch these N rows" maps to:

1. SCC generates one `release_group_id` (UUID) covering all N rows (stored in `mbContext`).
2. Server groups rows by `(workflow_path, surface, platform)` → produces M dispatch records (M ≤ 4 for MVP; only consumer-android workflow exists).
3. For each dispatch record, generate one `dispatch_id` (UUID) and assign it to those rows' `release_tracker.dispatch_id` column.
4. Insert one `release_event` per row: `BUSINESS / DISPATCH_REQUESTED / { release_group_id, dispatch_id }`.
5. Runner picks up next tick.

### 5.6 Concurrency & idempotency

- Stage 2 acquires `SELECT … FOR UPDATE` on the lowest-id row in the dispatch group; other workers see the lock and skip.
- Stage 3 (`DispatchWorkflow`) is the only non-idempotent step. We dispatch only when `external_run_id IS NULL` AND `mbWfStatus < MBDispatched` at the start of the stage. If the worker crashes between POST and DB commit, on restart we'll see `external_run_id IS NULL` but stage 4 (`ResolveRunId`) finds the orphan run via the nonce and adopts it — no double-dispatch.
- On SCC restart, `runnerStartupRecovery` keeps `INPROGRESS` mobile rows as INPROGRESS (their GH runs are still going independently). The next poll resumes from the appropriate stage based on `mbWfStatus`.

### 5.7 Failure modes

| Failure | Detection | Handling |
|---|---|---|
| Play API call fails at `ResolveVersion` (Android) | HTTP error from Play client | Retry via `Core/Http/Client` retry; on terminal fail → `MBFailed "version_resolution"`, row → ABORTED |
| **App Store Connect call fails at `ResolveVersion` (iOS)** | **HTTP error from ASC client** | **Same shape as Play: retry-then-abort. Most common cause: missing/expired `.p8` key or wrong issuer id → admin must fix `server_config` and re-trigger.** |
| **ASC bundle-id lookup returns no app** | **`GET /v1/apps?filter[bundleId]=<bundle_id>` returns empty list** | **`MBFailed "asc_app_not_found"`. Likely cause: bundle id in `app_catalog.package_name` is wrong, or the configured ASC API key doesn't have access to this app's team. Non-retryable; admin fixes the catalog row or rotates creds. (Falling-back to workflow auto-detect happens automatically if SCC dispatches with version_number blank — see §iOS-1.)** |
| `workflow_dispatch` returns non-2xx | 4xx/5xx from GH API | Retry once; on second fail → `MBFailed "dispatch"` |
| Run lookup never finds nonce | Timeout after 5 min in `ResolveRunId` | `MBFailed "run_lookup_timeout"`; manual override path: operator PATCHes `external_run_id` |
| Matrix job fails | `conclusion=failure` from GH | `MBFailed "build_failed"` with link to GH job logs |
| SCC crashes mid-build | Next runner tick observes orphan INPROGRESS row | Resume — stage guards skip completed stages |
| GH run cancelled outside SCC | `conclusion=cancelled` | `MBFailed "cancelled_externally"` |
| Tag never appears (uploaded but no tag) | `ConfirmTag` polls ~5 min then gives up | Mark `MBCompleted` but emit `BUSINESS / TAG_MISSING` event |
| **iOS: App Store Connect rejects the build during processing** | **The fastlane upload step inside the GH workflow exits non-zero** | **Matrix job `conclusion=failure` → `MBFailed "build_failed"` (existing path). The fastlane log carries Apple's reason; no SCC-specific handling needed.** |
| **iOS: matrix job hits the GH job's `timeout-minutes` cap** | **Matrix job `conclusion=cancelled` (timed out)** | **Existing path: `MBFailed "cancelled_externally"`. Mitigation: workflow author sets `timeout-minutes` appropriately for whatever the workflow does — entirely the team's choice; SCC imposes nothing.** |

## 6. HTTP API + RBAC

### 6.1 Permissions

**Reused (already generic enough):**

| Perm | Scope |
|---|---|
| `AP_RELEASE_VIEW` | view any release |
| `AP_RELEASE_CREATE` | draft a release |
| `AP_RELEASE_APPROVE` | sign off (separate from dispatch) |
| `AP_RELEASE_ABORT` | request cancel |
| `AP_RELEASE_DISCARD` | delete a draft |

**New:**

| Perm | Scope |
|---|---|
| `AP_MOBILE_DISPATCH` | fire the GH `workflow_dispatch` (separation-of-duties gate) |
| `AP_MOBILE_APP_MANAGE` | CRUD on `app_catalog` (admin) |

`AP_MOBILE_DISPATCH` is intentionally mobile-only rather than a generic `AP_RELEASE_DISPATCH` because backend Autopilot's existing `triggerReleaseH` doesn't gate on a dispatch perm today; we don't silently add a gate to backend deploys.

Editing the GitHub App private key + Play Console service account JSON reuses existing `AP_PRODUCT_CONFIG_EDIT` (those are stored as `server_config` rows of `type='secret'`).

**Default role bindings** (in `dev/sql-seed/system-control-seed.sql`):

| Role | New mobile perms granted |
|---|---|
| Admin | `AP_MOBILE_DISPATCH`, `AP_MOBILE_APP_MANAGE` |
| Manager | `AP_MOBILE_DISPATCH` |
| Viewer | (none) |

### 6.2 Endpoints

**Existing (now category-aware):**

```
GET  /releases?category=mobile         list, optionally filtered
GET  /releases/:id                     single release detail (any category)
GET  /releases/:id/events              event log (any category)
POST /releases/:id/approve             single-row approve (existing)
POST /releases/:id/abort               single-row abort (for mobile, calls GH /runs/:id/cancel)
POST /releases/:id/discard             discard a draft (existing)
```

**New mobile-specific:**

```
POST /releases/mobile/create           create N draft releases (one per selected app)
POST /releases/mobile/dispatch         group + trigger N approved releases
POST /mobile/versions/preview          dry-run: ask Play API for next versions
GET  /mobile/apps                      list app_catalog
POST /mobile/apps                      admin: add a new app
PATCH /mobile/apps/:id                 admin: toggle enabled, edit metadata
GET  /releases/live?category=all       what's currently live (Live Releases page)
```

### 6.3 Request/response shapes

**`POST /releases/mobile/create`**

```jsonc
// Request
{
  "release_group_label": "v2.5.0 customer-android batch",
  "change_log": "Performance improvements + bug fixes",
  "destination": "GooglePlay",
  "items": [
    { "app_catalog_id": 1, "version_name": null, "version_code": null },
    { "app_catalog_id": 2, "version_name": "2.5.0", "version_code": 12350 }
  ]
}
// Response — 201
{
  "release_group_id": "8c0e3f...",
  "releases": [
    { "id": "rt_a1b2...", "app_catalog_id": 1, "status": "CREATED" },
    { "id": "rt_c3d4...", "app_catalog_id": 2, "status": "CREATED" }
  ]
}
```

**`POST /releases/mobile/dispatch`**

```jsonc
// Request
{ "release_ids": ["rt_a1b2...", "rt_c3d4..."] }
// Response — 202
{
  "dispatches": [
    {
      "dispatch_id": "dis_xyz...",
      "workflow_path": ".github/workflows/fastlane-android.yaml",
      "release_ids": ["rt_a1b2...", "rt_c3d4..."],
      "expected_run_url": null
    }
  ]
}
```

If selection spans multiple `(surface, platform)` combos, response has multiple `dispatches` entries.

**`POST /mobile/versions/preview`**

```jsonc
// Request
{ "app_catalog_ids": [1, 2, 3, 11] }
// Response
{
  "previews": [
    // Android — two fields: next_version_name + next_version_code
    { "app_catalog_id": 1, "next_version_name": "2.5.1", "next_version_code": 12351, "source": "play_console" },
    { "app_catalog_id": 2, "next_version_name": "2.5.1", "next_version_code": 12351, "source": "play_console" },
    { "app_catalog_id": 3, "error": "play_api_unauthorized" },
    // iOS — ONE field: next_version_number (Apple convention; build number is
    // computed by the iOS workflow itself, not by SCC)
    { "app_catalog_id": 11, "next_version_number": "2.5.1", "source": "app_store_connect" }
  ]
}
```

`source` is one of `play_console | app_store_connect`. The handler dispatches on `app_catalog.platform`; **per-row failures don't block the others or block create.** **The response shape differs per platform** — Android rows return `next_version_name` + `next_version_code` (two fields); iOS rows return `next_version_number` (single field). Frontend must handle both shapes.

**`GET /releases/live?category=all|backend|mobile`**

```jsonc
// Response
{
  "backend": [
    { "app_group": "Beckn", "service": "rider-app", "env": "prod",
      "live_version": "v3.1.4", "rollout_state": { "status": "complete", "percent": 100 },
      "updated_at": "..." }
  ],
  "mobile": [
    { "app": "NammaYatri", "surface": "customer", "platform": "android",
      "live_version": "2.5.0", "version_code": 12345,
      "tag_pushed": "nammayatri/prod/android/v2.5.0+12345",
      "released_at": "..." }
  ]
}
```

Server-side computed via `SELECT DISTINCT ON (...)` on `release_tracker WHERE status='COMPLETED'`.

### 6.4 Servant route protection

```haskell
-- Products/Autopilot/Mobile/Routes.hs
type MobileAPI =
       "releases" :> "mobile" :> "create"
       :> Protected 'AP_RELEASE_CREATE
       :> ReqBody '[JSON] CreateMobileReleasesReq
       :> Post '[JSON] CreateMobileReleasesResp

  :<|> "releases" :> "mobile" :> "dispatch"
       :> Protected 'AP_MOBILE_DISPATCH
       :> ReqBody '[JSON] DispatchMobileReleasesReq
       :> Post '[JSON] DispatchMobileReleasesResp

  :<|> "mobile" :> "versions" :> "preview"
       :> Protected 'AP_RELEASE_CREATE
       :> ReqBody '[JSON] PreviewVersionsReq
       :> Post '[JSON] PreviewVersionsResp

  :<|> "mobile" :> "apps" :> Protected 'AP_RELEASE_VIEW :> Get '[JSON] [AppCatalogEntry]
  :<|> "mobile" :> "apps" :> Protected 'AP_MOBILE_APP_MANAGE :> ReqBody '[JSON] NewAppReq :> Post '[JSON] AppCatalogEntry
  :<|> "mobile" :> "apps" :> Capture "id" Int :> Protected 'AP_MOBILE_APP_MANAGE :> ReqBody '[JSON] PatchAppReq :> Patch '[JSON] AppCatalogEntry

  :<|> "releases" :> "live" :> QueryParam "category" Text :> Protected 'AP_RELEASE_VIEW :> Get '[JSON] LiveReleasesResp
```

Server registration: one `mobileServer` mount in `Core/Server.hs` alongside existing handlers.

### 6.5 Audit events emitted

| Endpoint / step | Event written |
|---|---|
| Create | `BUSINESS / TRACKER_CREATED` (per row, existing label) |
| Approve | `BUSINESS / TRACKER_APPROVED` (existing) |
| Dispatch endpoint | `BUSINESS / DISPATCH_REQUESTED` (new label, payload: `release_group_id` + `dispatch_id`) |
| Runner: `DispatchWorkflow` stage | `BUSINESS / GH_DISPATCHED` (payload: `external_run_id_pending`, `nonce`) |
| Runner: `ResolveRunId` stage | `BUSINESS / GH_RUN_RESOLVED` (payload: `external_run_id`, `run_url`) |
| Runner: `PollMatrixJobs` stage | `BUSINESS / MATRIX_JOB_UPDATED` (per status change; payload: `matrix_job_name`, `status`) |
| Runner: matrix job → store upload detected | `BUSINESS / STORE_SUBMITTED` |
| Runner: `ConfirmTag` stage | `BUSINESS / TAG_OBSERVED` (payload: `tag_name`, `version_name`, `version_code`) |
| Runner: `Finalize` stage | `NOTIFICATION / STATUS_UPDATED` (existing label) |
| Abort | `BUSINESS / TRACKER_ABORTED` (existing) |

All under existing `release_events` schema; new label values only.

## 7. Frontend

### 7.1 File layout

```
frontend/src/products/releases/
├── pages/
│   ├── ListRelease.tsx              ← extended (category filter)
│   ├── CreateRelease.tsx            ← unchanged (backend-only create)
│   ├── ReleaseSummary.tsx           ← extended (renders category-specific section)
│   ├── LiveReleases.tsx             ← NEW (the "what's live" overview)
│   └── mobile/
│       ├── CreateMobileRelease.tsx  ← NEW
│       ├── ReleaseGroupDetail.tsx   ← NEW (per release_group_id)
│       └── MobileAppsAdmin.tsx      ← NEW
├── api.ts                            ← extended with mobileApi.{create,dispatch,previewVersions,...}
├── hooks.ts                          ← new useMobileApps, useCreateMobileRelease, useLiveReleases
└── types.ts                          ← extended with mobile types
```

### 7.2 Registry — two dashboard tiles, one product

```ts
// frontend/src/products/registry.ts
const backendReleasesProduct: ProductDefinition = {
  slug: 'autopilot',
  label: 'Backend Releases',
  description: 'Microservice rollouts, VS edits, config maps',
  icon: 'Server',
  basePath: '/releases',
  defaultCategoryFilter: 'backend',     // NEW field
  viewPermission: 'AP_RELEASE_VIEW',
  navItems: [/* existing backend nav */],
};

const mobileReleasesProduct: ProductDefinition = {
  slug: 'autopilot',                     // SAME backend slug → same RBAC
  label: 'Mobile Releases',
  description: 'React Native app releases via GitHub Actions',
  icon: 'Smartphone',
  basePath: '/releases',
  defaultCategoryFilter: 'mobile',
  viewPermission: 'AP_RELEASE_VIEW',
  navItems: [
    { label: 'All Mobile Releases', path: '/releases?category=mobile', icon: 'List' },
    { label: 'New Mobile Release',  path: '/releases/mobile/new',      icon: 'Plus' },
    { label: 'Live Releases',       path: '/releases/live',            icon: 'Activity' },
    { label: 'Mobile Apps',         path: '/mobile/apps',              icon: 'Package',
                                     permission: 'AP_MOBILE_APP_MANAGE' },
  ],
};

export const PRODUCT_REGISTRY = [backendReleasesProduct, mobileReleasesProduct];
```

### 7.3 Pages

**`ListRelease.tsx` (extended):**
- Category filter chip: `All | Backend | Mobile`. Default applied from `defaultCategoryFilter` of the entry the user navigated from.
- New "Category" column (icon: server / smartphone).
- Mobile rows display `app + surface + platform + version`.
- Bulk-select + bulk actions: "Approve N selected" (if all CREATED + perm), "Dispatch N selected" (if all CREATED+approved Mobile + `AP_MOBILE_DISPATCH`).

**`CreateMobileRelease.tsx` (new — extended for iOS):**
- Multi-select apps from `app_catalog` (enabled only).
- Debounced `/mobile/versions/preview` call as selection changes; pre-fills versions (editable per app).
- Single change-log textarea for the whole batch.
- **Destination dropdown filters by platform of the selected apps:**
  - Android-only selection → `GooglePlay` (default) / `Firebase`.
  - iOS-only selection → `TestFlight` (default) / `AppStore`.
  - Mixed selection → split the form into "Android destination" + "iOS destination" subgroups so the user picks both. The backend receives one destination per row in `releases/mobile/create` (the `items[]` array gets a `destination` field per item, falling back to the top-level if absent).
- A subtle "Build number" label tooltip appears for iOS rows in the version table (vs "Version code" for Android) — same field, different conventional units (iOS is small `42`, Android is `12351`).
- Buttons: `Save as draft`, `Save & approve` (latter if user has `AP_RELEASE_APPROVE`).
- On submit: `POST /releases/mobile/create` → navigate to `ReleaseGroupDetail`.

**`ReleaseGroupDetail.tsx` (new):** one row per (app, surface, platform) in the group. Bulk actions at the group level: "Approve all", "Dispatch all approved", "Discard all drafts".

**`ReleaseSummary.tsx` (extended):** for Mobile rows, replaces the K8s rollout panel with: GH workflow run URL (clickable), matrix job status + duration, pushed tag link, `MobileBuildWFStatus` timeline, plus the existing event log component (works as-is). For iOS rows, after `MBCompleted`, the page shows a small footnote: *"This build is now uploaded to App Store Connect. Apple's processing typically takes 5–30 min before it appears in TestFlight."* — so users know `COMPLETED` here means "uploaded," not necessarily "live yet." (Whether the workflow also waited internally is opaque to SCC; the footnote is conservative.)

**`LiveReleases.tsx` (new):** at `/releases/live`. Two tables (Backend + Mobile) with a category filter. Driven by `GET /releases/live`. Shows currently-live version per (app/service, env/platform), last release time. Backend rows additionally show in-progress rollout percent if any. Mobile staged-rollout column placeholder (deferred).

**`MobileAppsAdmin.tsx` (new):** at `/mobile/apps`. Table of `app_catalog`. Toggle enabled, edit metadata, add new apps. Behind `AP_MOBILE_APP_MANAGE`.

### 7.4 Real-time updates

Existing detail page polls `/releases/:id` + `/releases/:id/events` on a 5–10s interval; same cadence for mobile detail. List page polls. With runner's 30s GH polling + UI's 5–10s polling, status changes show in ~10s after server records them. No WebSocket / SSE for MVP.

### 7.5 What stays in workflow vs. moves to UI

Stays in workflow (build internals): keystore/signing, OTA/Airborne fetch, native Slack notify (workflow already does it; SCC may piggy-back via existing `Notifications` module).

Moves to UI: app selection, version override, change log, destination toggle, "Run" button.

## 8. Testing & rollout

### 8.1 Tests

**Unit:**
- `Mobile/Versioning.hs` — given canned Play API responses, verify next version logic (incl. internal-equals-production patch-bump rule + empty-track fallback).
- **`Mobile/Versioning/Apple.hs`** — two test groups:
  - Pure: given canned ASC responses for `appStoreVersions` + `preReleaseVersions`, verify next version + build number logic. Empty-versions fallback: bump from `1.0.0/1`.
  - Inline JWT signer: sign a token with a fixture `.p8` key, decode (without verifying the signature), assert header has `alg="ES256"` + `kid=ascKeyId`, payload has `iss=ascIssuerId`, `aud="appstoreconnect-v1"`, `exp` ≤ now + 20min. Mirrors how `Versioning/Play.hs` tests its inline JWT minting.
- **`Mobile/Versioning.hs` dispatcher** — table-driven test: `(platform="android", …)` → calls `Play.resolve`; `(platform="ios", …)` → calls `Apple.resolve`; missing creds for either path → abort with the right error tag.
- Dispatch grouping — N release IDs across mixed surfaces → correct dispatches and membership.
- JSON round-trip for `MobileBuildContext` and `MobileDestination` (incl. new `MBTestFlight` / `MBAppStore` variants — serialize as `"TestFlight"` / `"AppStore"`).
- `MobileBuildWFStatus` transition validity (unchanged — no new variants for iOS).

**Integration (`sc-test-api`, real Postgres):**
- Create-mobile-release end-to-end up to dispatch (GH HTTP layer mocked).
- Approve / abort / discard for mobile rows.
- Live releases query with mixed backend + mobile rows.
- RBAC: 403 without `AP_MOBILE_DISPATCH`, 200 with.

**Mocked external APIs:**
- GitHub API: extend `Core/Http/Client` to inject a recorded-response handler. Fixtures for: workflow_dispatch 204, list runs, jobs, refs/tags, cancel run.
- Play Console API: same pattern, fixture file with sample tracks response.

**Optional E2E** (gated on env flag): dispatch against a no-op test workflow on a sandbox repo; verify SCC observes the run through completion. Run on demand.

### 8.2 Rollout

**Phase 0 — pre-merge prep (~1 day, admin):**
1. Create GitHub App on the org (`actions:write`, `metadata:read`, `contents:read`); install on `nammayatri/ny-react-native`.
2. Generate Play Console service account with `androidpublisher` scope (or reuse existing).
3. Stash both into a test SCC instance via one-time admin script.

**Phase 1 — merge with feature flag OFF:**
- Code lands; DB migration runs; `app_catalog` seeded with 10 customer Android apps; `mobile_dispatch_enabled = false`.
- Existing GH Actions UI flows continue unchanged. SCC is a no-op for mobile.
- "Mobile Releases" tile shows on dashboard; Dispatch button disabled with tooltip.

**Phase 2 — single-app dogfood:**
- Flip `mobile_dispatch_enabled = true`.
- In `app_catalog`, set `enabled=true` only for `NammaYatri`; other 9 stay `enabled=false`.
- Release engineer runs one real NammaYatri release through SCC; watches: GH dispatch succeeds, run_id resolves within ~30s, matrix job status updates appear within ~30–60s of GH state change, tag observation fires on success, `release_events` log is correct.
- If anything's off: flip flag off; in-flight GH run continues independently, SCC's polling stops.

**Phase 3 — broader enablement:**
- After 2–3 successful single-app releases, enable the other 9 apps.
- Communicate: SCC is a second way to trigger; GH Actions UI still works.

**Phase 4 — adoption:**
- Dual-track for ~2 weeks. Track usage. If SCC becomes default, document GH UI as fallback.
- No hard deprecation of GH UI — it's the underlying mechanism.

**Phase 5 — iOS extension rollout** (this proposal):

| Step | Owner | Detail |
|---|---|---|
| 5.1 Prep ASC credentials | RelEng admin | In App Store Connect → Users and Access → Integrations → App Store Connect API → generate an API Key with "Developer" role. Save the `.p8` file (one-shot download), **Issuer ID** (UUID near top of page), **Key ID** (10-char string). |
| 5.2 Look up ASC numeric app IDs | RelEng admin | Under "App Information" in App Store Connect for each app, copy the numeric app id. |
| 5.3 Fill the iOS section of `local-mobile-secrets.env` | RelEng admin | The **same** `backend/dev/local-mobile-secrets.env` already used for Android gets a new iOS block: `ASC_ISSUER_ID`, `ASC_KEY_ID`, `ASC_PRIVATE_KEY_P8_PATH`, and a comma-separated `ASC_APP_IDS=NammaYatri=123…,Cumta=234…`. No duplication of the GitHub/Play sections needed. |
| 5.4 Apply the updated `0011-mobile-releases.sql` | auto | `sc-dev` (or container start) re-applies the migration on every startup — that's how this repo's runner works (no migration-tracking table, idempotent `IF NOT EXISTS` / `ON CONFLICT` statements). The iOS additions land automatically. No local DB reset needed. |
| 5.5 Run the setup script | RelEng admin | `nix develop --command bash backend/scripts/setup-mobile-local.sh` — the existing script (extended in plan Task 33) UPDATEs the three ASC `server_config` rows. Same script that already handles Android. Outputs a verification block showing `<NNN chars>` for the .p8. **No per-app values to write** — ASC app id is resolved at runtime by bundle id. |
| 5.6 GH workflow contract | mobile dev | Confirm `fastlane.yaml` already accepts `{selected_apps, change_log, version_number, notify_slack, payload}` — it does today (lines 5–24). The workflow's inline ASC auto-detect (lines 261–346) is the fallback if SCC doesn't pre-fill `version_number`. **No workflow changes required.** |
| 5.7 Single-app dogfood (iOS) | RelEng | Enable one iOS row (e.g. `NammaYatri/customer/ios`) by adding `NammaYatri` to `ENABLE_APPS` and re-running the script. Cut a real TestFlight build through SCC. Row should reach `MBCompleted` when the iOS workflow finishes — the exact duration depends on what that workflow does internally. Verify in App Store Connect that the build is in TestFlight (immediately after `MBCompleted` if the workflow waits; 5–30 min later if it doesn't). |
| 5.8 Broader enablement | RelEng | After 2 successful iOS dogfoods, add the other 9 names to `ENABLE_APPS` and re-run the script. |
| 5.9 Provider iOS surfaces | RelEng | Same flow, just `app_catalog` rows with `surface='driver'` + `workflow_path='.github/workflows/provider-prod-ios-gen.yaml'`. No code changes. |

### 8.3 Migration

Single SQL migration `dev/migrations/system-control/0011-mobile-releases.sql`:

```sql
-- Two columns on release_tracker
ALTER TABLE release_tracker
  ADD COLUMN IF NOT EXISTS dispatch_id    TEXT,
  ADD COLUMN IF NOT EXISTS external_run_id TEXT;
CREATE INDEX IF NOT EXISTS rt_dispatch_id_idx     ON release_tracker(dispatch_id);
CREATE INDEX IF NOT EXISTS rt_external_run_id_idx ON release_tracker(external_run_id);

-- New app_catalog table
CREATE TABLE IF NOT EXISTS app_catalog (
  id              SERIAL PRIMARY KEY,
  name            TEXT NOT NULL,
  surface         TEXT NOT NULL,
  platform        TEXT NOT NULL,
  github_repo     TEXT NOT NULL,
  workflow_path   TEXT NOT NULL,
  package_name    TEXT,
  display_label   TEXT,
  enabled         BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (name, surface, platform)
);

-- Seed 10 customer Android apps
INSERT INTO app_catalog (name, surface, platform, github_repo, workflow_path, package_name, display_label, enabled)
VALUES
  ('Cumta',         'customer', 'android', 'nammayatri/ny-react-native', '.github/workflows/fastlane-android.yaml', 'in.mobility.cumta',           'Cumta (Customer Android)',           false),
  ('NammaYatri',    'customer', 'android', 'nammayatri/ny-react-native', '.github/workflows/fastlane-android.yaml', 'in.juspay.nammayatri',        'Namma Yatri (Customer Android)',     false),
  ('ManaYatri',     'customer', 'android', 'nammayatri/ny-react-native', '.github/workflows/fastlane-android.yaml', 'in.mobility.manayatri',       'Mana Yatri (Customer Android)',      false),
  ('Yatri',         'customer', 'android', 'nammayatri/ny-react-native', '.github/workflows/fastlane-android.yaml', 'net.openkochi.yatri',         'Yatri (Customer Android)',           false),
  ('OdishaYatri',   'customer', 'android', 'nammayatri/ny-react-native', '.github/workflows/fastlane-android.yaml', 'in.mobility.odishayatri',     'Odisha Yatri (Customer Android)',    false),
  ('YatriSathi',    'customer', 'android', 'nammayatri/ny-react-native', '.github/workflows/fastlane-android.yaml', 'in.juspay.jatrisaathi',       'Yatri Sathi (Customer Android)',     false),
  ('KeralaSavaari', 'customer', 'android', 'nammayatri/ny-react-native', '.github/workflows/fastlane-android.yaml', 'in.mobility.keralasavaariconsumer', 'Kerala Savaari (Customer Android)', false),
  ('Bridge',        'customer', 'android', 'nammayatri/ny-react-native', '.github/workflows/fastlane-android.yaml', 'com.mobility.bridge',         'Bridge (Customer Android)',          false),
  ('BharatTaxi',    'customer', 'android', 'nammayatri/ny-react-native', '.github/workflows/fastlane-android.yaml', 'in.mobility.bharatTaxi',      'Bharat Taxi (Customer Android)',     false),
  ('Lynx',          'customer', 'android', 'nammayatri/ny-react-native', '.github/workflows/fastlane-android.yaml', 'in.mobility.international',   'Lynx (Customer Android)',            false)
ON CONFLICT (name, surface, platform) DO NOTHING;

-- Runtime config flags + secret placeholders (admin populates real values)
INSERT INTO server_config (type, name, value, product, enabled, last_updated) VALUES
  ('flag',   'mobile_dispatch_enabled',          'false', 'autopilot', 0, now()),
  ('flag',   'mobile_run_poll_seconds',          '30',    'autopilot', 1, now()),
  ('secret', 'github_app_id',                    '',      'autopilot', 0, now()),
  ('secret', 'github_app_private_key',           '',      'autopilot', 0, now()),
  ('secret', 'github_app_installation_id',       '',      'autopilot', 0, now()),
  ('secret', 'play_console_service_account_json','',      'autopilot', 0, now())
ON CONFLICT DO NOTHING;

-- Grant new perms on existing system roles
UPDATE sc_role SET permissions = array_append(permissions, 'AP_MOBILE_DISPATCH')
  WHERE product_slug='autopilot' AND name IN ('Admin','Manager')
    AND NOT ('AP_MOBILE_DISPATCH' = ANY(permissions));
UPDATE sc_role SET permissions = array_append(permissions, 'AP_MOBILE_APP_MANAGE')
  WHERE product_slug='autopilot' AND name='Admin'
    AND NOT ('AP_MOBILE_APP_MANAGE' = ANY(permissions));
```

Idempotent, forward-only. No rollback needed — disable feature flag to revert behavior.

**iOS additions appended to `dev/migrations/system-control/0011-mobile-releases.sql`** (no new migration file — this repo's runner re-applies every file on every startup with idempotent guards, so an in-place edit is safe and is the simpler choice. The existing Android content stays untouched at the top of the file; the iOS block is appended below it):

```sql
-- ── (existing Android content above stays unchanged) ───────────────────────

-- ── iOS extension (appended) ───────────────────────────────────────────────
-- Mirrors the Android block above. Same migration file because the runner is
-- "re-apply everything on every startup with idempotent guards" (no migration-
-- tracking table, no checksums) — see flake.nix:95-99.
--
-- NO new column needed: ASC numeric app id is resolved at runtime via
-- GET /v1/apps?filter[bundleId]=<bundle_id>, mirroring the iOS workflow's own
-- approach (fastlane.yaml:304-312). The package_name column carries the bundle
-- id for iOS rows and the Play package name for Android rows.

-- Seed iOS rows (mirrors the 10 Android rows from 0011; disabled by default).
INSERT INTO app_catalog (name, surface, platform, github_repo, workflow_path, package_name, display_label, enabled)
VALUES
  ('Cumta',         'customer', 'ios', 'nammayatri/ny-react-native', '.github/workflows/fastlane.yaml', 'in.mobility.cumta.ios',           'Cumta (Customer iOS)',           false),
  ('NammaYatri',    'customer', 'ios', 'nammayatri/ny-react-native', '.github/workflows/fastlane.yaml', 'in.juspay.nammayatri.ios',        'Namma Yatri (Customer iOS)',     false),
  ('ManaYatri',     'customer', 'ios', 'nammayatri/ny-react-native', '.github/workflows/fastlane.yaml', 'in.mobility.manayatri.ios',       'Mana Yatri (Customer iOS)',      false),
  ('Yatri',         'customer', 'ios', 'nammayatri/ny-react-native', '.github/workflows/fastlane.yaml', 'net.openkochi.yatri.ios',         'Yatri (Customer iOS)',           false),
  ('OdishaYatri',   'customer', 'ios', 'nammayatri/ny-react-native', '.github/workflows/fastlane.yaml', 'in.mobility.odishayatri.ios',     'Odisha Yatri (Customer iOS)',    false),
  ('YatriSathi',    'customer', 'ios', 'nammayatri/ny-react-native', '.github/workflows/fastlane.yaml', 'in.juspay.jatrisaathi.ios',       'Yatri Sathi (Customer iOS)',     false),
  ('KeralaSavaari', 'customer', 'ios', 'nammayatri/ny-react-native', '.github/workflows/fastlane.yaml', 'in.mobility.keralasavaariconsumer.ios', 'Kerala Savaari (Customer iOS)', false),
  ('Bridge',        'customer', 'ios', 'nammayatri/ny-react-native', '.github/workflows/fastlane.yaml', 'com.mobility.bridge.ios',         'Bridge (Customer iOS)',          false),
  ('BharatTaxi',    'customer', 'ios', 'nammayatri/ny-react-native', '.github/workflows/fastlane.yaml', 'in.mobility.bharatTaxi.ios',      'Bharat Taxi (Customer iOS)',     false),
  ('Lynx',          'customer', 'ios', 'nammayatri/ny-react-native', '.github/workflows/fastlane.yaml', 'in.mobility.international.ios',   'Lynx (Customer iOS)',            false)
ON CONFLICT (name, surface, platform) DO NOTHING;
```

**Companion seed update — append to `dev/sql-seed/system-control-seed.sql`** (sits alongside the existing GitHub App + Play Console secret placeholders that already land there):

```sql
-- ASC secret placeholders for the iOS extension (admin populates via
-- backend/scripts/setup-mobile-local.sh; same script that handles GH + Play).
INSERT INTO server_config (type, name, value, product, enabled, last_updated) VALUES
  ('secret', 'app_store_connect_issuer_id',      '', 'autopilot', 0, now()),
  ('secret', 'app_store_connect_key_id',         '', 'autopilot', 0, now()),
  ('secret', 'app_store_connect_private_key_p8', '', 'autopilot', 0, now())
ON CONFLICT DO NOTHING;
```

Both are idempotent and forward-only. No new permissions, no schema-breaking changes — backend rows and Android rows are unaffected.

### 8.4 Observability

- **Logs:** every runner stage transition emits `logInfoG` with structured fields (`release_id`, `stage`, `dispatch_id`, `external_run_id`). Failures emit `logErrorG` with the full HTTP response on GH/Play API errors.
- **Audit log:** `release_events` is the source of truth; queryable via existing `/releases/:id/events`.
- **Metrics:** none for MVP. Runner stages are natural instrumentation points if added later.

### 8.5 Risks (recap)

1. `workflow_dispatch` returns 204 with no run_id → handled via nonce-in-payload trick; manual recovery path PATCHes `external_run_id`.
2. Workflow file changes silently breaking dispatch → monitor first-run failures; consider an "input shape validator" admin check in phase 2.
3. Play Console rate limits → cache `/mobile/versions/preview` responses for 60s in `Mobile/Versioning.hs`.
4. Race between SCC and GH UI dispatch → both runs proceed; SCC's nonce-matching tracks the right one. Acceptable for dual-track period.

## 9. Open questions / explicit non-goals

**Open (non-blocking for MVP, decide later):**
- Should SCC subscribe to GH webhooks for tag pushes (faster confirmation than polling)? Defer until polling proves insufficient.
- Should the workflow be modified to emit a structured "uploaded to Play Store" log line for cleaner `STORE_SUBMITTED` detection? Currently we'd parse fastlane output; structured signal would be more robust.

**Non-goals (explicitly deferred):**
- ~~Provider surface (driver app workflows).~~ → in scope (mostly just new `app_catalog` rows).
- ~~iOS surfaces (consumer or provider).~~ → **in scope (this extension).**
- Play Store / App Store staged rollout orchestration (10% → 50% → 100%) — both workflows do 100% today.
- App Store **production review** orchestration. SCC marks the row `COMPLETED` once the build reaches TestFlight (`VALID` in App Store Connect). Submitting for App Store review and tracking Apple's review verdict is **not** in scope — the team continues to drive that from the ASC web UI.
- Live catalyst.yaml sync.
- OTA/Airborne control from SCC (workflow handles it).
- Renaming `ProductSlug.Autopilot` → `Releases`.
- Tag-pushed webhook backflow.
- Generalizing `AP_MOBILE_DISPATCH` to all release categories.

## 10. References

- Existing Autopilot template: `backend/src/Products/Autopilot/`
- Workflow engine: `backend/src/Core/Workflow/Engine.hs`
- HTTP client: `backend/src/Core/Http/Client.hs`
- RBAC framework: `backend/src/Core/Auth/Protected.hs`
- Existing schema: `backend/src/Products/Autopilot/Types/Storage/Schema.hs`
- Mobile workflows (source of truth for dispatch contract):
  - `nammayatri/ny-react-native:.github/workflows/fastlane-android.yaml` (consumer Android, **shipped**)
  - `…/fastlane.yaml` (consumer iOS, **this proposal** — file is named `fastlane.yaml`, not `fastlane-ios.yaml`)
  - `…/provider-prod-apk-gen.yaml` (provider Android, this proposal)
  - `…/provider-prod-ios-gen.yaml` (provider iOS, this proposal)
- Catalog source: `nammayatri/ny-react-native:catalyst.yaml`
- App Store Connect API reference: https://developer.apple.com/documentation/appstoreconnectapi
  - Auth: https://developer.apple.com/documentation/appstoreconnectapi/generating_tokens_for_api_requests (ES256 JWT, 20 min expiry)
  - Endpoints used (version resolution only — no build-state polling):
    - `GET /v1/apps/:asc_app_id/appStoreVersions` — production version history
    - `GET /v1/apps/:asc_app_id/preReleaseVersions` — TestFlight build history
- fastlane `pilot upload` reference: https://docs.fastlane.tools/actions/pilot/ — referenced only as background for the §2 iOS-4 trade-off; SCC does not require any particular fastlane flag.
- Project memory: `~/.claude/projects/-home-shailesh-Desktop-Github-system-control-centre/memory/`

## 11. Post-implementation operator notes

Findings + adjustments from the first end-to-end local exercise (2026-05-13):

### Local dev setup

A turnkey harness was added:

- Template: `backend/dev/local-mobile-secrets.env.example` — fields for GitHub App ID, installation ID, PEM path, Play Console JSON path, feature flag, apps to enable, optional sandbox redirect.
- Script: `backend/scripts/setup-mobile-local.sh` — reads the env file, writes the 5 `server_config` rows, flips `mobile_dispatch_enabled`, enables selected apps, prints a final-state summary with secrets length-masked.

Run after `sc-dev` is up at least once (so the schema exists). Restart `sc-dev` after running so the backend's installation-token cache picks up fresh creds.

### GitHub App scope

The App must be installed on the **org** that owns the target repo, not on a personal account. Setting "Where can this GitHub App be installed?" to "Any account" + installing on `nammayatri` (requires org-admin approval) is the production path. Probe the install with `GET /app/installations` using a self-minted JWT to confirm the installation can see `ny-react-native` before attempting a dispatch.

### Dispatch input shape — workflow contract gotchas

The consumer-Android workflow's `Set Matrix configuration` step has this branching:

```bash
if [ -n "$PAYLOAD" ] ...; then  MATRICES=$(echo "$PAYLOAD" | jq -c '.matrices')  ...
```

Two contract details that bit us on first run:

1. **Do NOT pass a `payload` input** unless you're also passing a full matrix envelope. Any non-empty value flips the workflow into "use payload" mode and bypasses the `selected_apps`/catalyst path. SCC's dispatch inputs are now `{selected_apps, version_name, version_code, change_log}` only.
2. **`selected_apps` is comma-separated catalyst app NAMES** (e.g. `NammaYatri,KeralaSavaari`), not surfaces.

### Schema seeding ordering

`app_catalog` is created by migration `0011-mobile-releases.sql`. Migrations run AFTER the seed file (`dev/sql-seed/system-control-seed.sql`). The 10-row INSERT therefore lives in the migration alongside the `CREATE TABLE`, not in the seed.

### CAS preserves dispatch_id and external_run_id

`conditionalUpdateTracker*` does a DELETE+INSERT inside a txn. The in-memory domain `ReleaseTracker` does not expose `dispatch_id` or `external_run_id` (mobile reads them via raw SQL). Both are now read from the live DB row inside the transaction and preserved into the re-inserted row, alongside the existing `slack_thread_ts` preservation.

### Runner picks up mobile rows only after dispatch

`findRunnableReleaseTrackers` requires `dispatch_id IS NOT NULL` for `category='MobileBuild'`. Approval alone is not enough to start the workflow — this matches the lifecycle's separate Approve and Dispatch steps.

### Stage 5 (PollMatrixJobs) aborts on workflow-level failure

If the matrix never expands (e.g., the workflow's strategy evaluation fails before our job appears), the stage now detects "any returned job is in a failure-like terminal state AND none are in flight AND our job is missing" and aborts with `matrix job never appeared`. Previously it would loop in `StageWaiting` indefinitely.

### Advisory lock leak workaround

`pg_try_advisory_lock` is connection-bound; pooled connections persist across requests, so a stage 2 lock can leak if the worker errors out and the connection returns to the pool with the lock still held. The next worker tick sees "lock busy" and retries forever. Workaround for now: restart `sc-dev` to recycle the connection pool. Longer-term fix: convert to `pg_advisory_xact_lock` inside an explicit transaction.

### Frontend release normalizer

`frontend/src/products/releases/api.ts::normalizeRelease` was originally K8s-specific and stripped non-K8s fields out of `release_context`. It now passes through mobile-specific fields (`release_group_id`, `version_code`, `tag_pushed`, `matrix_job_name`, `destination`, `ota_namespace`, `change_log`, `kind`) so `ReleaseGroupDetail` and `LiveReleases` can read them.
