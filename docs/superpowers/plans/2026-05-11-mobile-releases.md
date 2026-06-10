# Mobile Releases Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `MobileBuild` release category to the existing `autopilot` product so React Native app releases (consumer-android only for MVP) can be created, approved, dispatched to GitHub Actions, and tracked alongside backend releases through the same lifecycle, RBAC, audit log, and UI.

**Architecture:** Extend `release_tracker` with two nullable columns + a new `app_catalog` auxiliary table. Add `MobileBuild` to `ReleaseCategory` ADT and a new `MobileBuildState` variant to `TargetState`. New module tree under `Products/Autopilot/Mobile/` for category-specific code: GitHub App client, Play Console version client, workflow spec (7 stages reusing `Core/Workflow/Engine.hs`), HTTP handlers. Frontend: extend `releases/` product with new pages; two `PRODUCT_REGISTRY` entries (Backend / Mobile) sharing the `autopilot` slug to render two dashboard tiles.

**Tech Stack:** Haskell (Servant + Beam ORM + ReaderT Flow monad), PostgreSQL, React + TypeScript + Vite, Tailwind UI components. Tests use hand-rolled assertions in `backend/test/Main.hs` (no hspec/tasty); integration tests via `scripts/test-api.sh`.

**Source spec:** `docs/superpowers/specs/2026-05-11-mobile-releases-design.md`

**Branch:** `feat/mobile-releases` (already created from master)

---

## Status & extensions

| Phase | Scope | Status |
|---|---|---|
| Phases 1–10 | Android MVP (customer-android, 10 apps) | ✅ Shipped on `feat/mobile-releases` |
| **Phase 11** | **iOS extension (customer + provider iOS surfaces)** | 🆕 **proposed by this plan addition (2026-05-13, shivendra02shah@gmail.com)** |

Phase 11 is **purely additive**: nothing in Phases 1–10 is rewritten. The iOS path branches off `Stage 1 (ResolveVersion)` in the existing `mobileBuildSpec` and adds one optional new stage. The DB-schema changes are **appended in place** to `0011-mobile-releases.sql` (this repo's migration runner re-applies every file on every startup with idempotent guards — no checksums, no migration-tracking table). Android rows are unaffected.

---

## Working agreement

- TDD where it adds signal: pure logic (state machine transitions, JSON round-trip, version bump rule, CSV grouping) gets a test before implementation. Schema migrations, ADT additions that the compiler enforces, and HTTP-handler wiring don't need failing tests up front — the compiler + a smoke test cover them.
- Frequent commits at task boundaries. One task = one commit.
- Run `sc-build` after each Haskell change to catch type errors early. Run `sc-test` after each test addition.
- Don't add hspec/tasty. Use the existing `assertEqual` / `assertBool` helpers in `backend/test/Main.hs`.
- Don't write secrets into the repo. The seed migration inserts empty placeholder rows; admins populate real values out of band.

---

## Phase 1 — Foundation: schema, types, permissions

### Task 1: DB migration for mobile schema additions

**Files:**
- Create: `backend/dev/migrations/system-control/0011-mobile-releases.sql`

**Why:** Adds the two nullable columns on `release_tracker` (`dispatch_id`, `external_run_id`) and the new `app_catalog` table. Idempotent so it can run on dev DBs that already have it.

- [ ] **Step 1: Write the migration**

```sql
-- 0011-mobile-releases.sql
-- Mobile release support: adds dispatch grouping + external run tracking
-- columns to release_tracker, and a new app_catalog auxiliary table.

-- Two nullable columns on release_tracker; backend rows leave them NULL.
ALTER TABLE release_tracker
  ADD COLUMN IF NOT EXISTS dispatch_id    TEXT,
  ADD COLUMN IF NOT EXISTS external_run_id TEXT;
CREATE INDEX IF NOT EXISTS rt_dispatch_id_idx     ON release_tracker(dispatch_id);
CREATE INDEX IF NOT EXISTS rt_external_run_id_idx ON release_tracker(external_run_id);

-- New auxiliary catalog of mobile apps releasable through SCC.
CREATE TABLE IF NOT EXISTS app_catalog (
  id              SERIAL PRIMARY KEY,
  name            TEXT NOT NULL,
  surface         TEXT NOT NULL,        -- 'customer' | 'driver'
  platform        TEXT NOT NULL,        -- 'android' | 'ios'
  github_repo     TEXT NOT NULL,
  workflow_path   TEXT NOT NULL,
  package_name    TEXT,
  display_label   TEXT,
  enabled         BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT app_catalog_unique_app UNIQUE (name, surface, platform)
);
```

- [ ] **Step 2: Reset and re-init dev DB to apply the migration**

```bash
rm -rf .local/data/pg
sc-dev   # let it boot until "all migrations applied"
# Ctrl+C once seen
```

Expected: log lines mention `0011-mobile-releases.sql`. No errors.

- [ ] **Step 3: Verify schema**

```bash
psql "$SC_DATABASE_URL" -c "\d release_tracker" | grep -E "dispatch_id|external_run_id"
psql "$SC_DATABASE_URL" -c "\d app_catalog"
```

Expected: both new columns shown with `text` type; `app_catalog` table with all columns.

- [ ] **Step 4: Commit**

```bash
git add backend/dev/migrations/system-control/0011-mobile-releases.sql
git commit -m "Add migration for mobile release schema additions"
```

---

### Task 2: Beam schema for new columns and table

**Files:**
- Modify: `backend/src/Products/Autopilot/Types/Storage/Schema.hs`
- Create: `backend/src/Products/Autopilot/Mobile/Types/Storage.hs`

**Why:** Map the new columns/table into Beam ORM so Haskell can read/write them.

- [ ] **Step 1: Add the two new fields to `ReleaseTrackerT`**

Open `backend/src/Products/Autopilot/Types/Storage/Schema.hs`, locate the `ReleaseTrackerT` record (around the existing `slackThreadTs` field), add two new fields. The Beam pattern is `Columnar f (Maybe Text)` for nullable columns, with `fieldNamed "snake_case_col"` in `defaultDbSettings`.

```haskell
-- inside data ReleaseTrackerT f = ReleaseTrackerT { ... , add:
    , rtDispatchId     :: Columnar f (Maybe Text)
    , rtExternalRunId  :: Columnar f (Maybe Text)
```

In the `tableSettings` block (or wherever existing columns map to DB names), add:

```haskell
    , rtDispatchId    = fieldNamed "dispatch_id"
    , rtExternalRunId = fieldNamed "external_run_id"
```

- [ ] **Step 2: Create the new app_catalog Beam table**

Create `backend/src/Products/Autopilot/Mobile/Types/Storage.hs`:

```haskell
{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies      #-}

module Products.Autopilot.Mobile.Types.Storage
    ( AppCatalogT (..)
    , AppCatalog
    , AppCatalogId
    , appCatalog
    ) where

import           Data.Int               (Int32)
import           Data.Text              (Text)
import           Data.Time              (UTCTime)
import           Database.Beam
import           GHC.Generics           (Generic)

data AppCatalogT f = AppCatalog
    { acId             :: Columnar f Int32
    , acName           :: Columnar f Text
    , acSurface        :: Columnar f Text
    , acPlatform       :: Columnar f Text
    , acGithubRepo     :: Columnar f Text
    , acWorkflowPath   :: Columnar f Text
    , acPackageName    :: Columnar f (Maybe Text)
    , acDisplayLabel   :: Columnar f (Maybe Text)
    , acEnabled        :: Columnar f Bool
    , acCreatedAt      :: Columnar f UTCTime
    } deriving (Generic, Beamable)

instance Table AppCatalogT where
    data PrimaryKey AppCatalogT f = AppCatalogId (Columnar f Int32)
        deriving (Generic, Beamable)
    primaryKey = AppCatalogId . acId

type AppCatalog   = AppCatalogT Identity
type AppCatalogId = PrimaryKey AppCatalogT Identity

deriving instance Show AppCatalog
deriving instance Eq   AppCatalog

appCatalog :: TableSettings AppCatalogT
appCatalog = defaultDbSettings `withDbModification`
    appCatalogModification

appCatalogModification :: EntityModification (DatabaseEntity be db) be (TableEntity AppCatalogT)
appCatalogModification = setEntityName "app_catalog" <> modifyTableFields tableModification
    { acId           = fieldNamed "id"
    , acName         = fieldNamed "name"
    , acSurface      = fieldNamed "surface"
    , acPlatform     = fieldNamed "platform"
    , acGithubRepo   = fieldNamed "github_repo"
    , acWorkflowPath = fieldNamed "workflow_path"
    , acPackageName  = fieldNamed "package_name"
    , acDisplayLabel = fieldNamed "display_label"
    , acEnabled      = fieldNamed "enabled"
    , acCreatedAt    = fieldNamed "created_at"
    }
```

- [ ] **Step 3: Register the table in `AutopilotDb`**

In `backend/src/Products/Autopilot/Types/Storage/Schema.hs`, find `data AutopilotDb f = AutopilotDb { ... }` and add:

```haskell
    , adAppCatalog       :: f (TableEntity AppCatalogT)
```

In the `defaultDbSettings`-equivalent block, add:

```haskell
    , adAppCatalog = appCatalog
```

Add the import at the top:

```haskell
import Products.Autopilot.Mobile.Types.Storage (AppCatalogT, appCatalog)
```

- [ ] **Step 4: Update package.yaml exposed-modules**

In `backend/package.yaml`, find the `library: exposed-modules:` list and add:

```yaml
  - Products.Autopilot.Mobile.Types.Storage
```

- [ ] **Step 5: Compile**

```bash
sc-build
```

Expected: compiles cleanly. If Beam complains about unhandled fields, recheck the `modifyTableFields` block.

- [ ] **Step 6: Commit**

```bash
git add backend/src/Products/Autopilot/Types/Storage/Schema.hs \
        backend/src/Products/Autopilot/Mobile/Types/Storage.hs \
        backend/package.yaml
git commit -m "Wire mobile schema additions into Beam ORM"
```

---

### Task 3: Extend `ReleaseCategory` with `MobileBuild`

**Files:**
- Modify: `backend/src/Products/Autopilot/Types/Workflow.hs`
- Modify: `backend/test/Main.hs`

**Why:** The `ReleaseCategory` ADT is the discriminator the runner uses to dispatch to the right workflow spec. Adding `MobileBuild` gives us the type slot; the compiler will then flag every match site that needs handling.

- [ ] **Step 1: Add a failing test for the new constructor + its default deployment target**

Open `backend/test/Main.hs`, find the existing test sections, add a new section near the other category-related tests:

```haskell
testReleaseCategoryMobileBuild :: IO ()
testReleaseCategoryMobileBuild = do
    putStrLn "ReleaseCategory: MobileBuild constructor"
    -- Smoke check: enum bounds include MobileBuild
    let allCategories = [minBound .. maxBound :: ReleaseCategory]
    assertBool "MobileBuild is in [minBound..maxBound]"
        (MobileBuild `elem` allCategories)
    -- Smoke check: getDefaultDeploymentTarget routes correctly
    assertEqual "default target for MobileBuild"
        "github-actions"
        (getDefaultDeploymentTarget MobileBuild)
```

Wire it into `main`:

```haskell
main :: IO ()
main = do
    -- ... existing test calls ...
    testReleaseCategoryMobileBuild
```

- [ ] **Step 2: Run test, expect FAIL**

```bash
sc-test
```

Expected: build fails with `Data constructor not in scope: MobileBuild` (or similar).

- [ ] **Step 3: Add `MobileBuild` to the ADT**

In `backend/src/Products/Autopilot/Types/Workflow.hs`, locate `data ReleaseCategory = ...` and add the new constructor:

```haskell
data ReleaseCategory
    = BackendService
    | BackendScheduler
    | BackendConfig
    | VSEdit
    | MobileBuild              -- NEW
    deriving (Eq, Show, Read, Generic, Enum, Bounded)
```

Update `getDefaultDeploymentTarget`:

```haskell
getDefaultDeploymentTarget :: ReleaseCategory -> Text
getDefaultDeploymentTarget BackendService    = "kubernetes"
getDefaultDeploymentTarget BackendScheduler  = "kubernetes"
getDefaultDeploymentTarget BackendConfig     = "kubernetes-config"
getDefaultDeploymentTarget VSEdit            = "kubernetes"
getDefaultDeploymentTarget MobileBuild       = "github-actions"
```

If there's a JSON instance (`ToJSON`/`FromJSON`) defined manually for `ReleaseCategory`, add the `MobileBuild` case there too. If derived via Generic, no change.

- [ ] **Step 4: Run test, expect PASS**

```bash
sc-test
```

Expected: PASS for `MobileBuild constructor`, `default target for MobileBuild`. Build will likely now fail elsewhere because non-exhaustive match warnings exist for any case-of on `ReleaseCategory`. Note them down — they'll be addressed in Tasks 5 and 16.

- [ ] **Step 5: Compile fully (with `-Wall`) and resolve any non-exhaustive matches in *non-runtime* sites by adding the new arm**

```bash
sc-build 2>&1 | grep -E "Pattern match|incomplete" | head -20
```

For pure helper functions that pattern-match on `ReleaseCategory` and need a sensible default for `MobileBuild`, add the arm. (Workflow factory and dispatch sites stay unhandled for now — those get filled in Tasks 13-16.)

- [ ] **Step 6: Commit**

```bash
git add backend/src/Products/Autopilot/Types/Workflow.hs backend/test/Main.hs
git commit -m "Add MobileBuild to ReleaseCategory ADT"
```

---

### Task 4: Add new permissions `AP_MOBILE_DISPATCH` and `AP_MOBILE_APP_MANAGE`

**Files:**
- Modify: `backend/src/Products/Autopilot/Types/Permission.hs`
- Modify: `backend/test/Main.hs`

**Why:** New mobile-specific perms with their `KnownPermission` type-level instances so the `Protected` Servant combinator can use them.

- [ ] **Step 1: Add tests**

In `backend/test/Main.hs`:

```haskell
testMobilePermissionsExist :: IO ()
testMobilePermissionsExist = do
    putStrLn "Mobile permissions: enum membership + text round-trip"
    let perms = [minBound .. maxBound :: AutopilotPermission]
    assertBool "AP_MOBILE_DISPATCH in enum"   (AP_MOBILE_DISPATCH   `elem` perms)
    assertBool "AP_MOBILE_APP_MANAGE in enum" (AP_MOBILE_APP_MANAGE `elem` perms)
    assertEqual "AP_MOBILE_DISPATCH textual"   "MOBILE_DISPATCH"
        (autopilotPermissionToText AP_MOBILE_DISPATCH)
    assertEqual "AP_MOBILE_APP_MANAGE textual" "MOBILE_APP_MANAGE"
        (autopilotPermissionToText AP_MOBILE_APP_MANAGE)
    assertEqual "round-trip MOBILE_DISPATCH"
        (Just AP_MOBILE_DISPATCH)
        (textToAutopilotPermission "MOBILE_DISPATCH")
```

Add `testMobilePermissionsExist` to `main`.

- [ ] **Step 2: Run, expect FAIL**

```bash
sc-test
```

Expected: not in scope.

- [ ] **Step 3: Extend the permission ADT and round-trip helpers**

In `backend/src/Products/Autopilot/Types/Permission.hs`, add the new constructors. Also add `KnownPermission` instances and update the text round-trip helpers:

```haskell
data AutopilotPermission
    = AP_RELEASE_VIEW | AP_RELEASE_CREATE | AP_RELEASE_APPROVE
    | AP_RELEASE_REVERT | AP_RELEASE_DISCARD | AP_RELEASE_PAUSE
    | AP_RELEASE_RESUME | AP_RELEASE_ABORT | AP_RELEASE_UPDATE
    | AP_RELEASE_DELETE | AP_MANAGE_STAGGER
    | AP_PRODUCT_CONFIG_VIEW | AP_PRODUCT_CONFIG_EDIT
    | AP_SERVICE_CONFIG_VIEW | AP_SERVICE_CONFIG_EDIT
    | AP_CONFIG_EDIT | AP_CONFIG_DISCARD | AP_CONFIG_REVERT
    | AP_FORCE_UNLOCK
    | AP_MOBILE_DISPATCH                  -- NEW
    | AP_MOBILE_APP_MANAGE                -- NEW
    deriving (Show, Read, Eq, Ord, Enum, Bounded)

instance KnownPermission 'AP_MOBILE_DISPATCH where
    permissionProduct _ = "autopilot"
    permissionName    _ = "MOBILE_DISPATCH"

instance KnownPermission 'AP_MOBILE_APP_MANAGE where
    permissionProduct _ = "autopilot"
    permissionName    _ = "MOBILE_APP_MANAGE"
```

Update `autopilotPermissionToText` (or whatever the existing round-trip function is named — find it via `grep -n "permissionToText\|toText" backend/src/Products/Autopilot/Types/Permission.hs`) to include:

```haskell
autopilotPermissionToText AP_MOBILE_DISPATCH    = "MOBILE_DISPATCH"
autopilotPermissionToText AP_MOBILE_APP_MANAGE  = "MOBILE_APP_MANAGE"
```

And the inverse `textToAutopilotPermission`:

```haskell
textToAutopilotPermission "MOBILE_DISPATCH"    = Just AP_MOBILE_DISPATCH
textToAutopilotPermission "MOBILE_APP_MANAGE"  = Just AP_MOBILE_APP_MANAGE
```

Also extend `permDescriptions` (or equivalent) with display strings:

```haskell
(AP_MOBILE_DISPATCH,   "Dispatch mobile release to GitHub Actions")
(AP_MOBILE_APP_MANAGE, "Manage mobile app catalog (admin)")
```

- [ ] **Step 4: Run tests, expect PASS**

```bash
sc-test
```

- [ ] **Step 5: Commit**

```bash
git add backend/src/Products/Autopilot/Types/Permission.hs backend/test/Main.hs
git commit -m "Add AP_MOBILE_DISPATCH and AP_MOBILE_APP_MANAGE permissions"
```

---

### Task 5: Define mobile domain types module

**Files:**
- Create: `backend/src/Products/Autopilot/Mobile/Types.hs`
- Modify: `backend/src/Products/Autopilot/Types/Target.hs`
- Modify: `backend/test/Main.hs`
- Modify: `backend/package.yaml`

**Why:** Defines `MobileBuildContext`, `MobileBuildTargetState`, `MobileBuildWFStatus`. Adds `MobileBuildState` to the existing `TargetState` sum so the runner can route per-category.

- [ ] **Step 1: Add tests for state machine + JSON round-trip**

In `backend/test/Main.hs`:

```haskell
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BL
import Products.Autopilot.Mobile.Types

testMobileBuildWFStatusTransitions :: IO ()
testMobileBuildWFStatusTransitions = do
    putStrLn "MobileBuildWFStatus: transition validity"
    -- Forward path
    assertBool "MBInit -> MBVersionResolved"
        (validMBTransition MBInit MBVersionResolved)
    assertBool "MBVersionResolved -> MBDispatched"
        (validMBTransition MBVersionResolved MBDispatched)
    assertBool "MBDispatched -> MBRunIdResolved"
        (validMBTransition MBDispatched MBRunIdResolved)
    assertBool "MBRunIdResolved -> MBBuilding"
        (validMBTransition MBRunIdResolved MBBuilding)
    assertBool "MBBuilding -> MBSubmittedToStore"
        (validMBTransition MBBuilding MBSubmittedToStore)
    assertBool "MBSubmittedToStore -> MBTagPushed"
        (validMBTransition MBSubmittedToStore MBTagPushed)
    assertBool "MBTagPushed -> MBCompleted"
        (validMBTransition MBTagPushed MBCompleted)
    -- Failure can come from any non-terminal state
    assertBool "MBBuilding -> MBFailed allowed"
        (validMBTransition MBBuilding (MBFailed "x"))
    assertBool "MBCompleted -> MBFailed NOT allowed (terminal)"
        (not (validMBTransition MBCompleted (MBFailed "x")))
    -- Skipping not allowed
    assertBool "MBInit -> MBBuilding NOT allowed"
        (not (validMBTransition MBInit MBBuilding))

testMobileBuildContextJsonRoundTrip :: IO ()
testMobileBuildContextJsonRoundTrip = do
    putStrLn "MobileBuildContext: JSON round-trip"
    let ctx = MobileBuildContext
            { mbcVersionCode      = Just 12345
            , mbcChangeLog        = "hello"
            , mbcDestination      = MBGooglePlay
            , mbcReleaseGroupId   = "rg_abc"
            , mbcMatrixJobName    = "NammaYatri-Release"
            , mbcOtaNamespace     = Just "nammayatriv2"
            , mbcTagPushed        = Nothing
            }
    let encoded = Aeson.encode ctx
    let decoded = Aeson.decode encoded :: Maybe MobileBuildContext
    assertEqual "round-trip equals original" (Just ctx) decoded
```

Add both to `main`.

- [ ] **Step 2: Run, expect FAIL (module not found)**

```bash
sc-test
```

- [ ] **Step 3: Create the types module**

Create `backend/src/Products/Autopilot/Mobile/Types.hs`:

```haskell
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE LambdaCase         #-}
{-# LANGUAGE OverloadedStrings  #-}

module Products.Autopilot.Mobile.Types
    ( MobileBuildContext (..)
    , MobileDestination (..)
    , MobileBuildTargetState (..)
    , MobileBuildWFStatus (..)
    , validMBTransition
    , isMBTerminal
    ) where

import           Data.Aeson    (FromJSON (..), ToJSON (..), Value, withObject, (.:), (.:?), (.=), object)
import qualified Data.Aeson    as Aeson
import           Data.Int      (Int32)
import           Data.Text     (Text)
import           Data.Time     (UTCTime)
import           GHC.Generics  (Generic)

data MobileDestination = MBGooglePlay | MBFirebase
    deriving (Eq, Show, Read, Generic)

instance ToJSON MobileDestination where
    toJSON MBGooglePlay = "GooglePlay"
    toJSON MBFirebase   = "Firebase"

instance FromJSON MobileDestination where
    parseJSON = Aeson.withText "MobileDestination" $ \case
        "GooglePlay" -> pure MBGooglePlay
        "Firebase"   -> pure MBFirebase
        other        -> fail $ "unknown destination: " <> show other

data MobileBuildContext = MobileBuildContext
    { mbcVersionCode    :: Maybe Int32
    , mbcChangeLog      :: Text
    , mbcDestination    :: MobileDestination
    , mbcReleaseGroupId :: Text
    , mbcMatrixJobName  :: Text
    , mbcOtaNamespace   :: Maybe Text
    , mbcTagPushed      :: Maybe Text
    } deriving (Eq, Show, Generic)

instance ToJSON MobileBuildContext where
    toJSON c = object
        [ "kind"             .= ("mobile_build" :: Text)
        , "version_code"     .= mbcVersionCode c
        , "change_log"       .= mbcChangeLog c
        , "destination"      .= mbcDestination c
        , "release_group_id" .= mbcReleaseGroupId c
        , "matrix_job_name"  .= mbcMatrixJobName c
        , "ota_namespace"    .= mbcOtaNamespace c
        , "tag_pushed"       .= mbcTagPushed c
        ]

instance FromJSON MobileBuildContext where
    parseJSON = withObject "MobileBuildContext" $ \o -> MobileBuildContext
        <$> o .:? "version_code"
        <*> o .:  "change_log"
        <*> o .:  "destination"
        <*> o .:  "release_group_id"
        <*> o .:  "matrix_job_name"
        <*> o .:? "ota_namespace"
        <*> o .:? "tag_pushed"

data MobileBuildWFStatus
    = MBInit
    | MBVersionResolved
    | MBDispatched
    | MBRunIdResolved
    | MBBuilding
    | MBSubmittedToStore
    | MBTagPushed
    | MBCompleted
    | MBAborting
    | MBAborted
    | MBFailed Text
    deriving (Eq, Show, Generic)

instance ToJSON MobileBuildWFStatus
instance FromJSON MobileBuildWFStatus

data MobileBuildTargetState = MobileBuildTargetState
    { mbWfStatus         :: MobileBuildWFStatus
    , mbContext          :: MobileBuildContext
    , mbExternalRunId    :: Maybe Text
    , mbMatrixJobStatus  :: Maybe Text
    , mbBuildStartedAt   :: Maybe UTCTime
    , mbBuildCompletedAt :: Maybe UTCTime
    } deriving (Eq, Show, Generic)

instance ToJSON   MobileBuildTargetState
instance FromJSON MobileBuildTargetState

isMBTerminal :: MobileBuildWFStatus -> Bool
isMBTerminal = \case
    MBCompleted -> True
    MBAborted   -> True
    MBFailed{}  -> True
    _           -> False

-- | Pure transition predicate. Mirrors validateStatusTransition's style.
validMBTransition :: MobileBuildWFStatus -> MobileBuildWFStatus -> Bool
validMBTransition from to
    | isMBTerminal from = False
    | otherwise = to `elem` allowed from
  where
    allowed MBInit              = [MBVersionResolved, fail_]
    allowed MBVersionResolved   = [MBDispatched, fail_]
    allowed MBDispatched        = [MBRunIdResolved, fail_]
    allowed MBRunIdResolved     = [MBBuilding, fail_]
    allowed MBBuilding          = [MBSubmittedToStore, MBAborting, fail_]
    allowed MBSubmittedToStore  = [MBTagPushed, fail_]
    allowed MBTagPushed         = [MBCompleted, fail_]
    allowed MBAborting          = [MBAborted]
    allowed _                   = []
    fail_ = MBFailed ""           -- equality on MBFailed ignores inner Text in `elem`
```

Note: the `fail_` placeholder in `allowed` works because `(==)` on `MBFailed _` matches any inner text via `Generic` derivation — actually, `Generic` derived `Eq` does compare the inner field. So `MBFailed "x" == MBFailed "y"` is `False`. To make the `elem` check work, override the predicate:

Replace the `(allowed from) elem to` with an explicit case:

```haskell
validMBTransition from to
    | isMBTerminal from = False
    | otherwise = case to of
        MBFailed _ -> from `notElem` [MBCompleted, MBAborted]   -- failure allowed from any non-terminal
        _          -> to `elem` allowedNonFail from
  where
    allowedNonFail MBInit             = [MBVersionResolved]
    allowedNonFail MBVersionResolved  = [MBDispatched]
    allowedNonFail MBDispatched       = [MBRunIdResolved]
    allowedNonFail MBRunIdResolved    = [MBBuilding]
    allowedNonFail MBBuilding         = [MBSubmittedToStore, MBAborting]
    allowedNonFail MBSubmittedToStore = [MBTagPushed]
    allowedNonFail MBTagPushed        = [MBCompleted]
    allowedNonFail MBAborting         = [MBAborted]
    allowedNonFail _                  = []
```

- [ ] **Step 4: Add `MobileBuildState` to `TargetState`**

In `backend/src/Products/Autopilot/Types/Target.hs`, add the new variant and JSON support. Existing pattern likely has a tagged sum — follow it. Add an import:

```haskell
import Products.Autopilot.Mobile.Types (MobileBuildTargetState)
```

Extend the type:

```haskell
data TargetState
    = K8sState K8sDeploymentState
    | ConfigState ConfigDeploymentState
    | MobileBuildState MobileBuildTargetState   -- NEW
    deriving (Eq, Show, Generic)
```

If `ToJSON`/`FromJSON` is hand-written using a tag field, add the `MobileBuildState` arm:

```haskell
instance ToJSON TargetState where
    toJSON (K8sState s)         = ...
    toJSON (ConfigState s)      = ...
    toJSON (MobileBuildState s) = object [ "tag" .= ("mobile_build" :: Text), "data" .= s ]

instance FromJSON TargetState where
    parseJSON = withObject "TargetState" $ \o -> do
        tag <- o .: "tag"
        case tag :: Text of
            "k8s"          -> K8sState         <$> o .: "data"
            "config"       -> ConfigState      <$> o .: "data"
            "mobile_build" -> MobileBuildState <$> o .: "data"
            other          -> fail $ "unknown TargetState tag: " <> show other
```

- [ ] **Step 5: Add module to package.yaml**

```yaml
exposed-modules:
  - Products.Autopilot.Mobile.Types
```

- [ ] **Step 6: Compile + test**

```bash
sc-build && sc-test
```

Expected: tests pass; compiles cleanly. Some `case ... of` sites on `TargetState` may now warn about non-exhaustive matches — note them; they get filled in Task 16.

- [ ] **Step 7: Commit**

```bash
git add backend/src/Products/Autopilot/Mobile/Types.hs \
        backend/src/Products/Autopilot/Types/Target.hs \
        backend/test/Main.hs backend/package.yaml
git commit -m "Add MobileBuildContext, MobileBuildTargetState, MobileBuildWFStatus types"
```

---

## Phase 2 — App catalog API

### Task 6: App catalog queries

**Files:**
- Create: `backend/src/Products/Autopilot/Mobile/Queries/AppCatalog.hs`
- Modify: `backend/package.yaml`

**Why:** DB queries used by all mobile endpoints. Polymorphic in `MonadFlow m =>` per the codebase convention.

- [ ] **Step 1: Create the queries module**

```haskell
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

module Products.Autopilot.Mobile.Queries.AppCatalog
    ( listAppCatalog
    , listEnabledAppCatalog
    , findAppCatalogById
    , insertAppCatalog
    , updateAppCatalog
    , NewAppCatalogRow (..)
    , PatchAppCatalogRow (..)
    ) where

import           Core.DB.Connection                       (runDB)
import           Core.Environment                          (MonadFlow, withDb)
import           Data.Int                                  (Int32)
import           Data.Maybe                                (fromMaybe)
import           Data.Text                                 (Text)
import           Data.Time                                 (getCurrentTime)
import           Database.Beam
import           Database.Beam.Postgres                    (Pg, runBeamPostgres)
import           Products.Autopilot.Mobile.Types.Storage
import           Products.Autopilot.Types.Storage.Schema   (AutopilotDb (..), autopilotDb)
import           Control.Monad.IO.Class                    (liftIO)

data NewAppCatalogRow = NewAppCatalogRow
    { nacName         :: Text
    , nacSurface      :: Text
    , nacPlatform     :: Text
    , nacGithubRepo   :: Text
    , nacWorkflowPath :: Text
    , nacPackageName  :: Maybe Text
    , nacDisplayLabel :: Maybe Text
    , nacEnabled      :: Maybe Bool
    } deriving (Eq, Show)

data PatchAppCatalogRow = PatchAppCatalogRow
    { pacEnabled      :: Maybe Bool
    , pacDisplayLabel :: Maybe Text
    , pacPackageName  :: Maybe Text
    , pacWorkflowPath :: Maybe Text
    } deriving (Eq, Show)

listAppCatalog :: MonadFlow m => m [AppCatalog]
listAppCatalog = withDb $ \db -> runDB db $ runBeamPostgres $ runSelectReturningList $
    select $ all_ (adAppCatalog autopilotDb)

listEnabledAppCatalog :: MonadFlow m => m [AppCatalog]
listEnabledAppCatalog = withDb $ \db -> runDB db $ runBeamPostgres $ runSelectReturningList $
    select $ filter_ (\ac -> acEnabled ac ==. val_ True) $ all_ (adAppCatalog autopilotDb)

findAppCatalogById :: MonadFlow m => Int32 -> m (Maybe AppCatalog)
findAppCatalogById aid = withDb $ \db -> runDB db $ runBeamPostgres $ runSelectReturningOne $
    select $ filter_ (\ac -> acId ac ==. val_ aid) $ all_ (adAppCatalog autopilotDb)

insertAppCatalog :: MonadFlow m => NewAppCatalogRow -> m AppCatalog
insertAppCatalog row = do
    now <- liftIO getCurrentTime
    let entry = AppCatalog
            { acId           = default_
            , acName         = val_ (nacName row)
            , acSurface      = val_ (nacSurface row)
            , acPlatform     = val_ (nacPlatform row)
            , acGithubRepo   = val_ (nacGithubRepo row)
            , acWorkflowPath = val_ (nacWorkflowPath row)
            , acPackageName  = val_ (nacPackageName row)
            , acDisplayLabel = val_ (nacDisplayLabel row)
            , acEnabled      = val_ (fromMaybe True (nacEnabled row))
            , acCreatedAt    = val_ now
            }
    inserted <- withDb $ \db -> runDB db $ runBeamPostgres $ runInsertReturningList $
        insert (adAppCatalog autopilotDb) (insertExpressions [entry])
    case inserted of
        [r] -> pure r
        _   -> error "insertAppCatalog: expected exactly one row"

updateAppCatalog :: MonadFlow m => Int32 -> PatchAppCatalogRow -> m (Maybe AppCatalog)
updateAppCatalog aid patch = do
    withDb $ \db -> runDB db $ runBeamPostgres $ runUpdate $ update (adAppCatalog autopilotDb)
        (\ac -> mconcat $ catMaybes
            [ (\v -> acEnabled      ac <-. val_ v) <$> pacEnabled patch
            , (\v -> acDisplayLabel ac <-. val_ (Just v)) <$> pacDisplayLabel patch
            , (\v -> acPackageName  ac <-. val_ (Just v)) <$> pacPackageName patch
            , (\v -> acWorkflowPath ac <-. val_ v)        <$> pacWorkflowPath patch
            ])
        (\ac -> acId ac ==. val_ aid)
    findAppCatalogById aid
  where
    catMaybes = foldr (\m acc -> maybe acc (:acc) m) []
```

- [ ] **Step 2: Add module to package.yaml**

```yaml
- Products.Autopilot.Mobile.Queries.AppCatalog
```

- [ ] **Step 3: Compile**

```bash
sc-build
```

If `withDb` returns `IO a` rather than threading through `runBeamPostgres`, adjust to match the existing pattern in `Products/Autopilot/Queries/*.hs`. Check one existing query for the exact form:

```bash
grep -l "runBeamPostgres\|runDB" backend/src/Products/Autopilot/Queries/ | head -1
```

- [ ] **Step 4: Commit**

```bash
git add backend/src/Products/Autopilot/Mobile/Queries/AppCatalog.hs backend/package.yaml
git commit -m "Add app_catalog queries module"
```

---

### Task 7: App catalog HTTP handlers + routes

**Files:**
- Create: `backend/src/Products/Autopilot/Mobile/Handlers/AppCatalog.hs`
- Create: `backend/src/Products/Autopilot/Mobile/Routes.hs`
- Modify: `backend/src/Products/Autopilot/Routes.hs`
- Modify: `backend/package.yaml`

**Why:** Expose app catalog over HTTP. Wires the new mobile API into the existing `CoreAPI` so the same Servant mount in `Core/Server.hs` serves both backend and mobile endpoints — preserves the unified-product principle.

- [ ] **Step 1: Define request/response types**

In `backend/src/Products/Autopilot/Mobile/Handlers/AppCatalog.hs` (top of file):

```haskell
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}

module Products.Autopilot.Mobile.Handlers.AppCatalog
    ( AppCatalogEntryResp (..)
    , NewAppReq (..)
    , PatchAppReq (..)
    , listAppsH
    , createAppH
    , patchAppH
    ) where

import           Core.Auth.Protected                       (AuthedPerson)
import           Core.Environment                          (Flow)
import           Data.Aeson                                (FromJSON, ToJSON)
import           Data.Int                                  (Int32)
import           Data.Text                                 (Text)
import           Data.Time                                 (UTCTime)
import           GHC.Generics                              (Generic)
import           Products.Autopilot.Mobile.Queries.AppCatalog
import           Products.Autopilot.Mobile.Types.Storage
import           Servant                                   (err404, throwError)
import qualified Servant

data AppCatalogEntryResp = AppCatalogEntryResp
    { id            :: Int32
    , name          :: Text
    , surface       :: Text
    , platform      :: Text
    , githubRepo    :: Text
    , workflowPath  :: Text
    , packageName   :: Maybe Text
    , displayLabel  :: Maybe Text
    , enabled       :: Bool
    , createdAt     :: UTCTime
    } deriving (Generic, Show, ToJSON, FromJSON)

data NewAppReq = NewAppReq
    { name          :: Text
    , surface       :: Text
    , platform      :: Text
    , githubRepo    :: Text
    , workflowPath  :: Text
    , packageName   :: Maybe Text
    , displayLabel  :: Maybe Text
    , enabled       :: Maybe Bool
    } deriving (Generic, Show, ToJSON, FromJSON)

data PatchAppReq = PatchAppReq
    { enabled       :: Maybe Bool
    , displayLabel  :: Maybe Text
    , packageName   :: Maybe Text
    , workflowPath  :: Maybe Text
    } deriving (Generic, Show, ToJSON, FromJSON)

toResp :: AppCatalog -> AppCatalogEntryResp
toResp r = AppCatalogEntryResp
    { id            = acId r
    , name          = acName r
    , surface       = acSurface r
    , platform      = acPlatform r
    , githubRepo    = acGithubRepo r
    , workflowPath  = acWorkflowPath r
    , packageName   = acPackageName r
    , displayLabel  = acDisplayLabel r
    , enabled       = acEnabled r
    , createdAt     = acCreatedAt r
    }

listAppsH :: AuthedPerson -> Flow [AppCatalogEntryResp]
listAppsH _ = map toResp <$> listAppCatalog

createAppH :: AuthedPerson -> NewAppReq -> Flow AppCatalogEntryResp
createAppH _ req = do
    let row = NewAppCatalogRow
            { nacName         = name req
            , nacSurface      = surface req
            , nacPlatform     = platform req
            , nacGithubRepo   = githubRepo req
            , nacWorkflowPath = workflowPath req
            , nacPackageName  = packageName req
            , nacDisplayLabel = displayLabel req
            , nacEnabled      = enabled req
            }
    toResp <$> insertAppCatalog row

patchAppH :: AuthedPerson -> Int32 -> PatchAppReq -> Flow AppCatalogEntryResp
patchAppH _ aid req = do
    let patch = PatchAppCatalogRow
            { pacEnabled      = enabled req
            , pacDisplayLabel = displayLabel req
            , pacPackageName  = packageName req
            , pacWorkflowPath = workflowPath req
            }
    mResult <- updateAppCatalog aid patch
    case mResult of
        Just r  -> pure (toResp r)
        Nothing -> Servant.throwError Servant.err404
```

- [ ] **Step 2: Define `MobileAPI` type and `mobileServer`**

Create `backend/src/Products/Autopilot/Mobile/Routes.hs`:

```haskell
{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators    #-}

module Products.Autopilot.Mobile.Routes
    ( MobileAPI
    , mobileServer
    ) where

import Core.Auth.Protected                          (Protected)
import Core.Environment                             (Flow)
import Data.Int                                     (Int32)
import Products.Autopilot.Mobile.Handlers.AppCatalog
import Products.Autopilot.Types.Permission          (AutopilotPermission (..))
import Servant

type MobileAPI =
       "mobile" :> "apps"
        :> Protected 'AP_RELEASE_VIEW
        :> Get '[JSON] [AppCatalogEntryResp]

  :<|> "mobile" :> "apps"
        :> Protected 'AP_MOBILE_APP_MANAGE
        :> ReqBody '[JSON] NewAppReq
        :> Post '[JSON] AppCatalogEntryResp

  :<|> "mobile" :> "apps" :> Capture "id" Int32
        :> Protected 'AP_MOBILE_APP_MANAGE
        :> ReqBody '[JSON] PatchAppReq
        :> Patch '[JSON] AppCatalogEntryResp

mobileServer :: ServerT MobileAPI Flow
mobileServer =
        listAppsH
   :<|> createAppH
   :<|> patchAppH
```

- [ ] **Step 3: Mount `MobileAPI` inside `CoreAPI`**

In `backend/src/Products/Autopilot/Routes.hs`, extend the API type and server:

```haskell
import Products.Autopilot.Mobile.Routes (MobileAPI, mobileServer)

type CoreAPI =
       ExistingCoreAPI                  -- whatever the type already is
  :<|> MobileAPI                        -- NEW

coreServer :: ServerT CoreAPI Flow
coreServer = existingCoreServer :<|> mobileServer
```

(Concretely: the existing `CoreAPI = "products" :> ... :<|> ...` chain gets extended at the end with `:<|> MobileAPI`. The `coreServer` definition gets `:<|> mobileServer` at the end.)

- [ ] **Step 4: Add modules to package.yaml**

```yaml
- Products.Autopilot.Mobile.Routes
- Products.Autopilot.Mobile.Handlers.AppCatalog
```

- [ ] **Step 5: Compile**

```bash
sc-build
```

Expected: clean compile.

- [ ] **Step 6: Smoke test via curl**

Start dev stack:

```bash
sc-dev   # in another terminal
```

Get an auth token (see existing scripts for the login pattern):

```bash
TOKEN=$(curl -s -X POST http://localhost:8012/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@juspay.in","password":"admin123"}' | jq -r .token)
```

Test list (empty, since seed not yet updated):

```bash
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:8012/mobile/apps
```

Expected: `[]`

Test create:

```bash
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"NammaYatri","surface":"customer","platform":"android",
       "githubRepo":"nammayatri/ny-react-native",
       "workflowPath":".github/workflows/fastlane-android.yaml",
       "packageName":"in.juspay.nammayatri","displayLabel":"Namma Yatri (Android)",
       "enabled":false}' \
  http://localhost:8012/mobile/apps
```

Expected: 200 with the created row.

Test patch:

```bash
curl -s -X PATCH -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"enabled":true}' \
  http://localhost:8012/mobile/apps/1
```

Expected: 200 with `enabled: true`.

- [ ] **Step 7: Commit**

```bash
git add backend/src/Products/Autopilot/Mobile/Handlers/AppCatalog.hs \
        backend/src/Products/Autopilot/Mobile/Routes.hs \
        backend/src/Products/Autopilot/Routes.hs \
        backend/package.yaml
git commit -m "Wire app_catalog HTTP endpoints into CoreAPI"
```

---

## Phase 3 — Play Console version preview

### Task 8: Play Console API client + version-bump logic

**Files:**
- Create: `backend/src/Products/Autopilot/Mobile/Versioning.hs`
- Modify: `backend/test/Main.hs`
- Modify: `backend/package.yaml`

**Why:** Calls the same Play Store API that the workflow does today (`fastlane-android.yaml:111-189`), implementing the same patch-bump rule. Used at dispatch time to fill `version_name` + `version_code`.

- [ ] **Step 1: Add tests for the version-bump logic**

```haskell
import Products.Autopilot.Mobile.Versioning

testVersionBumpLogic :: IO ()
testVersionBumpLogic = do
    putStrLn "Mobile version bump: workflow's algorithm"
    -- Internal == Production → bump patch
    assertEqual "internal == production bumps patch"
        ("2.5.1", 12346)
        (computeNextVersion (TrackInfo "2.5.0" 12345) (TrackInfo "2.5.0" 12340))
    -- Internal > Production → use internal's name; code = internal+1
    assertEqual "internal > production uses internal name"
        ("2.6.0", 12346)
        (computeNextVersion (TrackInfo "2.6.0" 12345) (TrackInfo "2.5.0" 12340))
    -- Empty (both tracks 0.0.0) → first-release default
    assertEqual "empty -> 0.0.0 baseline becomes 0.0.1 patch bump"
        ("0.0.1", 1)
        (computeNextVersion (TrackInfo "0.0.0" 0) (TrackInfo "0.0.0" 0))
```

- [ ] **Step 2: Run, expect FAIL**

```bash
sc-test
```

- [ ] **Step 3: Implement**

```haskell
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}

module Products.Autopilot.Mobile.Versioning
    ( TrackInfo (..)
    , computeNextVersion
    , fetchPlayTracks
    , PlayCreds (..)
    , PlayApiError (..)
    ) where

import           Control.Exception                 (Exception)
import           Core.Environment                  (MonadFlow)
import           Core.Http.Client                  (HttpReq (..), httpJson, HttpMethod (..))
import           Core.Types.Time                   (Seconds (..))
import           Data.Aeson                        (FromJSON, ToJSON, Value, withObject, (.:?))
import qualified Data.Aeson                        as Aeson
import           Data.Int                          (Int32)
import           Data.List                         (maximumBy)
import           Data.Ord                          (comparing)
import           Data.Text                         (Text)
import qualified Data.Text                         as T
import           GHC.Generics                      (Generic)

data TrackInfo = TrackInfo
    { tiName :: Text
    , tiCode :: Int32
    } deriving (Eq, Show, Generic, ToJSON, FromJSON)

data PlayCreds = PlayCreds
    { pcServiceAccountJson :: Text   -- the raw JSON loaded from server_config
    } deriving (Eq, Show)

data PlayApiError
    = PlayUnauthorized
    | PlayPackageNotFound Text
    | PlayHttpError Int Text
    deriving (Show)

instance Exception PlayApiError

-- | Workflow's algorithm: if internal == production, bump patch on internal.
-- Otherwise, use internal's name. Version code = internal_code + 1.
computeNextVersion :: TrackInfo -> TrackInfo -> (Text, Int32)
computeNextVersion internal production =
    let nextCode = tiCode internal + 1
        nextName
            | tiName internal == tiName production && tiName production /= "0.0.0" = bumpPatch (tiName internal)
            | tiName internal == "0.0.0" && tiName production == "0.0.0"           = "0.0.1"
            | otherwise                                                            = tiName internal
    in (nextName, nextCode)

bumpPatch :: Text -> Text
bumpPatch v =
    let parts = map (read . T.unpack) (T.splitOn "." v) :: [Int]
        padded = parts ++ replicate (3 - length parts) 0
        bumped = take 2 padded ++ [last padded + 1]
    in T.intercalate "." (map (T.pack . show) bumped)

-- | Calls the Play Console API to read internal + production tracks for a package.
-- Returns (internal, production). On failure throws PlayApiError.
fetchPlayTracks :: MonadFlow m => PlayCreds -> Text -> m (Either PlayApiError (TrackInfo, TrackInfo))
fetchPlayTracks _creds _package = do
    -- Implementation calls the androidpublisher v3 API.
    -- 1. Mint a JWT signed with the service account private key.
    -- 2. Exchange for an access token at https://oauth2.googleapis.com/token.
    -- 3. Create a short-lived edit on packages/{package}/edits.
    -- 4. GET edits/{editId}/tracks/internal and edits/{editId}/tracks/production.
    -- 5. Delete the edit (cleanup).
    -- 6. Parse: tracks[].releases[].name (version_name), tracks[].releases[].versionCodes (max).
    -- See fastlane-android.yaml:124-189 for the reference implementation.
    error "fetchPlayTracks: implementation pending — see step 4"
```

- [ ] **Step 4: Flesh out `fetchPlayTracks`**

The Google APIs auth flow + tracks endpoint isn't trivially short. Implement in roughly this shape:

```haskell
import qualified Web.JWT as JWT  -- add to package.yaml dependencies if not present
import           Data.Time.Clock (getCurrentTime, addUTCTime)
import           Crypto.PubKey.RSA.PKCS15  (signSafer)
-- (or use `cryptonite` + `jose` packages)

fetchPlayTracks creds package = do
    accessTokenE <- mintAccessToken creds
    case accessTokenE of
        Left err -> pure (Left err)
        Right tok -> do
            editIdE <- createEdit tok package
            case editIdE of
                Left err -> pure (Left err)
                Right editId -> do
                    internalR  <- getTrack tok package editId "internal"
                    productionR <- getTrack tok package editId "production"
                    _          <- deleteEdit tok package editId    -- cleanup, ignore failures
                    pure $ (,) <$> internalR <*> productionR

-- Each helper uses Core.Http.Client.httpJson with the right URL + bearer token.
-- Track JSON shape:
--   { "releases": [ { "name": "2.5.0", "versionCodes": ["12345","12346"], "status":"completed" } ] }
-- Pick the first 'completed' release; if none, the first release.
```

If `Web.JWT` or `jose` is not already a dependency, add it to `backend/package.yaml`. Look for "dependencies:" section and add:

```yaml
  - jose >= 0.10
  - aeson
```

If neither is available, fall back to shelling `openssl` to sign the JWT — slow but unblocking. Note as a tech-debt item.

- [ ] **Step 5: Add module to package.yaml + compile**

```yaml
- Products.Autopilot.Mobile.Versioning
```

```bash
sc-build && sc-test
```

Expected: tests pass; module compiles. `fetchPlayTracks` implementation may be partial — that's OK, the tests cover the pure logic.

- [ ] **Step 6: Commit**

```bash
git add backend/src/Products/Autopilot/Mobile/Versioning.hs \
        backend/test/Main.hs backend/package.yaml
git commit -m "Add Play Console API client and version-bump logic"
```

---

### Task 9: `POST /mobile/versions/preview` endpoint

**Files:**
- Create: `backend/src/Products/Autopilot/Mobile/Handlers/Versions.hs`
- Modify: `backend/src/Products/Autopilot/Mobile/Routes.hs`
- Modify: `backend/package.yaml`

**Why:** Frontend calls this when user picks apps in the create form, to pre-fill version fields.

- [ ] **Step 1: Define handler**

```haskell
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}

module Products.Autopilot.Mobile.Handlers.Versions
    ( PreviewVersionsReq (..)
    , PreviewVersionsResp (..)
    , VersionPreviewItem (..)
    , previewVersionsH
    ) where

import           Core.Auth.Protected                          (AuthedPerson)
import           Core.Environment                             (Flow, MonadFlow)
import           Data.Aeson                                   (FromJSON, ToJSON)
import           Data.Int                                     (Int32)
import           Data.Text                                    (Text)
import           GHC.Generics                                 (Generic)
import           Products.Autopilot.Mobile.Queries.AppCatalog
import           Products.Autopilot.Mobile.Versioning
import           Products.Autopilot.RuntimeConfig             (getConfigSecret)

data PreviewVersionsReq = PreviewVersionsReq
    { appCatalogIds :: [Int32]
    } deriving (Generic, Show, ToJSON, FromJSON)

data VersionPreviewItem = VersionPreviewItem
    { appCatalogId    :: Int32
    , nextVersionName :: Maybe Text
    , nextVersionCode :: Maybe Int32
    , source          :: Maybe Text
    , err             :: Maybe Text       -- field renamed since `error` is reserved-ish
    } deriving (Generic, Show, ToJSON, FromJSON)

data PreviewVersionsResp = PreviewVersionsResp
    { previews :: [VersionPreviewItem]
    } deriving (Generic, Show, ToJSON, FromJSON)

previewVersionsH :: AuthedPerson -> PreviewVersionsReq -> Flow PreviewVersionsResp
previewVersionsH _ req = do
    saJson <- getConfigSecret "play_console_service_account_json"
    let creds = PlayCreds { pcServiceAccountJson = saJson }
    items <- mapM (previewOne creds) (appCatalogIds req)
    pure $ PreviewVersionsResp { previews = items }

previewOne :: PlayCreds -> Int32 -> Flow VersionPreviewItem
previewOne creds aid = do
    mApp <- findAppCatalogById aid
    case mApp of
        Nothing -> pure $ VersionPreviewItem aid Nothing Nothing Nothing (Just "app_not_found")
        Just app -> case acPackageName app of
            Nothing  -> pure $ VersionPreviewItem aid Nothing Nothing Nothing (Just "no_package_name")
            Just pkg -> do
                result <- fetchPlayTracks creds pkg
                case result of
                    Left e -> pure $ VersionPreviewItem aid Nothing Nothing Nothing (Just (renderErr e))
                    Right (internal, production) -> do
                        let (vName, vCode) = computeNextVersion internal production
                        pure $ VersionPreviewItem aid (Just vName) (Just vCode) (Just "play_internal_track") Nothing

renderErr :: PlayApiError -> Text
renderErr PlayUnauthorized          = "play_api_unauthorized"
renderErr (PlayPackageNotFound p)   = "play_package_not_found:" <> p
renderErr (PlayHttpError code body) = "play_http_error:" <> T.pack (show code)
  where T = undefined  -- import Data.Text qualified as T at the top
```

(Fix the stray `T.pack` import — this is a typo to catch in step 3.)

- [ ] **Step 2: Wire route**

In `backend/src/Products/Autopilot/Mobile/Routes.hs`:

```haskell
import Products.Autopilot.Mobile.Handlers.Versions

type MobileAPI =
       -- ... existing ...
  :<|> "mobile" :> "versions" :> "preview"
        :> Protected 'AP_RELEASE_CREATE
        :> ReqBody '[JSON] PreviewVersionsReq
        :> Post '[JSON] PreviewVersionsResp

mobileServer =
        listAppsH
   :<|> createAppH
   :<|> patchAppH
   :<|> previewVersionsH
```

- [ ] **Step 3: Compile**

Fix any imports (qualify `Data.Text as T` properly at the top of `Versions.hs`). Run:

```bash
sc-build
```

- [ ] **Step 4: Smoke test (will fail without Play creds — expected)**

```bash
TOKEN=...
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"appCatalogIds":[1]}' http://localhost:8012/mobile/versions/preview
```

Expected: 200 with `previews[0].err = "play_api_unauthorized"` (since no creds configured yet). That's a valid response shape.

- [ ] **Step 5: Commit**

```bash
git add backend/src/Products/Autopilot/Mobile/Handlers/Versions.hs \
        backend/src/Products/Autopilot/Mobile/Routes.hs \
        backend/package.yaml
git commit -m "Add /mobile/versions/preview endpoint"
```

---

## Phase 4 — GitHub App integration

### Task 10: GitHub App authentication (JWT + installation token exchange)

**Files:**
- Create: `backend/src/Products/Autopilot/Mobile/Github/Auth.hs`
- Modify: `backend/test/Main.hs`
- Modify: `backend/package.yaml`

**Why:** GitHub App auth involves: (1) sign a JWT with the App's private key, (2) exchange the JWT for an installation token at `POST /app/installations/{id}/access_tokens`. Tokens last 1 hour; cache and refresh.

- [ ] **Step 1: Define types and the auth interface**

```haskell
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}

module Products.Autopilot.Mobile.Github.Auth
    ( GhAppCreds (..)
    , InstallationToken (..)
    , getInstallationToken
    , clearTokenCache
    ) where

import           Control.Concurrent.MVar
import           Core.Environment        (MonadFlow, getAppState, AppState)
import           Data.Aeson              (FromJSON)
import           Data.Text               (Text)
import           Data.Time               (UTCTime, addUTCTime, getCurrentTime)
import           GHC.Generics            (Generic)
import           System.IO.Unsafe        (unsafePerformIO)

data GhAppCreds = GhAppCreds
    { gacAppId          :: Text
    , gacPrivateKeyPem  :: Text
    , gacInstallationId :: Text
    } deriving (Eq, Show)

data InstallationToken = InstallationToken
    { itToken     :: Text
    , itExpiresAt :: UTCTime
    } deriving (Eq, Show, Generic, FromJSON)

-- Module-global token cache (one App per SCC instance for MVP).
{-# NOINLINE tokenCache #-}
tokenCache :: MVar (Maybe InstallationToken)
tokenCache = unsafePerformIO (newMVar Nothing)

-- | Returns a valid installation token, refreshing if missing/expired.
getInstallationToken :: MonadFlow m => GhAppCreds -> m Text
getInstallationToken creds = do
    now <- liftIO getCurrentTime
    cached <- liftIO (readMVar tokenCache)
    case cached of
        Just tok | itExpiresAt tok > addUTCTime 60 now -> pure (itToken tok)
        _ -> do
            fresh <- mintAndExchange creds
            liftIO $ modifyMVar_ tokenCache (\_ -> pure (Just fresh))
            pure (itToken fresh)

clearTokenCache :: MonadFlow m => m ()
clearTokenCache = liftIO $ modifyMVar_ tokenCache (\_ -> pure Nothing)

mintAndExchange :: MonadFlow m => GhAppCreds -> m InstallationToken
mintAndExchange creds = do
    -- 1. Build a JWT with iss=app_id, iat=now, exp=now+10min, alg=RS256
    --    signed with gacPrivateKeyPem.
    -- 2. POST /app/installations/{installation_id}/access_tokens
    --    with header: Authorization: Bearer <jwt>
    -- 3. Response: { "token": "ghs_...", "expires_at": "2026-05-11T15:00:00Z" }
    -- Use Web.JWT or jose to mint; Core.Http.Client.httpJson to POST.
    error "mintAndExchange: implementation pending"
```

- [ ] **Step 2: Implement `mintAndExchange`**

Using `jose` (preferred) or `Web.JWT`:

```haskell
import qualified Crypto.JWT as JWT  -- from `jose`
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Encoding as TE
import           Core.Http.Client     (HttpReq (..), HttpMethod (..), httpJson)
import           Core.Types.Time      (Seconds (..))

mintAndExchange creds = do
    now <- liftIO getCurrentTime
    let claims = JWT.emptyClaimsSet
            & JWT.claimIss ?~ JWT.unsafeStringOrUri (gacAppId creds)
            & JWT.claimIat ?~ JWT.NumericDate now
            & JWT.claimExp ?~ JWT.NumericDate (addUTCTime 600 now)
    jwk <- liftIO $ loadPemKey (gacPrivateKeyPem creds)   -- helper: parse PKCS#1 PEM
    signed <- liftIO $ JWT.runJOSE $ JWT.signClaims jwk (JWT.newJWSHeader ((), JWT.RS256)) claims
    case signed of
        Left (e :: JWT.JWTError) -> error ("JWT sign failed: " <> show e)
        Right jwt -> do
            let bearer = "Bearer " <> TE.decodeUtf8 (BL.toStrict (JWT.encodeCompact jwt))
                url    = "https://api.github.com/app/installations/" <> gacInstallationId creds <> "/access_tokens"
                req    = HttpReq POST url
                            [("Authorization", bearer), ("Accept", "application/vnd.github+json")]
                            Nothing (Seconds 30) 1 "github_app_token"
            result <- liftIO (httpJson req)
            case result of
                Right (tok :: InstallationToken) -> pure tok
                Left e   -> error ("token exchange failed: " <> show e)
```

- [ ] **Step 3: Add module + dependency to package.yaml**

```yaml
exposed-modules:
  - Products.Autopilot.Mobile.Github.Auth

dependencies:
  - jose >= 0.10
```

- [ ] **Step 4: Compile**

```bash
sc-build
```

If `jose` is too heavy or unavailable, the fallback is shelling `openssl`:

```haskell
mintJwtViaOpenssl :: Text -> Aeson.Value -> IO Text
-- Write headers+payload to temp files; openssl dgst -sha256 -sign key.pem;
-- base64url encode; concatenate. Slow (~50ms) but always works.
```

Use whichever lands faster.

- [ ] **Step 5: Commit**

```bash
git add backend/src/Products/Autopilot/Mobile/Github/Auth.hs backend/package.yaml
git commit -m "Add GitHub App auth (JWT + installation token cache)"
```

---

### Task 11: GitHub API helpers (dispatch, list runs, jobs, refs, cancel)

**Files:**
- Create: `backend/src/Products/Autopilot/Mobile/Github.hs`
- Modify: `backend/test/Main.hs`
- Modify: `backend/package.yaml`

**Why:** Five operations the runner needs: `workflow_dispatch`, list workflow runs (to resolve run_id by nonce), get jobs, list refs/tags, cancel run.

- [ ] **Step 1: Add tests for response parsing (pure, no HTTP)**

```haskell
import Products.Autopilot.Mobile.Github

testGithubRunsParser :: IO ()
testGithubRunsParser = do
    putStrLn "GitHub runs JSON parser"
    let body = "{\"workflow_runs\":[{\"id\":42,\"event\":\"workflow_dispatch\",\"status\":\"queued\",\"created_at\":\"2026-05-11T10:00:00Z\",\"head_branch\":\"master\",\"html_url\":\"https://github.com/foo/bar/actions/runs/42\",\"name\":\"x\",\"display_title\":\"y\"}]}"
    case Aeson.eitherDecode body :: Either String WorkflowRunsResp of
        Right resp -> assertEqual "parsed run id" 42 (wrId (head (wrrRuns resp)))
        Left e     -> fail ("parse failed: " <> e)

testGithubJobsParser :: IO ()
testGithubJobsParser = do
    putStrLn "GitHub jobs JSON parser"
    let body = "{\"jobs\":[{\"id\":1,\"name\":\"NammaYatri-Release\",\"status\":\"in_progress\",\"conclusion\":null,\"started_at\":\"2026-05-11T10:01:00Z\",\"completed_at\":null,\"html_url\":\"https://github.com/foo/bar/actions/runs/42/job/1\"}]}"
    case Aeson.eitherDecode body :: Either String JobsResp of
        Right resp -> assertEqual "parsed job name" "NammaYatri-Release" (jName (head (jrJobs resp)))
        Left e     -> fail ("parse failed: " <> e)
```

- [ ] **Step 2: Run, expect FAIL**

```bash
sc-test
```

- [ ] **Step 3: Implement the client module**

```haskell
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE RecordWildCards    #-}

module Products.Autopilot.Mobile.Github
    ( WorkflowDispatchReq (..)
    , WorkflowRun (..)
    , WorkflowRunsResp (..)
    , Job (..)
    , JobsResp (..)
    , dispatchWorkflow
    , listWorkflowRuns
    , listJobs
    , listTags
    , cancelRun
    ) where

import           Core.Environment                       (MonadFlow)
import           Core.Http.Client                       (HttpReq (..), HttpMethod (..), httpJson, httpRaw)
import           Core.Types.Time                        (Seconds (..))
import           Data.Aeson                             (FromJSON, ToJSON, Value, object, (.=))
import qualified Data.Aeson                             as Aeson
import           Data.Int                               (Int64)
import           Data.Text                              (Text)
import qualified Data.Text                              as T
import           Data.Time                              (UTCTime)
import           GHC.Generics                           (Generic)
import           Products.Autopilot.Mobile.Github.Auth  (GhAppCreds, getInstallationToken)
import           Control.Monad.IO.Class                 (liftIO)

-- Request payload for workflow_dispatch
data WorkflowDispatchReq = WorkflowDispatchReq
    { wdrRef    :: Text                   -- "master"
    , wdrInputs :: Aeson.Object           -- the workflow's inputs schema
    } deriving (Show)

instance ToJSON WorkflowDispatchReq where
    toJSON (WorkflowDispatchReq r i) = object [ "ref" .= r, "inputs" .= i ]

data WorkflowRun = WorkflowRun
    { wrId           :: Int64
    , wrEvent        :: Text
    , wrStatus       :: Text
    , wrConclusion   :: Maybe Text
    , wrCreatedAt    :: UTCTime
    , wrHtmlUrl      :: Text
    , wrName         :: Text
    , wrDisplayTitle :: Maybe Text
    } deriving (Generic, Show)

instance FromJSON WorkflowRun where
    parseJSON = Aeson.withObject "WorkflowRun" $ \o -> WorkflowRun
        <$> o Aeson..:  "id"
        <*> o Aeson..:  "event"
        <*> o Aeson..:  "status"
        <*> o Aeson..:? "conclusion"
        <*> o Aeson..:  "created_at"
        <*> o Aeson..:  "html_url"
        <*> o Aeson..:  "name"
        <*> o Aeson..:? "display_title"

newtype WorkflowRunsResp = WorkflowRunsResp { wrrRuns :: [WorkflowRun] }
    deriving (Show)

instance FromJSON WorkflowRunsResp where
    parseJSON = Aeson.withObject "WorkflowRunsResp" $ \o ->
        WorkflowRunsResp <$> o Aeson..: "workflow_runs"

data Job = Job
    { jId          :: Int64
    , jName        :: Text
    , jStatus      :: Text
    , jConclusion  :: Maybe Text
    , jStartedAt   :: Maybe UTCTime
    , jCompletedAt :: Maybe UTCTime
    , jHtmlUrl     :: Text
    } deriving (Generic, Show)

instance FromJSON Job where
    parseJSON = Aeson.withObject "Job" $ \o -> Job
        <$> o Aeson..:  "id"
        <*> o Aeson..:  "name"
        <*> o Aeson..:  "status"
        <*> o Aeson..:? "conclusion"
        <*> o Aeson..:? "started_at"
        <*> o Aeson..:? "completed_at"
        <*> o Aeson..:  "html_url"

newtype JobsResp = JobsResp { jrJobs :: [Job] } deriving (Show)
instance FromJSON JobsResp where
    parseJSON = Aeson.withObject "JobsResp" $ \o ->
        JobsResp <$> o Aeson..: "jobs"

-- The five HTTP operations
dispatchWorkflow :: MonadFlow m => GhAppCreds -> Text -> Text -> Text -> WorkflowDispatchReq -> m (Either Text ())
-- listWorkflowRuns :: ... :: m (Either Text [WorkflowRun])
-- listJobs         :: ... :: m (Either Text [Job])
-- listTags         :: ... :: m (Either Text [Text])
-- cancelRun        :: ... :: m (Either Text ())
```

Implement each operation as a wrapper around `httpJson` / `httpRaw`. Pattern (one example):

```haskell
dispatchWorkflow creds owner repo workflowFile body = do
    tok <- getInstallationToken creds
    let url = "https://api.github.com/repos/" <> owner <> "/" <> repo
              <> "/actions/workflows/" <> workflowFile <> "/dispatches"
        req = HttpReq POST url
                [ ("Authorization", "Bearer " <> tok)
                , ("Accept", "application/vnd.github+json")
                , ("X-GitHub-Api-Version", "2022-11-28")
                ]
                (Just (Aeson.encode body)) (Seconds 30) 1 "gh_dispatch"
    result <- liftIO (httpRaw req)
    case result of
        Right resp | respStatus resp == 204 -> pure (Right ())
        Right resp -> pure (Left ("dispatch failed: " <> T.pack (show (respStatus resp))))
        Left e     -> pure (Left ("dispatch http error: " <> T.pack (show e)))
```

The remaining four follow the same shape with different URLs:
- `listWorkflowRuns`: `GET /repos/{owner}/{repo}/actions/workflows/{workflow_id}/runs?event=workflow_dispatch&per_page=20`
- `listJobs`: `GET /repos/{owner}/{repo}/actions/runs/{run_id}/jobs`
- `listTags`: `GET /repos/{owner}/{repo}/git/matching-refs/tags/{prefix}`
- `cancelRun`: `POST /repos/{owner}/{repo}/actions/runs/{run_id}/cancel`

- [ ] **Step 4: Compile + run tests**

```bash
sc-build && sc-test
```

Expected: all parser tests PASS.

- [ ] **Step 5: Add module to package.yaml**

```yaml
- Products.Autopilot.Mobile.Github
```

- [ ] **Step 6: Commit**

```bash
git add backend/src/Products/Autopilot/Mobile/Github.hs backend/test/Main.hs backend/package.yaml
git commit -m "Add GitHub Actions API client (dispatch, runs, jobs, tags, cancel)"
```

---

## Phase 5 — Mobile workflow spec

### Task 12: Workflow spec skeleton + stages 1-2 (ResolveVersion, GroupForDispatch)

**Files:**
- Create: `backend/src/Products/Autopilot/Mobile/Workflow.hs`
- Modify: `backend/package.yaml`

**Why:** First two stages of the 7-stage spec. Stage 1 calls Play API and stores version in target state; Stage 2 collects sibling rows for dispatch grouping and acquires a lock.

- [ ] **Step 1: Create the spec skeleton**

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Products.Autopilot.Mobile.Workflow
    ( mobileBuildSpec
    ) where

import           Control.Monad                                (when)
import           Core.Environment                             (Flow, MonadFlow)
import           Core.Workflow.Engine                         (WorkflowSpec (..), Stage (..), StageOutcome (..))
import           Data.Text                                    (Text)
import           Products.Autopilot.Mobile.Github             as Gh
import           Products.Autopilot.Mobile.Github.Auth        (GhAppCreds (..))
import           Products.Autopilot.Mobile.Types
import           Products.Autopilot.Mobile.Versioning         as Ver
import           Products.Autopilot.Types.Release             (ReleaseTracker (..), ReleaseStatus (..))
import           Products.Autopilot.Types.Workflow            (ReleaseState (..))
import           Products.Autopilot.Mobile.Queries.Tracker    -- helpers, see Task 16

mobileBuildSpec :: WorkflowSpec ReleaseState
mobileBuildSpec = WorkflowSpec
    { wsName     = "mobile-build"
    , wsStages   = [ stageResolveVersion
                   , stageGroupForDispatch
                   , stageDispatchWorkflow
                   , stageResolveRunId
                   , stagePollMatrixJobs
                   , stageConfirmTag
                   , stageFinalize
                   ]
    , wsRollback = mobileRollback
    , wsPersist  = persistReleaseState
    }

mobileRollback :: e -> ExceptT e (Recorded ReleaseState Flow) ()
mobileRollback _ = pure ()  -- mobile has no rollback equivalent; FAILED is terminal

persistReleaseState :: ReleaseState -> Flow ()
persistReleaseState = ...   -- update release_tracker.releaseContext from current targetState
```

- [ ] **Step 2: Implement stage 1 — ResolveVersion**

```haskell
stageResolveVersion :: Stage ReleaseState
stageResolveVersion = Stage
    { stageName        = "ResolveVersion"
    , stageGuard       = \rs -> case targetState rs of
        Just (MobileBuildState s) | mbWfStatus s `notElem` [MBInit] -> Just ()
        _ -> Nothing
    , stagePreCheck    = pure ()
    , stageExec        = do
        rs <- get
        case targetState rs of
            Just (MobileBuildState s) -> do
                let pkg = mbContextPackage s    -- helper to read package_name
                creds <- liftIO loadPlayCreds   -- pulled from server_config
                outcome <- lift $ Ver.fetchPlayTracks creds pkg
                case outcome of
                    Left e -> do
                        liftIO $ logErrorG ("ResolveVersion failed: " <> renderErr e)
                        modify $ \rs' -> rs' { targetState = Just (MobileBuildState s
                            { mbWfStatus = MBFailed ("version_resolution: " <> renderErr e) }) }
                        pure StageAbort
                    Right (internal, production) -> do
                        let (vName, vCode) = Ver.computeNextVersion internal production
                        -- Update tracker.newVersion + targetState.mbContext.versionCode
                        modify $ updateNewVersion vName vCode
                        modify $ updateMbWfStatus MBVersionResolved
                        pure StageSuccess
            _ -> pure StageAbort
    , stageOnAdvance   = id
    , stageOnError     = \_ -> pure ()
    , stageAcquireLocks = pure ()
    }

updateNewVersion :: Text -> Int32 -> ReleaseState -> ReleaseState
updateNewVersion vName vCode rs = rs
    { releaseTracker = (releaseTracker rs) { newVersion = vName }
    , targetState = case targetState rs of
        Just (MobileBuildState s) -> Just (MobileBuildState s
            { mbContext = (mbContext s) { mbcVersionCode = Just vCode } })
        other -> other
    }

updateMbWfStatus :: MobileBuildWFStatus -> ReleaseState -> ReleaseState
updateMbWfStatus newSt rs = rs
    { targetState = case targetState rs of
        Just (MobileBuildState s) -> Just (MobileBuildState s { mbWfStatus = newSt })
        other -> other
    }
```

- [ ] **Step 3: Implement stage 2 — GroupForDispatch**

This stage acquires a row-level Postgres lock on the lowest-id row in the dispatch group.

```haskell
stageGroupForDispatch :: Stage ReleaseState
stageGroupForDispatch = Stage
    { stageName  = "GroupForDispatch"
    , stageGuard = \rs -> case releaseTracker rs of
        rt | rtExternalRunId rt /= Nothing -> Just ()
           | otherwise                     -> Nothing
    , stagePreCheck = pure ()
    , stageExec = do
        rs <- get
        let rt = releaseTracker rs
        case rtDispatchId rt of
            Nothing -> do
                liftIO $ logErrorG "GroupForDispatch: no dispatch_id set"
                pure StageAbort
            Just did -> do
                -- Acquire an advisory lock keyed on dispatch_id; blocks other workers.
                acquired <- lift $ tryAdvisoryLock did
                if acquired
                    then pure StageSuccess
                    else pure StageWaiting   -- another worker has the lock; try next tick
    , stageOnAdvance    = id
    , stageOnError      = \_ -> pure ()
    , stageAcquireLocks = pure ()
    }

tryAdvisoryLock :: MonadFlow m => Text -> m Bool
-- Use Postgres pg_try_advisory_lock(hashtext(:dispatch_id))
-- Released automatically at session end.
```

- [ ] **Step 4: Add module to package.yaml + compile**

```yaml
- Products.Autopilot.Mobile.Workflow
```

```bash
sc-build
```

Expected: compiles. The unimplemented helpers (`loadPlayCreds`, `mbContextPackage`, `tryAdvisoryLock`, `persistReleaseState`) are stubbed with `error "..."` for now and filled in Tasks 13-15.

- [ ] **Step 5: Commit**

```bash
git add backend/src/Products/Autopilot/Mobile/Workflow.hs backend/package.yaml
git commit -m "Add mobile workflow spec skeleton with stages 1-2"
```

---

### Task 13: Stages 3-4 (DispatchWorkflow, ResolveRunId)

**Files:**
- Modify: `backend/src/Products/Autopilot/Mobile/Workflow.hs`

**Why:** Stage 3 builds the workflow_dispatch payload (`selected_apps` CSV + version + nonce) and POSTs it. Stage 4 polls `/runs` until it finds the run that has our nonce in inputs.

- [ ] **Step 1: Implement stage 3 — DispatchWorkflow**

```haskell
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import qualified Data.Text as T
import qualified Data.HashMap.Strict as HM   -- or Aeson.KeyMap depending on version
import qualified Data.Aeson as Aeson

stageDispatchWorkflow :: Stage ReleaseState
stageDispatchWorkflow = Stage
    { stageName  = "DispatchWorkflow"
    , stageGuard = \rs -> case targetState rs of
        Just (MobileBuildState s) | mbWfStatus s `elem` [MBDispatched, MBRunIdResolved, MBBuilding,
                                                          MBSubmittedToStore, MBTagPushed,
                                                          MBCompleted, MBAborting, MBAborted]
                                  || isMBFailed (mbWfStatus s) -> Just ()
        _ -> Nothing
    , stagePreCheck = pure ()
    , stageExec = do
        rs <- get
        let rt = releaseTracker rs
        case (rtDispatchId rt, targetState rs) of
            (Just did, Just (MobileBuildState s)) -> do
                -- Collect all sibling rows in this dispatch
                siblings <- lift $ findSiblingsByDispatchId did
                let appNames    = T.intercalate "," (map (appGroup . releaseTracker) siblings)
                    versionName = newVersion rt
                    versionCode = case mbcVersionCode (mbContext s) of
                                    Just c  -> T.pack (show c)
                                    Nothing -> ""
                    nonce       = did   -- reuse dispatch_id as nonce
                    inputs = HM.fromList
                        [ ("selected_apps",  Aeson.String appNames)
                        , ("version_name",   Aeson.String versionName)
                        , ("version_code",   Aeson.String versionCode)
                        , ("change_log",     Aeson.String (mbcChangeLog (mbContext s)))
                        , ("notify_slack",   Aeson.Bool True)
                        , ("payload",        Aeson.String (Aeson.encode (Aeson.object
                                                              [("scc_dispatch_nonce", Aeson.String nonce)])))
                        ]
                creds <- liftIO loadGhCreds
                let appCat = appCatalogForRow rt    -- helper that joins on (app_group, surface, platform)
                outcome <- lift $ Gh.dispatchWorkflow creds
                                                     (gitOwner appCat) (gitRepo appCat)
                                                     (acWorkflowPath appCat)
                                                     (Gh.WorkflowDispatchReq "master" inputs)
                case outcome of
                    Right () -> do
                        modify $ updateMbWfStatus MBDispatched
                        liftIO $ logInfoG ("Dispatched workflow for " <> did)
                        pure StageSuccess
                    Left e -> do
                        liftIO $ logErrorG ("Dispatch failed: " <> e)
                        modify $ updateMbWfStatus (MBFailed ("dispatch: " <> e))
                        pure StageAbort
            _ -> pure StageAbort
    , stageOnAdvance    = id
    , stageOnError      = \_ -> pure ()
    , stageAcquireLocks = pure ()
    }
```

- [ ] **Step 2: Implement stage 4 — ResolveRunId**

```haskell
stageResolveRunId :: Stage ReleaseState
stageResolveRunId = Stage
    { stageName  = "ResolveRunId"
    , stageGuard = \rs -> case rtExternalRunId (releaseTracker rs) of
        Just _  -> Just ()
        Nothing -> Nothing
    , stagePreCheck = pure ()
    , stageExec = do
        rs <- get
        let rt = releaseTracker rs
        case rtDispatchId rt of
            Nothing -> pure StageAbort
            Just did -> do
                creds   <- liftIO loadGhCreds
                let appCat = appCatalogForRow rt
                runsR <- lift $ Gh.listWorkflowRuns creds (gitOwner appCat) (gitRepo appCat) (acWorkflowPath appCat)
                case runsR of
                    Left e -> do
                        liftIO $ logErrorG ("listWorkflowRuns failed: " <> e)
                        pure StageWaiting   -- transient; retry next tick
                    Right runs -> do
                        let matchingRun = lookupByNonce did runs    -- inspect run.inputs.payload
                        case matchingRun of
                            Nothing  -> do
                                -- Try a few times; treat 5+ failures as MBFailed
                                cnt <- lift $ incrementResolveAttempts (rtId rt)
                                if cnt >= 10
                                    then do
                                        modify $ updateMbWfStatus (MBFailed "run_lookup_timeout")
                                        pure StageAbort
                                    else pure StageWaiting
                            Just r -> do
                                -- Set external_run_id on this row AND all siblings
                                lift $ setExternalRunIdForDispatch did (T.pack (show (Gh.wrId r)))
                                modify $ updateMbWfStatus MBRunIdResolved
                                pure StageSuccess
    , stageOnAdvance    = id
    , stageOnError      = \_ -> pure ()
    , stageAcquireLocks = pure ()
    }

-- Helper: parse 'inputs.payload' field of WorkflowRun (it's a JSON-encoded string), look for nonce
lookupByNonce :: Text -> [Gh.WorkflowRun] -> Maybe Gh.WorkflowRun
lookupByNonce nonce = find $ \r -> case extractNonce r of
    Just n -> n == nonce
    Nothing -> False
  where
    -- extractNonce :: WorkflowRun -> Maybe Text
    -- needs to GET /runs/{id} which includes the inputs in the response (the workflow_runs list
    -- doesn't expose inputs — we need a follow-up call per recent run; or we can match by
    -- (actor, created_at within ±2min of dispatch time) as a fallback).
    extractNonce = error "extractNonce: needs follow-up GET /runs/:id"
```

**Implementation note:** GitHub's `/actions/workflows/.../runs` endpoint does NOT include `inputs.payload` in the list response. To match by nonce, we must either:
- (Preferred) Fetch each candidate run individually via `GET /runs/{id}` (which DOES include inputs), or
- (Fallback) Filter by `actor` (the GitHub App's bot user) + `created_at` within ±2 minutes of our dispatch time.

Implement the fallback for MVP and note the preferred path as a follow-up.

- [ ] **Step 3: Compile**

```bash
sc-build
```

- [ ] **Step 4: Commit**

```bash
git add backend/src/Products/Autopilot/Mobile/Workflow.hs
git commit -m "Add stages 3-4: DispatchWorkflow + ResolveRunId"
```

---

### Task 14: Stages 5-7 (PollMatrixJobs, ConfirmTag, Finalize)

**Files:**
- Modify: `backend/src/Products/Autopilot/Mobile/Workflow.hs`

**Why:** Stage 5 polls jobs and updates per-row status. Stage 6 verifies the annotated git tag was pushed. Stage 7 transitions to terminal status and notifies.

- [ ] **Step 1: Implement stage 5 — PollMatrixJobs**

```haskell
stagePollMatrixJobs :: Stage ReleaseState
stagePollMatrixJobs = Stage
    { stageName  = "PollMatrixJobs"
    , stageGuard = \rs -> case targetState rs of
        Just (MobileBuildState s) | isMBTerminal (mbWfStatus s) || mbWfStatus s == MBTagPushed -> Just ()
        _ -> Nothing
    , stagePreCheck = pure ()
    , stageExec = do
        rs <- get
        case (rtExternalRunId (releaseTracker rs), targetState rs) of
            (Just runId, Just (MobileBuildState s)) -> do
                creds <- liftIO loadGhCreds
                let appCat = appCatalogForRow (releaseTracker rs)
                jobsR <- lift $ Gh.listJobs creds (gitOwner appCat) (gitRepo appCat) runId
                case jobsR of
                    Left e -> do
                        liftIO $ logErrorG ("listJobs failed: " <> e)
                        pure StageWaiting
                    Right jobs -> do
                        let myJob = find (\j -> Gh.jName j == mbcMatrixJobName (mbContext s)) jobs
                        case myJob of
                            Nothing -> pure StageWaiting   -- job hasn't appeared yet
                            Just j  -> do
                                let st = Gh.jStatus j
                                modify $ \rs' -> rs'
                                    { targetState = case targetState rs' of
                                        Just (MobileBuildState x) -> Just (MobileBuildState x
                                            { mbMatrixJobStatus  = Just st
                                            , mbBuildStartedAt   = Gh.jStartedAt j
                                            , mbBuildCompletedAt = Gh.jCompletedAt j
                                            , mbWfStatus = case (st, Gh.jConclusion j) of
                                                ("in_progress", _)        -> MBBuilding
                                                ("completed", Just "success") -> MBSubmittedToStore
                                                ("completed", Just c)     -> MBFailed ("build_" <> c)
                                                _                         -> mbWfStatus x
                                            })
                                        other -> other
                                    }
                                lift $ logEvent (rtId (releaseTracker rs)) "MATRIX_JOB_UPDATED" $
                                    Aeson.object [ "matrix_job_name" .= Gh.jName j, "status" .= st ]
                                case Gh.jStatus j of
                                    "completed" -> pure StageSuccess
                                    _           -> pure StageWaiting
            _ -> pure StageAbort
    , stageOnAdvance    = id
    , stageOnError      = \_ -> pure ()
    , stageAcquireLocks = pure ()
    }
```

- [ ] **Step 2: Implement stage 6 — ConfirmTag**

```haskell
stageConfirmTag :: Stage ReleaseState
stageConfirmTag = Stage
    { stageName  = "ConfirmTag"
    , stageGuard = \rs -> case targetState rs of
        Just (MobileBuildState s) | isJust (mbcTagPushed (mbContext s)) -> Just ()
        _ -> Nothing
    , stagePreCheck = pure ()
    , stageExec = do
        rs <- get
        let rt = releaseTracker rs
        case targetState rs of
            Just (MobileBuildState s) | mbWfStatus s == MBSubmittedToStore -> do
                creds <- liftIO loadGhCreds
                let appCat   = appCatalogForRow rt
                    appSeg   = T.toLower (T.replace " " "-" (appGroup rt))
                    tagPrefix = appSeg <> "/prod/" <> env rt <> "/v" <> newVersion rt
                tagsR <- lift $ Gh.listTags creds (gitOwner appCat) (gitRepo appCat) tagPrefix
                case tagsR of
                    Left e -> do
                        liftIO $ logErrorG ("listTags failed: " <> e)
                        pure StageWaiting
                    Right [] -> pure StageWaiting   -- tag not yet pushed; try later
                    Right (tag:_) -> do
                        modify $ \rs' -> rs'
                            { targetState = case targetState rs' of
                                Just (MobileBuildState x) -> Just (MobileBuildState x
                                    { mbContext = (mbContext x) { mbcTagPushed = Just tag }
                                    , mbWfStatus = MBTagPushed
                                    })
                                other -> other
                            }
                        lift $ logEvent (rtId rt) "TAG_OBSERVED" $
                            Aeson.object [ "tag_name" .= tag ]
                        pure StageSuccess
            _ -> pure StageSuccess  -- not in expected state; let next stage decide
    , stageOnAdvance    = id
    , stageOnError      = \_ -> pure ()
    , stageAcquireLocks = pure ()
    }
```

- [ ] **Step 3: Implement stage 7 — Finalize**

```haskell
stageFinalize :: Stage ReleaseState
stageFinalize = Stage
    { stageName  = "Finalize"
    , stageGuard = \rs -> case status (releaseTracker rs) of
        s | isTerminalStatus s -> Just ()
        _ -> Nothing
    , stagePreCheck = pure ()
    , stageExec = do
        rs <- get
        let rt = releaseTracker rs
        case targetState rs of
            Just (MobileBuildState s) -> do
                let newStatus = case mbWfStatus s of
                        MBCompleted    -> COMPLETED
                        MBAborted      -> USER_ABORTED
                        MBFailed _     -> ABORTED
                        _              -> status rt   -- not yet terminal
                when (newStatus /= status rt) $ do
                    modify $ \rs' -> rs'
                        { releaseTracker = (releaseTracker rs') { status = newStatus } }
                    lift $ logEvent (rtId rt) "STATUS_UPDATED" $
                        Aeson.object [ "status" .= show newStatus ]
                    -- Optional Slack notification using existing module
                pure StageSuccess
            _ -> pure StageSuccess
    , stageOnAdvance    = id
    , stageOnError      = \_ -> pure ()
    , stageAcquireLocks = pure ()
    }
```

- [ ] **Step 4: Compile**

```bash
sc-build
```

Expected: compiles.

- [ ] **Step 5: Commit**

```bash
git add backend/src/Products/Autopilot/Mobile/Workflow.hs
git commit -m "Add stages 5-7: PollMatrixJobs + ConfirmTag + Finalize"
```

---

### Task 15: Tracker query helpers

**Files:**
- Create: `backend/src/Products/Autopilot/Mobile/Queries/Tracker.hs`
- Modify: `backend/package.yaml`

**Why:** The workflow stages reference helpers like `findSiblingsByDispatchId`, `setExternalRunIdForDispatch`, `incrementResolveAttempts`, `appCatalogForRow`, `loadGhCreds`, `loadPlayCreds`, `logEvent`. Centralize them.

- [ ] **Step 1: Implement the helpers**

```haskell
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

module Products.Autopilot.Mobile.Queries.Tracker
    ( findSiblingsByDispatchId
    , setExternalRunIdForDispatch
    , incrementResolveAttempts
    , appCatalogForRow
    , loadGhCreds
    , loadPlayCreds
    , logEvent
    , gitOwner
    , gitRepo
    ) where

import           Core.DB.Connection                          (runDB)
import           Core.Environment                            (MonadFlow, withDb, getConfig, getDBEnv)
import           Data.Aeson                                  (Value)
import           Data.Int                                    (Int32, Int64)
import           Data.Text                                   (Text)
import qualified Data.Text                                   as T
import           Database.Beam
import           Database.Beam.Postgres                      (runBeamPostgres)
import           Products.Autopilot.Mobile.Github.Auth       (GhAppCreds (..))
import           Products.Autopilot.Mobile.Versioning        (PlayCreds (..))
import           Products.Autopilot.Mobile.Types.Storage     (AppCatalog, acGithubRepo, acWorkflowPath)
import           Products.Autopilot.RuntimeConfig            (getConfigSecret)
import           Products.Autopilot.Types.Storage.Schema
import           Control.Monad.IO.Class                      (liftIO)

-- Find all release_tracker rows with the same dispatch_id.
findSiblingsByDispatchId :: MonadFlow m => Text -> m [ReleaseTracker]
-- ... uses Beam SELECT ... WHERE dispatch_id = ?

-- Set external_run_id on every row in the dispatch (single UPDATE).
setExternalRunIdForDispatch :: MonadFlow m => Text -> Text -> m ()

-- Track ResolveRunId attempts in releaseContext JSON; return new count.
incrementResolveAttempts :: MonadFlow m => Text -> m Int

-- Look up the AppCatalog row matching this tracker.
appCatalogForRow :: MonadFlow m => ReleaseTracker -> m AppCatalog

-- Load GH App creds from server_config.
loadGhCreds :: MonadFlow m => m GhAppCreds
loadGhCreds = GhAppCreds
    <$> getConfigSecret "github_app_id"
    <*> getConfigSecret "github_app_private_key"
    <*> getConfigSecret "github_app_installation_id"

-- Load Play Console creds.
loadPlayCreds :: MonadFlow m => m PlayCreds
loadPlayCreds = PlayCreds <$> getConfigSecret "play_console_service_account_json"

-- Append a release_event row.
logEvent :: MonadFlow m => Text -> Text -> Value -> m ()
-- delegates to existing EventLog module's INSERT

-- Parse "owner/repo" string into ("owner", "repo")
gitOwner :: AppCatalog -> Text
gitOwner ac = T.takeWhile (/= '/') (acGithubRepo ac)

gitRepo :: AppCatalog -> Text
gitRepo ac = T.drop 1 (T.dropWhile (/= '/') (acGithubRepo ac))
```

Implement each query body following patterns in existing `Products/Autopilot/Queries/*.hs` files.

- [ ] **Step 2: Add module to package.yaml**

```yaml
- Products.Autopilot.Mobile.Queries.Tracker
```

- [ ] **Step 3: Compile**

```bash
sc-build
```

- [ ] **Step 4: Commit**

```bash
git add backend/src/Products/Autopilot/Mobile/Queries/Tracker.hs backend/package.yaml
git commit -m "Add tracker helpers used by mobile workflow stages"
```

---

### Task 16: Wire `MobileBuild` into the existing workflow Factory

**Files:**
- Modify: `backend/src/Products/Autopilot/Workflow/Factory.hs`

**Why:** The runner already routes per-category. Add the `MobileBuild` arm.

- [ ] **Step 1: Add the import**

```haskell
import Products.Autopilot.Mobile.Workflow (mobileBuildSpec)
```

- [ ] **Step 2: Extend `getWorkflowForCategory`**

```haskell
getWorkflowForCategory = \case
    BackendService    -> runWorkflowSpec backendServiceSpec
    BackendScheduler  -> runWorkflowSpec backendSchedulerSpec
    BackendConfig     -> runWorkflowSpec backendConfigSpec
    VSEdit            -> notImplementedWorkflow "VSEdit"
    MobileBuild       -> runWorkflowSpec mobileBuildSpec   -- NEW
```

- [ ] **Step 3: Compile**

```bash
sc-build
```

If `case` blocks elsewhere on `ReleaseCategory` still warn about non-exhaustive patterns, add the `MobileBuild` arm with the most-conservative behavior (e.g., `MobileBuild -> True` for "is this a release type we handle", or whatever the local semantics demand).

- [ ] **Step 4: Commit**

```bash
git add backend/src/Products/Autopilot/Workflow/Factory.hs
git commit -m "Route MobileBuild category to mobileBuildSpec in workflow factory"
```

---

## Phase 6 — Mobile release endpoints

### Task 17: `POST /releases/mobile/create` handler

**Files:**
- Create: `backend/src/Products/Autopilot/Mobile/Handlers/Release.hs`
- Modify: `backend/src/Products/Autopilot/Mobile/Routes.hs`
- Modify: `backend/package.yaml`

**Why:** Creates N release_tracker rows in one transaction; one per (app_catalog_id, version).

- [ ] **Step 1: Define request/response + handler**

```haskell
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}

module Products.Autopilot.Mobile.Handlers.Release
    ( CreateMobileReleasesReq (..)
    , CreateMobileReleasesItem (..)
    , CreateMobileReleasesResp (..)
    , CreatedReleaseSummary (..)
    , createMobileReleasesH
    ) where

import           Core.Auth.Protected                          (AuthedPerson (..))
import           Core.Environment                             (Flow)
import           Data.Aeson                                   (FromJSON, ToJSON)
import           Data.Int                                     (Int32)
import           Data.Text                                    (Text)
import qualified Data.UUID                                    as UUID
import qualified Data.UUID.V4                                 as UUID
import           Data.Time                                    (getCurrentTime)
import           GHC.Generics                                 (Generic)
import           Products.Autopilot.Mobile.Queries.AppCatalog (findAppCatalogById)
import           Products.Autopilot.Mobile.Types
import           Products.Autopilot.Mobile.Queries.Tracker    (insertMobileTracker)
import           Products.Autopilot.Types.Release             (ReleaseStatus (..))
import           Products.Autopilot.Types.Workflow            (ReleaseCategory (..))
import           Servant                                      (err400, throwError, errBody)

data CreateMobileReleasesItem = CreateMobileReleasesItem
    { appCatalogId :: Int32
    , versionName  :: Maybe Text
    , versionCode  :: Maybe Int32
    } deriving (Generic, Show, ToJSON, FromJSON)

data CreateMobileReleasesReq = CreateMobileReleasesReq
    { releaseGroupLabel :: Maybe Text
    , changeLog         :: Text
    , destination       :: MobileDestination
    , items             :: [CreateMobileReleasesItem]
    } deriving (Generic, Show, ToJSON, FromJSON)

data CreatedReleaseSummary = CreatedReleaseSummary
    { id            :: Text
    , appCatalogId  :: Int32
    , status        :: Text
    } deriving (Generic, Show, ToJSON, FromJSON)

data CreateMobileReleasesResp = CreateMobileReleasesResp
    { releaseGroupId :: Text
    , releases       :: [CreatedReleaseSummary]
    } deriving (Generic, Show, ToJSON, FromJSON)

createMobileReleasesH :: AuthedPerson -> CreateMobileReleasesReq -> Flow CreateMobileReleasesResp
createMobileReleasesH auth req = do
    when (null (items req)) $
        Servant.throwError (Servant.err400 { errBody = "items must be non-empty" })

    rgId <- liftIO (UUID.toText <$> UUID.nextRandom)
    now  <- liftIO getCurrentTime

    summaries <- mapM (createOne auth req rgId now) (items req)
    pure $ CreateMobileReleasesResp { releaseGroupId = rgId, releases = summaries }

createOne :: AuthedPerson -> CreateMobileReleasesReq -> Text -> UTCTime
          -> CreateMobileReleasesItem -> Flow CreatedReleaseSummary
createOne auth req rgId now item = do
    mApp <- findAppCatalogById (appCatalogId item)
    case mApp of
        Nothing -> Servant.throwError (Servant.err400 { errBody = "unknown app_catalog_id" })
        Just app -> do
            rid <- liftIO (UUID.toText <$> UUID.nextRandom)
            let matrixJobName = acName app <> "-Release"   -- matches workflow's `name: ${{matrix.name}}-Release`
                ctx = MobileBuildContext
                    { mbcVersionCode    = versionCode item
                    , mbcChangeLog      = changeLog req
                    , mbcDestination    = destination req
                    , mbcReleaseGroupId = rgId
                    , mbcMatrixJobName  = matrixJobName
                    , mbcOtaNamespace   = Nothing
                    , mbcTagPushed      = Nothing
                    }
                state = MobileBuildTargetState
                    { mbWfStatus = MBInit
                    , mbContext  = ctx
                    , mbExternalRunId    = Nothing
                    , mbMatrixJobStatus  = Nothing
                    , mbBuildStartedAt   = Nothing
                    , mbBuildCompletedAt = Nothing
                    }
            -- Insert release_tracker row with category=MobileBuild,
            -- app_group=acName app, service=acSurface app, env=acPlatform app,
            -- newVersion = versionName item or "" (filled later by ResolveVersion stage),
            -- releaseContext = JSON of state, status=CREATED, mode=MANUAL,
            -- createdBy = email of auth, dateCreated = now
            insertMobileTracker rid app state (versionName item) (createdByEmail auth) now
            pure $ CreatedReleaseSummary { id = rid, appCatalogId = appCatalogId item, status = "CREATED" }
```

Implementation of `insertMobileTracker` goes in `Mobile/Queries/Tracker.hs`.

- [ ] **Step 2: Wire route**

In `backend/src/Products/Autopilot/Mobile/Routes.hs`:

```haskell
import Products.Autopilot.Mobile.Handlers.Release

type MobileAPI =
       -- ... existing ...
  :<|> "releases" :> "mobile" :> "create"
        :> Protected 'AP_RELEASE_CREATE
        :> ReqBody '[JSON] CreateMobileReleasesReq
        :> Post '[JSON] CreateMobileReleasesResp

mobileServer = ... :<|> createMobileReleasesH
```

- [ ] **Step 3: Add module to package.yaml + compile**

```yaml
- Products.Autopilot.Mobile.Handlers.Release
```

```bash
sc-build
```

- [ ] **Step 4: Smoke test via curl**

```bash
TOKEN=...
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"changeLog":"test","destination":"GooglePlay",
       "items":[{"appCatalogId":1,"versionName":null,"versionCode":null}]}' \
  http://localhost:8012/releases/mobile/create
```

Expected: 200 with `releaseGroupId` UUID and one `releases[0]` with `status=CREATED`.

Verify in DB:

```bash
psql "$SC_DATABASE_URL" -c "SELECT id, app_group, service, env, category, status FROM release_tracker WHERE category='MobileBuild';"
```

- [ ] **Step 5: Commit**

```bash
git add backend/src/Products/Autopilot/Mobile/Handlers/Release.hs \
        backend/src/Products/Autopilot/Mobile/Queries/Tracker.hs \
        backend/src/Products/Autopilot/Mobile/Routes.hs \
        backend/package.yaml
git commit -m "Add POST /releases/mobile/create handler"
```

---

### Task 18: `POST /releases/mobile/dispatch` handler

**Files:**
- Modify: `backend/src/Products/Autopilot/Mobile/Handlers/Release.hs`
- Modify: `backend/src/Products/Autopilot/Mobile/Routes.hs`

**Why:** Bundled dispatch endpoint. Groups release IDs by (workflow_path, surface, platform), assigns a dispatch_id to each group, transitions all rows to INPROGRESS so the runner picks them up.

- [ ] **Step 1: Add tests for the grouping function**

In `backend/test/Main.hs`:

```haskell
testDispatchGrouping :: IO ()
testDispatchGrouping = do
    putStrLn "Mobile dispatch grouping by (workflow, surface, platform)"
    let rows =
            [ FauxRow 1 "fastlane-android.yaml" "customer" "android"
            , FauxRow 2 "fastlane-android.yaml" "customer" "android"
            , FauxRow 3 "fastlane.yaml"          "customer" "ios"
            ]
    let groups = groupForDispatch rows
    assertEqual "two groups produced" 2 (length groups)
    -- Verify groups have right membership
    let androidGroup = head $ filter (\g -> length (gMembers g) == 2) groups
    assertEqual "android group has 2 members" 2 (length (gMembers androidGroup))
```

(Define a tiny `FauxRow` for testability and a pure `groupForDispatch :: [FauxRow] -> [Group]` function in the handlers module.)

- [ ] **Step 2: Implement `groupForDispatch` and the handler**

```haskell
data DispatchMobileReleasesReq = DispatchMobileReleasesReq
    { releaseIds :: [Text]
    } deriving (Generic, Show, ToJSON, FromJSON)

data DispatchInfo = DispatchInfo
    { dispatchId       :: Text
    , workflowPath     :: Text
    , releaseIdsInDisp :: [Text]
    , expectedRunUrl   :: Maybe Text
    } deriving (Generic, Show, ToJSON, FromJSON)

data DispatchMobileReleasesResp = DispatchMobileReleasesResp
    { dispatches :: [DispatchInfo]
    } deriving (Generic, Show, ToJSON, FromJSON)

dispatchMobileReleasesH :: AuthedPerson -> DispatchMobileReleasesReq -> Flow DispatchMobileReleasesResp
dispatchMobileReleasesH _ req = do
    rows <- mapM loadAndValidate (releaseIds req)
    let groups = groupBy3 (\(rt, _) -> (acWorkflowPath, acSurface, acPlatform)) rows
    dispatchInfos <- mapM (assignAndPersist) groups
    pure $ DispatchMobileReleasesResp { dispatches = dispatchInfos }

loadAndValidate :: Text -> Flow (ReleaseTracker, AppCatalog)
-- Looks up by id; fails 400 if status /= CREATED or not approved or category /= MobileBuild

assignAndPersist :: [(ReleaseTracker, AppCatalog)] -> Flow DispatchInfo
assignAndPersist members = do
    did <- liftIO (UUID.toText <$> UUID.nextRandom)
    let ids = map (rtId . fst) members
    setDispatchIdForRows did ids                         -- single UPDATE
    transitionToInProgress ids                           -- status=INPROGRESS
    mapM_ (\rid -> logEvent rid "DISPATCH_REQUESTED" $
                       Aeson.object [ "dispatch_id" .= did ]) ids
    pure $ DispatchInfo { dispatchId = did
                        , workflowPath = acWorkflowPath (snd (head members))
                        , releaseIdsInDisp = ids
                        , expectedRunUrl = Nothing
                        }
```

- [ ] **Step 3: Wire route**

```haskell
:<|> "releases" :> "mobile" :> "dispatch"
      :> Protected 'AP_MOBILE_DISPATCH
      :> ReqBody '[JSON] DispatchMobileReleasesReq
      :> Post '[JSON] DispatchMobileReleasesResp
```

- [ ] **Step 4: Compile + run tests**

```bash
sc-build && sc-test
```

- [ ] **Step 5: Smoke test**

```bash
# Approve the release we created in Task 17 first
TOKEN=...
RID="<id from Task 17>"
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  http://localhost:8012/releases/$RID/approve

# Now dispatch
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"releaseIds\":[\"$RID\"]}" \
  http://localhost:8012/releases/mobile/dispatch
```

Expected: 202 with one `dispatches[0]` entry. Status in DB transitions to INPROGRESS. Runner picks up next tick (will fail at ResolveVersion without Play creds — that's OK, validates the dispatch path).

- [ ] **Step 6: Commit**

```bash
git add backend/src/Products/Autopilot/Mobile/Handlers/Release.hs \
        backend/src/Products/Autopilot/Mobile/Routes.hs backend/test/Main.hs
git commit -m "Add POST /releases/mobile/dispatch with grouping"
```

---

### Task 19: Live releases endpoint + category filter on `/releases`

**Files:**
- Create: `backend/src/Products/Autopilot/Mobile/Handlers/Live.hs`
- Modify: `backend/src/Products/Autopilot/Mobile/Routes.hs`
- Modify: `backend/src/Products/Autopilot/Routes.hs` (add `?category=` query param to existing list endpoint)
- Modify: `backend/src/Products/Autopilot/Actions/Release.hs` (apply category filter in list handler)
- Modify: `backend/package.yaml`

**Why:** Powers the new "Live Releases" page; also lets the existing list endpoint filter by category.

- [ ] **Step 1: Implement `GET /releases/live`**

```haskell
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}

module Products.Autopilot.Mobile.Handlers.Live
    ( LiveReleasesResp (..)
    , LiveBackendRow (..)
    , LiveMobileRow (..)
    , liveReleasesH
    ) where

import Core.Auth.Protected (AuthedPerson)
import Core.Environment    (Flow, MonadFlow, withDb)
import Data.Aeson          (FromJSON, ToJSON)
import Data.Int            (Int32)
import Data.Text           (Text)
import Data.Time           (UTCTime)
import GHC.Generics        (Generic)

data LiveBackendRow = LiveBackendRow
    { appGroup     :: Text
    , service      :: Text
    , env          :: Text
    , liveVersion  :: Text
    , rolloutState :: Maybe Text
    , updatedAt    :: UTCTime
    } deriving (Generic, Show, ToJSON, FromJSON)

data LiveMobileRow = LiveMobileRow
    { app          :: Text
    , surface      :: Text
    , platform     :: Text
    , liveVersion  :: Text
    , versionCode  :: Maybe Int32
    , tagPushed    :: Maybe Text
    , releasedAt   :: UTCTime
    } deriving (Generic, Show, ToJSON, FromJSON)

data LiveReleasesResp = LiveReleasesResp
    { backend :: [LiveBackendRow]
    , mobile  :: [LiveMobileRow]
    } deriving (Generic, Show, ToJSON, FromJSON)

liveReleasesH :: AuthedPerson -> Maybe Text -> Flow LiveReleasesResp
liveReleasesH _ catFilter = do
    let want c = catFilter `elem` [Nothing, Just "all", Just c]
    bs <- if want "backend" then queryLiveBackend else pure []
    ms <- if want "mobile"  then queryLiveMobile  else pure []
    pure $ LiveReleasesResp { backend = bs, mobile = ms }

queryLiveBackend :: MonadFlow m => m [LiveBackendRow]
-- SELECT DISTINCT ON (app_group, service, env) ... FROM release_tracker
-- WHERE status='COMPLETED' AND category IN ('BackendService','BackendScheduler','BackendConfig')
-- ORDER BY app_group, service, env, end_time DESC
-- (Use raw SQL via beam's `runSelectReturningList . select $ ...` with appropriate ordering,
--  or fall back to a `Database.Beam.Postgres.Conduit.runQueryReturning` with raw SQL.)

queryLiveMobile :: MonadFlow m => m [LiveMobileRow]
-- SELECT DISTINCT ON (app_group, service, env) ... FROM release_tracker
-- WHERE status='COMPLETED' AND category='MobileBuild'
-- ORDER BY app_group, service, env, end_time DESC
-- For each row: extract tag_pushed and version_code from releaseContext JSON.
```

- [ ] **Step 2: Wire route**

```haskell
:<|> "releases" :> "live"
      :> QueryParam "category" Text
      :> Protected 'AP_RELEASE_VIEW
      :> Get '[JSON] LiveReleasesResp
```

- [ ] **Step 3: Add `?category=` to existing list endpoint**

In `backend/src/Products/Autopilot/Routes.hs`, find the `GET /releases` definition (probably uses `Capture` or `QueryParams`). Add:

```haskell
"releases"
  :> QueryParam "category" Text
  :> QueryParam "from" UTCTime
  :> QueryParam "to" UTCTime
  :> Protected 'AP_RELEASE_VIEW
  :> Get '[JSON] [ReleaseTracker]
```

In the corresponding handler in `Actions/Release.hs`, accept the new optional `Maybe Text` param and apply a `WHERE category = ?` filter when present.

- [ ] **Step 4: Compile**

```bash
sc-build
```

- [ ] **Step 5: Smoke test**

```bash
TOKEN=...
curl -s -H "Authorization: Bearer $TOKEN" "http://localhost:8012/releases?category=mobile"
curl -s -H "Authorization: Bearer $TOKEN" "http://localhost:8012/releases/live?category=all"
```

Expected: filter narrows the list; `/releases/live` returns shape with `backend: []` and `mobile: []` (or rows if any exist).

- [ ] **Step 6: Commit**

```bash
git add backend/src/Products/Autopilot/Mobile/Handlers/Live.hs \
        backend/src/Products/Autopilot/Mobile/Routes.hs \
        backend/src/Products/Autopilot/Routes.hs \
        backend/src/Products/Autopilot/Actions/Release.hs \
        backend/package.yaml
git commit -m "Add /releases/live endpoint and category filter on /releases"
```

---

## Phase 7 — RBAC + seed config

### Task 20: Update SQL seed with new perms, secret placeholders, and app catalog rows

**Files:**
- Modify: `backend/dev/sql-seed/system-control-seed.sql`

**Why:** Centralize the bootstrap so a fresh dev DB reset includes the mobile feature in a sensible default state (flag OFF, secrets empty, all apps present but `enabled=false`).

- [ ] **Step 1: Append seed fragments**

Open `backend/dev/sql-seed/system-control-seed.sql` and add at the bottom (or in the appropriate sections, matching the file's existing structure):

```sql
-- ---------------------------------------------------------------
-- Mobile releases (added 2026-05-11)
-- ---------------------------------------------------------------

-- Seed 10 customer Android apps (all disabled by default; admin enables per phase)
INSERT INTO app_catalog (name, surface, platform, github_repo, workflow_path, package_name, display_label, enabled)
VALUES
  ('Cumta',         'customer', 'android', 'nammayatri/ny-react-native', '.github/workflows/fastlane-android.yaml', 'in.mobility.cumta',                  'Cumta (Customer Android)',           false),
  ('NammaYatri',    'customer', 'android', 'nammayatri/ny-react-native', '.github/workflows/fastlane-android.yaml', 'in.juspay.nammayatri',               'Namma Yatri (Customer Android)',     false),
  ('ManaYatri',     'customer', 'android', 'nammayatri/ny-react-native', '.github/workflows/fastlane-android.yaml', 'in.mobility.manayatri',              'Mana Yatri (Customer Android)',      false),
  ('Yatri',         'customer', 'android', 'nammayatri/ny-react-native', '.github/workflows/fastlane-android.yaml', 'net.openkochi.yatri',                'Yatri (Customer Android)',           false),
  ('OdishaYatri',   'customer', 'android', 'nammayatri/ny-react-native', '.github/workflows/fastlane-android.yaml', 'in.mobility.odishayatri',            'Odisha Yatri (Customer Android)',    false),
  ('YatriSathi',    'customer', 'android', 'nammayatri/ny-react-native', '.github/workflows/fastlane-android.yaml', 'in.juspay.jatrisaathi',              'Yatri Sathi (Customer Android)',     false),
  ('KeralaSavaari', 'customer', 'android', 'nammayatri/ny-react-native', '.github/workflows/fastlane-android.yaml', 'in.mobility.keralasavaariconsumer',  'Kerala Savaari (Customer Android)',  false),
  ('Bridge',        'customer', 'android', 'nammayatri/ny-react-native', '.github/workflows/fastlane-android.yaml', 'com.mobility.bridge',                'Bridge (Customer Android)',          false),
  ('BharatTaxi',    'customer', 'android', 'nammayatri/ny-react-native', '.github/workflows/fastlane-android.yaml', 'in.mobility.bharatTaxi',             'Bharat Taxi (Customer Android)',     false),
  ('Lynx',          'customer', 'android', 'nammayatri/ny-react-native', '.github/workflows/fastlane-android.yaml', 'in.mobility.international',          'Lynx (Customer Android)',            false)
ON CONFLICT (name, surface, platform) DO NOTHING;

-- Runtime config: feature flag (default OFF) + poll cadence
INSERT INTO server_config (type, name, value, product, enabled, last_updated) VALUES
  ('flag', 'mobile_dispatch_enabled',  'false', 'autopilot', 0, now()),
  ('flag', 'mobile_run_poll_seconds',  '30',    'autopilot', 1, now())
ON CONFLICT DO NOTHING;

-- Secret placeholders (admin populates real values out of band)
INSERT INTO server_config (type, name, value, product, enabled, last_updated) VALUES
  ('secret', 'github_app_id',                     '', 'autopilot', 0, now()),
  ('secret', 'github_app_private_key',            '', 'autopilot', 0, now()),
  ('secret', 'github_app_installation_id',        '', 'autopilot', 0, now()),
  ('secret', 'play_console_service_account_json', '', 'autopilot', 0, now())
ON CONFLICT DO NOTHING;

-- Grant new perms on existing system roles
UPDATE sc_role
   SET permissions = array_append(permissions, 'MOBILE_DISPATCH')
 WHERE product_slug = 'autopilot' AND name IN ('Admin','Manager')
   AND NOT ('MOBILE_DISPATCH' = ANY(permissions));

UPDATE sc_role
   SET permissions = array_append(permissions, 'MOBILE_APP_MANAGE')
 WHERE product_slug = 'autopilot' AND name = 'Admin'
   AND NOT ('MOBILE_APP_MANAGE' = ANY(permissions));
```

(Note: permission text in `sc_role.permissions` follows the existing convention — strip the `AP_` prefix per `permissionToText`. Verify by `grep -E "permissions.*ARRAY" backend/dev/sql-seed/system-control-seed.sql` to see the existing format.)

- [ ] **Step 2: Reset DB and verify**

```bash
rm -rf .local/data/pg
sc-dev   # let it boot
# Then in another terminal:
psql "$SC_DATABASE_URL" -c "SELECT name, surface, platform, enabled FROM app_catalog ORDER BY name;"
psql "$SC_DATABASE_URL" -c "SELECT name, value, product FROM server_config WHERE name LIKE 'mobile_%' OR name LIKE 'github_%' OR name LIKE 'play_%';"
psql "$SC_DATABASE_URL" -c "SELECT name, permissions FROM sc_role WHERE product_slug='autopilot';"
```

Expected: 10 app_catalog rows, 6 server_config rows, Admin role has `MOBILE_DISPATCH` + `MOBILE_APP_MANAGE`, Manager has `MOBILE_DISPATCH`.

- [ ] **Step 3: Commit**

```bash
git add backend/dev/sql-seed/system-control-seed.sql
git commit -m "Seed mobile app catalog, perms, and config placeholders"
```

---

## Phase 8 — Frontend foundation

### Task 21: Frontend types, API client, and hooks for mobile

**Files:**
- Modify: `frontend/src/products/releases/types.ts`
- Modify: `frontend/src/products/releases/api.ts`
- Modify: `frontend/src/products/releases/hooks.ts`

**Why:** Type-safe access to the new endpoints from React.

- [ ] **Step 1: Add types**

In `types.ts`:

```ts
export type AppCatalogEntry = {
  id: number;
  name: string;
  surface: 'customer' | 'driver';
  platform: 'android' | 'ios';
  githubRepo: string;
  workflowPath: string;
  packageName: string | null;
  displayLabel: string | null;
  enabled: boolean;
  createdAt: string;
};

export type MobileDestination = 'GooglePlay' | 'Firebase';

export type CreateMobileReleasesItem = {
  appCatalogId: number;
  versionName: string | null;
  versionCode: number | null;
};

export type CreateMobileReleasesReq = {
  releaseGroupLabel?: string;
  changeLog: string;
  destination: MobileDestination;
  items: CreateMobileReleasesItem[];
};

export type CreateMobileReleasesResp = {
  releaseGroupId: string;
  releases: { id: string; appCatalogId: number; status: string }[];
};

export type DispatchInfo = {
  dispatchId: string;
  workflowPath: string;
  releaseIdsInDisp: string[];
  expectedRunUrl: string | null;
};

export type DispatchMobileReleasesResp = { dispatches: DispatchInfo[] };

export type VersionPreviewItem = {
  appCatalogId: number;
  nextVersionName?: string;
  nextVersionCode?: number;
  source?: string;
  err?: string;
};

export type LiveReleasesResp = {
  backend: {
    appGroup: string; service: string; env: string;
    liveVersion: string; rolloutState: string | null; updatedAt: string;
  }[];
  mobile: {
    app: string; surface: string; platform: string;
    liveVersion: string; versionCode: number | null; tagPushed: string | null; releasedAt: string;
  }[];
};
```

- [ ] **Step 2: Add API client methods**

In `api.ts`:

```ts
import { apiClient } from '../../lib/api-client';
import type {
  AppCatalogEntry, CreateMobileReleasesReq, CreateMobileReleasesResp,
  DispatchMobileReleasesResp, VersionPreviewItem, LiveReleasesResp,
} from './types';

export const mobileApi = {
  listApps:        () => apiClient.get<AppCatalogEntry[]>('/mobile/apps'),
  createApp:       (body: Partial<AppCatalogEntry>) => apiClient.post<AppCatalogEntry>('/mobile/apps', body),
  patchApp:        (id: number, body: Partial<AppCatalogEntry>) =>
                     apiClient.patch<AppCatalogEntry>(`/mobile/apps/${id}`, body),

  previewVersions: (appCatalogIds: number[]) =>
                     apiClient.post<{ previews: VersionPreviewItem[] }>('/mobile/versions/preview', { appCatalogIds }),

  createReleases:  (req: CreateMobileReleasesReq) =>
                     apiClient.post<CreateMobileReleasesResp>('/releases/mobile/create', req),

  dispatchReleases:(releaseIds: string[]) =>
                     apiClient.post<DispatchMobileReleasesResp>('/releases/mobile/dispatch', { releaseIds }),

  liveReleases:    (category: 'all' | 'backend' | 'mobile' = 'all') =>
                     apiClient.get<LiveReleasesResp>(`/releases/live?category=${category}`),
};
```

- [ ] **Step 3: Add React Query hooks**

In `hooks.ts`:

```ts
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { mobileApi } from './api';

export function useMobileApps() {
  return useQuery({ queryKey: ['mobile', 'apps'], queryFn: () => mobileApi.listApps() });
}

export function usePreviewVersions(appCatalogIds: number[]) {
  return useQuery({
    queryKey: ['mobile', 'versions', 'preview', appCatalogIds.sort().join(',')],
    queryFn: () => mobileApi.previewVersions(appCatalogIds),
    enabled: appCatalogIds.length > 0,
    staleTime: 60_000,
  });
}

export function useCreateMobileReleases() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: mobileApi.createReleases,
    onSuccess: () => qc.invalidateQueries({ queryKey: ['releases'] }),
  });
}

export function useDispatchMobileReleases() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: mobileApi.dispatchReleases,
    onSuccess: () => qc.invalidateQueries({ queryKey: ['releases'] }),
  });
}

export function useLiveReleases(category: 'all' | 'backend' | 'mobile' = 'all') {
  return useQuery({
    queryKey: ['releases', 'live', category],
    queryFn: () => mobileApi.liveReleases(category),
    refetchInterval: 10_000,
  });
}
```

- [ ] **Step 4: Verify TS compiles + dev server starts**

```bash
cd frontend && yarn tsc --noEmit
```

- [ ] **Step 5: Commit**

```bash
git add frontend/src/products/releases/types.ts \
        frontend/src/products/releases/api.ts \
        frontend/src/products/releases/hooks.ts
git commit -m "Add mobile types, API client, and hooks"
```

---

### Task 22: PRODUCT_REGISTRY — two dashboard tiles sharing the autopilot slug

**Files:**
- Modify: `frontend/src/products/registry.ts`

**Why:** Renders two dashboard tiles ("Backend Releases" and "Mobile Releases") for the same backend product, satisfying the user's "I want to see Mobile Releases at dashboard level too" requirement without splitting the backend product.

- [ ] **Step 1: Edit the registry**

```ts
import type { ProductDefinition } from './types';
import { ListRelease } from './pages/ListRelease';
import { CreateRelease } from './pages/CreateRelease';
import { ReleaseSummary } from './pages/ReleaseSummary';
import { LiveReleases } from './pages/LiveReleases';
import { CreateMobileRelease } from './pages/mobile/CreateMobileRelease';
import { ReleaseGroupDetail } from './pages/mobile/ReleaseGroupDetail';
import { MobileAppsAdmin } from './pages/mobile/MobileAppsAdmin';

const backendReleasesProduct: ProductDefinition = {
  slug: 'autopilot',
  label: 'Backend Releases',
  description: 'Microservice rollouts, VS edits, config maps',
  icon: 'Server',
  basePath: '/releases',
  defaultCategoryFilter: 'backend',
  viewPermission: 'RELEASE_VIEW',
  navItems: [
    { label: 'Releases',         path: '/releases',              icon: 'List' },
    { label: 'Create Release',   path: '/releases/new',          icon: 'Plus' },
    { label: 'Config Maps',      path: '/configmap',             icon: 'FileText' },
    { label: 'VS Editor',        path: '/vs-editor',             icon: 'Settings' },
    { label: 'Server Config',    path: '/configurations',        icon: 'Settings' },
  ],
  routes: [
    { path: '/releases',         component: ListRelease },
    { path: '/releases/new',     component: CreateRelease, permission: 'RELEASE_CREATE' },
    { path: '/releases/:id',     component: ReleaseSummary },
    { path: '/releases/live',    component: LiveReleases },
  ],
};

const mobileReleasesProduct: ProductDefinition = {
  slug: 'autopilot',                   // SAME backend slug, same RBAC
  label: 'Mobile Releases',
  description: 'React Native app releases via GitHub Actions',
  icon: 'Smartphone',
  basePath: '/releases',
  defaultCategoryFilter: 'mobile',
  viewPermission: 'RELEASE_VIEW',
  navItems: [
    { label: 'All Mobile Releases', path: '/releases?category=mobile', icon: 'List' },
    { label: 'New Mobile Release',  path: '/releases/mobile/new',      icon: 'Plus' },
    { label: 'Live Releases',       path: '/releases/live',            icon: 'Activity' },
    { label: 'Mobile Apps',         path: '/mobile/apps',              icon: 'Package',
                                     permission: 'MOBILE_APP_MANAGE' },
  ],
  routes: [
    { path: '/releases/mobile/new',                component: CreateMobileRelease, permission: 'RELEASE_CREATE' },
    { path: '/release-groups/:groupId',            component: ReleaseGroupDetail },
    { path: '/mobile/apps',                        component: MobileAppsAdmin,     permission: 'MOBILE_APP_MANAGE' },
  ],
};

export const PRODUCT_REGISTRY: ProductDefinition[] = [
  backendReleasesProduct,
  mobileReleasesProduct,
];
```

If `ProductDefinition` doesn't currently have a `defaultCategoryFilter` field, add it to its type:

```ts
// in frontend/src/products/types.ts (or wherever ProductDefinition lives)
export type ProductDefinition = {
  // ... existing fields ...
  defaultCategoryFilter?: 'backend' | 'mobile' | 'all';
};
```

The dashboard component reading from `PRODUCT_REGISTRY` should already iterate the array; it'll naturally render two tiles.

- [ ] **Step 2: Verify TS compiles**

```bash
cd frontend && yarn tsc --noEmit
```

(The new page imports won't resolve yet — that's fine; they're created in Tasks 23-26. Stub them with empty default exports if the typecheck blocks merging.)

Quick stubs in each `pages/...` file:

```ts
export function CreateMobileRelease() { return null; }
export function ReleaseGroupDetail() { return null; }
export function MobileAppsAdmin() { return null; }
export function LiveReleases() { return null; }
```

- [ ] **Step 3: Commit**

```bash
git add frontend/src/products/registry.ts frontend/src/products/types.ts \
        frontend/src/products/releases/pages/LiveReleases.tsx \
        frontend/src/products/releases/pages/mobile/{CreateMobileRelease,ReleaseGroupDetail,MobileAppsAdmin}.tsx
git commit -m "Register Mobile Releases as a second dashboard tile sharing autopilot slug"
```

---

## Phase 9 — Frontend pages

### Task 23: Extend ListRelease + ReleaseSummary for mobile

**Files:**
- Modify: `frontend/src/products/releases/pages/ListRelease.tsx`
- Modify: `frontend/src/products/releases/pages/ReleaseSummary.tsx`

**Why:** Make the existing pages category-aware so mobile releases show up properly when filtered.

- [ ] **Step 1: Add category filter chip to `ListRelease.tsx`**

Find the existing list component. Add state for the category filter (initialized from URL `?category=` or `defaultCategoryFilter` prop), pass `category` as an API query param, and render a chip group above the table:

```tsx
const [searchParams, setSearchParams] = useSearchParams();
const category = (searchParams.get('category') as 'all' | 'backend' | 'mobile') || 'all';

const setCategory = (c: typeof category) => {
  if (c === 'all') searchParams.delete('category');
  else searchParams.set('category', c);
  setSearchParams(searchParams);
};

// in JSX:
<div className="flex gap-2 mb-4">
  {(['all','backend','mobile'] as const).map(c => (
    <button key={c}
      className={c === category ? 'chip-active' : 'chip'}
      onClick={() => setCategory(c)}>
      {c === 'all' ? 'All' : c === 'backend' ? 'Backend' : 'Mobile'}
    </button>
  ))}
</div>
```

Update the table rendering to handle mobile rows: the existing column for "Service" can show `surface` for mobile rows; add a new "Category" column with an icon.

- [ ] **Step 2: Add a mobile-specific section to `ReleaseSummary.tsx`**

Detect category by reading the release's `category` field; if `MobileBuild`, render a sub-component:

```tsx
{release.category === 'MobileBuild' && (
  <MobileReleaseDetailSection release={release} />
)}
```

Where `MobileReleaseDetailSection` reads `releaseContext` for `tagPushed`, `matrixJobName`, looks at `external_run_id` for the GH run URL, and renders:
- GH workflow run link
- Matrix job status badge + duration
- Tag push confirmation
- A small timeline of `MobileBuildWFStatus` derived from event log entries

The existing event log component (probably `<EventLog releaseId={...} />`) renders unchanged — the new event labels (`GH_DISPATCHED`, `MATRIX_JOB_UPDATED`, etc.) flow through naturally.

- [ ] **Step 3: Verify TS + run dev server**

```bash
cd frontend && yarn tsc --noEmit && yarn dev
```

Click around: list page should show category chip, dispatch a release, view the summary, see the mobile section.

- [ ] **Step 4: Commit**

```bash
git add frontend/src/products/releases/pages/ListRelease.tsx \
        frontend/src/products/releases/pages/ReleaseSummary.tsx
git commit -m "Extend ListRelease + ReleaseSummary for mobile category"
```

---

### Task 24: Build `CreateMobileRelease.tsx`

**Files:**
- Modify: `frontend/src/products/releases/pages/mobile/CreateMobileRelease.tsx`

**Why:** The primary user-facing UI for the new feature. Multi-select apps, version preview, change log, dispatch.

- [ ] **Step 1: Implement the page**

```tsx
import { useState, useMemo } from 'react';
import { useNavigate } from 'react-router-dom';
import { useMobileApps, usePreviewVersions, useCreateMobileReleases } from '../../hooks';
import type { CreateMobileReleasesItem, MobileDestination } from '../../types';

export function CreateMobileRelease() {
  const nav = useNavigate();
  const { data: apps = [] } = useMobileApps();
  const enabled = useMemo(() => apps.filter(a => a.enabled), [apps]);

  const [selectedIds, setSelectedIds]   = useState<number[]>([]);
  const [overrides, setOverrides]       = useState<Record<number, { name?: string; code?: number }>>({});
  const [changeLog, setChangeLog]       = useState('');
  const [destination, setDestination]   = useState<MobileDestination>('GooglePlay');

  const { data: previewResp } = usePreviewVersions(selectedIds);
  const previews = previewResp?.previews ?? [];

  const create = useCreateMobileReleases();

  const submit = async (alsoApprove: boolean) => {
    const items: CreateMobileReleasesItem[] = selectedIds.map(id => ({
      appCatalogId: id,
      versionName:  overrides[id]?.name ?? null,
      versionCode:  overrides[id]?.code ?? null,
    }));
    const resp = await create.mutateAsync({ changeLog, destination, items });
    // Optionally call /releases/:id/approve for each created id if alsoApprove === true
    nav(`/release-groups/${resp.releaseGroupId}`);
  };

  return (
    <div className="space-y-6">
      <h1>New Mobile Release</h1>
      <Section title="Apps">
        {enabled.map(app => (
          <label key={app.id} className="block">
            <input type="checkbox"
              checked={selectedIds.includes(app.id)}
              onChange={e => setSelectedIds(prev =>
                e.target.checked ? [...prev, app.id] : prev.filter(x => x !== app.id))} />
            {' '}{app.displayLabel ?? `${app.name} (${app.surface} ${app.platform})`}
          </label>
        ))}
      </Section>

      <Section title="Versions">
        {selectedIds.map(id => {
          const app = apps.find(a => a.id === id);
          const pv = previews.find(p => p.appCatalogId === id);
          return (
            <div key={id} className="grid grid-cols-3 gap-2 items-center">
              <span>{app?.name}</span>
              <input
                placeholder={pv?.nextVersionName ?? 'auto'}
                value={overrides[id]?.name ?? ''}
                onChange={e => setOverrides(prev => ({ ...prev, [id]: { ...prev[id], name: e.target.value } }))} />
              <input
                placeholder={pv?.nextVersionCode?.toString() ?? 'auto'}
                value={overrides[id]?.code?.toString() ?? ''}
                onChange={e => setOverrides(prev => ({ ...prev, [id]: { ...prev[id], code: Number(e.target.value) || undefined } }))} />
              {pv?.err && <span className="text-yellow-600 col-span-3">{pv.err}</span>}
            </div>
          );
        })}
      </Section>

      <Section title="Change log">
        <textarea value={changeLog} onChange={e => setChangeLog(e.target.value)} rows={4} className="w-full" />
      </Section>

      <Section title="Destination">
        <select value={destination} onChange={e => setDestination(e.target.value as MobileDestination)}>
          <option value="GooglePlay">Google Play</option>
          <option value="Firebase">Firebase</option>
        </select>
      </Section>

      <div className="flex gap-2">
        <button onClick={() => submit(false)} disabled={selectedIds.length === 0}>Save as draft</button>
        <button onClick={() => submit(true)}  disabled={selectedIds.length === 0}>Save & approve</button>
      </div>
    </div>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section>
      <h2 className="text-lg font-semibold mb-2">{title}</h2>
      {children}
    </section>
  );
}
```

(Replace inline className styling with whatever the existing `frontend/src/shared/ui/` components offer — Card, Input, Button, etc.)

- [ ] **Step 2: Verify**

```bash
cd frontend && yarn tsc --noEmit && yarn dev
```

Navigate to `/releases/mobile/new`. With backend running but no apps `enabled=true`, the list will be empty — toggle one in DB to test.

- [ ] **Step 3: Commit**

```bash
git add frontend/src/products/releases/pages/mobile/CreateMobileRelease.tsx
git commit -m "Build CreateMobileRelease page"
```

---

### Task 25: Build `ReleaseGroupDetail.tsx` and `LiveReleases.tsx`

**Files:**
- Modify: `frontend/src/products/releases/pages/mobile/ReleaseGroupDetail.tsx`
- Modify: `frontend/src/products/releases/pages/LiveReleases.tsx`

- [ ] **Step 1: ReleaseGroupDetail**

```tsx
import { useParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { apiClient } from '../../../../lib/api-client';
import { useDispatchMobileReleases } from '../../hooks';

export function ReleaseGroupDetail() {
  const { groupId } = useParams<{ groupId: string }>();
  const { data: rows = [] } = useQuery({
    queryKey: ['release-group', groupId],
    // The backend doesn't currently have a GET /release-groups/:id endpoint;
    // this fetches all mobile releases and filters client-side by releaseContext.release_group_id.
    // (Add a server-side endpoint later if this query becomes hot.)
    queryFn: () => apiClient.get<any[]>(`/releases?category=mobile`),
    refetchInterval: 5_000,
    select: (data) => data.filter((r: any) => r.releaseContext?.release_group_id === groupId),
  });

  const dispatchMut = useDispatchMobileReleases();
  const [selected, setSelected] = useState<string[]>([]);

  return (
    <div>
      <h1>Release Group {groupId}</h1>
      <table className="w-full">
        <thead>
          <tr><th></th><th>App</th><th>Surface</th><th>Platform</th><th>Version</th><th>Status</th></tr>
        </thead>
        <tbody>
          {rows.map(r => (
            <tr key={r.id}>
              <td>
                <input type="checkbox"
                  checked={selected.includes(r.id)}
                  onChange={e => setSelected(p => e.target.checked ? [...p, r.id] : p.filter(x => x !== r.id))} />
              </td>
              <td>{r.appGroup}</td>
              <td>{r.service}</td>
              <td>{r.env}</td>
              <td>{r.newVersion || 'auto'}</td>
              <td>{r.status}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <div className="flex gap-2 mt-4">
        <button onClick={() => dispatchMut.mutate(selected)}
                disabled={selected.length === 0}>Dispatch selected</button>
      </div>
    </div>
  );
}
```

- [ ] **Step 2: LiveReleases**

```tsx
import { useState } from 'react';
import { useLiveReleases } from '../hooks';

export function LiveReleases() {
  const [cat, setCat] = useState<'all'|'backend'|'mobile'>('all');
  const { data } = useLiveReleases(cat);

  return (
    <div className="space-y-6">
      <div className="flex gap-2">
        {(['all','backend','mobile'] as const).map(c => (
          <button key={c} className={c === cat ? 'chip-active' : 'chip'} onClick={() => setCat(c)}>
            {c}
          </button>
        ))}
      </div>

      <section>
        <h2 className="text-lg font-semibold">Backend</h2>
        <table className="w-full">
          <thead><tr><th>App group</th><th>Service</th><th>Env</th><th>Live ver.</th><th>Rollout</th><th>Updated</th></tr></thead>
          <tbody>
            {(data?.backend ?? []).map((r, i) => (
              <tr key={i}>
                <td>{r.appGroup}</td><td>{r.service}</td><td>{r.env}</td>
                <td>{r.liveVersion}</td><td>{r.rolloutState ?? '—'}</td><td>{r.updatedAt}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>

      <section>
        <h2 className="text-lg font-semibold">Mobile</h2>
        <table className="w-full">
          <thead><tr><th>App</th><th>Surface</th><th>Platform</th><th>Live ver.</th><th>Tag</th><th>Released</th></tr></thead>
          <tbody>
            {(data?.mobile ?? []).map((r, i) => (
              <tr key={i}>
                <td>{r.app}</td><td>{r.surface}</td><td>{r.platform}</td>
                <td>{r.liveVersion}{r.versionCode ? `+${r.versionCode}` : ''}</td>
                <td>{r.tagPushed ?? '—'}</td><td>{r.releasedAt}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>
    </div>
  );
}
```

- [ ] **Step 3: Verify**

```bash
cd frontend && yarn tsc --noEmit && yarn dev
```

- [ ] **Step 4: Commit**

```bash
git add frontend/src/products/releases/pages/mobile/ReleaseGroupDetail.tsx \
        frontend/src/products/releases/pages/LiveReleases.tsx
git commit -m "Build ReleaseGroupDetail and LiveReleases pages"
```

---

### Task 26: Build `MobileAppsAdmin.tsx`

**Files:**
- Modify: `frontend/src/products/releases/pages/mobile/MobileAppsAdmin.tsx`

- [ ] **Step 1: Implement**

```tsx
import { useState } from 'react';
import { useMobileApps } from '../../hooks';
import { mobileApi } from '../../api';
import { useQueryClient } from '@tanstack/react-query';

export function MobileAppsAdmin() {
  const { data: apps = [] } = useMobileApps();
  const qc = useQueryClient();

  const togglEnabled = async (id: number, enabled: boolean) => {
    await mobileApi.patchApp(id, { enabled });
    qc.invalidateQueries({ queryKey: ['mobile', 'apps'] });
  };

  return (
    <div>
      <h1>Mobile Apps</h1>
      <table className="w-full">
        <thead>
          <tr><th>Name</th><th>Surface</th><th>Platform</th><th>Repo</th><th>Workflow</th><th>Package</th><th>Enabled</th></tr>
        </thead>
        <tbody>
          {apps.map(a => (
            <tr key={a.id}>
              <td>{a.name}</td>
              <td>{a.surface}</td>
              <td>{a.platform}</td>
              <td>{a.githubRepo}</td>
              <td>{a.workflowPath}</td>
              <td>{a.packageName}</td>
              <td>
                <input type="checkbox" checked={a.enabled} onChange={e => togglEnabled(a.id, e.target.checked)} />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
```

- [ ] **Step 2: Verify + commit**

```bash
cd frontend && yarn tsc --noEmit
git add frontend/src/products/releases/pages/mobile/MobileAppsAdmin.tsx
git commit -m "Build MobileAppsAdmin page"
```

---

## Phase 10 — End-to-end verification

### Task 27: Local dev verification with sandbox repo

**Files:** none (manual verification)

**Why:** Validates the full loop end-to-end. Cannot be automated for MVP because real GitHub Actions runs are non-deterministic.

- [ ] **Step 1: Set up a sandbox GitHub repo**

Create a tiny test repo (e.g., `<your-username>/scc-mobile-test`) with one workflow file `.github/workflows/test-mobile.yaml`:

```yaml
name: Test Mobile Workflow
on:
  workflow_dispatch:
    inputs:
      selected_apps: { description: 'apps', required: false }
      version_name:  { description: 'version', required: false }
      version_code:  { description: 'code',    required: false }
      change_log:    { description: 'log',     required: true }
      payload:       { description: 'payload', required: false }
      notify_slack:  { description: 'slack',   type: boolean, default: false }
jobs:
  TestApp-Release:
    runs-on: ubuntu-latest
    steps:
      - run: echo "Built TestApp ${{ inputs.version_name }} (${{ inputs.version_code }})"
      - name: Push tag
        run: |
          git config user.name "GitHub Actions Bot"
          git config user.email "actions@github.com"
          git tag -a "testapp/prod/android/v${{ inputs.version_name }}+${{ inputs.version_code }}" -m "release"
          git push origin --tags
```

- [ ] **Step 2: Install GitHub App on the sandbox repo**

In the GitHub UI: Settings → Developer settings → GitHub Apps → New GitHub App. Permissions: `actions:write`, `metadata:read`, `contents:write`. Generate a private key. Install it on the sandbox repo. Note the App ID and installation ID.

- [ ] **Step 3: Configure SCC secrets**

```sql
UPDATE server_config SET value='<APP_ID>'           WHERE name='github_app_id';
UPDATE server_config SET value='<PRIVATE_KEY_PEM>'  WHERE name='github_app_private_key';
UPDATE server_config SET value='<INSTALLATION_ID>'  WHERE name='github_app_installation_id';
UPDATE server_config SET value='true'               WHERE name='mobile_dispatch_enabled';
```

- [ ] **Step 4: Add a test app entry pointing at the sandbox**

Via curl or direct SQL:

```sql
INSERT INTO app_catalog (name, surface, platform, github_repo, workflow_path, package_name, display_label, enabled)
VALUES ('TestApp', 'customer', 'android', '<your-username>/scc-mobile-test',
        '.github/workflows/test-mobile.yaml', 'com.example.test', 'Test App', true);
```

- [ ] **Step 5: Drive the full flow from the UI**

1. Open the dashboard. Confirm "Mobile Releases" tile shows.
2. Navigate to "New Mobile Release". TestApp should appear.
3. Select TestApp; verify version preview tries to call Play API (will return `play_api_unauthorized` error since no Play creds — that's fine, fill version manually like `1.0.0` / `1`).
4. Enter changelog "smoke test" and click "Save & approve".
5. From the Release Group page, click "Dispatch selected".
6. Within ~30s, the row's status transitions from CREATED → INPROGRESS.
7. Open GitHub Actions UI for the sandbox repo — observe the run started.
8. Within another ~30s, the matrix job status updates in SCC (`matrix_job_status: in_progress` then `success`).
9. After workflow completes (~minute on github-hosted runner), the tag is pushed and SCC observes it.
10. Status transitions to COMPLETED. Visit `/releases/live` — TestApp should appear in the Mobile section.

- [ ] **Step 6: Capture issues + fix**

Any issue surfaced in this E2E run gets a follow-up commit on this branch. Common issues:
- `extractNonce` fallback logic doesn't match correctly → use the actor + created_at fallback noted in Task 13.
- Tag prefix derivation wrong for an app whose name has special chars → adjust the `appSeg` normalization in stage 6.
- Polling too aggressive → tune `mobile_run_poll_seconds` upward.

- [ ] **Step 7: Document successful E2E in CHANGELOG or commit message**

```bash
git commit --allow-empty -m "Verified mobile release E2E with sandbox repo"
```

---

## Phase 11 — iOS extension (App Store Connect-driven version resolution)

> Author of Phase 11: **shivendra02shah@gmail.com**, 2026-05-13.
> All Android tasks (1–27) remain unchanged. Each iOS task is a small, isolated diff against the shipped Android implementation.
>
> **Design choice:** SCC **does not wait for Apple's TestFlight processing**, neither inside an SCC stage nor by dictating fastlane flags to the iOS GH workflow. SCC dispatches whatever workflow `app_catalog.workflow_path` points to, observes the matrix job + pushed tag, and stops. iOS `MBCompleted` therefore means "uploaded to ASC, Apple processing pending" — different from Android's "live on Play." Trade-off documented in spec §2 iOS-4. Consequence: **no new `MobileBuildWFStatus` variant, no new workflow stage, no SCC-side polling, no constraint on the mobile team's workflow.**

### Task 28: Append iOS additions to `0011-mobile-releases.sql` (in place)

**Files:**
- Modify: `backend/dev/migrations/system-control/0011-mobile-releases.sql` (append iOS column + iOS catalog seed at the bottom — do NOT create `0012-*.sql`)
- Modify: `backend/dev/sql-seed/system-control-seed.sql` (add 3 ASC secret placeholders)

**Why edit in place instead of creating `0012-ios-extension.sql`:** the SCC migration runner (see `flake.nix:95-99`) **re-applies every `.sql` file in `dev/migrations/system-control/` on every startup**, with `ON_ERROR_STOP=0`. There's no migration-tracking table, no checksums. Every statement is expected to be idempotent (`IF NOT EXISTS`, `ON CONFLICT DO NOTHING`). This means:

- Editing `0011` in place is safe — every dev's next `sc-dev` startup re-runs the whole file, picks up the new statements (existing ones no-op).
- A separate `0012-ios-extension.sql` would work too, but adds a file for no semantic gain — "mobile releases" is one conceptual unit.
- The Android catalog seed already lives inline in `0011` (it's not in `system-control-seed.sql`, because seed runs before migrations). The iOS catalog seed belongs in the same place for the same reason.

ASC secrets, on the other hand, go in `system-control-seed.sql` — consistent with where `github_app_*` and `play_console_service_account_json` rows already live (lines 207–240).

- [ ] **Step 1: Append iOS block to `0011-mobile-releases.sql`** (see the full SQL in spec §8.3 block). Layout:
  - The existing Android `ALTER TABLE` + `CREATE INDEX` + 10-row INSERT stays at the top, unchanged.
  - Below it, add 10 iOS rows with `platform='ios'`, `workflow_path='.github/workflows/fastlane.yaml'` (note: real filename is `fastlane.yaml`, not `fastlane-ios.yaml`), `package_name=<bundle_id>`, `enabled=false`, all guarded by `ON CONFLICT (name, surface, platform) DO NOTHING`. **No new column.** ASC numeric app id is resolved at runtime in `Versioning/Apple.hs` via bundle id lookup.

- [ ] **Step 2: Append ASC secret placeholders** to `backend/dev/sql-seed/system-control-seed.sql`, alongside the existing mobile section (line 207+):

```sql
INSERT INTO server_config (type, name, value, product, enabled, last_updated) VALUES
  ('secret', 'app_store_connect_issuer_id',      '', 'autopilot', 0, now()),
  ('secret', 'app_store_connect_key_id',         '', 'autopilot', 0, now()),
  ('secret', 'app_store_connect_private_key_p8', '', 'autopilot', 0, now())
ON CONFLICT DO NOTHING;
```

- [ ] **Step 3: Apply locally — NO RESET NEEDED**

```bash
sc-dev   # the runner re-applies 0011 on startup; you'll see "[migrate] 0011-mobile-releases.sql" again
# Ctrl+C once it logs "[db-init] done"
```

Resetting (`rm -rf .local/data/pg`) is only needed if you're worried about pre-existing inconsistent state. For a clean development cycle it's optional.

- [ ] **Step 4: Verify**

```bash
psql "$SC_DATABASE_URL" -c "SELECT name, type, enabled FROM server_config WHERE name LIKE 'app_store_connect_%';"  # expect 3 rows, all enabled=0 initially
psql "$SC_DATABASE_URL" -c "SELECT COUNT(*) FROM app_catalog WHERE platform='ios';"   # expect 10
psql "$SC_DATABASE_URL" -c "SELECT name, package_name FROM app_catalog WHERE platform='ios' LIMIT 3;"  # bundle ids populated
```

> **Why the in-place edit is safe in *this* repo and not in others:** SCC's migration runner is a `for f in *.sql; do psql -f "$f"; done` loop — there's no `schema_migrations` table or checksum. Migration files are treated as **idempotent seed scripts that re-run every startup**, not as the immutable append-only history that Flyway / Liquibase / Alembic enforce. The "never edit a shipped migration" rule from those tools doesn't apply here.

### Task 29: Rename Versioning.hs → Versioning/Play.hs (Android code move)

**Files:**
- Rename: `backend/src/Products/Autopilot/Mobile/Versioning.hs` → `backend/src/Products/Autopilot/Mobile/Versioning/Play.hs`
- Update: all imports of `Products.Autopilot.Mobile.Versioning` (call sites are `Mobile/Workflow.hs` and `Mobile/Handlers/Versions.hs`).
- Rename the module declaration `module Products.Autopilot.Mobile.Versioning` → `module Products.Autopilot.Mobile.Versioning.Play`.

**Why:** Makes room for a thin dispatcher `Versioning.hs` (Task 30) and a sibling `Versioning/Apple.hs` (Task 30). Pure mechanical rename — **no logic changes**.

- [ ] **Step 1:** Move the file, update the module declaration.
- [ ] **Step 2:** Update the two call sites' imports (`import qualified Products.Autopilot.Mobile.Versioning as V` → `import qualified Products.Autopilot.Mobile.Versioning.Play as V` for now — Task 30 replaces this with the dispatcher).
- [ ] **Step 3:** `sc-build && sc-test` — must remain green. The Android unit tests should pass unchanged.
- [ ] **Step 4:** Commit: `Move Versioning.hs to Versioning/Play.hs (no logic changes)` — one-commit refactor lets git track the rename cleanly.

### Task 30: Versioning dispatcher + Apple version-resolution client (auth inlined)

**Files:**
- Create: `backend/src/Products/Autopilot/Mobile/Versioning/Apple.hs`
- Create (thin re-write): `backend/src/Products/Autopilot/Mobile/Versioning.hs` — the dispatcher.
- Modify: `backend/package.yaml` + `backend/scc.cabal` — expose `cryptonite`, `asn1-encoding`, `asn1-types`, `base64-bytestring`, `memory` to the lib's `build-depends`. All five are already in the nix env (transitively pulled in by `Web.JWT` / `http-client-tls`); we just need them explicitly so the new module can import them. **No new package added to the dep tree.**

**Why:** Single dispatch point so callers don't branch on platform. Apple client mirrors **the full shape of `Versioning/Play.hs`** — creds loader, JWT signer, and API calls all live in **one file**, matching the precedent set by Play. No separate `Auth.hs` (matching Play, *not* `Github/Auth.hs`).

**Apple.hs shape (everything inline):**

```haskell
module Products.Autopilot.Mobile.Versioning.Apple
  ( -- pure
    computeNextIosVersion
    -- IO
  , AscError (..)
  , AscCreds (..)
  , loadAscCreds         -- reads 3 server_config rows
  , fetchAscVersions     -- :: AscCreds -> Text {- asc_app_id -} -> IO (Either AscError (Maybe Text, Maybe Int))
  , resolve              -- :: MonadFlow m => AppCatalog -> m (Either Text (Text, Int))
                         --    the dispatcher-shaped entry point
  ) where

-- ES256 signing built directly on cryptonite + asn1-encoding (Web.JWT
-- doesn't expose EC private keys). PKCS#8 .p8 parsing inlined here.
import qualified Crypto.PubKey.ECC.ECDSA as ECDSA
import qualified Crypto.PubKey.ECC.Types as ECC
import Crypto.Hash.Algorithms (SHA256 (..))
import Data.ASN1.BinaryEncoding (DER (..))
import Data.ASN1.Encoding (decodeASN1')
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Base64.URL as B64U

ascBase = "https://api.appstoreconnect.apple.com"

-- Module layout (matches Versioning/Play.hs section-by-section):
--   1. Pure algorithm   — computeNextIosVersion
--   2. Creds + errors   — AscCreds, AscError, loadAscCreds
--   3. JWT minter       — mintAscToken inline (NOT a separate module)
--      • ES256 signing of header { alg="ES256", kid=ascKeyId, typ="JWT" }
--        — built on cryptonite's Crypto.PubKey.ECC.ECDSA (RFC 5915 / FIPS 186)
--        with manual ASN.1 → raw R||S conversion for the JWS wire format
--        (RFC 7515 §3.4). The PKCS#8 .p8 parser uses asn1-encoding + a small
--        hand-rolled walker for the PrivateKeyInfo SEQUENCE shape.
--      • payload { iss=ascIssuerId, iat, exp=iat+20min, aud="appstoreconnect-v1" }
--      • returns Text — used directly as the bearer token (no OAuth exchange step)
--   4. API client       — fetchAscVersions, calling the two endpoints below
--   5. Dispatcher entry — resolve :: AppCatalog -> m (Either Text (Text, Int))

-- Endpoints (version resolution only — SCC doesn't poll ASC for build state):
-- GET /v1/apps/:id/preReleaseVersions  (TestFlight)
-- GET /v1/apps/:id/appStoreVersions    (production)
```

> **No token caching for v1.** Each ASC call mints its own JWT. ES256 signing is microseconds; ASC version-resolution calls happen ≤10 times per release row (once at Stage 1 + once per `versions/preview` request), so the cost is negligible. If iOS volume ever justifies caching, promote this to its own `Apple/Auth.hs` with an IORef — 10-min refactor.

**Versioning.hs (dispatcher) shape:**

```haskell
module Products.Autopilot.Mobile.Versioning
  ( resolveNextVersion
  , module Products.Autopilot.Mobile.Versioning.Play   -- legacy re-exports
  , module Products.Autopilot.Mobile.Versioning.Apple
  ) where

import Products.Autopilot.Mobile.Versioning.Play  hiding (resolve)
import Products.Autopilot.Mobile.Versioning.Apple hiding (resolve)
import qualified Products.Autopilot.Mobile.Versioning.Play  as P
import qualified Products.Autopilot.Mobile.Versioning.Apple as A

resolveNextVersion :: MonadFlow m => AppCatalog -> m (Either Text (Text, Int))
resolveNextVersion ac = case acPlatform ac of
  "android" -> P.resolve ac
  "ios"     -> A.resolve ac
  other     -> pure (Left ("unsupported platform: " <> other))
```

- [ ] **Step 1: TDD `computeNextIosVersion`** — pure function. Test cases:
  - Production = `2.5.0`, TestFlight build = `42` → next = `(2.5.0, 43)` (patch bump only when production already shipped this version).
  - Production = `2.5.0`, no TestFlight → `(2.5.1, 1)`.
  - No production yet, no TestFlight → `(1.0.0, 1)`.

- [ ] **Step 2: Inline JWT signer** in `Versioning/Apple.hs`. Mirror the layout of Play's section "JWT minting + OAuth exchange" (lines ~203–253 of today's `Versioning.hs`). Differences from Play:
  - Algorithm: ES256 (Play uses RS256).
  - Header: include `kid` (Play does not).
  - No OAuth exchange — the signed JWT *is* the bearer token.
  - Audience: `"appstoreconnect-v1"` (Play uses `"https://oauth2.googleapis.com/token"`).

  Unit test in `backend/test/Main.hs`: sign with a fixture `.p8` (generate once via `openssl ecparam -name prime256v1 -genkey -noout -out test.p8`), decode the JWT (no signature verify), assert header `alg=ES256` + `kid` set, payload `iss` + `aud="appstoreconnect-v1"` + `exp ≤ now+20m`.

- [ ] **Step 3: `loadAscCreds`** reads the three `server_config` rows (`type='secret'`, names `app_store_connect_issuer_id` / `..._key_id` / `..._private_key_p8`). Returns `Nothing` if any is empty. Matches `loadPlayCreds`'s shape exactly.

- [ ] **Step 4: Implement the two ASC HTTP calls** using `Core/Http/Client.hs`. Bearer token = the inline-minted JWT. Decode JSON with `aeson`.

- [ ] **Step 5: Wire retry** via the existing retry helper. 3 retries with backoff; on terminal HTTP fail return `Left AscError`.

- [ ] **Step 6: Define a `VersionResolution` sum type** in `Versioning.hs` so the dispatcher signature is honest:

```haskell
data VersionResolution
  = AndroidVersion { vName :: Text, vCode :: Int }   -- two-field, matches Play's existing tuple
  | IosVersion     { vNumber :: Text }                -- single field, matches Apple convention
  deriving (Eq, Show, Generic)

resolveNextVersion :: MonadFlow m => AppCatalog -> m (Either Text VersionResolution)
```

`Apple.resolve` returns `IosVersion`, `Play.resolve` returns `AndroidVersion`. Callers pattern-match.

- [ ] **Step 7: Extract a `Play.resolve` helper in `Versioning/Play.hs`** with shape `AppCatalog -> m (Either Text VersionResolution)` returning `AndroidVersion`. Existing Play body delegates to this new helper. **No logic changes.**

- [ ] **Step 8: Write the dispatcher** in the new top-level `Versioning.hs`.

- [ ] **Step 9: ASC numeric-app-id lookup** in `Apple.resolve`: call `GET /v1/apps?filter[bundleId]=<package_name>` (mirrors `fastlane.yaml:304-312`), take `data[0].id` as the ASC app id, then call `GET /v1/apps/:id/preReleaseVersions` to find the latest TestFlight build. Return `Left "asc_app_not_found"` if the bundle lookup is empty.

- [ ] **Step 10: Table-driven dispatcher test** in `backend/test/Main.hs`:
  - `(platform="android", …)` → returns `AndroidVersion { vName, vCode }`.
  - `(platform="ios", …)` → returns `IosVersion { vNumber }`.
  - `(platform="windows", …)` → returns `Left "unsupported platform: windows"`.

- [ ] **Step 11: `sc-build && sc-test`** should pass.

### Task 31: Extend `MobileDestination` + update `execResolveVersion` / `execDispatchWorkflow` / `previewVersionsH`

**Files:**
- Modify: `backend/src/Products/Autopilot/Mobile/Types.hs` (extend the ADT)
- Modify: `backend/src/Products/Autopilot/Mobile/Workflow.hs` (both Stage 1 and Stage 3)
- Modify: `backend/src/Products/Autopilot/Mobile/Handlers/Versions.hs`

**Why:** Three call sites need to be platform-aware now. Stage 1 (`execResolveVersion`) writes the resolved version to the tracker. Stage 3 (`execDispatchWorkflow`) sends a different `inputs` shape per platform. `previewVersionsH` returns a different response shape per platform. Plus a small ADT extension so iOS callers have correct `destination` values to pass through the create API (currently the field is required and only accepts Android labels).

#### Step 0 — Extend `MobileDestination` (preparatory)

The destination is metadata only — neither GH workflow reads it (verified by grep). But `CreateMobileReleasesReq.destination` requires it on every create, so iOS callers need real values to pass.

```haskell
-- backend/src/Products/Autopilot/Mobile/Types.hs
data MobileDestination
  = MBGooglePlay      -- Android, production track  (existing)
  | MBFirebase        -- Android, App Distribution  (existing)
  | MBTestFlight      -- NEW — iOS beta channel
  | MBAppStore        -- NEW — iOS production (App Store)
  deriving (Eq, Show, Read, Generic, Enum, Bounded)

-- ToJSON / FromJSON instances: "TestFlight" / "AppStore"
```

- [ ] **Edit the ADT, update JSON instances.** Then `sc-build` — the compiler will flag every `case` on `MobileDestination` that is now non-exhaustive. Likely sites:
  - `Mobile/Types.hs` (JSON instances)
  - `Mobile/Handlers/Release.hs` (the `destination` field on `CreateMobileReleasesReq`)
  - Frontend `types.ts` mirror (Task 32 step 1)
- [ ] **Round-trip test** in `backend/test/Main.hs` — JSON encode/decode each new variant: `"TestFlight"` and `"AppStore"`.
- [ ] **Note:** the workflow_dispatch payload does NOT include `destination`. The field travels only in SCC's internal `releaseContext` JSON for audit/UI purposes.

#### Step 1 — `execResolveVersion` (Stage 1)

```haskell
execResolveVersion = mobileStage "ResolveVersion" $ do
  rs <- gets id
  let rt = releaseTracker rs
  ac <- appCatalogForRow rt
  res <- Versioning.resolveNextVersion ac
  case res of
    Right (AndroidVersion name code) -> do
      persistAndroidVersion rt name code      -- existing path (Android = two fields)
      setMbWfStatus MBVersionResolved
      pure StageDone
    Right (IosVersion number) -> do
      persistIosVersion rt number             -- NEW: write only newVersion = version_number
      setMbWfStatus MBVersionResolved          -- (build_number is filled in later from the tag)
      pure StageDone
    Left err -> abort err
```

For iOS, write `releaseTracker.newVersion = version_number` and leave `mbContext.versionCode` unset (the workflow's `fastlane fetch_build_number` resolves the build number; SCC reads it from the pushed tag in Stage 6 `ConfirmTag`).

#### Step 2 — `execDispatchWorkflow` (Stage 3) — platform-aware `inputs`

```haskell
execDispatchWorkflow = mobileStage "DispatchWorkflow" $ do
  rs <- gets id
  let rt = releaseTracker rs
  ac <- appCatalogForRow rt
  let dispatchInputs = case acPlatform ac of
        "android" -> object
          [ "selected_apps" .= csvOfSelectedApps rs
          , "version_name"  .= (newVersion rt)        -- two-field Android shape
          , "version_code"  .= (versionCode (mbContext (targetState rs)))
          , "change_log"    .= (changeLog (mbContext (targetState rs)))
          , "payload"       .= object ["scc_dispatch_nonce" .= nonce]
          ]
        "ios" -> object
          [ "selected_apps"  .= csvOfSelectedApps rs
          , "version_number" .= (newVersion rt)         -- single-field iOS shape
          , "change_log"     .= (changeLog (mbContext (targetState rs)))
          , "payload"        .= object ["scc_dispatch_nonce" .= nonce]
          ]
        other -> error $ "unsupported platform in dispatch: " <> T.unpack other
  -- existing POST-to-GH machinery follows, unchanged
```

The `inputs` shapes match the workflow contracts:
- Android (`fastlane-android.yaml:17-22`): `version_name`, `version_code`.
- iOS (`fastlane.yaml:17-19`): `version_number`.

`notify_slack` defaults to `true` in both workflows so SCC omits it. `payload` carries the SCC dispatch nonce (existing pattern).

#### Step 3 — `previewVersionsH`

```haskell
previewVersionsH _ req = do
  let ids = ... -- existing
  results <- forM ids $ \cid -> do
    ac <- findAppCatalogById cid
    res <- Versioning.resolveNextVersion ac
    pure $ case res of
      Right (AndroidVersion n c) ->
        object [ "app_catalog_id"    .= cid
               , "next_version_name" .= n
               , "next_version_code" .= c
               , "source"            .= ("play_console" :: Text)
               ]
      Right (IosVersion n) ->
        object [ "app_catalog_id"     .= cid
               , "next_version_number" .= n          -- single field for iOS
               , "source"              .= ("app_store_connect" :: Text)
               ]
      Left err -> object [ "app_catalog_id" .= cid, "error" .= err ]
  pure $ object ["previews" .= results]
```

Different response shape per platform. Frontend handles both.

#### Step 4 — Tests

- Stage 1: `platform="ios"` + ASC mock returning `IosVersion "2.5.1"` → tracker's `newVersion = "2.5.1"`.
- Stage 3: `platform="ios"` row → POST body's `inputs.version_number` is set; `inputs.version_name` and `inputs.version_code` are absent. `platform="android"` (regression) → unchanged shape.
- `previewVersionsH` mixed request → iOS rows have `next_version_number`, Android rows have `next_version_name`+`next_version_code`.

> **Watch-out (no preemptive change):** `Mobile/Handlers/Release.hs:166` hardcodes `mbcMatrixJobName = acName app_ <> "-Release"`, which matches Android's `<name>-Release` job naming. iOS jobs are named `<target>-<release_type>` (`fastlane.yaml:143`) where `release_type` comes from Catalyst. **If Catalyst's `ios_prod` extraction yields `release_type=Release`, the existing equality match works for iOS too** and no change is needed. If it yields anything else (`AppStore`, `TestFlight`, `AdHoc`…) iOS rows will hang in `MBBuilding` because `execPollMatrixJobs` won't find the matching job. **Do not preemptively change this** — verify empirically during the E2E dogfood (Task 34); if it hangs, switch the matcher from equality to prefix-match (`T.isPrefixOf` on `<acName>-`). Documented as a known imprecision rather than a required step so we don't refactor on speculation.

### Task 32: Frontend — per-platform version-field rendering + iOS preview-source handling

**Files:**
- Modify: `frontend/src/products/releases/types.ts` — adjust `VersionPreview` to be a discriminated union (Android two-field vs iOS single-field response shapes).
- Modify: `frontend/src/products/releases/pages/mobile/CreateMobileRelease.tsx` — show different version inputs by platform; consume the discriminated preview response.
- Modify: `frontend/src/products/releases/pages/ReleaseSummary.tsx` — iOS post-completion footnote.

**Why:** UI mirror for the platform-aware version model + the extended `MobileDestination`:
- Android rows have **two version fields** (version_name + version_code) — already there.
- iOS rows have **one version field** (version_number); the workflow computes the build number.
- The destination dropdown is **platform-aware**: Android shows `GooglePlay | Firebase`, iOS shows `TestFlight | AppStore`. The field is still required on every row (it ends up in the row's audit context), but the choices differ.

- [ ] **Step 1: Update `types.ts`**:

```ts
// Mirror of the backend ADT — must stay in sync.
type MobileDestination = "GooglePlay" | "Firebase" | "TestFlight" | "AppStore";

// Discriminated preview (per spec §6.3).
type VersionPreview =
  | { app_catalog_id: number; source: "play_console";      next_version_name: string; next_version_code: number }
  | { app_catalog_id: number; source: "app_store_connect"; next_version_number: string }
  | { app_catalog_id: number; error: string };
```

- [ ] **Step 2: In `CreateMobileRelease.tsx`**, render per row based on `platform`:
  - **Android row:** existing two input fields (Version Name, Version Code). Destination dropdown shows `GooglePlay | Firebase`. On preview response, pre-fill both version fields from `next_version_name` + `next_version_code`.
  - **iOS row:** single input field labelled "Version Number". Destination dropdown shows `TestFlight | AppStore` (default `TestFlight`). On preview response, pre-fill from `next_version_number`. Show a hint: "Build number is computed by the build workflow."
  - **Mixed selection:** render per-row, each row using its own platform's choices. Two separate destination dropdowns rendered (one set of choices per platform), or per-row dropdowns — whichever is more ergonomic. The form ends up with a mix of one-field and two-field rows. That's expected and honest.

- [ ] **Step 3: In `ReleaseSummary.tsx`**, for iOS rows that have reached `MBCompleted`, show a small footnote under the status card: *"This build is now uploaded to App Store Connect. Apple's processing typically takes 5–30 min before it appears in TestFlight."* — so users understand that `COMPLETED` on iOS doesn't necessarily mean "live yet" (conservative wording; safe whether the workflow waits or not).

- [ ] **Step 4: Tests** — unit-test the discriminated preview parser; smoke-test the create page rendering Android-only, iOS-only, and mixed selections; verify the destination dropdown shows the right options per platform.

### Task 33: Extend `local-mobile-secrets.env.example` + `setup-mobile-local.sh` for iOS

**Files:**
- Modify: `backend/dev/local-mobile-secrets.env.example`
- Modify: `backend/scripts/setup-mobile-local.sh`

**Why:** Android already has a clean local-setup ergonomics — copy the example, fill in real values, run the script, you're done. iOS should plug into the SAME ergonomics, not create a parallel iOS-only setup. iOS adds 3 ASC secret rows to `server_config`; **no per-app values to write** (the ASC numeric app id is resolved at runtime via bundle id, see Task 30 step 9).

#### Step 1: Extend the env example

Append an iOS section to `backend/dev/local-mobile-secrets.env.example`, mirroring the existing GitHub App + Play Console blocks:

```bash
# ─────────────────────────────────────────────────────────────────────────────
# App Store Connect credentials (iOS only — leave blank to skip iOS setup)
# How to obtain: App Store Connect → Users and Access → Integrations → App
# Store Connect API → generate an API Key with "Developer" role. Download the
# .p8 file (you can only download it once — save it). Note the Issuer ID
# (UUID, top of the page) and the Key ID (10-character string next to the key).
# ─────────────────────────────────────────────────────────────────────────────
ASC_ISSUER_ID=
ASC_KEY_ID=

# Absolute path to the downloaded .p8 file. The script reads the contents and
# stores them in server_config.
ASC_PRIVATE_KEY_P8_PATH=
```

**No `ASC_APP_IDS` env var.** ASC numeric app ids are resolved at runtime by `Versioning/Apple.hs` via `GET /v1/apps?filter[bundleId]=<bundle_id>` — same approach as the iOS workflow. The mapping lives nowhere on disk.

No new feature flag — `MOBILE_DISPATCH_ENABLED` already covers both platforms. No iOS-specific `ENABLE_APPS` either; reuse the existing `ENABLE_APPS` list (the script enables every matching row, both platforms).

#### Step 2: Extend the setup script

Modify `backend/scripts/setup-mobile-local.sh` to:

1. **Treat ASC values as optional.** If `ASC_ISSUER_ID` is blank → skip iOS setup with an `info` log, don't fail. This lets Android-only contributors keep using the script unchanged.

2. **If ASC values are present:**
   - Add a `validate_file ASC_PRIVATE_KEY_P8_PATH` call alongside the existing `validate_file GITHUB_APP_PRIVATE_KEY_PATH`.
   - Read the `.p8` file contents via `cat`.
   - Add a "BEGIN PRIVATE KEY" sanity check like the existing GH PEM check.
   - Add three more `UPDATE server_config` rows to the existing psql block, between the Play and feature-flag lines:
     ```sql
     UPDATE server_config SET value = :'asc_issuer',  enabled = 1 WHERE name = 'app_store_connect_issuer_id';
     UPDATE server_config SET value = :'asc_key_id',  enabled = 1 WHERE name = 'app_store_connect_key_id';
     UPDATE server_config SET value = :'asc_p8',      enabled = 1 WHERE name = 'app_store_connect_private_key_p8';
     ```

3. **Final verification block (Step 8) gets one more SELECT** querying the three ASC server_config rows alongside the existing GH/Play check.

The script remains idempotent and gracefully handles both Android-only and Android+iOS configurations.

#### Step 3: Smoke-test the script

```bash
# Fill in ASC values in local-mobile-secrets.env, then:
nix develop --command bash backend/scripts/setup-mobile-local.sh

# Expected final-state output:
#   - app_store_connect_* rows show <NNN chars> for the .p8 line
#   - All three rows are enabled=1
```

> **Per-team ASC creds caveat:** the iOS workflow uses different ASC keys per app (lines 276–285 of `fastlane.yaml` hardcode a `key_id_map` and `issuer_map` for Cumta and YatriSathi, with a default for everyone else). SCC's single-creds model mirrors how Android works (one Play service account for the whole org); if your chosen ASC key doesn't have access to an app's Apple team, SCC's version resolution will fail for that app and Stage 1 will abort with `asc_app_not_found`. To avoid that, dispatch with `version_number` blank and let the workflow's per-team auto-detect do the work — i.e. drop SCC's `Versioning/Apple.hs` call for that one row, or rotate the ASC key on the team holding most apps and only fall back for the outliers. Out of v1 scope but worth flagging.

### Task 34: E2E iOS verification with a sandbox TestFlight app

**Files:** none (manual verification — leverages the setup script from Task 33)

**Why:** Validates the full iOS loop. Can't be automated for MVP — Apple's processing is genuinely async. **Uses the same ergonomics as Android: edit `local-mobile-secrets.env`, run the script, drive the UI.**

- [ ] **Step 1: Create a sandbox app in App Store Connect** (use a personal Apple developer account or a sandbox team). Under "App Information," note the **numeric app id** (e.g. `1234567890`).

- [ ] **Step 2: Generate an ASC API key**

In App Store Connect → Users and Access → Integrations → App Store Connect API → "+":
- Role: **Developer** (minimum needed for `appStoreVersions` + `preReleaseVersions` reads).
- Download the `.p8` (one-shot — save it locally, e.g. `~/.scc-secrets/AuthKey_ABC1234XYZ.p8`).
- Note the **Issuer ID** (UUID near the top of the page) and the **Key ID** (10-char string next to the key).

- [ ] **Step 3: Fill in `local-mobile-secrets.env`**

```bash
cp backend/dev/local-mobile-secrets.env.example backend/dev/local-mobile-secrets.env  # if not already
$EDITOR backend/dev/local-mobile-secrets.env

# In the iOS section:
ASC_ISSUER_ID=<UUID>
ASC_KEY_ID=<KEY_ID>
ASC_PRIVATE_KEY_P8_PATH=/Users/<you>/.scc-secrets/AuthKey_<KEY_ID>.p8
ENABLE_APPS=NammaYatri   # enables both Android + iOS rows for NammaYatri
```

Note: no `ASC_APP_IDS` — the ASC numeric app id is resolved at runtime from the row's `package_name` (bundle id).

- [ ] **Step 4: Run the setup script**

```bash
nix develop --command bash backend/scripts/setup-mobile-local.sh
```

Expected: the script confirms server_config rows are updated, ASC secrets show length not content, the iOS NammaYatri row is `enabled=true`. If anything mis-validates (file not readable, bad PEM shape, etc.) the script exits with a clear `[fail]` line.

- [ ] **Step 5: Verify the iOS workflow contract**

You don't need to author a new workflow — `.github/workflows/fastlane.yaml` already accepts the right shape (`selected_apps`, `change_log`, `version_number`, `notify_slack`, `payload`). Just verify it points at a non-prod app + sandbox runner labels for the dogfood, or use a sandbox repo that mirrors it. Point the iOS app_catalog row at the right place:

```sql
UPDATE app_catalog
   SET github_repo='<your-username>/scc-mobile-test',
       workflow_path='.github/workflows/fastlane.yaml',
       package_name='com.example.sandbox.ios'      -- bundle id of the sandbox ASC app
 WHERE name='NammaYatri' AND platform='ios';
```

(Or set `SANDBOX_GITHUB_REPO` / `SANDBOX_WORKFLOW_PATH` in the env file and re-run the script — it has built-in sandbox redirection for the enabled rows.)

- [ ] **Step 6: Drive the full flow from the UI**

1. Open Mobile Releases → New Mobile Release.
2. Select the iOS sandbox app. Verify the version preview returns `source: app_store_connect` with `next_version_number` populated. The form should show ONE input ("Version Number") for the iOS row, not two. The destination dropdown should offer `TestFlight | AppStore` (defaulting to `TestFlight`), not the Android choices.
3. Approve + Dispatch.
4. Watch the row pass through `MBDispatched → MBRunIdResolved → MBBuilding`. Duration depends on whether the iOS workflow waits for ASC processing — could be a few minutes (no wait) or 15–40 min (waits).
5. Once fastlane returns success, the matrix job completes; SCC advances `MBBuilding → MBSubmittedToStore → MBTagPushed → MBCompleted` within the next runner tick.
6. Visit `/releases/live` — the iOS row should appear in the Mobile section.

- [ ] **Step 7: Test the failure paths**

- Change `package_name` on the row to a bundle id Apple doesn't recognize → release aborts at Stage 1 with `asc_app_not_found` (the `GET /v1/apps?filter[bundleId]=...` call returned empty).
- Set a wrong Key ID in the env file + re-run the script → Apple resolution fails with `asc_api_unauthorized`; fix the value, re-run, the runner picks back up on its next tick.
- Cause fastlane to fail (e.g. wrong signing cert) → matrix job `conclusion=failure` → `MBFailed "build_failed"` (existing path, no iOS-specific handling).
- Let the iOS job hit its `timeout-minutes` → `conclusion=cancelled` → `MBFailed "cancelled_externally"` (existing path).

- [ ] **Step 8: Document successful iOS E2E**

```bash
git commit --allow-empty -m "Verified iOS mobile release E2E with sandbox TestFlight app"
```

---

## Self-review notes (the plan vs the spec)

After writing this plan, I cross-referenced it against the spec sections:

- **§3 Architecture overview** — covered by Tasks 2, 3, 5, 16, 22 (single product slug; Mobile module tree under Products/Autopilot/; two registry entries on frontend).
- **§4 Data model** — Tasks 1 (migration), 2 (Beam), 5 (Haskell types), 17 (insertMobileTracker uses the column mapping).
- **§5 Lifecycle & runner** — Tasks 12-14 (the 7 stages), 16 (factory wiring). Reuses existing runner loop unchanged.
- **§6 API + RBAC** — Tasks 4 (perms), 7 (app catalog), 9 (versions preview), 17 (create), 18 (dispatch), 19 (live + filter), 20 (role grants).
- **§7 Frontend** — Tasks 21 (foundation), 22 (registry), 23-26 (pages).
- **§8 Testing & rollout** — Tests embedded throughout (Tasks 3, 4, 5, 8, 11, 18); rollout phases noted in Task 20 (flag default OFF, apps default disabled). Phase 0 admin steps are in Task 27.
- **§9 Open questions / non-goals** — respected; provider/iOS/staged-rollouts/catalyst-sync not in this plan.

**Known imprecisions** (called out at the relevant task):
- `extractNonce` in Task 13 needs follow-up GET /runs/:id; Task 13 documents the fallback (actor + created_at window).
- `fetchPlayTracks` in Task 8 is partially implemented; the JWT minting + 4 HTTP calls need the `jose` library wiring fully fleshed out during Task 8 step 4.
- `loadGhCreds` in Task 15 assumes `getConfigSecret` exists in `RuntimeConfig`; if it doesn't, add a small wrapper that reads `server_config WHERE type='secret' AND name=:name`.

These are all flagged with explicit notes in the relevant tasks rather than left as silent unknowns.

### Phase 11 coverage (iOS extension)

Added 2026-05-13, revised 2026-05-14 after reading the real iOS workflow (`fastlane.yaml`). Phase 11 is now 7 tasks (28–34) — smaller, and aligned with the workflow's actual input contract.

| Spec § | Tasks |
|---|---|
| §2 Q&A rows iOS-1 … iOS-6 (the 6 iOS decisions) | Touched by Tasks 28–34 collectively. iOS-4 (no SCC wait for ASC processing) needs no code — it's a stance, documented. iOS-5 (workflow contract: `version_number` single field) implemented by Task 31 step 2. |
| §3 Architecture (`Versioning.hs` dispatcher + `Versioning/{Play,Apple}.hs`; auth inlined into `Apple.hs`) | Tasks 29 (Play move), 30 (Apple client + inlined JWT + dispatcher + runtime ASC-app-id lookup via bundle id). |
| §4 Data model — **no new column, no new status** (small ADT extension on `MobileDestination` to add `MBTestFlight` / `MBAppStore` so iOS callers have meaningful values for SCC's required `destination` field; metadata only, not read by workflows) | Task 28 (catalog seed), Task 31 Step 0 (ADT extension). |
| §5 Lifecycle (Stage 1 via Versioning dispatcher; **Stage 3 dispatch payload branches on platform**; no new stage) | Task 31 (both stages + handler). |
| §6 HTTP API (preview response shape differs per platform: `next_version_name`+`next_version_code` for Android, `next_version_number` for iOS) | Task 31 (HTTP handler) + Task 32 (frontend discriminated parser). |
| §7 Frontend (per-platform version-field rendering, platform-aware destination dropdown (`TestFlight\|AppStore` for iOS), iOS completion footnote) | Task 32. |
| §8 Migration changes appended to `0011-mobile-releases.sql` in place (no new migration file, no new column) | Task 28. |
| §8 Phase 5 admin runbook — extends `local-mobile-secrets.env.example` + `setup-mobile-local.sh` to handle iOS (3 new ASC secrets; no per-app values) | Task 33. |
| §8 Failure modes (`asc_app_not_found`, ASC unauthorized, fastlane fail/timeout) | Task 34 step 7 tests them. |
| §9 Non-goals (iOS removed from deferred list; App Store production review still deferred) | Implicit — Phase 11 closes the iOS gap; production review remains out of scope. |

**Known imprecisions in Phase 11** (called out at the relevant task):
- Task 30 — the iOS buildNumber bump rule is **not** SCC's concern; the workflow's `fastlane fetch_build_number` computes it. SCC only resolves the `version_number` (semver string). The iOS workflow's own auto-version logic (lines 261–346 of `fastlane.yaml`) does a patch bump from the latest TestFlight build; SCC mirrors that pure logic in `Versioning/Apple.hs:computeNextIosVersion`.
- Task 30 — extracting `Play.resolve` from the existing Play body so the dispatcher has symmetric branches is mechanical but touches the most-tested module. Land it in a separate commit ahead of the dispatcher itself.
- Task 30 — JWT signing is inlined in `Versioning/Apple.hs` (matches Play's pattern). If iOS volume grows and ASC throttles, lift the signer into a separate file with IORef-backed caching — see `Mobile/Github/Auth.hs`.
- Task 30 — **ES256 implemented (2026-05-14).** Web.JWT only supports RS/HS algorithms, so the signer is built on `cryptonite`'s `Crypto.PubKey.ECC.ECDSA` (P-256 + SHA-256) with a hand-rolled PKCS#8 .p8 parser (`asn1-encoding`) and ASN.1→raw R‖S conversion (`ecdsaSigToRaw`, RFC 7515 §3.4). No new package added; `cryptonite`, `asn1-encoding`, `asn1-types`, `base64-bytestring`, `memory` were already in the nix env, declared explicitly in `package.yaml`/`scc.cabal` so the new module can import them.
- Task 30 — `Versioning/Apple.hs` uses a single org-wide ASC API key from `server_config`. The iOS workflow uses per-app keys (Cumta and YatriSathi have their own, default for the rest — `fastlane.yaml:276-285`). If SCC's chosen key doesn't have access to an app's Apple team, version resolution fails for that app with `asc_app_not_found`; the fallback is to skip SCC-side resolution and let the workflow's per-team auto-detect take over (i.e. dispatch with `version_number` blank). Documented in Task 33's "Per-team ASC creds caveat".
- Task 31 — the iOS `inputs` shape (`version_number` single field, no `version_name`/`version_code`) is the load-bearing difference between platforms; a build-time test that asserts the constructed JSON has the right keys for each platform is the most valuable regression coverage.
- **Matrix-job-name match (no preemptive change)** — `Mobile/Handlers/Release.hs:166` hardcodes `<acName>-Release`. Android jobs are named `<name>-Release` (literal suffix in `fastlane-android.yaml:74`), so the equality match in `execPollMatrixJobs` works. iOS jobs are named `<target>-<release_type>` (`fastlane.yaml:143`) where `release_type` comes from Catalyst. If Catalyst's `ios_prod` matrix uses `release_type=Release` the existing code works for iOS unchanged. **Only fix if E2E dogfood (Task 34) shows iOS rows hanging in `MBBuilding`** — at that point change `execPollMatrixJobs` from equality to prefix match (`T.isPrefixOf` on `<acName>-`). Discovered while tracing the workflow files end-to-end; flagged here so the fix is obvious if needed, not pre-applied because it may not be needed.
- Task 34 step 5 — SCC requires that `app_catalog.workflow_path` for iOS rows points at `fastlane.yaml` (not `fastlane-ios.yaml` — different name in the real repo). The workflow already accepts the right `inputs` shape today; no changes required from the mobile team.
