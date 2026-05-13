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
    logEvent,
    gitOwner,
    gitRepo,
    insertMobileTracker,
) where

import Control.Monad.Catch (throwM)
import Core.AppError (DBError (..))
import Core.DB.Connection (runDB)
import Core.Environment (MonadFlow, withDb)
import Data.Aeson (Value)
import qualified Data.Aeson as Aeson
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (UTCTime)
import Database.Beam
import Products.Autopilot.Mobile.Types (
    MobileBuildTargetState (..),
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

{- | Set @external_run_id@ on every tracker row in the dispatch group.
A single SQL UPDATE so siblings can never disagree on which GHA run
they're tied to.
-}
setExternalRunIdForDispatch ::
    (MonadFlow m) =>
    Text ->
    Text ->
    m ()
setExternalRunIdForDispatch dispatchId runId = withDb $ \db ->
    runDB db $
        runUpdate $
            update
                (releaseTrackers autopilotDb)
                (\rt -> rtExternalRunId rt <-. val_ (Just runId))
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
appCatalogForRow rt = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    ac <- all_ (appCatalogs autopilotDb)
                    guard_ (acName ac ==. val_ (appGroup rt))
                    guard_ (acSurface ac ==. val_ (service rt))
                    guard_ (acPlatform ac ==. val_ (env rt))
                    pure ac
    case rows of
        (x : _) -> pure x
        [] ->
            throwM $
                DBError "appCatalogForRow" $
                    "no app_catalog row for ("
                        <> appGroup rt
                        <> ", "
                        <> service rt
                        <> ", "
                        <> env rt
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
    Text ->
    UTCTime ->
    m ()
insertMobileTracker rid ac targetState mVersionName createdBy_ createdAt =
    insertReleaseTrackerRow row
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
        }

parseCategory :: Text -> ReleaseCategory
parseCategory = parseReleaseCategory

parseStatus :: Text -> ReleaseStatus
parseStatus = parseReleaseStatus

parseWFStatus :: Text -> ReleaseWFStatus
parseWFStatus = parseReleaseWFStatus

parseModeT :: Maybe Text -> Mode
parseModeT = parseMode
