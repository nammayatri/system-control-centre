{-# LANGUAGE OverloadedStrings #-}

module Products.Autopilot.Queries.ReleaseTracker
  ( -- * Insert / Update
    insertReleaseTracker,
    conditionalUpdateTracker,
    conditionalUpdateTrackerRow,
    insertReleaseTrackerRow,

    -- * Queries
    findReleaseTracker,
    listReleaseEvents,
    listReleaseTrackers,
    listReleaseTrackersByDateRange,
    findRunnableReleaseTrackers,
    findInProgressReleaseTrackers,
    findCleanupScheduledTrackers,
    findAbortingReleaseTrackers,
    findOngoingReleaseTrackers,
    findTrackersWithStatusAndTime,
    findApprovedReleasesWithStatus,
    findReleaseTrackersByCategory,
    findReleaseTrackerByGlobalId,
    findCompletedTrackersForScaleDown,

    -- * Events
    insertReleaseEvent,

    -- * Delete
    deleteReleaseTracker,
    deleteReleaseEvents,

    -- * Misc / Update helpers
    updateReleaseTrackerSlackThreadTs,

    -- * Row conversion
    toRow,
    fromRow,

    -- * Parsing / Encoding helpers
    parseReleaseCategory,
    parseReleaseWFStatus,
    parseReleaseStatus,
    parseMode,
    releaseStatusToText,
    modeToText,
    parseDecisionEngineHSStatus,
    encodeJsonText,
    parseJsonTextOr,
    parseJsonTextMaybe,

    -- * Internal
    safeHead,
    TrackerWithTarget,
  )
where

import Core.DB.Connection (runDB, withConn)
import Core.Environment (DBEnv)
import Data.Aeson (FromJSON, ToJSON, Value, eitherDecode, encode, toJSON)
import qualified Data.ByteString.Lazy as BSL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (NominalDiffTime, UTCTime, addUTCTime, getCurrentTime)
import Database.Beam
import Database.Beam.Postgres
import Database.PostgreSQL.Simple (Only (..), execute, withTransaction)
import Products.Autopilot.Types
import qualified Products.Autopilot.Types as NT
import Products.Autopilot.Types.Target (TargetState (..))
import Products.Autopilot.Types.Target.Kubernetes
import Products.Autopilot.Types.Storage.Schema

-- | Type alias for tracker + target state pair
type TrackerWithTarget = (ReleaseTracker, Maybe TargetState)

insertReleaseTracker :: DBEnv -> ReleaseTracker -> Maybe TargetState -> IO ()
insertReleaseTracker db rt mts = do
  now <- getCurrentTime
  let row = toRow now now rt mts
  -- Atomic: DELETE+INSERT in a single transaction (if INSERT fails, DELETE is rolled back)
  withConn db $ \conn ->
    withTransaction conn $ do
      execute conn "DELETE FROM release_tracker WHERE id = ?" (Only (releaseId rt))
      runBeamPostgres conn $ runInsert $ insert (releaseTrackers autopilotDb) $ insertValues [row]

-- | Atomically update a release tracker only if its current status matches the expected value.
-- Uses DELETE ... WHERE id = ? AND status = ? to prevent concurrent modifications.
-- Returns True if the update succeeded, False if the status was changed by another thread.
conditionalUpdateTracker :: DBEnv -> ReleaseTracker -> Maybe TargetState -> Text -> IO Bool
conditionalUpdateTracker db rt mts expectedStatus = do
  now <- getCurrentTime
  let row = toRow now now rt mts
  withConn db $ \conn ->
    withTransaction conn $ do
      rowsDeleted <-
        execute
          conn
          "DELETE FROM release_tracker WHERE id = ? AND status = ?"
          (releaseId rt, expectedStatus)
      if rowsDeleted == 0
        then pure False
        else do
          runBeamPostgres conn $ runInsert $ insert (releaseTrackers autopilotDb) $ insertValues [row]
          pure True

-- | Like 'conditionalUpdateTracker' but accepts a raw 'ReleaseTrackerRow'.
-- Returns True if the update succeeded, False if the status was changed by another thread.
conditionalUpdateTrackerRow :: DBEnv -> ReleaseTrackerRow -> Text -> IO Bool
conditionalUpdateTrackerRow db row expectedStatus =
  withConn db $ \conn ->
    withTransaction conn $ do
      rowsDeleted <-
        execute
          conn
          "DELETE FROM release_tracker WHERE id = ? AND status = ?"
          (rtId row, expectedStatus)
      if rowsDeleted == 0
        then pure False
        else do
          runBeamPostgres conn $ runInsert $ insert (releaseTrackers autopilotDb) $ insertValues [row]
          pure True

findReleaseTracker :: DBEnv -> Text -> IO (Maybe TrackerWithTarget)
findReleaseTracker db rid = do
  rows <-
    runDB db $
      runSelectReturningList $
        select $
          do
            rt <- all_ (releaseTrackers autopilotDb)
            guard_ (rtId rt ==. val_ rid)
            pure rt
  pure $ fmap fromRow (safeHead rows)

listReleaseEvents :: DBEnv -> Text -> IO [ReleaseEvent]
listReleaseEvents db rid =
  runDB db $
    runSelectReturningList $
      select $ do
        ev <- all_ (releaseEvents autopilotDb)
        guard_ (reReleaseId ev ==. val_ rid)
        pure ev

listReleaseTrackers :: DBEnv -> IO [TrackerWithTarget]
listReleaseTrackers db = do
  rows <-
    runDB db $
      runSelectReturningList $
        select $
          orderBy_ (desc_ . rtCreatedAt) $ do
            rt <- all_ (releaseTrackers autopilotDb)
            pure rt
  pure (map fromRow rows)

listReleaseTrackersByDateRange :: DBEnv -> UTCTime -> UTCTime -> IO [TrackerWithTarget]
listReleaseTrackersByDateRange db fromTime toTime = do
  rows <-
    runDB db $
      runSelectReturningList $
        select $
          orderBy_ (desc_ . rtCreatedAt) $ do
            rt <- all_ (releaseTrackers autopilotDb)
            guard_ (rtCreatedAt rt >=. val_ fromTime)
            guard_ (rtCreatedAt rt <=. val_ toTime)
            -- Exclude VS edits and ConfigMap changes (shown in their own sections)
            guard_ (rtCategory rt /=. val_ "VSEdit")
            guard_ (rtCategory rt /=. val_ "BackendConfig")
            pure rt
  pure (map fromRow rows)

-- | Find releases ready to be dispatched. Only picks CREATED status.
-- INPROGRESS releases are NOT re-dispatched — on server restart, they are
-- rolled back (matching Julia production behavior: rollbackReleaseInProgress).
findRunnableReleaseTrackers :: DBEnv -> UTCTime -> IO [TrackerWithTarget]
findRunnableReleaseTrackers db now = do
  rows <-
    runDB db $
      runSelectReturningList $
        select $
          orderBy_ (asc_ . rtCreatedAt) $ do
            rt <- all_ (releaseTrackers autopilotDb)
            guard_ (rtStatus rt ==. val_ "CREATED")
            pure rt
  let parsed = map fromRow rows
      isDue (tracker, _) = case scheduleTime tracker of
        Nothing -> True
        Just t -> t <= now
      isApproved' (tracker, _) = isApproved tracker
  pure (filter (\t -> isDue t && isApproved' t) parsed)

-- | Find all INPROGRESS releases (for rollback on startup).
findInProgressReleaseTrackers :: DBEnv -> IO [TrackerWithTarget]
findInProgressReleaseTrackers db = do
  rows <-
    runDB db $
      runSelectReturningList $
        select $
          orderBy_ (asc_ . rtCreatedAt) $ do
            rt <- all_ (releaseTrackers autopilotDb)
            guard_ (rtStatus rt `in_` [val_ "INPROGRESS", val_ "PAUSED", val_ "REVERTING"])
            pure rt
  pure (map fromRow rows)

findCleanupScheduledTrackers :: DBEnv -> UTCTime -> IO [TrackerWithTarget]
findCleanupScheduledTrackers db now = do
  rows <-
    runDB db $
      runSelectReturningList $
        select $
          orderBy_ (asc_ . rtUpdatedAt) $ do
            rt <- all_ (releaseTrackers autopilotDb)
            guard_ (rtStatus rt `in_` [val_ "COMPLETED", val_ "ABORTED", val_ "USER_ABORTED"])
            pure rt
  let parsed = map fromRow rows
      isDue (_, mts) =
        case mts of
          Just (K8sState k8s) ->
            let ctx = context k8s
             in case podsScaleDownTimestamp ctx of
                  Just t -> t <= now && podsScaleDownStatus ctx == Just ScaleDownScheduled
                  Nothing ->
                    case cleanupAt ctx of
                      Just t -> t <= now && cleanupStatus ctx == Just "SCALE_DOWN_SCHEDULED"
                      Nothing -> False
          _ -> False
  pure (filter isDue parsed)

findAbortingReleaseTrackers :: DBEnv -> IO [TrackerWithTarget]
findAbortingReleaseTrackers db = do
  rows <-
    runDB db $
      runSelectReturningList $
        select $
          orderBy_ (asc_ . rtUpdatedAt) $ do
            rt <- all_ (releaseTrackers autopilotDb)
            guard_ (rtStatus rt ==. val_ "ABORTING")
            pure rt
  pure (map fromRow rows)

findOngoingReleaseTrackers :: DBEnv -> IO [TrackerWithTarget]
findOngoingReleaseTrackers db = do
  rows <-
    runDB db $
      runSelectReturningList $
        select $
          orderBy_ (desc_ . rtUpdatedAt) $ do
            rt <- all_ (releaseTrackers autopilotDb)
            guard_ (rtStatus rt `in_` [val_ "INPROGRESS", val_ "PAUSED", val_ "ABORTING", val_ "REVERTING", val_ "RESTARTING"])
            pure rt
  pure (map fromRow rows)

-- | Find trackers with specific status and time filter
findTrackersWithStatusAndTime :: DBEnv -> [Text] -> UTCTime -> IO [TrackerWithTarget]
findTrackersWithStatusAndTime db statusList ts = do
  rows <-
    runDB db $
      runSelectReturningList $
        select $
          orderBy_ (asc_ . rtUpdatedAt) $ do
            rt <- all_ (releaseTrackers autopilotDb)
            guard_ (rtStatus rt `in_` map val_ statusList)
            guard_ (rtUpdatedAt rt <=. val_ ts)
            pure rt
  pure (map fromRow rows)

-- | Find approved releases with given statuses
findApprovedReleasesWithStatus :: DBEnv -> [Text] -> IO [TrackerWithTarget]
findApprovedReleasesWithStatus db statusList = do
  rows <-
    runDB db $
      runSelectReturningList $
        select $
          orderBy_ (asc_ . rtCreatedAt) $ do
            rt <- all_ (releaseTrackers autopilotDb)
            guard_ (rtStatus rt `in_` map val_ statusList)
            guard_ (rtIsApproved rt ==. val_ (Just True))
            pure rt
  pure (map fromRow rows)

findReleaseTrackersByCategory :: DBEnv -> Text -> UTCTime -> UTCTime -> IO [TrackerWithTarget]
findReleaseTrackersByCategory db cat from to = do
  rows <-
    runDB db $
      runSelectReturningList $
        select $
          orderBy_ (desc_ . rtCreatedAt) $ do
            rt <- all_ (releaseTrackers autopilotDb)
            guard_ (rtCategory rt ==. val_ cat)
            guard_ (rtCreatedAt rt >=. val_ from)
            guard_ (rtCreatedAt rt <=. val_ to)
            pure rt
  pure (map fromRow rows)

insertReleaseEvent :: DBEnv -> Text -> Text -> Text -> Value -> IO ()
insertReleaseEvent db rid category label payload = do
  now <- getCurrentTime
  runDB db $
    runInsert $
      insert (releaseEvents autopilotDb) $
        insertExpressions
          [ ReleaseEventT
              { reId = default_,
                reReleaseId = val_ rid,
                reCategory = val_ category,
                reLabel = val_ label,
                rePayload = val_ payload,
                reCreatedAt = val_ now
              }
          ]

toRow :: UTCTime -> UTCTime -> ReleaseTracker -> Maybe TargetState -> ReleaseTrackerRow
toRow createdAt updatedAt ReleaseTracker {..} mts =
  ReleaseTrackerT
    { rtId = releaseId,
      rtOldVersion = oldVersion,
      rtNewVersion = newVersion,
      rtAppGroup = appGroup,
      rtService = service,
      rtPriority = priority,
      rtEnv = env,
      rtCategory = T.pack (show category),
      rtStatus = releaseStatusToText status,
      rtReleaseWFStatus = T.pack (show releaseWFStatus),
      rtMode = Just (modeToText mode),
      rtCreatedBy = createdBy,
      rtApprovedBy = approvedBy,
      rtIsApproved = Just isApproved,
      rtIsInfraApproved = Just isInfraApproved,
      rtReleaseTag = Just (fromMaybe releaseId releaseTag),
      rtScheduleTime = scheduleTime,
      rtStartTime = startTime,
      rtEndTime = endTime,
      rtRolloutStrategy = Just (encodeJsonText rolloutStrategy),
      rtRolloutHistory = Just (encodeJsonText rolloutHistory),
      rtTargetState = fmap encodeJsonText mts,
      rtInfo = info,
      rtDescription = description,
      rtChangeLog = changeLog,
      rtMetadata = fmap encodeJsonText metadata,
      rtGlobalId = globalId,
      rtSyncEnabled = syncEnabled,
      rtEnvOverrideData = envOverrideData,
      rtSlackThreadTs = slackThreadTs,
      rtCreatedAt = createdAt,
      rtUpdatedAt = updatedAt
    }

fromRow :: ReleaseTrackerRow -> TrackerWithTarget
fromRow ReleaseTrackerT {..} =
  let -- Deserialize full TargetState; fall back to legacy K8sReleaseContext JSON
      mTargetState = case parseJsonTextMaybe rtTargetState :: Maybe TargetState of
        Just ts -> Just ts
        Nothing -> case parseJsonTextMaybe rtTargetState :: Maybe K8sReleaseContext of
          Just ctx -> Just $ K8sState $ emptyK8sState{context = ctx}
          Nothing -> Nothing
      -- Extract the K8s context as a JSON Value so the frontend can display
      -- cluster / namespace / pods scale-down status / etc.
      mReleaseContext = case mTargetState of
        Just (K8sState k8s) -> Just (toJSON (context k8s))
        _ -> Nothing
      tracker =
        ReleaseTracker
          { releaseId = rtId,
            appGroup = rtAppGroup,
            service = rtService,
            env = rtEnv,
            category = parseReleaseCategory rtCategory,
            status = parseReleaseStatus rtStatus,
            releaseWFStatus = parseReleaseWFStatus rtReleaseWFStatus,
            mode = parseMode rtMode,
            createdBy = rtCreatedBy,
            approvedBy = rtApprovedBy,
            isApproved = fromMaybe False rtIsApproved,
            isInfraApproved = fromMaybe False rtIsInfraApproved,
            releaseTag = rtReleaseTag,
            dateCreated = Just rtCreatedAt,
            lastUpdated = Just rtUpdatedAt,
            scheduleTime = rtScheduleTime,
            startTime = rtStartTime,
            endTime = rtEndTime,
            rolloutStrategy = parseJsonTextOr [] rtRolloutStrategy,
            rolloutHistory = parseJsonTextOr [] rtRolloutHistory,
            oldVersion = rtOldVersion,
            newVersion = rtNewVersion,
            info = rtInfo,
            description = rtDescription,
            changeLog = rtChangeLog,
            metadata = parseJsonTextMaybe rtMetadata,
            priority = rtPriority,
            globalId = rtGlobalId,
            syncEnabled = rtSyncEnabled,
            envOverrideData = rtEnvOverrideData,
            slackThreadTs = rtSlackThreadTs,
            releaseContext = mReleaseContext
          }
   in (tracker, mTargetState)

-- New parsers (recommended)
parseReleaseCategory :: Text -> ReleaseCategory
parseReleaseCategory t =
  case T.toUpper t of
    "BACKENDSERVICE" -> BackendService
    "BACKENDSCHEDULER" -> BackendScheduler
    "BACKENDCRONJOB" -> BackendCronJob
    "BACKENDJOB" -> BackendJob
    "BACKENDCONFIG" -> BackendConfig
    "MOBILEAPPANDROID" -> MobileAppAndroid
    "MOBILEAPPIOS" -> MobileAppIOS
    "WEBAPPLICATION" -> WebApplication
    "INFRASTRUCTURE" -> Infrastructure
    "VSEDIT" -> VSEdit
    _ -> BackendService -- Default fallback

-- | Parse ReleaseWFStatus from DB text. Explicit case at the DB boundary
-- (haskell-reviewer Trap 7 — avoid 'read' which is strict about whitespace and
-- gives terrible error messages). Constructors are UPPER_SNAKE, so they match
-- the DB wire format 1:1.
parseReleaseWFStatus :: Text -> ReleaseWFStatus
parseReleaseWFStatus t =
  case T.toUpper t of
    "INIT" -> INIT
    "PREPARING" -> PREPARING
    "DEPLOYING" -> DEPLOYING
    "MONITORING" -> MONITORING
    "FINALIZING" -> FINALIZING
    "DONE" -> DONE
    "ROLLING_BACK" -> ROLLING_BACK
    "ROLLINGBACK" -> ROLLING_BACK -- legacy pascalCase-without-underscore
    _ -> INIT -- safe default; unknown values shouldn't exist after DB cleanup

-- | Parse ReleaseStatus from DB text. Delegates to 'parseReleaseStatusText'
-- in "Products.Autopilot.Types.Release", which derives the lookup from the
-- 'ReleaseStatus' 'Enum'\/'Bounded' instance — one source of truth for both
-- the DB layer and the Aeson JSON layer.
parseReleaseStatus :: Text -> ReleaseStatus
parseReleaseStatus = parseReleaseStatusText

parseMode :: Maybe Text -> Mode
parseMode Nothing = AUTO
parseMode (Just t) =
  case T.toUpper t of
    "MANUAL" -> MANUAL
    "AUTO" -> AUTO
    _ -> AUTO

-- | Convert ReleaseStatus to UPPERCASE Text for DB storage.
-- Re-export of 'releaseStatusText' from "Products.Autopilot.Types.Release"
-- so callers in this module don't need to import the types module directly.
releaseStatusToText :: ReleaseStatus -> Text
releaseStatusToText = releaseStatusText

-- | Convert Mode to UPPERCASE Text for DB storage (same as show).
modeToText :: Mode -> Text
modeToText = T.pack . show

parseDecisionEngineHSStatus :: Maybe Text -> DecisionEngineHSStatus
parseDecisionEngineHSStatus Nothing = Uninitiated
parseDecisionEngineHSStatus (Just t) =
  case T.toUpper t of
    "UNINITIATED" -> Uninitiated
    "CONFIG_FOUND" -> ConfigFound
    "CONFIGFOUND" -> ConfigFound
    "STARTED" -> Started
    "RUNNING" -> Running
    "STOPPED" -> Stopped
    "AB_HS_EXCEPTION" -> AbHsException
    "ABHSEXCEPTION" -> AbHsException
    _ -> Uninitiated

encodeJsonText :: (ToJSON a) => a -> Text
encodeJsonText = TE.decodeUtf8 . BSL.toStrict . encode

parseJsonTextOr :: (FromJSON a) => a -> Maybe Text -> a
parseJsonTextOr fallback Nothing = fallback
parseJsonTextOr fallback (Just t) =
  case eitherDecode (BSL.fromStrict (TE.encodeUtf8 t)) of
    Left _ -> fallback
    Right a -> a

parseJsonTextMaybe :: (FromJSON a) => Maybe Text -> Maybe a
parseJsonTextMaybe Nothing = Nothing
parseJsonTextMaybe (Just t) =
  case eitherDecode (BSL.fromStrict (TE.encodeUtf8 t)) of
    Left _ -> Nothing
    Right a -> Just a

findReleaseTrackerByGlobalId :: DBEnv -> Text -> IO (Maybe TrackerWithTarget)
findReleaseTrackerByGlobalId db gid = do
  rows <-
    runDB db $
      runSelectReturningList $
        select $
          orderBy_ (desc_ . rtCreatedAt) $ do
            rt <- all_ (releaseTrackers autopilotDb)
            guard_ (rtGlobalId rt ==. val_ (Just gid))
            pure rt
  pure $ fmap fromRow (safeHead rows)

deleteReleaseTracker :: DBEnv -> Text -> IO ()
deleteReleaseTracker db rid = withConn db $ \conn -> do
  _ <- execute conn "DELETE FROM release_tracker WHERE id = ?" (Only rid)
  pure ()

deleteReleaseEvents :: DBEnv -> Text -> IO ()
deleteReleaseEvents db rid = withConn db $ \conn -> do
  _ <- execute conn "DELETE FROM release_events WHERE re_release_id = ?" (Only rid)
  pure ()

safeHead :: [a] -> Maybe a
safeHead [] = Nothing
safeHead (x : _) = Just x

-- | Find completed/aborted trackers whose old deployment is due for scale-down.
-- A tracker is eligible if:
-- - status IN (COMPLETED, ABORTED, USER_ABORTED)
-- - end_time + delay hours < now
-- - old_version is not empty/unknown/new
-- - podsScaleDownStatus is NOT already ScaleDownCompleted
-- When delay is 0, all completed trackers with end_time set are immediately eligible.
findCompletedTrackersForScaleDown :: DBEnv -> UTCTime -> Double -> IO [TrackerWithTarget]
findCompletedTrackersForScaleDown db now delayHours = do
  rows <-
    runDB db $
      runSelectReturningList $
        select $
          orderBy_ (asc_ . rtUpdatedAt) $ do
            rt <- all_ (releaseTrackers autopilotDb)
            guard_ (rtStatus rt `in_` [val_ "COMPLETED", val_ "ABORTED", val_ "USER_ABORTED"])
            pure rt
  let parsed = map fromRow rows
      isEligible (tracker, mts) =
        let oldVer = NT.oldVersion tracker
            hasOldVersion = not (T.null oldVer) && T.toLower oldVer /= "unknown" && oldVer /= "new"
            endTimeOk = case NT.endTime tracker of
              Just et -> addDelay et <= now
              Nothing ->
                -- Fallback: use lastUpdated if endTime not set
                case NT.lastUpdated tracker of
                  Just lu -> addDelay lu <= now
                  Nothing -> False
            notAlreadyScaledDown = case mts of
              Just (K8sState k8s) ->
                case podsScaleDownStatus (context k8s) of
                  Just ScaleDownCompleted -> False
                  _ -> True
              _ -> False -- Non-K8s: not applicable
         in hasOldVersion && endTimeOk && notAlreadyScaledDown
      addDelay t = addUTCTime (realToFrac (delayHours * 3600) :: NominalDiffTime) t
  pure (filter isEligible parsed)

-- | Store the Slack thread_ts for the first message in a release's Slack
-- thread. Write-once: only the FIRST writer succeeds, subsequent writers
-- become no-ops. This closes a race (task #31) where two concurrent
-- notifications each discovered @slack_thread_ts IS NULL@, each created a
-- fresh Slack thread, and then raced to overwrite the stored thread_ts —
-- losing one thread to orphaning.
--
-- The @AND slack_thread_ts IS NULL@ guard in the WHERE clause means the
-- UPDATE is atomic: PostgreSQL's MVCC serializes the two concurrent writers
-- and the loser's row-match count is zero, so its write silently no-ops.
-- Callers do not need to check the row count — the contract is "best
-- effort, if someone else already set it the value is preserved".
updateReleaseTrackerSlackThreadTs :: DBEnv -> Text -> Text -> IO ()
updateReleaseTrackerSlackThreadTs db rid value =
  withConn db $ \conn -> do
    _ <-
      execute
        conn
        "UPDATE release_tracker SET slack_thread_ts = ? \
        \WHERE id = ? AND slack_thread_ts IS NULL"
        (value, rid)
    pure ()

-- | Insert a raw ReleaseTrackerRow (used by VSEdit handlers that build rows directly)
insertReleaseTrackerRow :: DBEnv -> ReleaseTrackerRow -> IO ()
insertReleaseTrackerRow db row =
  withConn db $ \conn ->
    withTransaction conn $ do
      execute conn "DELETE FROM release_tracker WHERE id = ?" (Only (rtId row))
      runBeamPostgres conn $ runInsert $ insert (releaseTrackers autopilotDb) $ insertValues [row]
