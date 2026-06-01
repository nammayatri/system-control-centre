{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- | Cross-cutting helpers used by the mobile workflow stages and the
mobile create endpoint. Concerns split out of the workflow modules so
T12-T14 (workflow stages) and T17 (create endpoint) can share a single
source of truth for the dispatch-group + AppCatalog joins, the
ResolveRunId attempt counter, and tracker INSERTs.

Note: 'loadGhCreds' lives in @Products.Autopilot.Mobile.Github.Auth@ and
'loadPlayCreds' lives in @Products.Autopilot.Mobile.Versioning@; this
module deliberately does not redefine them.
-}
module Products.Autopilot.Mobile.Queries.Tracker (
    findSiblingsByDispatchId,
    setExternalRunIdForDispatch,
    incrementResolveAttempts,
    appCatalogForRow,
    appCatalogForRowRaw,
    appCatalogByKey,
    logEvent,
    gitOwner,
    gitRepo,
    insertMobileTracker,
    mkMobileTrackerRow,
    -- Revert helpers
    fetchRevertCandidates,
    findPreviousGoodSCCRelease,
    findMobileReleaseById,
    parseMobileTargetState,
    insertMobileRevertTracker,
    markReleaseRevertedBy,
    isReverted,
    ReleaseTrackerRow,
) where

import Control.Monad.Catch (throwM)
import Core.AppError (DBError (..))
import Core.DB.Connection (runDB)
import Core.Environment (MonadFlow, withDb)
import Data.Aeson (Value)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as AK
import qualified Data.Aeson.KeyMap as KM
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (UTCTime)
import Database.Beam
import Products.Autopilot.Mobile.RevertResolver (RevertCand (..))
import Products.Autopilot.Mobile.Types (
    MobileBuildContext (..),
    MobileBuildTargetState (..),
    isDebugBuildType,
 )
import Products.Autopilot.Mobile.Types.Storage (
    AppCatalog,
    AppCatalogT (..),
 )
import Products.Autopilot.Queries.ReleaseTracker (
    encodeJsonText,
    insertReleaseEvent,
    insertReleaseTrackerRow,
    parseMode,
    parseReleaseCategory,
    parseReleaseStatus,
    parseReleaseWFStatus,
 )
import Products.Autopilot.Types.Release (
    Mode,
    ReleaseStatus,
    ReleaseTracker (..),
 )
import Products.Autopilot.Types.Storage.Schema (
    AutopilotDb (..),
    ReleaseTrackerT (..),
    autopilotDb,
 )
import Products.Autopilot.Types.Target (TargetState (..))
import Products.Autopilot.Types.Workflow (ReleaseCategory, ReleaseWFStatus)

{- | All tracker rows in the same dispatch group, paired with their
@AppCatalog@ row. The join key is @(app_group, surface, platform)@,
which uniquely identifies a catalog entry (DB unique constraint).

Rows whose catalog entry has been deleted are silently dropped (INNER
JOIN); the mobile workflow never expects this to happen, but it's
safer than crashing the worker tick.
-}
findSiblingsByDispatchId ::
    (MonadFlow m) =>
    Text ->
    m [(ReleaseTracker, AppCatalog)]
findSiblingsByDispatchId dispatchId = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (\(rt, _) -> asc_ (rtId rt)) $ do
                        rt <- all_ (releaseTrackers autopilotDb)
                        ac <- all_ (appCatalogs autopilotDb)
                        guard_ (rtDispatchId rt ==. val_ (Just dispatchId))
                        guard_ (acName ac ==. rtAppGroup rt)
                        guard_ (acSurface ac ==. rtService rt)
                        guard_ (acPlatform ac ==. rtEnv rt)
                        pure (rt, ac)
    pure (map (\(rt, ac) -> (rowToDomain rt, ac)) rows)

{- | Set @external_run_id@ and @commit_sha@ on every tracker row in the
dispatch group. A single SQL UPDATE so siblings can never disagree on
which GHA run they're tied to or which commit they built from.

@commit_sha@ is the @head_sha@ returned by the GH run API — i.e. the
SHA of HEAD at dispatch time on whichever ref the dispatch carried
(branch or tag). All siblings in the dispatch group share the same
ref, so they all carry the same SHA.
-}
setExternalRunIdForDispatch ::
    (MonadFlow m) =>
    Text ->
    Text ->
    Text ->
    m ()
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

{- | Bump the ResolveRunId attempt counter stored in the tracker's
@release_context@ JSON (a @MobileBuildTargetState@ wrapped in
@TargetState.MobileBuildState@). Returns the post-increment value so
the caller can decide whether to give up.

Concurrency: this is a read-modify-write loop, not a SQL-side
increment. The mobile worker drives ResolveRunId from a single tick
loop, so concurrent bumps on the same row don't happen in practice.
-}
incrementResolveAttempts ::
    (MonadFlow m) =>
    Text ->
    m Int
incrementResolveAttempts releaseId' = withDb $ \db -> do
    mRow <-
        runDB db $
            runSelectReturningOne $
                select $ do
                    rt <- all_ (releaseTrackers autopilotDb)
                    guard_ (rtId rt ==. val_ releaseId')
                    pure rt
    case mRow of
        Nothing ->
            throwM $
                DBError "incrementResolveAttempts" $
                    "release_tracker not found for id=" <> releaseId'
        Just row -> do
            let prev = rtTargetState row >>= decodeMobile
                next = case prev of
                    Just s ->
                        let n = fromMaybe 0 (mbResolveAttempts s) + 1
                         in s{mbResolveAttempts = Just n}
                    Nothing ->
                        throwImpureBecauseRowIsNotMobile releaseId'
                newCount = fromMaybe 0 (mbResolveAttempts next)
                encoded = encodeJsonText (MobileBuildState next)
            runDB db $
                runUpdate $
                    update
                        (releaseTrackers autopilotDb)
                        (\rt -> rtTargetState rt <-. val_ (Just encoded))
                        (\rt -> rtId rt ==. val_ releaseId')
            pure newCount
  where
    decodeMobile :: Text -> Maybe MobileBuildTargetState
    decodeMobile t = case Aeson.eitherDecodeStrict (TE.encodeUtf8 t) of
        Right (MobileBuildState s) -> Just s
        _ -> Nothing

    -- Helper to keep the case branch readable. If the row is not a
    -- MobileBuild tracker (or has lost its context), the caller is
    -- buggy: incrementResolveAttempts is only valid for mobile rows.
    throwImpureBecauseRowIsNotMobile :: Text -> a
    throwImpureBecauseRowIsNotMobile rid =
        error $
            "incrementResolveAttempts: tracker "
                <> T.unpack rid
                <> " has no MobileBuildState release_context"

{- | Look up the AppCatalog row for a tracker. Throws 'DBError' on miss
because a well-formed mobile tracker row always has a matching catalog
entry (enforced at create time).
-}
appCatalogForRow ::
    (MonadFlow m) =>
    ReleaseTracker ->
    m AppCatalog
appCatalogForRow rt = appCatalogByKey (appGroup rt) (service rt) (env rt)

{- | Row-variant of 'appCatalogForRow'. Same lookup, but takes the raw
Beam row so callers that haven't projected to the domain type (e.g.
the revert handler) don't need to construct a stub 'ReleaseTracker'.
-}
appCatalogForRowRaw ::
    (MonadFlow m) =>
    ReleaseTrackerRow ->
    m AppCatalog
appCatalogForRowRaw rt = appCatalogByKey (rtAppGroup rt) (rtService rt) (rtEnv rt)

appCatalogByKey ::
    (MonadFlow m) =>
    Text ->
    Text ->
    Text ->
    m AppCatalog
appCatalogByKey nameK surfaceK platformK = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    ac <- all_ (appCatalogs autopilotDb)
                    guard_ (acName ac ==. val_ nameK)
                    guard_ (acSurface ac ==. val_ surfaceK)
                    guard_ (acPlatform ac ==. val_ platformK)
                    pure ac
    case rows of
        (x : _) -> pure x
        [] ->
            throwM $
                DBError "appCatalogForRow" $
                    "no app_catalog row for ("
                        <> nameK
                        <> ", "
                        <> surfaceK
                        <> ", "
                        <> platformK
                        <> ")"

{- | Generic BUSINESS-category event emitter. Wraps
@insertReleaseEvent@ from the autopilot query module so mobile callers
don't have to thread the category string through every site.
-}
logEvent ::
    (MonadFlow m) =>
    Text ->
    Text ->
    Value ->
    m ()
logEvent rid label payload = insertReleaseEvent rid "BUSINESS" label payload

-- | Owner part of an @"owner/repo"@ slug from an AppCatalog row.
gitOwner :: AppCatalog -> Text
gitOwner ac = T.takeWhile (/= '/') (acGithubRepo ac)

-- | Repo part of an @"owner/repo"@ slug from an AppCatalog row.
gitRepo :: AppCatalog -> Text
gitRepo ac = T.drop 1 (T.dropWhile (/= '/') (acGithubRepo ac))

{- | Insert a fully-formed mobile tracker row. The release_context
column is populated with @MobileBuildState target@ encoded as JSON
text, so workflow stages can deserialize it via the standard
'TargetState' parser. @dispatch_id@ and @external_run_id@ are left
NULL — the dispatch endpoint sets them later.

The underlying @insertReleaseTrackerRow@ does DELETE + INSERT in a
transaction, so a stale row with the same id is replaced. The mobile
create flow generates fresh UUIDs so this collision path should not
fire.
-}
insertMobileTracker ::
    (MonadFlow m) =>
    Text ->
    AppCatalog ->
    MobileBuildTargetState ->
    Maybe Text ->
    Maybe Text ->
    Text ->
    UTCTime ->
    m ()
insertMobileTracker rid ac targetState mVersionName mSourceRef createdBy_ createdAt =
    insertReleaseTrackerRow (mkMobileTrackerRow rid ac targetState mVersionName mSourceRef createdBy_ createdAt)

{- | Pure builder for a fresh MobileBuild @release_tracker@ row (status CREATED,
mode MANUAL, unapproved). Extracted from 'insertMobileTracker' so the create
handler can build N rows and insert them in one transaction via
'insertReleaseTrackerRowsBatch'.
-}
mkMobileTrackerRow ::
    Text ->
    AppCatalog ->
    MobileBuildTargetState ->
    Maybe Text ->
    Maybe Text ->
    Text ->
    UTCTime ->
    ReleaseTrackerRow
mkMobileTrackerRow rid ac targetState mVersionName mSourceRef createdBy_ createdAt = row
  where
    versionName = fromMaybe "" mVersionName
    encodedCtx = encodeJsonText (MobileBuildState targetState)
    row =
        ReleaseTrackerT
            { rtId = rid
            , rtOldVersion = ""
            , rtNewVersion = versionName
            , rtAppGroup = acName ac
            , rtService = acSurface ac
            , rtPriority = 0
            , rtEnv = acPlatform ac
            , rtCategory = "MobileBuild"
            , rtStatus = "CREATED"
            , rtReleaseWFStatus = "INIT"
            , rtMode = Just "MANUAL"
            , rtCreatedBy = createdBy_
            , rtApprovedBy = Nothing
            , rtIsApproved = Just False
            , rtIsInfraApproved = Just False
            , -- release_tag is NOT NULL in the schema; default it to the
              -- release id so the row inserts cleanly. The dispatch flow
              -- can overwrite this later if it needs a human-readable tag.
              rtReleaseTag = Just rid
            , rtScheduleTime = Nothing
            , rtStartTime = Nothing
            , rtEndTime = Nothing
            , rtRolloutStrategy = Nothing
            , rtRolloutHistory = Nothing
            , rtTargetState = Just encodedCtx
            , rtInfo = Nothing
            , rtDescription = Nothing
            , rtChangeLog = Nothing
            , rtMetadata = Nothing
            , rtGlobalId = Nothing
            , rtSyncEnabled = Nothing
            , rtEnvOverrideData = Nothing
            , rtSlackThreadTs = Nothing
            , rtDispatchId = Nothing
            , rtExternalRunId = Nothing
            , rtCommitSha = Nothing
            , rtSourceRef = mSourceRef
            , rtRevertsReleaseId = Nothing
            , rtCreatedAt = createdAt
            , rtUpdatedAt = createdAt
            }

-- ─── Internal helpers ──────────────────────────────────────────────

{- | Project a raw 'ReleaseTrackerRow' to the domain 'ReleaseTracker'
needed by callers of 'findSiblingsByDispatchId'. Mirrors the shape of
'fromRow' in @Products.Autopilot.Queries.ReleaseTracker@ but exposes a
narrower projection: mobile callers don't need the parsed
'TargetState' here (they get it from their own scheduler tick), and we
deliberately skip the K8s-specific 'releaseContext' summary.
-}
rowToDomain :: ReleaseTrackerT Identity -> ReleaseTracker
rowToDomain ReleaseTrackerT{..} =
    ReleaseTracker
        { releaseId = rtId
        , appGroup = rtAppGroup
        , service = rtService
        , env = rtEnv
        , category = parseCategory rtCategory
        , status = parseStatus rtStatus
        , releaseWFStatus = parseWFStatus rtReleaseWFStatus
        , mode = parseModeT rtMode
        , createdBy = rtCreatedBy
        , approvedBy = rtApprovedBy
        , isApproved = fromMaybe False rtIsApproved
        , isInfraApproved = fromMaybe False rtIsInfraApproved
        , releaseTag = rtReleaseTag
        , dateCreated = Just rtCreatedAt
        , lastUpdated = Just rtUpdatedAt
        , scheduleTime = rtScheduleTime
        , startTime = rtStartTime
        , endTime = rtEndTime
        , rolloutStrategy = []
        , rolloutHistory = []
        , oldVersion = rtOldVersion
        , newVersion = rtNewVersion
        , info = rtInfo
        , description = rtDescription
        , changeLog = rtChangeLog
        , metadata = Nothing
        , priority = rtPriority
        , globalId = rtGlobalId
        , syncEnabled = rtSyncEnabled
        , envOverrideData = rtEnvOverrideData
        , slackThreadTs = rtSlackThreadTs
        , releaseContext = Nothing
        , sourceRef = rtSourceRef
        , commitSha = rtCommitSha
        , revertsReleaseId = rtRevertsReleaseId
        }

parseCategory :: Text -> ReleaseCategory
parseCategory = parseReleaseCategory

parseStatus :: Text -> ReleaseStatus
parseStatus = parseReleaseStatus

parseWFStatus :: Text -> ReleaseWFStatus
parseWFStatus = parseReleaseWFStatus

parseModeT :: Maybe Text -> Mode
parseModeT = parseMode

-- ─── Revert helpers ────────────────────────────────────────────────

{- | Decode a @release_tracker.release_context@ string into a
'MobileBuildTargetState'. Returns @Nothing@ for backend rows (whose
target state is K8s-shaped) and for rows whose JSON failed to parse.

The revert handler needs this to read @mbcTagPushed@ (the tag pushed
by the workflow at release time — used as the dispatch ref for
revert) and @mbcVersionCode@ (the version code that shipped, so we
can compute @bad + 1@ for the revert).
-}
parseMobileTargetState :: Maybe Text -> Maybe MobileBuildTargetState
parseMobileTargetState Nothing = Nothing
parseMobileTargetState (Just t) =
    case Aeson.eitherDecodeStrict (TE.encodeUtf8 t) of
        Right (MobileBuildState s) -> Just s
        _ -> Nothing

{- | Fetch a single mobile release tracker by ID, paired with its
parsed mobile target state. Returns @Nothing@ if the row is not found
or is not a mobile release.
-}
findMobileReleaseById ::
    (MonadFlow m) =>
    Text ->
    m (Maybe (ReleaseTrackerRow, Maybe MobileBuildTargetState))
findMobileReleaseById releaseId' = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    rt <- all_ (releaseTrackers autopilotDb)
                    guard_ (rtId rt ==. val_ releaseId')
                    guard_ (rtCategory rt ==. val_ "MobileBuild")
                    pure rt
    pure $ case rows of
        (row : _) -> Just (row, parseMobileTargetState (rtTargetState row))
        [] -> Nothing

{- | Fetch the window of rollback candidates for an app: COMPLETED,
non-debug, non-reverted mobile releases for the same
@(app_group, service, env)@, excluding the bad release itself. Store-sync
rows are __included__ — they record real versions users were on, so they
are valid rollback targets (the resolver handles the case where such a
target has no SCC build artifact).

The window is bounded (most recent 50 by @created_at@) purely to cap the
row set; the actual rollback target is then chosen by /version order/, not
creation time — see "Products.Autopilot.Mobile.RevertResolver". The B4
store-sync dedup index keeps this window from filling with duplicates. If
an app ever outgrows 50, promote @version_code@ to an indexed column and
resolve with a single ordered @LIMIT 1@ (see post-MVP design §15).

Filtering of debug / reverted rows happens in Haskell because that state
lives inside the @target_state@ / @metadata@ JSON columns.
-}
fetchRevertCandidates ::
    (MonadFlow m) =>
    -- | app_group (app name, e.g. "NammaYatri")
    Text ->
    -- | service (surface, e.g. "customer")
    Text ->
    -- | env (platform, e.g. "android")
    Text ->
    -- | id of the bad release, excluded from the window
    Text ->
    m [RevertCand]
fetchRevertCandidates appGroup' service' env' excludeId = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    limit_ 50 $
                        orderBy_ (desc_ . rtCreatedAt) $ do
                            rt <- all_ (releaseTrackers autopilotDb)
                            guard_ (rtCategory rt ==. val_ "MobileBuild")
                            guard_ (rtAppGroup rt ==. val_ appGroup')
                            guard_ (rtService rt ==. val_ service')
                            guard_ (rtEnv rt ==. val_ env')
                            guard_ (rtStatus rt ==. val_ "COMPLETED")
                            guard_ (rtId rt /=. val_ excludeId)
                            pure rt
    pure (mapMaybe toCand rows)
  where
    toCand row
        | isReverted row = Nothing
        | otherwise =
            let mState = parseMobileTargetState (rtTargetState row)
             in case mState of
                    Just st | isDebugBuildType (mbcBuildType (mbContext st)) -> Nothing
                    _ ->
                        Just
                            RevertCand
                                { rcId = rtId row
                                , rcVersionName = rtNewVersion row
                                , rcVersionCode = mState >>= mbcVersionCode . mbContext
                                , rcTag = mState >>= mbcTagPushed . mbContext
                                , rcCommitSha = rtCommitSha row
                                , rcCreatedAt = rtCreatedAt row
                                }

findPreviousGoodSCCRelease ::
    (MonadFlow m) =>
    Text ->
    Text ->
    Text ->
    m (Maybe (ReleaseTrackerRow, Maybe MobileBuildTargetState))
findPreviousGoodSCCRelease appGroup' service' env' = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    limit_ 20 $
                        orderBy_ (desc_ . rtCreatedAt) $ do
                            rt <- all_ (releaseTrackers autopilotDb)
                            guard_ (rtCategory rt ==. val_ "MobileBuild")
                            guard_ (rtAppGroup rt ==. val_ appGroup')
                            guard_ (rtService rt ==. val_ service')
                            guard_ (rtEnv rt ==. val_ env')
                            guard_ (rtStatus rt ==. val_ "COMPLETED")
                            guard_ (rtMode rt /=. val_ (Just "STORE_SYNC"))
                            pure rt
    pure (firstNonDebug rows)

firstNonDebug :: [ReleaseTrackerRow] -> Maybe (ReleaseTrackerRow, Maybe MobileBuildTargetState)
firstNonDebug [] = Nothing
firstNonDebug (row : rest)
    | isReverted row = firstNonDebug rest
    | otherwise =
        case parseMobileTargetState (rtTargetState row) of
            Just st | isDebugBuildType (mbcBuildType (mbContext st)) -> firstNonDebug rest
            parsed -> Just (row, parsed)

isReverted :: ReleaseTrackerRow -> Bool
isReverted row = case rtMetadata row of
    Nothing -> False
    Just t -> case Aeson.eitherDecodeStrict (TE.encodeUtf8 t) of
        Right (Aeson.Object o) -> KM.member (AK.fromText "reverted_by") o
        _ -> False

-- Re-export to keep the import surface tight for callers that need
-- the Beam row type without pulling Schema in directly.
type ReleaseTrackerRow = ReleaseTrackerT Identity

{- | Insert a mobile revert tracker row. Differs from the normal
'insertMobileTracker' in three places:

* @source_ref@ is set to @refs\/tags\/<previous-good-tag>@ so the
  dispatched workflow checks out the previous good commit.
* @reverts_release_id@ links back to the release being reverted.
* @change_log@ is provided up-front (auto-generated from the Compare
  API by the caller; operator may have edited it in the UI).

Other fields mirror 'insertMobileTracker': status = CREATED,
isApproved = False, dispatch_id = NULL (the operator hits the
existing dispatch endpoint once the revert is approved).
-}
insertMobileRevertTracker ::
    (MonadFlow m) =>
    -- | new release id (UUID)
    Text ->
    -- | app catalog row matching the bad release
    AppCatalog ->
    -- | initial target state (mbContext.versionCode = bad+1, etc.)
    MobileBuildTargetState ->
    -- | new version name (e.g. "1.2.4")
    Text ->
    -- | change log (auto-generated; operator may have edited)
    Text ->
    -- | source_ref (e.g. "refs/tags/nammayatri/prod/android/v1.2.2+450")
    Text ->
    -- | reverts_release_id (the bad release's id)
    Text ->
    -- | created_by (operator email from AuthedPerson)
    Text ->
    UTCTime ->
    m ()
insertMobileRevertTracker rid ac targetState versionName changeLog_ sourceRef_ revertsId createdBy_ createdAt =
    insertReleaseTrackerRow row
  where
    encodedCtx = encodeJsonText (MobileBuildState targetState)
    row =
        ReleaseTrackerT
            { rtId = rid
            , rtOldVersion = ""
            , rtNewVersion = versionName
            , rtAppGroup = acName ac
            , rtService = acSurface ac
            , rtPriority = 0
            , rtEnv = acPlatform ac
            , rtCategory = "MobileBuild"
            , rtStatus = "CREATED"
            , rtReleaseWFStatus = "INIT"
            , rtMode = Just "MANUAL"
            , rtCreatedBy = createdBy_
            , rtApprovedBy = Nothing
            , rtIsApproved = Just False
            , rtIsInfraApproved = Just False
            , rtReleaseTag = Just rid
            , rtScheduleTime = Nothing
            , rtStartTime = Nothing
            , rtEndTime = Nothing
            , rtRolloutStrategy = Nothing
            , rtRolloutHistory = Nothing
            , rtTargetState = Just encodedCtx
            , rtInfo = Nothing
            , rtDescription = Nothing
            , rtChangeLog = Just changeLog_
            , rtMetadata = Nothing
            , rtGlobalId = Nothing
            , rtSyncEnabled = Nothing
            , rtEnvOverrideData = Nothing
            , rtSlackThreadTs = Nothing
            , rtDispatchId = Nothing
            , rtExternalRunId = Nothing
            , rtCommitSha = Nothing
            , rtSourceRef = Just sourceRef_
            , rtRevertsReleaseId = Just revertsId
            , rtCreatedAt = createdAt
            , rtUpdatedAt = createdAt
            }

{- | Stamp @metadata.reverted_by = <revertId>@ on the bad release row.
Drives the "⤴ Reverted by X" banner on the bad release's detail page.

Implementation: read the existing @metadata@ JSON (or @{}@ if NULL),
set the @reverted_by@ key, write it back. Single UPDATE.
-}
markReleaseRevertedBy ::
    (MonadFlow m) =>
    -- | bad release id
    Text ->
    -- | revert release id
    Text ->
    m ()
markReleaseRevertedBy badId revertId = withDb $ \db -> do
    -- Read existing metadata.
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    rt <- all_ (releaseTrackers autopilotDb)
                    guard_ (rtId rt ==. val_ badId)
                    pure (rtMetadata rt)
    -- Merge existing keys with the new "reverted_by" key. If the
    -- existing metadata is missing or not an object, start fresh.
    let existingMap :: KM.KeyMap Aeson.Value
        existingMap = case rows of
            (Just existing : _) ->
                case Aeson.eitherDecodeStrict (TE.encodeUtf8 existing) of
                    Right (Aeson.Object o) -> o
                    _ -> KM.empty
            _ -> KM.empty
        updated =
            Aeson.Object
                ( KM.insert "reverted_by" (Aeson.String revertId) existingMap
                )
        encoded = encodeJsonText updated
    runDB db $
        runUpdate $
            update
                (releaseTrackers autopilotDb)
                (\rt -> rtMetadata rt <-. val_ (Just encoded))
                (\rt -> rtId rt ==. val_ badId)
