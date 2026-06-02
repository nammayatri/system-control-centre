# Mobile Releases — Post-MVP Implementation Plan (Consolidated)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement all mobile release features after the MVP. Covers: mobile revert (full flow + store-sync integration + debug exclusion + version-ordered rollback resolution / revert-of-a-revert [B6] + custom commit source), branch picker + server-side search, debug/release build types, latest build enrichment, periodic store sync, platform filter, apps admin redesign, dispatch from summary, Firebase observability (Crashlytics + Performance Monitoring + Alerts).

**Architecture:** Three new nullable columns on `release_tracker` (`commit_sha`, `source_ref`, `reverts_release_id`). New module tree: `Mobile/Github/Compare.hs`, `Mobile/Changelog.hs`, `Mobile/Handlers/Revert.hs`, `Mobile/StoreSync.hs`. Extend `Mobile/Github.hs` with branch listing, commit verification, and tag creation. Frontend: new `MobileRevert.tsx` page, branch combobox on create form, build-type toggle, platform filter, apps admin redesign, dispatch button on summary.

**Tech Stack:** Haskell (Servant + Beam ORM + ReaderT Flow), PostgreSQL, React + TypeScript + Vite + Tailwind. No new dependencies on either side.

**Source spec:** `docs/superpowers/specs/2026-05-18-mobile-releases-post-mvp-design.md`

> **⚠️ Post-MVP hardening (2026-05-29).** An edge-case audit reworked several
> paths described below. The `[x] Done` steps record the *original*
> implementation; these supersede them:
> - **Create** is now validate-first + atomic (`insertReleaseTrackerRowsBatch`),
>   not a per-item `createOne` insert loop (**B1**).
> - **`fetchLatestBuildsPerApp`** parses in Haskell, not raw-SQL `ROW_NUMBER`
>   (**B2**); a scoped `fetchLatestBuildsForApp` serves single-app callers (**P2**).
> - **ConfirmTag** has a wall-clock timeout (`mobile_tag_confirm_timeout_minutes`)
>   (**B3**); store sync dedups via a partial unique index, migration `0021` (**B4**);
>   dispatch batches its lookups (**P4**).
>
> See §15 of the design spec
> (`2026-05-18-mobile-releases-post-mvp-design.md`) — the full audit record.

**Base (untouched):** `docs/superpowers/plans/2026-05-11-mobile-releases.md`, `docs/superpowers/specs/2026-05-11-mobile-releases-design.md`

**Branch:** `feat/mobile-releases`

---

## Status

| Phase | Scope | Status |
|---|---|---|
| Phase 1 | Mobile Revert — schema, plumbing, Compare client, handlers, FE | ✅ Done |
| Phase 2 | Branch picker + server-side search | ✅ Done |
| Phase 3 | Debug/Release build types | ✅ Done |
| Phase 4 | Latest build enrichment + periodic store sync | ✅ Done |
| Phase 5 | Store-sync revert integration | ✅ Done |
| Phase 6 | Revert hardening (debug exclusion, revert-of-a-revert + already-reverted guard, custom commit) | ✅ Done |
| Phase 7 | UI polish (platform filter, apps admin redesign, dispatch button) | ✅ Done |
| Phase 8 | Post-release health monitoring (crash, perf, alerts) | ⚠️ No in-app dashboards (Firebase Crashlytics has no public read REST API). Deep-link to Firebase Console implemented instead — sidebar link + per-release Crashlytics button with project/app/version context. |
| Phase 9 | Changelog preview on create (commit diff between last release and selected branch) + revert commit list redesign | ✅ Done |

---

## Working agreement

- TDD where it adds signal: pure logic (version-bump rule, changelog renderer, previous-good selector) gets a test before implementation. Schema migrations and HTTP-handler wiring don't need failing tests up front — the compiler + a smoke test cover them.
- Frequent commits at task boundaries. One task = one commit.
- Run `sc-build` after each Haskell change to catch type errors early. Run `sc-test` after each test addition.
- Don't add hspec/tasty. Use the existing `assertEqual` / `assertBool` helpers in `backend/test/Main.hs`.
- Don't add new dependencies on either side.
- Don't change the GH Actions workflow YAML.
- Don't write secrets into the repo. GH App creds are already in `server_config` from the mobile MVP work.

---

## Phase 1 — Mobile Revert

### Task 1.1: DB migration for revert columns

**Files:**
- Create: `backend/dev/migrations/system-control/0012-mobile-revert.sql`

**Why:** Three nullable columns enable revert without affecting existing rows. `commit_sha` and `reverts_release_id` are new for this work; `source_ref` is added here (revert uses it) and reused later by the branch-picker (Phase 2).

- [x] **Step 1: Write the migration**

```sql
-- 0012-mobile-revert.sql
-- Mobile revert support: capture build commit, allow ref override on dispatch,
-- link revert rows back to the release they revert.

ALTER TABLE release_tracker
  ADD COLUMN IF NOT EXISTS commit_sha         TEXT,
  ADD COLUMN IF NOT EXISTS source_ref         TEXT,
  ADD COLUMN IF NOT EXISTS reverts_release_id TEXT;

CREATE INDEX IF NOT EXISTS idx_rt_commit_sha
  ON release_tracker(commit_sha);
CREATE INDEX IF NOT EXISTS idx_rt_reverts_release_id
  ON release_tracker(reverts_release_id);

-- At most one ACTIVE revert per bad release (B6, 2026-06-01) — prevents
-- two operators / a double-submit creating duplicate rollbacks. Terminal
-- statuses free it again (allows revert-of-a-revert + retry-after-failure).
CREATE UNIQUE INDEX IF NOT EXISTS uq_release_tracker_revert_inflight
  ON release_tracker (reverts_release_id)
  WHERE reverts_release_id IS NOT NULL
    AND status IN ('CREATED','INPROGRESS','PAUSED','ABORTING','REVERTING','RESTARTING','PREPARING');
```

- [x] **Step 2: Reset and re-init dev DB**

```bash
rm -rf .local/data/pg
sc-dev
```

- [x] **Step 3: Verify columns exist**

```bash
psql -h 127.0.0.1 -p 5434 -U $USER -d system_control -c "\d release_tracker" | grep -E "commit_sha|source_ref|reverts_release_id"
```

Expected: three rows.

---

### Task 1.2: Beam schema updates

**Files:**
- Modify: `backend/src/Products/Autopilot/Types/Storage/Schema.hs`

- [x] **Step 1: Add three fields to `ReleaseTrackerT`**

After the existing `rtExternalRunId` field:

```haskell
, rtCommitSha        :: Columnar f (Maybe Text)
, rtSourceRef        :: Columnar f (Maybe Text)
, rtRevertsReleaseId :: Columnar f (Maybe Text)
```

- [x] **Step 2: Add field mappings in `autopilotDb`**

Inside the `releaseTrackers` `tableModification` block:

```haskell
, rtCommitSha        = fieldNamed "commit_sha"
, rtSourceRef        = fieldNamed "source_ref"
, rtRevertsReleaseId = fieldNamed "reverts_release_id"
```

- [x] **Step 3: Fix all constructor call sites to pass `Nothing`**

Every place that constructs a `ReleaseTrackerT` record needs the new fields. The compiler flags them.

- [x] **Step 4: Compile**

```bash
sc-build
```

---

### Task 1.3: Capture `commit_sha` in `stageResolveRunId`

**Files:**
- Modify: `backend/src/Products/Autopilot/Mobile/Workflow.hs`

**Why:** The polled GH run response includes `head_sha`. Write it to `release_tracker.commit_sha` alongside `external_run_id`.

- [x] **Step 1: Extract `head_sha` from the GH run response**

The run response JSON includes `"head_sha"`. Parse it alongside `"id"`:

```haskell
headSha <- case Aeson.parseMaybe (Aeson..: "head_sha") runObj of
    Just sha -> pure sha
    Nothing  -> pure ""
```

- [x] **Step 2: Persist in the same UPDATE via `setExternalRunIdForDispatch`**

Extend the helper to accept `headSha` as a third parameter:

```haskell
setExternalRunIdForDispatch ::
    (MonadFlow m) => Text -> Text -> Text -> m ()
setExternalRunIdForDispatch dispatchId runId headSha = withDb $ \db ->
    runDB db $
        runUpdate $
            update
                (releaseTrackers autopilotDb)
                ( \rt ->
                    mconcat
                        [ rtExternalRunId rt <-. val_ (Just runId)
                        , rtCommitSha rt <-. val_ (Just headSha)
                        ]
                )
                (\rt -> rtDispatchId rt ==. val_ (Just dispatchId))
```

- [x] **Step 3: Compile + verify**

```bash
sc-build
```

---

### Task 1.4: Read `source_ref` in `stageDispatchWorkflow`

**Files:**
- Modify: `backend/src/Products/Autopilot/Mobile/Workflow.hs`

**Why:** Replace hardcoded `"main"` with configurable ref. Normal releases use NULL (defaults to main). Revert releases use `"refs/tags/<prev-good-tag>"`.

- [x] **Step 1: Replace hardcoded ref**

In the dispatch stage, around the `WorkflowDispatchReq` construction:

```haskell
ref = fromMaybe "main" (sourceRef rt)
body =
    WorkflowDispatchReq
        { wdrRef = ref
        , wdrInputs = inputs
        }
```

- [x] **Step 2: Select workflow path**

```haskell
wfPath = acWorkflowPath ac
```

- [x] **Step 3: Log the chosen ref**

```haskell
logInfoIO $
    "[DispatchWorkflow] "
        <> releaseId rt
        <> " dispatched workflow="
        <> wfPath
        <> " ref="
        <> ref
```

---

### Task 1.5: GitHub Compare API client

**Files:**
- Create: `backend/src/Products/Autopilot/Mobile/Github/Compare.hs`

**Why:** The revert handler needs a list of commits between two refs to build the changelog. The GH Compare API returns this directly.

- [x] **Step 1: Define `CommitInfo` and `CompareResult`**

```haskell
module Products.Autopilot.Mobile.Github.Compare
    ( CommitInfo (..)
    , CompareResult (..)
    , compareRefs
    , extractPrNumber
    , shortSha
    ) where

data CommitInfo = CommitInfo
    { ciSha         :: Text
    , ciShortSha    :: Text     -- first 7 chars
    , ciMessage     :: Text     -- full commit message
    , ciSubject     :: Text     -- first line
    , ciAuthorLogin :: Text     -- GH login or "unknown"
    , ciHtmlUrl     :: Text
    , ciPrNumber    :: Maybe Int  -- parsed from "(#NNN)" in subject
    } deriving (Eq, Show, Generic, ToJSON)

data CompareResult = CompareResult
    { crCommits  :: [CommitInfo]
    , crStatus   :: Text    -- "ahead", "behind", "identical", "diverged"
    , crAheadBy  :: Int
    , crBehindBy :: Int
    } deriving (Eq, Show, Generic, ToJSON)
```

- [x] **Step 2: Implement `compareRefs`**

```haskell
compareRefs
    :: (MonadFlow m)
    => GhAppCreds -> Text -> Text -> Text -> Text
    -> m (Either Text CompareResult)
compareRefs creds owner repo base headRef = do
    tok <- getInstallationToken creds
    let encodedBase = urlEncodePathSegment base
        encodedHead = urlEncodePathSegment headRef
        url = apiBase <> "/repos/" <> owner <> "/" <> repo
              <> "/compare/" <> encodedBase <> "..." <> encodedHead
    -- GET with gh headers, parse response
```

The `urlEncodePathSegment` helper escapes `/`, `+`, and spaces in tag names like `nammayatri/prod/android/v1.2.3+456`.

- [x] **Step 3: PR number extraction helper**

```haskell
extractPrNumber :: Text -> Maybe Int
extractPrNumber subject = case T.breakOn "(#" subject of
    (_, rest) | not (T.null rest) ->
        let inner = T.drop 2 rest
        in case T.breakOn ")" inner of
            (numStr, _) -> readMaybe (T.unpack numStr)
    _ -> Nothing
```

- [x] **Step 4: Unit tests**

```haskell
assertEqual "extractPrNumber with PR" (Just 123) (extractPrNumber "fix: foo (#123)")
assertEqual "extractPrNumber without PR" Nothing (extractPrNumber "chore: bump deps")
assertEqual "extractPrNumber first match" (Just 12) (extractPrNumber "fix (#12) and (#34)")
```

- [x] **Step 5: Add module to `package.yaml` + compile**

```bash
sc-build && sc-test
```

---

### Task 1.6: Changelog renderer

**Files:**
- Create: `backend/src/Products/Autopilot/Mobile/Changelog.hs`

**Why:** Pure module for rendering the revert changelog from Compare API commits and for version bump logic.

- [x] **Step 1: Implement `bumpPatch`**

```haskell
module Products.Autopilot.Mobile.Changelog
    ( bumpPatch
    , renderRevertChangelog
    ) where

bumpPatch :: Text -> Text
bumpPatch v = case T.splitOn "." v of
    [maj, mi, patch] -> case readMaybe (T.unpack patch) of
        Just n  -> maj <> "." <> mi <> "." <> T.pack (show (n + 1 :: Int))
        Nothing -> v <> ".1"
    [maj, mi] -> maj <> "." <> mi <> ".1"
    [single]  -> single <> ".0.1"
    parts     -> T.intercalate "." parts <> ".1"
```

- [x] **Step 2: Implement `renderRevertChangelog`**

```haskell
renderRevertChangelog :: Text -> Text
renderRevertChangelog badVer = "Revert v" <> badVer
```

The simple one-liner was chosen because operators always edit the changelog before submitting. Earlier versions with full commit listings were too verbose.

- [x] **Step 3: Unit tests**

```haskell
assertEqual "bumpPatch 3-part" "1.2.4" (bumpPatch "1.2.3")
assertEqual "bumpPatch 2-part" "1.2.1" (bumpPatch "1.2")
assertEqual "bumpPatch 1-part" "1.0.1" (bumpPatch "1")
assertEqual "bumpPatch non-numeric" "1.2.beta.1" (bumpPatch "1.2.beta")
assertEqual "bumpPatch empty" "0.0.1" (bumpPatch "")
```

---

### Task 1.7: Rollback candidate fetch + version-ordered resolver

> **Reworked 2026-06-01 (B6).** Originally `findPreviousGoodMobileRelease` chose
> the previous good release by **`created_at`** (a `< beforeDate` cutoff). Store-sync
> writes older versions at later times, so creation time mis-sequences releases.
> Replaced by a bounded **candidate fetch** + a **pure, version-ordered resolver**.

**Files:**
- Modify: `backend/src/Products/Autopilot/Mobile/Queries/Tracker.hs`
- Create: `backend/src/Products/Autopilot/Mobile/RevertResolver.hs`

**Why:** The handler needs the correct rollback target for the same app — the
highest *good* version strictly **below** the bad one (by version, not time),
skipping debug and reverted rows. Splitting the DB fetch from the pure ranking
keeps the ranking unit-testable.

- [x] **Step 1: Add `fetchRevertCandidates` (bounded window, no time cutoff)**

Fetches the most recent 50 COMPLETED candidates for the same (appGroup, service, env), excluding the bad release itself; store-sync rows are **kept** (valid targets). Debug / reverted rows are dropped in Haskell; each surviving row becomes a `RevertCand`:

```haskell
fetchRevertCandidates ::
    (MonadFlow m) => Text -> Text -> Text -> Text -> m [RevertCand]
fetchRevertCandidates appGroup service env excludeId = withDb $ \db -> do
    rows <- runDB db $ runSelectReturningList $
        select $ limit_ 50 $ orderBy_ (desc_ . rtCreatedAt) $ do
            rt <- all_ (releaseTrackers autopilotDb)
            guard_ (rtCategory rt ==. val_ "MobileBuild")
            guard_ (rtAppGroup rt ==. val_ appGroup)
            guard_ (rtService rt ==. val_ service)
            guard_ (rtEnv rt ==. val_ env)
            guard_ (rtStatus rt ==. val_ "COMPLETED")
            guard_ (rtId rt /=. val_ excludeId)
            pure rt
    pure (mapMaybe toCand rows)   -- drops debug + reverted, builds RevertCand
```

- [x] **Step 2: Pure resolver `resolveRollback` (version order, target/source split)**

`Mobile/RevertResolver.hs` ranks candidates by the store's sequence key `(version_code, semver(version_name), created_at)` and returns one of four plans — `Rollback` / `RebuildLower` / `NeedsManualSource` / `NoPriorRelease` (see design §1 "Rollback target resolution"). Pure, no Beam/JSON:

```haskell
resolveRollback :: RevertCand -> [RevertCand] -> RollbackPlan
resolveRollback bad cands =
    case sortBy (\x y -> compareSeq (seqKey y) (seqKey x))
              (filter (\c -> compareSeq (seqKey c) (seqKey bad) == LT) cands) of
        []        -> NoPriorRelease
        (tgt:_)
          | hasTag tgt -> Rollback tgt tgt
          | otherwise  -> case filter hasTag ordered of
                            (src:_) -> RebuildLower tgt src
                            []      -> NeedsManualSource tgt
```

- [x] **Step 3: `isReverted` helper (exported)** — used both to drop reverted candidates and to guard re-reverting an already-reverted release:

```haskell
isReverted :: ReleaseTrackerRow -> Bool
isReverted row = case rtMetadata row of
    Nothing -> False
    Just md -> case Aeson.decodeStrict (TE.encodeUtf8 md) of
        Just (Aeson.Object obj) -> KM.member (AK.fromText "reverted_by") obj
        _ -> False
```

`findPreviousGoodSCCRelease` (re-assert path, §Phase 5) keeps `firstNonDebug` and is unchanged.

---

### Task 1.8: Revert handlers

**Files:**
- Create: `backend/src/Products/Autopilot/Mobile/Handlers/Revert.hs`
- Modify: `backend/src/Products/Autopilot/Mobile/Routes.hs`

**Why:** Two endpoints: draft (read-only preview) and create (persist the revert release).

- [x] **Step 1: Define response types**

```haskell
module Products.Autopilot.Mobile.Handlers.Revert
    ( RevertDraft (..)
    , RevertReq (..)
    , RevertResp (..)
    , VerifyCommitResp (..)
    , mobileRevertDraftH
    , mobileRevertCreateH
    , verifyCommitH
    ) where

data RevertDraft = RevertDraft
    { rdBadReleaseId       :: Text
    , rdBadVersion         :: Text
    , rdBadVersionCode     :: Maybe Int32
    , rdPrevGoodReleaseId  :: Text
    , rdPrevGoodVersion    :: Text
    , rdPrevGoodShortSha   :: Text
    , rdPrevGoodTag        :: Text
    , rdSuggestedVersion   :: Text
    , rdSuggestedCode      :: Maybe Int32
    , rdChangelog          :: Text
    , rdCommits            :: [CommitInfo]
    , rdCommitCount        :: Int
    , rdPlatform           :: Text
    , rdIsStoreSyncRevert  :: Bool
    , rdStoreVersion       :: Maybe Text
    , rdStoreVersionCode   :: Maybe Int32
    } deriving (Generic, ToJSON)

data RevertReq = RevertReq
    { rrNewVersionName :: Text
    , rrNewVersionCode :: Int32
    , rrChangelog      :: Text
    , rrSourceCommit   :: Maybe Text  -- custom commit SHA (Phase 6)
    } deriving (Generic, FromJSON)
```

- [x] **Step 2: Implement `mobileRevertDraftH`**

```haskell
mobileRevertDraftH :: AuthedPerson -> Text -> Flow RevertDraft
mobileRevertDraftH _ releaseId = do
    bad <- findMobileReleaseById releaseId
    -- Guards: must be COMPLETED, must be MobileBuild, must NOT be debug,
    -- must NOT be already reverted (revert-of-a-revert IS allowed; see Task 6.2)
    guardCompleted bad
    guardNotDebug bad
    when' (isReverted bad) $ BadRequest "This release has already been reverted."
    -- Branch: store-sync (re-assert) vs SCC release (version-ordered rollback)
    let isStoreSync = rtMode bad == Just "STORE_SYNC"
    if isStoreSync
        then draftForStoreSyncRevert bad
        else draftForSCCRevert bad
```

`draftForSCCRevert` resolves the rollback target by version (Task 1.7), calls the GitHub Compare API between the build-source tag and the bad tag, generates the changelog, and computes version suggestions. The plan returns the *target* (display) and *build source* (rebuild from); for `manual_required` it skips the diff and asks for a source commit:

```haskell
draftForSCCRevert :: ReleaseTrackerRow -> Flow RevertDraft
draftForSCCRevert bad = do
    cands <- fetchRevertCandidates appGroup service env (rtId bad)
    (target, mSource, srcKind, warnings) <- case resolveRollback (mkBadCand bad) cands of
        Rollback t s        -> pure (t, Just s, "tag", [])
        RebuildLower t s    -> pure (t, Just s, "rebuild_lower", ["target_has_no_artifact"])
        NeedsManualSource t -> pure (t, Nothing, "manual_required", ["manual_source_required"])
        NoPriorRelease      -> throwM $ BadRequest "nothing to roll back to"
    creds <- loadGhCredsSafe
    ac    <- appCatalogForRow bad
    -- Compare only when both a source tag and the bad tag exist:
    commitsRes <- traverse (\srcTag -> compareRefs creds (gitOwner ac) (gitRepo ac) srcTag badTag)
                           (mSource >>= rcTag)
    -- Store version floor for the code suggestion:
    builds <- fetchLatestBuildsForApp appGroup service env
    let storeCode = lookupStoreCode builds bad
        suggestedCode = max (versionCode bad) (fromMaybe 0 storeCode) + 1
    ...
```

`draftForStoreSyncRevert` uses `findPreviousGoodSCCRelease` (excludes STORE_SYNC rows) and gracefully falls back when no tag or Compare API call fails.

- [x] **Step 3: Implement `mobileRevertCreateH`**

```haskell
mobileRevertCreateH :: AuthedPerson -> Text -> RevertReq -> Flow RevertResp
mobileRevertCreateH auth releaseId req = do
    bad <- findMobileReleaseById releaseId
    guardCompleted bad
    guardNotDebug bad
    when' (isReverted bad) $ BadRequest "This release has already been reverted."
    -- Re-resolve the build source (don't trust the draft): store-sync re-asserts
    -- the latest SCC build; rollback resolves by version (Task 1.7). manual_required
    -- demands a source commit.
    (prevId, prevTag, manualNeeded) <- resolveBuildSource bad
    when' (manualNeeded && noCommit req) $
        BadRequest "Target version has no SCC artifact; provide a source commit."
    -- Version invariant: code must clear max(bad, live store) floor
    when (rrNewVersionCode req <= floorCode) $
        throwM (BusinessError "new version_code must be > the store/bad floor")
    -- Determine source ref
    sourceRef <- case rrSourceCommit req of
        Just sha -> do
            -- Verify commit, create temporary tag
            creds <- loadGhCredsSafe
            fullSha <- resolveCommit creds owner repo sha
            let tagName = "scc-revert/" <> newId
            createGitRef creds owner repo ("refs/tags/" <> tagName) fullSha
            pure ("refs/tags/" <> tagName)
        Nothing -> pure ("refs/tags/" <> prevGoodTag)
    -- Insert release_tracker row
    insertMobileRevertTracker newId bad prevGood req sourceRef (userEmail auth) now
    -- Audit
    logEvent newId "REVERT_CREATED" $ object [...]
    pure $ RevertResp { rrRevertReleaseId = newId }
```

- [x] **Step 4: Wire routes**

In `Routes.hs`:

```haskell
:<|> "releases" :> Capture "releaseId" Text :> "mobile-revert" :> "draft"
              :> Protected 'AP_RELEASE_REVERT
              :> Get '[JSON] RevertDraft

:<|> "releases" :> Capture "releaseId" Text :> "mobile-revert"
              :> Protected 'AP_RELEASE_REVERT
              :> ReqBody '[JSON] RevertReq
              :> Post '[JSON] RevertResp
```

- [x] **Step 5: Smoke test**

```bash
TOKEN=$(curl -s -X POST http://localhost:8012/auth/login -d '{"email":"admin@juspay.in","password":"admin123"}' | jq -r .token)
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:8012/releases/<completed-mobile-id>/mobile-revert/draft | jq .
```

Expected: `RevertDraft` JSON with `rdSuggestedVersion`, `rdChangelog`, `rdCommits`.

---

### Task 1.9: Frontend — Revert page

**Files:**
- Create: `frontend/src/products/releases/pages/mobile/MobileRevert.tsx`
- Modify: `frontend/src/products/releases/api.ts`

**Why:** Full page (not modal) because the changelog preview was too large for a modal on mobile screens.

- [x] **Step 1: API wrappers**

In `api.ts`:

```typescript
export interface RevertDraft {
    rdBadReleaseId: string;
    rdBadVersion: string;
    rdBadVersionCode: number | null;
    rdPrevGoodReleaseId: string;
    rdPrevGoodVersion: string;
    rdPrevGoodShortSha: string;
    rdPrevGoodTag: string;
    rdSuggestedVersion: string;
    rdSuggestedCode: number | null;
    rdChangelog: string;
    rdCommits: RevertCommit[];
    rdCommitCount: number;
    rdPlatform: string;
    rdIsStoreSyncRevert: boolean;
    rdStoreVersion: string | null;
    rdStoreVersionCode: number | null;
}

export const getMobileRevertDraft = (releaseId: string) =>
    apiClient.get(`/releases/${releaseId}/mobile-revert/draft`).then(r => r.data);

export const createMobileRevert = (releaseId: string, body: RevertCreateReq) =>
    apiClient.post(`/releases/${releaseId}/mobile-revert`, body).then(r => r.data);
```

- [x] **Step 2: Implement `MobileRevert.tsx`**

Page at `/releases/:id/revert`. Key structure:

```tsx
const MobileRevert: React.FC = () => {
  const { id } = useParams<{ id: string }>();
  const { data: draft, isLoading, error } = useQuery<RevertDraft>({
    queryKey: ['mobile-revert-draft', id],
    queryFn: () => getMobileRevertDraft(id!),
    enabled: !!id,
    retry: false,
  });

  const [versionName, setVersionName] = useState('');
  const [versionCode, setVersionCode] = useState('');
  const [changelog, setChangelog] = useState('');
  const [sourceMode, setSourceMode] = useState<'prevGood' | 'customCommit'>('prevGood');
  const [customCommit, setCustomCommit] = useState('');
  const [verifiedCommit, setVerifiedCommit] = useState<VerifyCommitResp | null>(null);

  // Seed form fields from draft
  useEffect(() => {
    if (draft) {
      setVersionName(draft.rdSuggestedVersion);
      setVersionCode(String(draft.rdSuggestedCode ?? ''));
      setChangelog(draft.rdChangelog);
    }
  }, [draft]);
  ...
```

Sections:
1. **Summary card** (read-only): rolling back from v{bad} to v{prevGood} ({commitCount} commits)
2. **Source selector**: radio toggle between "Previous good release" and "Custom commit"
3. **Editable form**: version name, version code (with `max(badCode, storeCode)` floor), changelog textarea
4. **Validation**: disable submit if `code <= floor` or `name === badVersion`
5. **Store-sync banner**: amber info box when `rdIsStoreSyncRevert` is true
6. **Store version info**: blue badge showing current store version when available

- [x] **Step 3: TypeScript compiles**

```bash
cd frontend && npx tsc --noEmit
```

---

### Task 1.10: Frontend — Banners and list integration

**Files:**
- Modify: `frontend/src/products/releases/pages/ReleaseSummary.tsx`
- Modify: `frontend/src/products/releases/pages/ListRelease.tsx`

- [x] **Step 1: "Reverted by" banner on bad release detail**

If `release.metadata?.reverted_by` is set:

```tsx
<div className="bg-amber-50 border border-amber-200 rounded-lg p-3">
  <span>This release was reverted by release {shortId}.</span>
  <Link to={`/releases/${revertedBy}?category=mobile`}>View revert →</Link>
</div>
```

- [x] **Step 2: "Reverts" banner on revert release detail**

If `release.revertsReleaseId` (from `reverts_release_id` column) is set:

```tsx
<div className="bg-violet-50 border border-violet-200 rounded-lg p-3">
  <span>↩ This is a revert of release {badShortId}.</span>
  <Link to={`/releases/${revertsId}?category=mobile`}>View original →</Link>
</div>
```

- [x] **Step 3: Revert button on completed mobile rows in list**

Condition: `status === 'COMPLETED' && isMobile && !isDebugBuild && !release.metadata?.reverted_by`
(the `!isMobileRevertBuild` gate was **removed in B6** — a revert build is itself revertable; only an already-reverted release is hidden; see Task 6.2.)

- [x] **Step 4: REVERT badge on list and detail**

Detects mobile reverts via `revertsReleaseId` field (in addition to backend `release_context.revert` flag).

- [x] **Step 5: Move `markReleaseRevertedBy` to workflow finalize**

In `Workflow.hs::execFinalize`, when status reaches COMPLETED and `revertsReleaseId` is set:

```haskell
when (newStatus == "COMPLETED") $
    case rtRevertsReleaseId rt of
        Just badId -> markReleaseRevertedBy badId (rtId rt)
        Nothing    -> pure ()
```

This prevents marking the bad release as "reverted" if the revert build is aborted.

---

## Phase 2 — Branch Picker + Server-Side Search

### Task 2.1: Branch list backend

**Files:**
- Modify: `backend/src/Products/Autopilot/Mobile/Github.hs`
- Modify: `backend/src/Products/Autopilot/Mobile/Handlers/Release.hs`
- Modify: `backend/src/Products/Autopilot/Mobile/Routes.hs`

- [x] **Step 1: Add `BranchInfo` type and `listBranches`**

In `Github.hs`:

```haskell
data BranchInfo = BranchInfo
    { biName :: Text
    , biSha  :: Text
    } deriving (Eq, Show, Generic, ToJSON)

listBranches :: (MonadFlow m)
    => GhAppCreds -> Text -> Text -> m (Either Text [BranchInfo])
-- GET /repos/{owner}/{repo}/branches?per_page=100&sort=updated&direction=desc
```

- [x] **Step 2: Add `listBranchesH` handler**

In `Handlers/Release.hs`:

```haskell
listBranchesH :: AuthedPerson -> Maybe Text -> Flow BranchesResp
listBranchesH _ mQuery = do
    creds <- loadGhCredsSafe
    firstApp <- headMay <$> listEnabledAppCatalog
    case firstApp of
        Nothing -> pure $ BranchesResp []
        Just app -> do
            result <- case mQuery of
                Just q | T.length q >= 1 -> searchBranches creds owner repo q
                _                        -> do
                    bs <- listBranches creds owner repo
                    pure (fmap pinMain bs)
            case result of
                Right bs -> pure $ BranchesResp bs
                Left e   -> throwM $ BusinessError e
```

The `pinMain` helper moves `main`/`master` to the top of the list when no search query is active.

- [x] **Step 3: Wire route**

```haskell
:<|> "mobile" :> "branches"
      :> Protected 'AP_RELEASE_CREATE
      :> QueryParam "q" Text
      :> Get '[JSON] BranchesResp
```

---

### Task 2.2: Source ref on create request

**Files:**
- Modify: `backend/src/Products/Autopilot/Mobile/Handlers/Release.hs`
- Modify: `backend/src/Products/Autopilot/Mobile/Queries/Tracker.hs`

- [x] **Step 1: Add `sourceRef` to `CreateMobileReleasesReq`**

```haskell
data CreateMobileReleasesReq = CreateMobileReleasesReq
    { cmrChangeLog    :: Text
    , cmrDestination  :: MobileDestination
    , cmrItems        :: [CreateMobileReleasesItem]
    , cmrSourceRef    :: Maybe Text   -- NEW
    } deriving (Generic, FromJSON)
```

- [x] **Step 2: Thread through `createOne` to `insertMobileTracker`**

```haskell
insertMobileTracker :: (MonadFlow m)
    => Text -> AppCatalog -> MobileBuildTargetState
    -> Maybe Text -> Maybe Text -> Text -> UTCTime -> m ()
--                   ^versionName  ^sourceRef  ^email  ^now
```

NULL stored in DB for main (backward compatible): `sourceRef IS NULL` means "use main".

---

### Task 2.3: Frontend — Branch combobox

**Files:**
- Modify: `frontend/src/products/releases/pages/mobile/CreateMobileRelease.tsx`
- Modify: `frontend/src/products/releases/hooks.ts`
- Modify: `frontend/src/products/releases/api.ts`

- [x] **Step 1: API + hook**

```typescript
// api.ts
listBranches: async (q?: string): Promise<BranchInfo[]> => {
    const params: Record<string, string> = {};
    if (q) params.q = q;
    const { data } = await apiClient.get('/mobile/branches', { params });
    return data?.branches ?? [];
},

// hooks.ts
export function useMobileBranches(search?: string) {
  return useQuery({
    queryKey: ['mobile', 'branches', search ?? ''],
    queryFn: () => mobileApi.listBranches(search),
    staleTime: search ? 30_000 : 5 * 60_000,
    placeholderData: keepPreviousData,  // TanStack Query v5 syntax
  });
}
```

- [x] **Step 2: Searchable combobox on Create form**

```tsx
const [sourceRef, setSourceRef] = useState<string>('main');
const [branchSearch, setBranchSearch] = useState('main');
const [debouncedSearch, setDebouncedSearch] = useState('');

useEffect(() => {
    const t = setTimeout(() => setDebouncedSearch(branchSearch), 300);
    return () => clearTimeout(t);
}, [branchSearch]);

const { data: branches = [] } = useMobileBranches(
    debouncedSearch.length >= 2 ? debouncedSearch : undefined,
);
```

Text input with dropdown, click-outside/Escape closes, Enter selects first match. Warning banner when building from non-main branch.

- [x] **Step 3: Source Branch on Release Summary**

When `sourceRef` is set on the release, show with `GitBranch` icon in the Mobile Build detail section.

---

### Task 2.4: Server-side search enhancement

**Files:**
- Modify: `backend/src/Products/Autopilot/Mobile/Github.hs`

**Why:** GitHub's `GET /branches` returns at most 100 sorted alphabetically. Repos with 500+ branches don't show recent branches. Use the `matching-refs` API for prefix search.

- [x] **Step 1: Add `searchBranches`**

```haskell
searchBranches :: (MonadFlow m)
    => GhAppCreds -> Text -> Text -> Text -> m (Either Text [BranchInfo])
-- GET /repos/{owner}/{repo}/git/matching-refs/heads/{query}
-- Returns refs like "refs/heads/feature/foo", strip prefix to get branch name
```

Results are `BranchRefItem` (refs format) converted to `BranchInfo` by stripping `refs/heads/` prefix.

---

## Phase 3 — Debug & Release Build Types

> **⚠️ Superseded — build type model refactored.** The `MobileDestination` ADT
> below (and the per-context `mbcDestination` field) was **removed**. Build type
> is now a plain `mbcBuildType :: Text` (`"debug"`/`"release"`) on the context,
> set server-side from the `mobile_build_type` env-invariant config flag; the
> upload destination is derived from build type + platform, never stored. Debug
> branching uses `isDebugBuildType`. Store sync is gated release-only and the
> create form sends no destination. The steps below are kept for history — see
> the design spec **§7 Debug & Release Build Types** for the current model.

### Task 3.1: Destination ADT extension

**Files:**
- Modify: `backend/src/Products/Autopilot/Mobile/Types.hs`
- Modify: `frontend/src/products/releases/types.ts`

- [x] **Step 1: Add iOS destinations and `isDebugDestination`**

```haskell
data MobileDestination
    = MBGooglePlay   -- Android release
    | MBFirebase     -- Android debug
    | MBTestFlight   -- iOS debug
    | MBAppStore     -- iOS release
    deriving (Eq, Show, Read, Generic)

isDebugDestination :: MobileDestination -> Bool
isDebugDestination MBFirebase   = True
isDebugDestination MBTestFlight = True
isDebugDestination _            = False
```

- [x] **Step 2: Frontend mirror**

```typescript
export type MobileDestination = 'GooglePlay' | 'Firebase' | 'TestFlight' | 'AppStore';
export type BuildType = 'debug' | 'release';

export const destinationFor = (
  buildType: BuildType, platform: 'android' | 'ios',
): MobileDestination =>
  buildType === 'debug'
    ? platform === 'ios' ? 'TestFlight' : 'Firebase'
    : platform === 'ios' ? 'AppStore' : 'GooglePlay';
```

---

### Task 3.2: Workflow stage changes for debug builds

**Files:**
- Modify: `backend/src/Products/Autopilot/Mobile/Workflow.hs`

Six stages affected:

- [x] **ResolveVersion**: Skip for debug — log `VERSION_RESOLVED` with `source = "debug_skip"`, bump to `MBVersionResolved`
- [x] **DispatchWorkflow**: Only send `selected_apps` + `change_log` (no version inputs) for debug destinations
- [x] **ResolveRunId**: Poll on `workflow_path`
- [x] **MonitorMatrixJob**: Look for `{app}-Debug` instead of `{app}-Release`

```haskell
mbcMatrixJobName = acName app <> if isDebugDestination dest then "-Debug" else "-Release"
```

- [x] **ConfirmTag**: Skip for debug — write `tag_pushed = "debug-no-tag"`, advance immediately
- [x] **Finalize**: No changes (handles both build types)

---

### Task 3.4: Frontend — Build type toggle

**Files:**
- Modify: `frontend/src/products/releases/pages/mobile/CreateMobileRelease.tsx`
- Modify: `frontend/src/products/releases/pages/ListRelease.tsx`
- Modify: `frontend/src/products/releases/pages/ReleaseSummary.tsx`

- [x] **Step 1: Build Type toggle on Create form**

Maps to destination via `destinationFor(buildType, platform)`. Version fields hidden for debug builds.

- [x] **Step 2: DEBUG badge on list**

```tsx
{isDebugBuild && (
  <span className="bg-amber-50 text-amber-700 border border-amber-200 px-1.5 py-0.5 rounded text-[10px]">
    DEBUG
  </span>
)}
```

Where `isDebugBuild = destination === 'Firebase' || destination === 'TestFlight'`.

---

## Phase 4 — Latest Build Enrichment + Periodic Store Sync

### Task 4.1: Latest build query

**Files:**
- Modify: `backend/src/Products/Autopilot/Mobile/Queries/AppCatalog.hs`

- [x] **Step 1: Add `fetchLatestBuildsPerApp`**

Raw SQL with window function (Beam can't express this):

```sql
SELECT app_group, service, env,
  CASE WHEN destination IN ('Firebase', 'TestFlight')
       THEN 'debug' ELSE 'release' END AS build_type,
  new_version, version_code, destination, tag_pushed, commit_sha, date_created
FROM (
  SELECT *, ROW_NUMBER() OVER (
    PARTITION BY app_group, service, env,
      CASE WHEN destination IN ('Firebase', 'TestFlight')
           THEN 'debug' ELSE 'release' END
    ORDER BY date_created DESC
  ) AS rn
  FROM release_tracker
  WHERE category = 'MobileBuild' AND status = 'COMPLETED'
    AND release_context IS NOT NULL
) sub WHERE rn = 1
```

Returns `[LatestBuildRow]` — one row per (app, surface, platform, build_type).

---

### Task 4.2: API enrichment

**Files:**
- Modify: `backend/src/Products/Autopilot/Mobile/Handlers/AppCatalog.hs`

- [x] **Step 1: Add `LatestBuildResp` to response**

```haskell
data LatestBuildResp = LatestBuildResp
    { lbrVersion     :: Text
    , lbrVersionCode :: Maybe Int32
    , lbrDestination :: Maybe Text
    , lbrTagPushed   :: Maybe Text
    , lbrCommitSha   :: Maybe Text
    , lbrCompletedAt :: UTCTime
    } deriving (Generic)

instance ToJSON LatestBuildResp where
    toJSON = genericToJSON (defaultOptions { omitNothingFields = True })
```

- [x] **Step 2: Enrich `AppCatalogEntryResp`**

```haskell
, latestReleaseBuild :: Maybe LatestBuildResp
, latestDebugBuild   :: Maybe LatestBuildResp
```

- [x] **Step 3: Handler builds map from query results**

```haskell
listAppsH :: AuthedPerson -> Flow [AppCatalogEntryResp]
listAppsH _ = do
    apps <- listAppCatalog
    builds <- fetchLatestBuildsPerApp
    let buildMap = Map.fromList [((lbrAppGroup b, lbrService b, lbrEnv b, lbrBuildType b), b) | b <- builds]
    pure $ map (toResp buildMap) apps
```

---

### Task 4.3: Frontend — Latest build badges

**Files:**
- Modify: `frontend/src/products/releases/types.ts`
- Modify: `frontend/src/products/releases/pages/mobile/CreateMobileRelease.tsx`
- Modify: `frontend/src/products/releases/pages/mobile/MobileAppsAdmin.tsx`
- Modify: `frontend/src/products/releases/pages/ReleaseSummary.tsx`

- [x] **Step 1: Type**

```typescript
export type LatestBuild = {
  version: string;
  versionCode?: number;
  destination?: string;
  tagPushed?: string;
  commitSha?: string;
  completedAt: string;
};
```

- [x] **Step 2: `LatestBuildBadge` on Create form app cards**

```tsx
const LatestBuildBadge = ({ build, label }: { build: LatestBuild; label: string }) => (
  <span className={cn(
    'inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium',
    label === 'debug'
      ? 'bg-amber-50 text-amber-700 border border-amber-200'
      : 'bg-emerald-50 text-emerald-700 border border-emerald-200',
  )}>
    <span className="uppercase">{label}</span>
    <span className="font-mono">v{build.version}</span>
    {build.versionCode != null && <span className="opacity-70">+{build.versionCode}</span>}
  </span>
);
```

- [x] **Step 3: `BuildCell` on Apps Admin table** (two new columns: Latest Release + Latest Debug)

- [x] **Step 4: `PrevBuildBadge` on Release Summary** (matched app lookup via `useMobileApps()`)

---

### Task 4.4: Store sync module

**Files:**
- Create: `backend/src/Products/Autopilot/Mobile/StoreSync.hs`

- [x] **Step 1: Two entry points**

```haskell
module Products.Autopilot.Mobile.StoreSync
    ( storeSyncLoop
    , runStoreSync
    ) where

storeSyncLoop :: Flow ()
storeSyncLoop = do
    enabled <- isStoreSyncEnabled
    when enabled $ do
        runStoreSync `catch` \(e :: SomeException) ->
            logErrorG ("Store sync failed: " <> T.pack (show e))
    intervalMin <- getStoreSyncIntervalMinutes
    liftIO $ threadDelay (Minutes intervalMin)
    storeSyncLoop

runStoreSync :: Flow ()
runStoreSync = do
    apps <- listEnabledAppCatalog
    builds <- fetchLatestBuildsPerApp
    let buildMap = Map.fromList [((lbrAppGroup b, lbrService b, lbrEnv b), b) | b <- builds]
    forM_ apps $ \app -> syncApp app buildMap `catch` \(e :: SomeException) ->
        logWarningG ("Sync failed for " <> acName app <> ": " <> T.pack (show e))
```

- [x] **Step 2: Platform-specific sync**

```haskell
syncApp :: AppCatalog -> BuildMap -> Flow ()
syncApp app buildMap = case acPlatform app of
    "android" -> syncAndroid app buildMap
    "ios"     -> syncIos app buildMap
    _         -> pure ()
```

- [x] **Step 3: Synthetic row shape**

| Column | Value |
|--------|-------|
| `mode` | `'STORE_SYNC'` |
| `created_by` | `'store-sync'` |
| `status` | `'COMPLETED'` |
| `release_context` | Encoded `MobileBuildState` with destination + version code |

Android rows derive `tag_pushed` from naming convention: `{normalizeAppSegment(name)}/prod/android/v{version}+{code}`.

- [x] **Step 4: Version comparison**

```haskell
isNewerAndroid :: TrackInfo -> Maybe LatestBuildRow -> Bool
isNewerAndroid store Nothing = tiName store /= "0.0.0"
isNewerAndroid store (Just lb)
    | tiName store /= lbrVersion lb = tiName store /= "0.0.0"
    | otherwise = tiCode store > fromMaybe 0 (lbrVersionCode lb)
```

---

### Task 4.5: Store sync scheduling + config

**Files:**
- Modify: `backend/src/Products/Autopilot/Runner.hs`
- Modify: `backend/app/Main.hs`
- Modify: `backend/src/Products/Autopilot/RuntimeConfig.hs`
- Create: `backend/dev/migrations/system-control/0015-store-sync-config.sql`

- [x] **Step 1: Fork in Runner + Main**

```haskell
-- Runner.hs (RUNNER mode)
runnerLoop st = do
    runnerStartupRecovery st
    runFlow st $ forkFlow storeSyncLoop
    runnerPollLoop st

-- Main.hs (SERVER mode)
"SERVER" -> do
    _ <- runFlow st $ forkFlow storeSyncLoop
    ...
```

- [x] **Step 2: Runtime config helpers**

```haskell
isStoreSyncEnabled :: (MonadFlow m) => m Bool
getStoreSyncIntervalMinutes :: (MonadFlow m) => m Int
getMobileBuildType :: (MonadFlow m) => m Text   -- "debug" | "release"
```

> **Note (post-refactor):** `storeSyncLoop` now also reads `getMobileBuildType`
> and is a **no-op in a debug env** (`isDebugBuildType`), regardless of
> `store_sync_enabled` — store sync only ever records production store releases.

- [x] **Step 3: Migration**

```sql
-- 0015-store-sync-config.sql
INSERT INTO server_config (type, name, value, product, enabled, last_updated) VALUES
  ('flag', 'store_sync_enabled',           'false', 'autopilot', 0, now()),
  ('flag', 'store_sync_interval_minutes',  '30',    'autopilot', 1, now())
ON CONFLICT DO NOTHING;
```

> **Later migrations:** `0019-version-preview-config.sql` adds
> `version_preview_enabled` (gates `POST /mobile/versions/preview`);
> `0020-mobile-build-type-config.sql` adds `mobile_build_type` (env invariant:
> master=`debug`, prod=`release`). These three mobile flags are registered under
> the **Mobile** config group; `version_preview_enabled` + `store_sync_*` are
> hidden in the debug env UI (release-only), and `mobile_build_type` is hidden
> everywhere (set via migration only, never an editable toggle).

---

## Phase 5 — Store-Sync Revert Integration

> **Superseded 2026-06-02 — store-sync "re-assert" removed.** This phase built a
> separate store-sync revert that re-pushed the *latest* SCC build (possibly a
> *higher* version). That's not a revert. Store-sync rows now go through the same
> version-ordered rollback (Phase 1 Task 1.7 / design §1): target must be a
> strictly-lower good version, else the revert is refused. `findPreviousGoodSCCRelease`,
> `firstNonDebug`, and `draftForStoreSyncRevert` were deleted; both draft and create
> call `resolveRollback`. The Task 5.1/5.2 steps below are kept for history.

### Task 5.1: SCC-only previous-good query

**Files:**
- Modify: `backend/src/Products/Autopilot/Mobile/Queries/Tracker.hs`

- [x] **Step 1: Add `findPreviousGoodSCCRelease`**

```haskell
findPreviousGoodSCCRelease :: (MonadFlow m)
    => Text -> Text -> Text
    -> m (Maybe (ReleaseTrackerRow, Maybe MobileBuildTargetState))
```

This is the **re-assert** target query (distinct from the rollback resolver in Task 1.7):
- No cutoff and no version ordering — finds the *latest* SCC release regardless of when the store-sync row was created
- Excludes `mode = 'STORE_SYNC'` rows
- Still uses `firstNonDebug` to skip debug + reverted rows

---

### Task 5.2: Store-sync aware draft handler

**Files:**
- Modify: `backend/src/Products/Autopilot/Mobile/Handlers/Revert.hs`

- [x] **Step 1: Split draft into two paths**

```haskell
mobileRevertDraftH _ releaseId = do
    bad <- findMobileReleaseById releaseId
    ...
    let isStoreSync = rtMode bad == Just "STORE_SYNC"
    if isStoreSync
        then draftForStoreSyncRevert bad
        else draftForSCCRevert bad
```

- [x] **Step 2: `draftForStoreSyncRevert`**

Uses `findPreviousGoodSCCRelease`, checks if bad store-sync row has a derived `tag_pushed`. If both tags exist, calls Compare API. Otherwise falls back to empty commits with simple changelog.

---

### Task 5.3: Smarter version code suggestions

- [x] **Step 1: Call `fetchLatestBuildsPerApp` during draft**

```haskell
builds <- fetchLatestBuildsPerApp
let storeCode = lookupStoreVersionCode builds (rtAppGroup bad) (rtService bad) (rtEnv bad)
    suggestedCode = max (fromMaybe 0 badCode) (fromMaybe 0 storeCode) + 1
```

- [x] **Step 2: New fields on `RevertDraft`**

```haskell
, rdStoreVersion     :: Maybe Text
, rdStoreVersionCode :: Maybe Int32
```

Shown in a blue info box on the frontend.

- [x] **Step 3: Server-side validation uses same floor**

```haskell
let floor = max (fromMaybe 0 badCode) (fromMaybe 0 storeCode)
when (rrNewVersionCode req <= floor) $
    throwM (BusinessError $ "version_code must be > " <> T.pack (show floor))
```

---

### Task 5.4: Frontend store-sync UI

**Files:**
- Modify: `frontend/src/products/releases/pages/mobile/MobileRevert.tsx`

- [x] Store-sync banner (amber): explains that this is a store-synced release
- [x] All conditionals check actual commit data (`rdCommits.length`, `rdCommitCount`) rather than just the `rdIsStoreSyncRevert` flag
- [x] "Create new release instead" button when no SCC release exists for this app

---

## Phase 6 — Revert Hardening

### Task 6.1: Debug build exclusion

**Files:**
- Modify: `backend/src/Products/Autopilot/Mobile/Handlers/Revert.hs`
- Modify: `backend/src/Products/Autopilot/Mobile/Queries/Tracker.hs`
- Modify: `frontend/src/products/releases/pages/ListRelease.tsx`
- Modify: `frontend/src/products/releases/pages/ReleaseSummary.tsx`

- [x] **Step 1: Backend guard in both handlers**

```haskell
guardNotDebug :: ReleaseTrackerRow -> Flow ()
guardNotDebug row = case parseMobileTargetState row of
    Just s | isDebugDestination (mbcDestination (mbContext s)) ->
        throwM $ BusinessError "Debug builds (Firebase / TestFlight) cannot be reverted."
    _ -> pure ()
```

- [x] **Step 2: Query filtering**

`fetchRevertCandidates` (rollback) and `findPreviousGoodSCCRelease` (re-assert) fetch a bounded window, then drop rows where `isDebugBuildType (mbcBuildType ...)` is true. Since the build type lives inside `release_context` JSONB (not a top-level column), filtering happens in Haskell.

- [x] **Step 3: Frontend — hide revert button**

```tsx
// ListRelease.tsx
const isDebugBuild = dest === 'Firebase' || dest === 'TestFlight';
{!isDebugBuild && <RevertButton ... />}

// ReleaseSummary.tsx — same check on mobile revert button
```

---

### Task 6.2: Revert-of-a-revert & already-reverted guard

> **Reworked 2026-06-01 (B6).** Originally this *blocked* reverting any revert
> build (`guardNotRevertBuild`). That was over-conservative — a revert is a real
> shipped build and must be revertable if it breaks. The block is removed; the
> version-ordered resolver naturally skips the already-reverted original, and the
> `version_code` floor prevents loops. What we now guard is *double-reverting one
> release*.

**Files:**
- Modify: `backend/src/Products/Autopilot/Mobile/Handlers/Revert.hs`
- Modify: `backend/src/Products/Autopilot/Mobile/Workflow.hs`
- Modify: `backend/src/Products/Autopilot/Mobile/Queries/Tracker.hs`
- Modify: `backend/dev/migrations/system-control/0012-mobile-revert.sql`
- Modify: `frontend/src/products/releases/pages/ListRelease.tsx`
- Modify: `frontend/src/products/releases/pages/ReleaseSummary.tsx`

**Why:** Reverting a revert must roll back to the correct *previous* version (not
the original bad one); and two rollbacks of the *same* release must be prevented.

- [x] **Step 1: Allow revert-of-a-revert; guard already-reverted instead**

```haskell
-- No rtRevertsReleaseId block. Block only an already-reverted release:
when' (isReverted bad) $
    BadRequest "This release has already been reverted. Create a new release instead."
```

- [x] **Step 2: Candidate filtering — `isReverted`**

`fetchRevertCandidates` drops rows whose `metadata` contains `"reverted_by"`, so the resolver never picks an already-reverted (e.g. the original bad) release.

- [x] **Step 3: Concurrency — inflight-revert unique index**

`uq_release_tracker_revert_inflight` (migration `0012`) → at most one active revert per bad release.

- [x] **Step 4: Move `markReleaseRevertedBy` to workflow finalize**

Called only when the revert reaches COMPLETED (an aborted revert leaves the bad release revertable again):

```haskell
-- Workflow.hs :: execFinalize
when (newStatus == "COMPLETED") $
    case rtRevertsReleaseId rt of
        Just badId -> markReleaseRevertedBy badId (rtId rt)
        Nothing    -> pure ()
```

- [x] **Step 5: Frontend — revert-of-revert reachable; hide only already-reverted**

```tsx
// dropped the isMobileRevertBuild gate; hide only once already reverted
{release.status === 'COMPLETED' && !isDebugBuild && !release.metadata?.reverted_by
  && <RevertButton ... />}
```

- [x] **Step 6: REVERT badge**

```tsx
const isRevert = !!release.release_context?.revert || !!release.revertsReleaseId;
{isRevert && <span className="bg-violet-50 text-violet-700 ...">REVERT</span>}
```

---

### Task 6.3: Custom commit source for revert

**Files:**
- Modify: `backend/src/Products/Autopilot/Mobile/Github.hs`
- Modify: `backend/src/Products/Autopilot/Mobile/Handlers/Revert.hs`
- Modify: `backend/src/Products/Autopilot/Mobile/Routes.hs`
- Modify: `frontend/src/products/releases/api.ts`
- Modify: `frontend/src/products/releases/pages/mobile/MobileRevert.tsx`

**Why:** GitHub `workflow_dispatch` only accepts branch/tag names. SCC creates a lightweight tag as a bridge for custom commits.

- [x] **Step 1: Two new GitHub helpers**

```haskell
-- Github.hs
createGitRef :: (MonadFlow m)
    => GhAppCreds -> Text -> Text -> Text -> Text -> m (Either Text ())
-- POST /repos/{owner}/{repo}/git/refs  { "ref": "refs/tags/scc-revert/...", "sha": "..." }

getCommitInfo :: (MonadFlow m)
    => GhAppCreds -> Text -> Text -> Text -> m (Either Text CommitDetail)
-- GET /repos/{owner}/{repo}/commits/{sha}

data CommitDetail = CommitDetail
    { cdFullSha    :: Text
    , cdShortSha   :: Text
    , cdSubject    :: Text
    , cdAuthorLogin :: Text
    , cdHtmlUrl    :: Text
    } deriving (Generic, ToJSON)
```

- [x] **Step 2: Verify-commit endpoint**

```haskell
-- Handlers/Revert.hs
verifyCommitH :: AuthedPerson -> Text -> Text -> Flow VerifyCommitResp
verifyCommitH _ releaseId sha = do
    bad <- findMobileReleaseById releaseId
    creds <- loadGhCredsSafe
    ac <- appCatalogForRow bad
    result <- getCommitInfo creds (gitOwner ac) (gitRepo ac) sha
    case result of
        Right detail -> pure $ VerifyCommitResp
            { vcFullSha = cdFullSha detail, vcShortSha = cdShortSha detail
            , vcSubject = cdSubject detail, vcAuthorLogin = cdAuthorLogin detail
            , vcHtmlUrl = cdHtmlUrl detail, vcValid = True, vcError = Nothing }
        Left e -> pure $ VerifyCommitResp { ..., vcValid = False, vcError = Just e }
```

Routes:

```haskell
:<|> "releases" :> Capture "releaseId" Text :> "mobile-revert" :> "verify-commit"
              :> Protected 'AP_RELEASE_REVERT
              :> QueryParam' '[Required, Strict] "sha" Text
              :> Get '[JSON] VerifyCommitResp
-- Live "commits being rolled back" for the selected source (commit/branch/tag):
:<|> "releases" :> Capture "releaseId" Text :> "mobile-revert" :> "diff"
              :> Protected 'AP_RELEASE_REVERT
              :> QueryParam' '[Required, Strict] "source" Text
              :> Get '[JSON] RevertDiffResp
```

- [x] **Step 2b: Live diff handler (`mobileRevertDiffH`)** — runs GitHub Compare between the chosen `source` and the bad release's tag (or `commit_sha`); returns the commits in the bad release not reachable from `source` (`RevertDiffResp { rdfCommits, rdfCommitCount, rdfBaseRef, rdfHeadRef, rdfStatus }`). The FE calls this on every source change so "Commits being rolled back" stays in sync with the selection (not the static draft default).

- [x] **Step 3: Create handler — custom commit path**

In `mobileRevertCreateH`, if `rrSourceCommit` is provided:
1. Verify commit via `getCommitInfo` (resolves short SHA to full)
2. Create tag `scc-revert/<newReleaseId>` at the full SHA via `createGitRef`
3. Use `"refs/tags/scc-revert/<newReleaseId>"` as `source_ref`

- [x] **Step 4: Frontend — source mode toggle**

```tsx
const [sourceMode, setSourceMode] = useState<'prevGood' | 'customCommit'>('prevGood');
const [customCommit, setCustomCommit] = useState('');
const [verifiedCommit, setVerifiedCommit] = useState<VerifyCommitResp | null>(null);

// Radio toggle
<label><input type="radio" ... /> Previous good release</label>
<label><input type="radio" ... /> Custom commit</label>

// Custom commit mode: SHA input + Verify button
{sourceMode === 'customCommit' && (
  <>
    <Input value={customCommit} onChange={...} placeholder="Enter commit SHA" />
    <Button onClick={() => verifyMut.mutate()}>Verify</Button>
    {verifiedCommit?.vcValid && (
      <div className="bg-emerald-50 border border-emerald-200 rounded-lg p-3">
        <span className="font-mono">{verifiedCommit.vcShortSha}</span>
        <span>{verifiedCommit.vcSubject}</span>
        <span>by @{verifiedCommit.vcAuthorLogin}</span>
      </div>
    )}
  </>
)}
```

Validation: submit requires both hex format AND successful verification.

---

## Phase 7 — UI Polish

### Task 7.1: Platform filter on release list

**Files:**
- Modify: `frontend/src/products/releases/pages/ListRelease.tsx`

- [x] **Step 1: Add `platformFilter` state**

```tsx
const [platformFilter, setPlatformFilter] = useState<string>('');
```

- [x] **Step 2: Conditional dropdown when mobile category active**

```tsx
{category === 'mobile' && (
  <select
    value={platformFilter}
    onChange={(e) => setPlatformFilter(e.target.value)}
    className="px-2 py-1.5 text-xs border rounded-lg bg-white"
  >
    <option value="">All Platforms</option>
    <option value="android">Android</option>
    <option value="ios">iOS</option>
  </select>
)}
```

- [x] **Step 3: Filter matches on `release.env`**

```tsx
const matchesPlatform = !platformFilter || r.env === platformFilter;
```

- [x] **Step 4: Auto-reset when category changes**

```tsx
useEffect(() => {
  if (category !== 'mobile') setPlatformFilter('');
}, [category]);
```

- [x] **Step 5: Both desktop and mobile responsive layouts include the dropdown**

---

### Task 7.2: Apps admin table redesign

**Files:**
- Modify: `frontend/src/products/releases/pages/mobile/MobileAppsAdmin.tsx`

- [x] **Step 1: Platform badges**

```tsx
const PlatformBadge = ({ platform }: { platform: string }) => {
  if (platform === 'ios') {
    return (
      <span className="inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide bg-zinc-100 text-zinc-700 border border-zinc-300">
        <Apple className="w-3 h-3" /> iOS
      </span>
    );
  }
  return (
    <span className="inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide bg-[#3DDC84]/15 text-[#1B8A4F] border border-[#3DDC84]/30">
      <AndroidIcon className="w-3 h-3" /> Android
    </span>
  );
};
```

- [x] **Step 2: Compact columns (10 → 7)**

| Before (10 cols) | After (7 cols) |
|---|---|
| Enabled, Name, Surface, Platform, Repo, Release WF, Debug WF, Package, Release Build, Debug Build | **On**, **App** (name+surface), **Platform** (badge), **Workflows** (YAML filename only), **Package**, **Latest Release**, **Latest Debug** |

`wfShort` helper extracts filename from full path:

```tsx
const wfShort = (path: string) => {
  const parts = path.split('/');
  return parts[parts.length - 1] || path;
};
```

- [x] **Step 3: Enabled apps sorted to top**

```tsx
const apps = useMemo(
  () => [...rawApps].sort((a, b) => {
    if (a.enabled !== b.enabled) return a.enabled ? -1 : 1;
    return (a.displayLabel || a.name).localeCompare(b.displayLabel || b.name);
  }),
  [rawApps],
);
```

Disabled rows render at 50% opacity: `className={cn(..., !app.enabled && 'opacity-50')}`.

---

### Task 7.3: Dispatch button on Release Summary

**Files:**
- Modify: `frontend/src/products/releases/pages/ReleaseSummary.tsx`
- Modify: `frontend/src/products/releases/hooks.ts`

- [x] **Step 1: Import and wire**

```tsx
import { useDispatchMobileReleases } from '../hooks';
import { Send } from 'lucide-react';

const dispatchMobileMut = useDispatchMobileReleases();
```

- [x] **Step 2: Dispatch button — appears for CREATED + approved mobile releases**

```tsx
{s === 'CREATED' && isMobile && !!release.is_approved && (
  <PermissionGate product="autopilot" permission="MOBILE_DISPATCH">
    <Button
      size="sm"
      variant="outline"
      className="border-emerald-300 text-emerald-700 hover:bg-emerald-50"
      loading={dispatchMobileMut.isPending}
      onClick={() => doAction(
        'dispatch',
        () => dispatchMobileMut.mutateAsync([id!]),
        false,
        'This will dispatch the GitHub workflow for this release.'
      )}
    >
      <Send className="w-3.5 h-3.5" /> Dispatch
    </Button>
  </PermissionGate>
)}
```

Note: `mobileApi.dispatchReleases` takes `string[]` directly (not `{releaseIds: string[]}`).

- [x] **Step 3: Hook enhancement**

```tsx
export function useDispatchMobileReleases() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: mobileApi.dispatchReleases,
    onSuccess: (resp) => {
      toast.success(`Dispatched ${resp.dispatches.length} workflow${resp.dispatches.length === 1 ? '' : 's'}`);
      qc.invalidateQueries({ queryKey: ['releases'] });
      qc.invalidateQueries({ queryKey: ['release'] });  // so summary page refreshes
    },
    onError: (err: any) => {
      toast.error(err?.response?.data?.message || err.message || 'Failed to dispatch');
    },
  });
}
```

- [x] **Step 4: TypeScript compiles**

```bash
cd frontend && npx tsc --noEmit
```

---

## Phase 9 — Changelog Preview on Create

When creating a new mobile release, show the operator the commits between the last completed release and the selected branch HEAD. Reuses `compareRefs` (GitHub Compare API) and `fetchLatestBuildsPerApp` (latest build query) from earlier phases.

### Task 9.1: Backend — Changelog preview endpoint

**Files:**
- Modify: `backend/src/Products/Autopilot/Mobile/Handlers/Release.hs`
- Modify: `backend/src/Products/Autopilot/Mobile/Github/Compare.hs`
- Modify: `backend/src/Products/Autopilot/Mobile/Queries/Tracker.hs`
- Modify: `backend/src/Products/Autopilot/Mobile/Routes.hs`

- [x] **Step 1: Add `ToJSON` instance for `CommitInfo`** (in `Compare.hs`)
- [x] **Step 2: Export `appCatalogByKey`** (in `Tracker.hs`)
- [x] **Step 3: Define `ChangelogPreviewResp` + implement `changelogPreviewH`** (in `Release.hs`)

Handler flow: look up app catalog entry → `fetchLatestBuildsPerApp` → `findLastReleaseBuild` (filters to `buildType == "release"`, rejects `"debug-no-tag"` sentinel) → `compareRefs` between base tag and branch → cap at 50 commits → build GitHub compare URL.

- [x] **Step 4: Wire route** (in `Routes.hs`)

```haskell
:<|> "mobile" :> "changelog-preview"
      :> Protected 'AP_RELEASE_CREATE
      :> QueryParam' '[Required, Strict] "app" Text
      :> QueryParam' '[Required, Strict] "surface" Text
      :> QueryParam' '[Required, Strict] "platform" Text
      :> QueryParam' '[Required, Strict] "branch" Text
      :> Get '[JSON] ChangelogPreviewResp
```

- [x] **Step 5: `sc-build` passes**

---

### Task 9.2: Frontend — API + hook

**Files:**
- Modify: `frontend/src/products/releases/types.ts`
- Modify: `frontend/src/products/releases/api.ts`
- Modify: `frontend/src/products/releases/hooks.ts`

- [x] **Step 1: Types** — `CommitInfo` and `ChangelogPreviewResp` added to `types.ts`
- [x] **Step 2: API wrapper** — `mobileApi.changelogPreview(app, surface, platform, branch)` in `api.ts`
- [x] **Step 3: Multi-app hook** — `useChangelogPreviews(apps, branch)` using `useQueries` (not single `useQuery`). Fires one parallel query per selected app. Each app gets its own cache key and compare result. `ChangelogApp` type exported for consumers.

---

### Task 9.3: Frontend — Changelog panel on Create form + revert commit list redesign

**Files:**
- Modify: `frontend/src/products/releases/pages/mobile/CreateMobileRelease.tsx`
- Modify: `frontend/src/products/releases/pages/mobile/MobileRevert.tsx`

- [x] **Step 1: Per-app changelog with tabs on Create form**

Derives `changelogApps` from selected IDs. When 2+ apps are selected, a tab bar appears showing each app's label with commit count badge. Each tab shows that app's own changelog (based on its own last release tag as base ref). Single app selection = no tabs. Tab auto-resets when selection changes.

- [x] **Step 2: Enhanced commit row layout**

Both Create form and Revert page share the same commit row style:
- **Newest first** — commits reversed from GitHub API's chronological order
- **Single-row layout**: `# | avatar | SHA link | subject | PR# link | author`
- **GitHub avatars** — 20×20 rounded, lazy-loaded, hidden on error
- **Clickable SHA** — blue link to commit on GitHub
- **Clickable PR#** — blue link derived from commit URL (`/commit/{sha}` → `/pull/{number}`)
- **Author on the right** — muted text, truncated at 100px
- **Row numbers** — subtle counter for easy reference
- **"Showing N of M"** — visible when commits are truncated
- **"View full diff on GitHub"** — compare URL link at bottom

- [x] **Step 3: Debug build exclusion** — changelog panel hidden when build type is "Debug" (`!isDebug` gate), since debug builds don't produce real tags and the comparison base would be misleading.

- [x] **Step 4: Revert page commit list redesigned + made source-reactive** — `MobileRevert.tsx` "Commits being rolled back" section matches the create form style. Originally the list was frozen at the draft's previous-good diff, so selecting a custom commit/branch didn't change it (and a store-synced previous-good with no real diff showed empty). Now it is driven by a live `['mobile-revert-diff', id, effectiveSourceRef]` query against the new `GET …/mobile-revert/diff?source=` endpoint, recomputed whenever the source changes; loading / unverified / empty / error states handled. "View full diff on GitHub" link uses the diff's `rdfBaseRef`/`rdfHeadRef`.

- [x] **Step 5: `npx tsc --noEmit` passes**

---

### Task 9.4: Validate Phase 9

- [x] **Step 1: `sc-build` passes.**
- [x] **Step 2: `npx tsc --noEmit` passes.**
- [ ] **Step 3: Select an app + branch on Create form → changelog panel shows commits.**
- [ ] **Step 4: Click "View full diff on GitHub" → opens correct compare URL in new tab.**
- [ ] **Step 5: Change branch → panel updates with new commits (debounced).**
- [ ] **Step 6: Select multiple apps → tabs appear, each with own changelog.**
- [ ] **Step 7: Switch to Debug build type → changelog panel hidden.**
- [ ] **Step 8: Revert page → commits shown newest first with same row layout + "View full diff on GitHub".**

**Risk:** Low — read-only feature, doesn't affect release creation. Compare API is slow (~500ms) but query is cached and non-blocking.

**Rollback:** Revert Phase 9 commits. No schema changes.

---

## Migration map

```
0012-mobile-revert.sql                    commit_sha, source_ref, reverts_release_id + indexes + uq_release_tracker_revert_inflight (B6)
0013-local-mobile-revert-test-data.sql    test data for revert dev (local only)
0015-store-sync-config.sql                store_sync_enabled, store_sync_interval_minutes
0019-version-preview-config.sql           version_preview_enabled (gates /mobile/versions/preview)
0020-mobile-build-type-config.sql         mobile_build_type (env invariant: master=debug, prod=release)
0021-store-sync-dedup.sql                 partial unique index uq_release_tracker_store_sync (dedup synthetic rows)
```

## Key modules added/modified

| Module | Purpose |
|--------|---------|
| `Mobile/Github/Compare.hs` | GitHub Compare API client — `compareRefs`, `CommitInfo`, `CompareResult` |
| `Mobile/Changelog.hs` | Revert changelog renderer (`renderRevertChangelog`) + `bumpPatch` |
| `Mobile/Handlers/Revert.hs` | Draft + create + verify-commit + live-diff (`mobileRevertDiffH`) handlers; version-ordered rollback (B6); store-sync rows revert via the same resolver (re-assert removed) |
| `Mobile/StoreSync.hs` | Periodic store sync background job — `storeSyncLoop`, `runStoreSync` |
| `Mobile/Github.hs` | `listBranches`, `searchBranches`, `createGitRef`, `getCommitInfo`, `CommitDetail` |
| `Mobile/Workflow.hs` | `source_ref` dispatch, `commit_sha` capture, debug stage skipping, `markReleaseRevertedBy` in finalize |
| `Mobile/Handlers/Release.hs` | `sourceRef` on create, `listBranchesH` with search, matrix job name suffix, `changelogPreviewH` + `ChangelogPreviewResp` |
| `Mobile/Handlers/AppCatalog.hs` | Latest build enrichment |
| `Mobile/RevertResolver.hs` | Pure rollback resolver (B6) — `seqKey`/`compareSeq`/`parseSemver`/`resolveRollback`, target-vs-source split |
| `Mobile/Queries/Tracker.hs` | `fetchRevertCandidates` (B6, replaced `findPreviousGoodMobileRelease`/`findPreviousGoodSCCRelease`), `isReverted`, `markReleaseRevertedBy` |
| `Mobile/Queries/AppCatalog.hs` | `fetchLatestBuildsPerApp` — raw SQL with `ROW_NUMBER() OVER (PARTITION BY ...)` |
| `RuntimeConfig.hs` | `isStoreSyncEnabled`, `getStoreSyncIntervalMinutes` |

## Frontend files added/modified

| File | Features |
|------|----------|
| `pages/mobile/MobileRevert.tsx` | Full revert page: draft preview, editable fields, source mode toggle (prev good / custom commit), store-sync banner, version validation, **source-reactive** "commits being rolled back" (live `/mobile-revert/diff` query, newest first, row layout, GitHub diff link) |
| `pages/mobile/CreateMobileRelease.tsx` | Branch combobox (debounced server search), build type toggle, `LatestBuildBadge` per app card, version fields, per-app changelog preview with tabs |
| `pages/mobile/MobileAppsAdmin.tsx` | Redesigned 7-column table: `PlatformBadge`, `wfShort`, `BuildCell`, enabled-first sort, 50% opacity disabled rows |
| `pages/ListRelease.tsx` | Platform filter dropdown, revert button (debug excluded; revert-of-revert reachable; hidden once already reverted), DEBUG badge, REVERT badge |
| `pages/ReleaseSummary.tsx` | Dispatch button (CREATED + approved mobile), revert banners (reverted-by / reverts), source branch field, `PrevBuildBadge`, DEBUG/REVERT badges |
| `hooks.ts` | `useMobileBranches(search?)` with `placeholderData: keepPreviousData`, `useDispatchMobileReleases` with toast + invalidation, `useChangelogPreviews(apps, branch)` with `useQueries` |
| `api.ts` | `getMobileRevertDraft`, `createMobileRevert`, `verifyRevertCommit`, `listBranches(q?)`, `changelogPreview(app, surface, platform, branch)`, `RevertDraft`, `VerifyCommitResp` |
| `types.ts` | `LatestBuild`, `BranchInfo`, `BuildType`, `destinationFor`, `destinationsForPlatform`, `MobileDestination` (extended with iOS), `CommitInfo`, `ChangelogPreviewResp` |

## Ship order

- **Phase 1 first** — without `commit_sha` capture and `source_ref` plumbing, nothing else works.
- **Phase 2 next** — branch picker reuses `source_ref` column from Phase 1.
- **Phase 3** — debug builds are independent but affect Phase 6's exclusion logic.
- **Phase 4** — latest build enrichment feeds into Phase 5's version suggestions.
- **Phase 5** — store-sync revert depends on Phase 4's store sync module.
- **Phase 6** — hardening (debug exclusion, revert-of-a-revert + already-reverted guard, custom commit) layers on Phase 1's revert flow.
- **Phase 7** — pure UI polish, no backend dependencies.
- **Phase 8: Deep-link to Firebase Crashlytics** — no public read REST API, so in-app dashboards are not possible. Instead: added `firebase_project_id` column to `app_catalog` (migration 0017), Crashlytics sidebar link in Mobile Releases, and a per-release Crashlytics button on ReleaseSummary that deep-links with project + package name + version + version code.
- **Phase 9** — independent of all other phases. Reuses `compareRefs` (Phase 1) and `fetchLatestBuildsPerApp` (Phase 4). No schema changes.

---

## References

- Consolidated spec: `docs/superpowers/specs/2026-05-18-mobile-releases-post-mvp-design.md`
- Base MVP spec: `docs/superpowers/specs/2026-05-11-mobile-releases-design.md`
- Base MVP plan: `docs/superpowers/plans/2026-05-11-mobile-releases.md`
- Future scope: `docs/MOBILE_RELEASE_FUTURE_SCOPE.md`
- Roadmap: `docs/MOBILE_RELEASE_ROADMAP.md`
- DB schema: `docs/DATABASE.md`
