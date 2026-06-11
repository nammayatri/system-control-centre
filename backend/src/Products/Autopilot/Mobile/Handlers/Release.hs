{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- | HTTP handlers for the user-facing mobile release endpoints.

* @POST /releases/mobile/create@ — drafts N mobile release rows in one
  shot (one per app the user picked), all sharing a freshly-minted
  @release_group_id@.

* @POST /releases/mobile/dispatch@ — bundles approved release rows into
  GitHub workflow dispatches grouped by
  @(github_repo, workflow_path, surface, platform)@ and assigns
  @dispatch_id@s. Status stays at @CREATED@ so the runner's
  'findRunnableReleaseTrackers' picks the rows up on its next tick and
  CAS-claims them as INPROGRESS itself. Gated by the
  @mobile_dispatch_enabled@ feature flag (@server_config@); short-circuits
  with a 400 BadRequest when the flag is missing or not "true".
-}
module Products.Autopilot.Mobile.Handlers.Release (
    -- * Create
    CreateMobileReleasesItem (..),
    CreateMobileReleasesReq (..),
    CreatedReleaseSummary (..),
    CreateMobileReleasesResp (..),
    createMobileReleasesH,

    -- * Dispatch
    DispatchMobileReleasesReq (..),
    DispatchInfo (..),
    DispatchMobileReleasesResp (..),
    dispatchMobileReleasesH,

    -- * Branches
    BranchesResp (..),
    listBranchesH,

    -- * Changelog preview
    ChangelogPreviewResp (..),
    changelogPreviewH,

    -- * Create-time AI changelog summary
    AiSummaryResp (..),
    changelogAiSummaryH,
) where

import Control.Monad (unless, void, when)
import Control.Monad.Catch (throwM)
import Core.AppError (APIError (..))
import Core.Auth.Protected (AuthedPerson (..))
import Core.DB.Connection (runDB)
import Core.Environment (Flow, forkFlow, withDb)
import Data.Aeson (FromJSON (..), Options (..), ToJSON (..), defaultOptions, genericToJSON, object, (.=))
import Data.Int (Int32)
import Data.List (nub, partition, sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, getCurrentTime)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import Database.Beam
import Products.Autopilot.Mobile.Github (BranchInfo (..), listBranches, searchBranches)
import Products.Autopilot.Mobile.Github.Auth (loadGhCreds)
import Products.Autopilot.Mobile.Github.Compare (CommitInfo (..), CompareResult (..), compareAllCommits, compareRefs)
import Products.Autopilot.Mobile.Queries.AppCatalog (LatestBuildRow (..), fetchLatestBuildsForApp, findAppCatalogByIds, listAppCatalog, listEnabledAppCatalog)
import Products.Autopilot.Mobile.Queries.Tracker (
    ReleaseTrackerRow,
    appCatalogByKey,
    gitOwner,
    gitRepo,
    logEvent,
    mkMobileTrackerRow,
 )
import Products.Autopilot.Mobile.Types (
    MobileBuildContext (..),
    MobileBuildTargetState (..),
    MobileBuildWFStatus (..),
    isDebugBuildType,
 )
import Products.Autopilot.Mobile.Types.Storage (
    AppCatalog,
    AppCatalogT (..),
 )
import Products.Autopilot.Queries.ReleaseTracker (TrackerWithTarget, findReleaseTrackersByIds, insertReleaseTrackerRowsBatch)
import Products.Autopilot.RuntimeConfig (getMobileBuildType)
import qualified Shared.AI.Changelog as CL
import Shared.AI.Config (loadAiConfig)
import Shared.AI.Queries (claimReleaseSummary, computePromptHash, lookupReleaseSummary, upsertReleaseSummary)
import Shared.AI.ReleaseSummary (generateWithFallback)
import Products.Autopilot.Types.Release (
    ReleaseStatus (..),
    ReleaseTracker (..),
 )
import qualified Products.Autopilot.Types.Release as RT
import Products.Autopilot.Types.Storage.Schema (
    AutopilotDb (..),
    ReleaseTrackerT (..),
    autopilotDb,
 )
import Products.Autopilot.Types.Target (TargetState (..))
import Shared.Queries.ServerConfig (getEnabledServerConfigValueForProduct)

-- ─── Create: request / response types ──────────────────────────────

data CreateMobileReleasesItem = CreateMobileReleasesItem
    { appCatalogId :: Int32
    , versionName :: Maybe Text
    , versionCode :: Maybe Int32
    }
    deriving (Generic, Show)

instance ToJSON CreateMobileReleasesItem where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}
instance FromJSON CreateMobileReleasesItem

data CreateMobileReleasesReq = CreateMobileReleasesReq
    { releaseGroupLabel :: Maybe Text
    , changeLog :: Text
    , sourceRef :: Maybe Text
    , items :: [CreateMobileReleasesItem]
    , destination :: Maybe Text
    -- ^ Store destination ("GooglePlay" / "Firebase") for provider PROD
    -- Android builds. Optional: only the provider-prod-Android dispatch reads
    -- it; absent (older clients, or any non-provider-Android selection) means
    -- the dispatch falls back to "GooglePlay".
    }
    deriving (Generic, Show)

instance ToJSON CreateMobileReleasesReq where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}
instance FromJSON CreateMobileReleasesReq

data CreatedReleaseSummary = CreatedReleaseSummary
    { id :: Text
    , appCatalogId :: Int32
    , status :: Text
    }
    deriving (Generic, Show)

instance ToJSON CreatedReleaseSummary
instance FromJSON CreatedReleaseSummary

data CreateMobileReleasesResp = CreateMobileReleasesResp
    { releaseGroupId :: Text
    , releases :: [CreatedReleaseSummary]
    }
    deriving (Generic, Show)

instance ToJSON CreateMobileReleasesResp
instance FromJSON CreateMobileReleasesResp

-- ─── Create handler ───────────────────────────────────────────────

{- | Draft N mobile release rows (one per selected app) under one
@release_group_id@.

Validate-before-write (mirrors the backend @createReleaseH@ guard chain): the
request is fully checked — non-empty items, non-empty changelog, no duplicate
@appCatalogId@, and every id exists — BEFORE any row is written. The N inserts
then commit in a single transaction ('insertReleaseTrackerRowsBatch'), so a
create is all-or-nothing: a bad request leaves zero rows, never a partial group.

Note: version fields aren't validated here — for release builds the workflow's
ResolveVersion stage resolves @version_name@/@version_code@ from the store
(authoritative), and debug builds carry no version. The create-time values are
preview suggestions only.
-}
createMobileReleasesH :: AuthedPerson -> CreateMobileReleasesReq -> Flow CreateMobileReleasesResp
createMobileReleasesH ap CreateMobileReleasesReq{..} = do
    -- ── Validate everything up front (no partial writes) ──
    when (null items) $ throwM $ BadRequest "items must be non-empty"
    when (T.null (T.strip changeLog)) $ throwM $ BadRequest "changeLog must not be empty"
    let aids = [a | CreateMobileReleasesItem{appCatalogId = a} <- items]
    when (length (nub aids) /= length aids) $
        throwM $
            BadRequest "items contains duplicate appCatalogId"
    apps <- findAppCatalogByIds aids
    let appById = Map.fromList [(acId a, a) | a <- apps]
        missing = [a | a <- aids, not (Map.member a appById)]
    unless (null missing) $
        throwM $
            BadRequest ("unknown app_catalog_id(s): " <> T.intercalate ", " (map (T.pack . show) missing))
    -- ── Build all rows, then insert atomically ──
    -- Build type is fixed per deployment env (master = debug, prod = release)
    -- via the mobile_build_type config flag — not chosen by the caller.
    buildType <- getMobileBuildType
    groupId <- liftIO (UUID.toText <$> UUID.nextRandom)
    now <- liftIO getCurrentTime
    built <- mapM (buildRow ap appById groupId changeLog buildType destination sourceRef now) items
    insertReleaseTrackerRowsBatch (map fst built)
    pure
        CreateMobileReleasesResp
            { releaseGroupId = groupId
            , releases = map snd built
            }

{- | Build one tracker row + its response summary. The app is looked up from the
pre-validated map ('createMobileReleasesH' has already proved every id exists),
so this performs no DB read — only a fresh release-id mint.
-}
buildRow ::
    AuthedPerson ->
    Map.Map Int32 AppCatalog ->
    Text ->
    Text ->
    Text ->
    Maybe Text ->
    -- ^ destination (provider prod Android only)
    Maybe Text ->
    -- ^ source ref
    UTCTime ->
    CreateMobileReleasesItem ->
    Flow (ReleaseTrackerRow, CreatedReleaseSummary)
buildRow ap appById groupId changeLog_ buildType mDestination mSourceRef now CreateMobileReleasesItem{appCatalogId = aid, versionName = mVer, versionCode = mCode} = do
    rid <- liftIO (UUID.toText <$> UUID.nextRandom)
    -- safe: createMobileReleasesH validated that every id is present in appById
    let app_ = appById Map.! aid
        -- The destination input only exists on provider-prod-apk-gen.yaml, so
        -- only stamp it on provider (driver) + Android + release rows. Everything
        -- else stores Nothing (the dispatch ignores it for those builds anyway).
        isProviderProdAndroid =
            acSurface app_ == "driver"
                && acPlatform app_ == "android"
                && not (isDebugBuildType buildType)
        ctx =
            MobileBuildContext
                { mbcVersionCode = mCode
                , mbcChangeLog = changeLog_
                , mbcBuildType = buildType
                , mbcReleaseGroupId = groupId
                , mbcMatrixJobName = acName app_ <> if isDebugBuildType buildType then "-Debug" else "-Release"
                , mbcOtaNamespace = Nothing
                , mbcTagPushed = Nothing
                , mbcDestination = if isProviderProdAndroid then mDestination else Nothing
                }
        target =
            MobileBuildTargetState
                { mbWfStatus = MBInit
                , mbContext = ctx
                , mbExternalRunId = Nothing
                , mbMatrixJobStatus = Nothing
                , mbBuildStartedAt = Nothing
                , mbBuildCompletedAt = Nothing
                , mbResolveAttempts = Nothing
                , mbReviewSubmittedAt = Nothing
                , mbReviewLastPolledAt = Nothing
                }
        row = mkMobileTrackerRow rid app_ target mVer mSourceRef (apEmail ap) now
    pure
        ( row
        , CreatedReleaseSummary
            { id = rid
            , appCatalogId = aid
            , status = "CREATED"
            }
        )

-- ─── Dispatch: request / response types ───────────────────────────

newtype DispatchMobileReleasesReq = DispatchMobileReleasesReq
    { releaseIds :: [Text]
    }
    deriving (Generic, Show)

instance ToJSON DispatchMobileReleasesReq
instance FromJSON DispatchMobileReleasesReq

data DispatchInfo = DispatchInfo
    { dispatchId :: Text
    , workflowPath :: Text
    , releaseIdsInDisp :: [Text]
    , expectedRunUrl :: Maybe Text
    -- ^ Always Nothing at dispatch time; filled later by the runner once
    -- it resolves the GH run URL.
    }
    deriving (Generic, Show)

instance ToJSON DispatchInfo where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}
instance FromJSON DispatchInfo

newtype DispatchMobileReleasesResp = DispatchMobileReleasesResp
    { dispatches :: [DispatchInfo]
    }
    deriving (Generic, Show)

instance ToJSON DispatchMobileReleasesResp where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}
instance FromJSON DispatchMobileReleasesResp

-- ─── Dispatch handler ─────────────────────────────────────────────

dispatchMobileReleasesH :: AuthedPerson -> DispatchMobileReleasesReq -> Flow DispatchMobileReleasesResp
dispatchMobileReleasesH _ap DispatchMobileReleasesReq{releaseIds = rids} = do
    -- Phase-1 kill-switch (per spec): until @mobile_dispatch_enabled@
    -- flips to "true" the SCC stays a no-op for mobile — the row exists
    -- but no GH workflow is dispatched and no runner work is started.
    -- We gate ONLY this endpoint, not the runner: rows already
    -- in-flight (dispatched before the flag was flipped off) continue
    -- to drive their workflow to completion. A lookup miss / disabled
    -- row / non-"true" value all count as "off".
    enabledStr <- getEnabledServerConfigValueForProduct "mobile_dispatch_enabled" (Just "autopilot")
    let enabled = enabledStr == Just "true"
    unless enabled $
        throwM $
            BadRequest "Mobile dispatch is currently disabled by the mobile_dispatch_enabled feature flag"
    case rids of
        [] -> throwM $ BadRequest "releaseIds must be non-empty"
        _ -> pure ()
    -- Batch both lookups up front (was an N+1: findReleaseTracker +
    -- loadAppCatalogFor per release). One tracker query + one catalog read,
    -- then pure per-release validation against the maps.
    trackerById <-
        Map.fromList . map (\twt@(rt, _) -> (releaseId rt, twt))
            <$> findReleaseTrackersByIds rids
    acByKey <-
        Map.fromList . map (\a -> ((acName a, acSurface a, acPlatform a), a))
            <$> listAppCatalog
    loaded <- mapM (validateForDispatch trackerById acByKey) rids
    -- Group by (github_repo, workflow_path, surface, platform). Each
    -- group maps to one workflow_dispatch — siblings in a group are
    -- tied to the same dispatch_id so the workflow can run them as one
    -- matrix job set.
    let groups :: [(GroupKey, [(ReleaseTracker, AppCatalog, Maybe TargetState)])]
        groups = Map.toList $ Map.fromListWith (<>) [(groupKey ac, [triple]) | triple@(_, ac, _) <- loaded]
    infos <- mapM dispatchOne groups
    pure DispatchMobileReleasesResp{dispatches = infos}

-- | Composite grouping key for one workflow_dispatch.
type GroupKey = (Text, Text, Text, Text)

groupKey :: AppCatalog -> GroupKey
groupKey ac = (acGithubRepo ac, acWorkflowPath ac, acSurface ac, acPlatform ac)

{- | Verify a release is in a state where dispatch is allowed: status=CREATED,
is_approved=True, target state is MobileBuild, and a matching @app_catalog@ row
exists. Throws 'BadRequest' (with the failing release id) on any violation.

Pure over pre-fetched maps (tracker-by-id, app-catalog-by-(name,surface,platform))
— the dispatch handler batches both lookups, so this performs no DB read. The
'Maybe TargetState' is carried along so 'logDispatchEvent' can read the
release_group_id out of the MobileBuild context.
-}
validateForDispatch ::
    Map.Map Text TrackerWithTarget ->
    Map.Map (Text, Text, Text) AppCatalog ->
    Text ->
    Flow (ReleaseTracker, AppCatalog, Maybe TargetState)
validateForDispatch trackerById acByKey rid =
    case Map.lookup rid trackerById of
        Nothing -> throwM $ BadRequest ("release not found: " <> rid)
        Just (rt, mTs) -> do
            case mTs of
                Just (MobileBuildState _) -> pure ()
                _ ->
                    throwM $
                        BadRequest ("release is not a MobileBuild release: " <> rid)
            case RT.status rt of
                CREATED -> pure ()
                s ->
                    throwM $
                        BadRequest
                            ( "release "
                                <> rid
                                <> " is not in CREATED status (current: "
                                <> T.pack (show s)
                                <> ")"
                            )
            unless (RT.isApproved rt) $
                throwM $
                    BadRequest ("release " <> rid <> " is not approved; cannot dispatch")
            case Map.lookup (appGroup rt, service rt, env rt) acByKey of
                Just ac -> pure (rt, ac, mTs)
                Nothing ->
                    throwM $
                        BadRequest
                            ( "release "
                                <> rid
                                <> " has no matching app_catalog row for ("
                                <> appGroup rt
                                <> ", "
                                <> service rt
                                <> ", "
                                <> env rt
                                <> ")"
                            )

{- | Mint a dispatch_id, atomically tag every row in the group with that
dispatch_id, and append a per-row DISPATCH_REQUESTED event. Returns a
'DispatchInfo' summarising the group; @expectedRunUrl@ is left
Nothing — the runner fills it once GH resolves the run.

We deliberately leave @status = 'CREATED'@ here. The runner picks up
@(status='CREATED' AND is_approved=true)@ rows on its next tick (see
'findRunnableReleaseTrackers') and atomically claims them via
'conditionalUpdateTrackerRow' before dispatching the workflow. If we
flipped to INPROGRESS here, the runner would never pick the row up
and the seven-stage mobile workflow would never run.

@is_approved@ is left untouched: dispatch precondition (validated in
'loadAndValidate') already requires @is_approved = true@, so the
approval lifecycle has happened before we get here.
-}
dispatchOne ::
    (GroupKey, [(ReleaseTracker, AppCatalog, Maybe TargetState)]) ->
    Flow DispatchInfo
dispatchOne ((_, wfPath, _, _), triples) = do
    did <- liftIO (UUID.toText <$> UUID.nextRandom)
    now <- liftIO getCurrentTime
    let rids = sortOn Prelude.id [releaseId rt | (rt, _, _) <- triples]
    -- Single SQL UPDATE so all sibling rows in the group share the
    -- dispatch_id atomically. Status stays CREATED (see haddock above).
    withDb $ \db ->
        runDB db $
            runUpdate $
                update
                    (releaseTrackers autopilotDb)
                    ( \rt ->
                        mconcat
                            [ rtDispatchId rt <-. val_ (Just did)
                            , rtUpdatedAt rt <-. val_ now
                            ]
                    )
                    (\rt -> rtId rt `in_` map val_ rids)
    -- Per-row business event so the audit trail records who entered which dispatch.
    mapM_ (logDispatchEvent did) triples
    pure
        DispatchInfo
            { dispatchId = did
            , workflowPath = wfPath
            , releaseIdsInDisp = rids
            , expectedRunUrl = Nothing
            }

{- | Append a BUSINESS / DISPATCH_REQUESTED event including the
release_group_id from the tracker's MobileBuild context and the
assigned dispatch_id.
-}
logDispatchEvent :: Text -> (ReleaseTracker, AppCatalog, Maybe TargetState) -> Flow ()
logDispatchEvent did (rt, _ac, mTs) = do
    let groupId = case mTs of
            Just (MobileBuildState s) -> Just (mbcReleaseGroupId (mbContext s))
            _ -> Nothing
    logEvent (releaseId rt) "DISPATCH_REQUESTED" $
        object
            [ "release_group_id" .= groupId
            , "dispatch_id" .= did
            ]

-- ─── Branches ────────────────────────────────────────────────────

newtype BranchesResp = BranchesResp
    { branches :: [BranchInfo]
    }
    deriving (Generic, Show)

instance ToJSON BranchesResp
instance FromJSON BranchesResp

listBranchesH :: AuthedPerson -> Maybe Text -> Flow BranchesResp
listBranchesH _ap mQuery = do
    apps <- listEnabledAppCatalog
    case apps of
        [] -> throwM $ BadRequest "No enabled apps in catalog"
        (ac : _) -> do
            creds <- loadGhCreds
            let owner = gitOwner ac
                repo = gitRepo ac
            result <- case mQuery of
                Just q | not (T.null q) -> searchBranches creds owner repo q
                _ -> do
                    res <- listBranches creds owner repo
                    pure $ fmap pinMain res
            case result of
                Left e -> throwM $ BadRequest ("GitHub API error: " <> e)
                Right bs -> pure BranchesResp{branches = bs}
  where
    pinMain :: [BranchInfo] -> [BranchInfo]
    pinMain bs =
        let (mains, rest) = partition (\b -> biName b == "main" || biName b == "master") bs
         in mains ++ rest

-- ─── Changelog preview ──────────────────────────────────────────

data ChangelogPreviewResp = ChangelogPreviewResp
    { cpCommits :: [CommitInfo]
    , cpAheadBy :: Int
    , cpStatus :: Text
    , cpBaseTag :: Maybe Text
    , cpBaseVersion :: Maybe Text
    , cpCompareUrl :: Maybe Text
    }
    deriving (Generic, Show)

instance ToJSON ChangelogPreviewResp where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}

changelogPreviewH :: AuthedPerson -> Text -> Text -> Text -> Text -> Flow ChangelogPreviewResp
changelogPreviewH _ap appName surface platform branch = do
    ac <- appCatalogByKey appName surface platform
    creds <- loadGhCreds
    let owner = gitOwner ac
        repo = gitRepo ac
    builds <- fetchLatestBuildsForApp appName surface platform
    let lastRelease = findLastReleaseBuild builds appName surface platform
    case lastRelease of
        Nothing ->
            pure emptyPreview
        Just lb -> do
            let baseRef = case lbrTagPushed lb of
                    Just t | not (T.null t) && t /= "debug-no-tag" -> t
                    _ -> case lbrCommitSha lb of
                        Just s | not (T.null s) -> s
                        _ -> ""
            if T.null baseRef
                then pure emptyPreview
                else do
                    result <- compareRefs creds owner repo baseRef branch
                    case result of
                        Right cr -> do
                            -- Compare returns at most 250 commits, oldest-first. If the
                            -- release has more, fetch the full set newest-first via List
                            -- Commits; otherwise just reverse the compare list
                            -- (oldest-first → newest-first). Either way cpCommits is
                            -- newest-first and the UI renders it verbatim.
                            commits <-
                                if crTotalCommits cr > length (crCommits cr)
                                    then do
                                        -- compareAllCommits paginates Compare and returns
                                        -- oldest-first; reverse for newest-first display.
                                        eAll <- compareAllCommits creds owner repo baseRef branch
                                        pure $ case eAll of
                                            Right cs -> reverse cs
                                            Left _ -> reverse (crCommits cr)
                                    else pure (reverse (crCommits cr))
                            pure
                                ChangelogPreviewResp
                                    { cpCommits = commits
                                    , cpAheadBy = crTotalCommits cr
                                    , cpStatus = crStatus cr
                                    , cpBaseTag = lbrTagPushed lb
                                    , cpBaseVersion = Just (lbrVersion lb)
                                    , cpCompareUrl =
                                        Just $
                                            "https://github.com/"
                                                <> owner
                                                <> "/"
                                                <> repo
                                                <> "/compare/"
                                                <> baseRef
                                                <> "..."
                                                <> branch
                                    }
                        Left _ ->
                            pure emptyPreview
  where
    emptyPreview =
        ChangelogPreviewResp
            { cpCommits = []
            , cpAheadBy = 0
            , cpStatus = "unknown"
            , cpBaseTag = Nothing
            , cpBaseVersion = Nothing
            , cpCompareUrl = Nothing
            }

findLastReleaseBuild :: [LatestBuildRow] -> Text -> Text -> Text -> Maybe LatestBuildRow
findLastReleaseBuild builds appName surface platform =
    case filter matches builds of
        (x : _) -> Just x
        [] -> Nothing
  where
    matches b =
        lbrAppGroup b == appName
            && lbrSurface b == surface
            && lbrPlatform b == platform
            && lbrBuildType b == "release"

-- ─── Create-time AI changelog summary ───────────────────────────
--
-- Summarise the commits being released BEFORE the release exists. Reuses the
-- same commit-gathering as 'changelogPreviewH'; the cache subject is the commit
-- RANGE (content-keyed), not a release id. Gated by 'AP_AI_SUMMARIZE'.

data AiSummaryResp = AiSummaryResp
    { available :: Bool
    , status :: Text
    -- ^ "ready" | "pending" | "failed" | "unavailable"
    , reason :: Maybe Text
    , summaryLong :: Maybe Text
    -- ^ AI prose (chunked); deterministic fallback while pending/failed
    , summaryShort :: Maybe Text
    -- ^ AI 2-3 line synopsis (only when ready)
    , model :: Maybe Text
    }
    deriving (Generic, Show)

instance ToJSON AiSummaryResp where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}

aiUnavailable :: Text -> AiSummaryResp
aiUnavailable r =
    AiSummaryResp
        { available = False
        , status = "unavailable"
        , reason = Just r
        , summaryLong = Nothing
        , summaryShort = Nothing
        , model = Nothing
        }

renderCommitsForAi :: [CommitInfo] -> Text
renderCommitsForAi cs =
    T.unlines
        ["- " <> ciShortSha c <> " " <> ciSubject c <> " (@" <> ciAuthorLogin c <> ")" | c <- cs]

toCommitItem :: CommitInfo -> CL.CommitItem
toCommitItem c = CL.CommitItem (ciShortSha c) (ciSubject c) (ciAuthorLogin c)

{- | Build the response for a lifecycle state. @summaryLong@ always carries
something to render — AI when @ready@, the deterministic changelog while
@pending@ — so the UI never blanks. A non-empty @model@ ⇒ the UI badges it as AI;
empty/absent ⇒ auto-generated.
-}
stateResp :: Text -> Text -> Text -> Maybe Text -> AiSummaryResp
stateResp st longTxt shortTxt mModel =
    AiSummaryResp
        { available = True
        , status = st
        , reason = Nothing
        , summaryLong = Just longTxt
        , summaryShort = if T.null (T.strip shortTxt) then Nothing else Just shortTxt
        , model = mModel
        }

changelogAiSummaryH :: AuthedPerson -> Text -> Text -> Text -> Text -> Maybe Text -> Maybe Text -> Flow AiSummaryResp
changelogAiSummaryH ap appName surface platform branch mVersionName mVersionCode = do
    ac <- appCatalogByKey appName surface platform
    creds <- loadGhCreds
    let owner = gitOwner ac
        repo = gitRepo ac
    builds <- fetchLatestBuildsForApp appName surface platform
    case findLastReleaseBuild builds appName surface platform of
        Nothing -> pure (aiUnavailable "no prior release build to compare against")
        Just lb -> do
            let baseRef = case lbrTagPushed lb of
                    Just t | not (T.null t) && t /= "debug-no-tag" -> t
                    _ -> case lbrCommitSha lb of
                        Just s | not (T.null s) -> s
                        _ -> ""
            if T.null baseRef
                then pure (aiUnavailable "no base ref to compare against")
                else do
                    result <- compareRefs creds owner repo baseRef branch
                    case result of
                        Left e -> pure (aiUnavailable ("changelog fetch failed: " <> e))
                        Right cr -> do
                            let commits = crCommits cr
                                -- Scope to the selected app's surface (drop the
                                -- other side's commits; keep this side + shared).
                                items = CL.filterCommitsForSurface surface (map toCommitItem commits)
                                detLong = CL.renderLongSummary items
                                n = length items
                                excluded = length commits - n
                                vName = maybe "" T.strip mVersionName
                                vCode = maybe "" T.strip mVersionCode
                                versionStr
                                    | T.null vName = ""
                                    | T.null vCode = "v" <> vName
                                    | otherwise = "v" <> vName <> "+" <> vCode
                                appLabel = appName <> " (" <> CL.ownSideLabel surface <> ")"
                                -- Generic one-liner for summary_short when AI is off or
                                -- every model fails (no app name — usable as release notes).
                                detShort = CL.renderShortSummary items
                                -- "rn4" = generation version. Bump it whenever the
                                -- prompt/format changes so cached rows invalidate.
                                contentKey =
                                    computePromptHash $
                                        T.intercalate "\US" ["rn4", appName, surface, platform, branch, versionStr, renderCommitsForAi commits]
                            mRow <- lookupReleaseSummary contentKey
                            case mRow of
                                -- Done → return the AI (or cached deterministic) result.
                                Just ("ready", mLong, mShort, mModel, _) ->
                                    pure (stateResp "ready" (fromMaybe detLong mLong) (fromMaybe "" mShort) mModel)
                                -- Not ready → ensure a DETACHED generation is running and return
                                -- immediately. The work outlives this request and the browser tab.
                                _ -> do
                                    ecfg <- loadAiConfig
                                    case ecfg of
                                        Left _ -> do
                                            -- AI off/unconfigured: the deterministic changelog IS the result.
                                            upsertReleaseSummary contentKey detLong detShort "" n
                                            pure (stateResp "ready" detLong detShort Nothing)
                                        Right cfg -> do
                                            -- One generator per content key; reclaims a failed row or a
                                            -- pending row orphaned by a restart (see 'claimReleaseSummary').
                                            claimed <- claimReleaseSummary contentKey detLong n
                                            when claimed $
                                                void $
                                                    forkFlow $ do
                                                        mRes <- generateWithFallback (apEmail ap) cfg appLabel versionStr excluded (CL.otherSideLabel surface) items
                                                        case mRes of
                                                            Just (lng, sht, usedModel) -> upsertReleaseSummary contentKey lng sht usedModel n
                                                            -- Every model failed → store the deterministic
                                                            -- changelog as the ready result (model="" ⇒ "auto").
                                                            Nothing -> upsertReleaseSummary contentKey detLong detShort "" n
                                            -- A concurrent generation may have just finished; otherwise
                                            -- report pending with the deterministic placeholder.
                                            st <- lookupReleaseSummary contentKey
                                            pure $ case st of
                                                Just ("ready", mLong, mShort, mModel, _) ->
                                                    stateResp "ready" (fromMaybe detLong mLong) (fromMaybe "" mShort) mModel
                                                _ -> stateResp "pending" detLong "" Nothing
