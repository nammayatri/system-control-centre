{-# LANGUAGE OverloadedStrings #-}

module Products.Autopilot.Queries.ReleaseTracker (
    -- * Insert / Update
    insertReleaseTracker,
    conditionalUpdateTracker,
    conditionalUpdateApprove,
    conditionalUpdateTrackerRow,
    insertReleaseTrackerRow,

    -- * Queries
    findReleaseTracker,
    listReleaseEvents,
    listReleaseEventsByCategory,
    listReleaseTrackers,
    listReleaseTrackersByDateRange,
    findRunnableReleaseTrackers,
    findActiveTrackersForService,
    findInProgressReleaseTrackers,
    findCleanupScheduledTrackers,
    findAbortingReleaseTrackers,
    findOngoingReleaseTrackers,
    findTrackersWithStatusAndTime,
    findApprovedReleasesWithStatus,
    findReleaseTrackersByCategory,
    findReleaseTrackerByGlobalId,
    findCompletedTrackersForScaleDown,
    findLeakedNewDeploymentTrackers,
    resetStuckScaleDownInProgress,
    findActiveSyncTrackers,
    findEventByLabel,
    sweepStaleDiscardingTrackers,
    sweepAutoCompleteVsTrackers,
    findLastGcltAbortedTracker,

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
import Core.Environment (MonadFlow, withDb)
import Data.Aeson (FromJSON, ToJSON, Value, fromJSON, toJSON)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Text as AesonText
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Lazy as LT
import Data.Time.Clock (NominalDiffTime, UTCTime, addUTCTime, getCurrentTime)
import Database.Beam
import Database.Beam.Postgres
import Database.PostgreSQL.Simple (Only (..), execute, execute_, query, withTransaction)
import Database.PostgreSQL.Simple.Types ((:.) (..))
import qualified Debug.Trace as DT
import Products.Autopilot.Types
import qualified Products.Autopilot.Types as NT
import Products.Autopilot.Types.Storage.Schema
import Products.Autopilot.Types.Target (TargetState (..))
import Products.Autopilot.Types.Target.Kubernetes

-- | Type alias for tracker + target state pair
type TrackerWithTarget = (ReleaseTracker, Maybe TargetState)

insertReleaseTracker :: (MonadFlow m) => ReleaseTracker -> Maybe TargetState -> m ()
insertReleaseTracker rt mts = withDb $ \db -> do
    now <- getCurrentTime
    let created = fromMaybe now (dateCreated rt)
        row = toRow created now rt mts
    -- Real UPSERT — single statement, no transaction needed.
    -- Every non-PK column must be listed in BOTH the INSERT column list AND
    -- the DO UPDATE SET clause, otherwise that column would silently retain
    -- its old value on conflict (which would corrupt the rollout state).
    withConn db $ \conn -> do
        _ <-
            execute
                conn
                "INSERT INTO release_tracker \
                \  ( id, old_version, new_version, app_group, service, priority, env \
                \  , category, status, release_wf_status, mode, release_manager, approved_by \
                \  , is_approved, is_infra_approved, release_tag, schedule_time, start_time \
                \  , end_time, rollout_strategy, rollout_history, release_context, info \
                \  , description, change_log, metadata, global_id, sync_enabled \
                \  , env_override_data, slack_thread_ts, date_created, last_updated ) \
                \VALUES \
                \  ( ?, ?, ?, ?, ?, ?, ? \
                \  , ?, ?, ?, ?, ?, ? \
                \  , ?, ?, ?, ?, ? \
                \  , ?, ?, ?, ?, ? \
                \  , ?, ?, ?, ?, ? \
                \  , ?, ?, ?, ? ) \
                \ON CONFLICT (id) DO UPDATE SET \
                \    old_version       = EXCLUDED.old_version \
                \  , new_version       = EXCLUDED.new_version \
                \  , app_group         = EXCLUDED.app_group \
                \  , service           = EXCLUDED.service \
                \  , priority          = EXCLUDED.priority \
                \  , env               = EXCLUDED.env \
                \  , category          = EXCLUDED.category \
                \  , status            = EXCLUDED.status \
                \  , release_wf_status = EXCLUDED.release_wf_status \
                \  , mode              = EXCLUDED.mode \
                \  , release_manager   = EXCLUDED.release_manager \
                \  , approved_by       = EXCLUDED.approved_by \
                \  , is_approved       = EXCLUDED.is_approved \
                \  , is_infra_approved = EXCLUDED.is_infra_approved \
                \  , release_tag       = EXCLUDED.release_tag \
                \  , schedule_time     = EXCLUDED.schedule_time \
                \  , start_time        = EXCLUDED.start_time \
                \  , end_time          = EXCLUDED.end_time \
                \  , rollout_strategy  = EXCLUDED.rollout_strategy \
                \  , rollout_history   = EXCLUDED.rollout_history \
                \  , release_context   = EXCLUDED.release_context \
                \  , info              = EXCLUDED.info \
                \  , description       = EXCLUDED.description \
                \  , change_log        = EXCLUDED.change_log \
                \  , metadata          = EXCLUDED.metadata \
                \  , global_id         = EXCLUDED.global_id \
                \  , sync_enabled      = EXCLUDED.sync_enabled \
                \  , env_override_data = EXCLUDED.env_override_data \
                \  , slack_thread_ts   = COALESCE(EXCLUDED.slack_thread_ts, release_tracker.slack_thread_ts) \
                \  , date_created      = EXCLUDED.date_created \
                \  , last_updated      = EXCLUDED.last_updated"
                ( (rtId row, rtOldVersion row, rtNewVersion row, rtAppGroup row, rtService row, rtPriority row, rtEnv row)
                    :. (rtCategory row, rtStatus row, rtReleaseWFStatus row, rtMode row, rtCreatedBy row, rtApprovedBy row)
                    :. (rtIsApproved row, rtIsInfraApproved row, rtReleaseTag row, rtScheduleTime row, rtStartTime row)
                    :. (rtEndTime row, rtRolloutStrategy row, rtRolloutHistory row, rtTargetState row, rtInfo row)
                    :. (rtDescription row, rtChangeLog row, rtMetadata row, rtGlobalId row, rtSyncEnabled row)
                    :. (rtEnvOverrideData row, rtSlackThreadTs row, rtCreatedAt row, rtUpdatedAt row)
                )
        pure ()

{- | Atomically update a release tracker only if its current status matches the expected value.
Uses DELETE ... WHERE id = ? AND status = ? to prevent concurrent modifications.
Returns True if the update succeeded, False if the status was changed by another thread.
-}
conditionalUpdateTracker :: (MonadFlow m) => ReleaseTracker -> Maybe TargetState -> Text -> m Bool
conditionalUpdateTracker rt mts expectedStatus = withDb $ \db -> do
    now <- getCurrentTime
    let created = fromMaybe now (dateCreated rt)
        row = toRow created now rt mts
    withConn db $ \conn ->
        withTransaction conn $ do
            -- Bug fix (Slack thread race): preserve slack_thread_ts written
            -- by notifyReleaseCreated's updateReleaseTrackerSlackThreadTs.
            -- The DELETE+INSERT pattern below would otherwise clobber the
            -- column to NULL whenever the in-memory `rt` was snapshotted
            -- before the side-effect UPDATE landed. Read the live value
            -- inside the transaction so the INSERT carries it forward.
            existingTs <-
                query
                    conn
                    "SELECT slack_thread_ts FROM release_tracker WHERE id = ?"
                    (Only (releaseId rt))
            let preservedTs = case existingTs of
                    [Only (Just ts)] -> Just ts
                    _ -> rtSlackThreadTs row
                mergedRow = row{rtSlackThreadTs = preservedTs}
            rowsDeleted <-
                execute
                    conn
                    "DELETE FROM release_tracker WHERE id = ? AND status = ?"
                    (releaseId rt, expectedStatus)
            if rowsDeleted == 0
                then pure False
                else do
                    runBeamPostgres conn $ runInsert $ insert (releaseTrackers autopilotDb) $ insertValues [mergedRow]
                    pure True

{- | Atomic approve. Like conditionalUpdateTracker but the precondition is
    is_approved=false AND status='CREATED'. Two concurrent approve handlers
    both pass the in-memory pre-check; only the one that wins this DELETE
    gets to insert the updated row. The loser sees rowsDeleted=0 and returns
    False so the handler can throw a friendly error.
-}
conditionalUpdateApprove :: (MonadFlow m) => ReleaseTracker -> Maybe TargetState -> m Bool
conditionalUpdateApprove rt mts = withDb $ \db -> do
    now <- getCurrentTime
    let created = fromMaybe now (dateCreated rt)
        row = toRow created now rt mts
    withConn db $ \conn ->
        withTransaction conn $ do
            -- Bug fix (Slack thread race): see conditionalUpdateTracker.
            existingTs <-
                query
                    conn
                    "SELECT slack_thread_ts FROM release_tracker WHERE id = ?"
                    (Only (releaseId rt))
            let preservedTs = case existingTs of
                    [Only (Just ts)] -> Just ts
                    _ -> rtSlackThreadTs row
                mergedRow = row{rtSlackThreadTs = preservedTs}
            rowsDeleted <-
                execute
                    conn
                    "DELETE FROM release_tracker WHERE id = ? AND status = 'CREATED' AND is_approved = false"
                    (Only (releaseId rt))
            if rowsDeleted == 0
                then pure False
                else do
                    runBeamPostgres conn $ runInsert $ insert (releaseTrackers autopilotDb) $ insertValues [mergedRow]
                    pure True

{- | Like 'conditionalUpdateTracker' but accepts a raw 'ReleaseTrackerRow'.
Returns True if the update succeeded, False if the status was changed by another thread.
-}
conditionalUpdateTrackerRow :: (MonadFlow m) => ReleaseTrackerRow -> Text -> m Bool
conditionalUpdateTrackerRow row expectedStatus = withDb $ \db ->
    withConn db $ \conn ->
        withTransaction conn $ do
            -- Bug fix (Slack thread race): see conditionalUpdateTracker.
            existingTs <-
                query
                    conn
                    "SELECT slack_thread_ts FROM release_tracker WHERE id = ?"
                    (Only (rtId row))
            let preservedTs = case existingTs of
                    [Only (Just ts)] -> Just ts
                    _ -> rtSlackThreadTs row
                mergedRow = row{rtSlackThreadTs = preservedTs}
            rowsDeleted <-
                execute
                    conn
                    "DELETE FROM release_tracker WHERE id = ? AND status = ?"
                    (rtId row, expectedStatus)
            if rowsDeleted == 0
                then pure False
                else do
                    runBeamPostgres conn $ runInsert $ insert (releaseTrackers autopilotDb) $ insertValues [mergedRow]
                    pure True

findReleaseTracker :: (MonadFlow m) => Text -> m (Maybe TrackerWithTarget)
findReleaseTracker rid = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    do
                        rt <- all_ (releaseTrackers autopilotDb)
                        guard_ (rtId rt ==. val_ rid)
                        pure rt
    pure $ fmap fromRow (safeHead rows)

listReleaseEvents :: (MonadFlow m) => Text -> m [ReleaseEvent]
listReleaseEvents rid = withDb $ \db ->
    runDB db $
        runSelectReturningList $
            select $ do
                ev <- all_ (releaseEvents autopilotDb)
                guard_ (reReleaseId ev ==. val_ rid)
                pure ev

{- | Like 'listReleaseEvents' but filters by event category in SQL. Used by
release-diff handlers that only care about a single category (e.g.
"SNAPSHOT") and don't want to pull every event for the release just to
discard most of them in Haskell.
-}
listReleaseEventsByCategory :: (MonadFlow m) => Text -> Text -> m [ReleaseEvent]
listReleaseEventsByCategory rid cat = withDb $ \db ->
    runDB db $
        runSelectReturningList $
            select $ do
                ev <- all_ (releaseEvents autopilotDb)
                guard_ (reReleaseId ev ==. val_ rid)
                guard_ (reCategory ev ==. val_ cat)
                pure ev

listReleaseTrackers :: (MonadFlow m) => m [TrackerWithTarget]
listReleaseTrackers = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (desc_ . rtCreatedAt) $ do
                        rt <- all_ (releaseTrackers autopilotDb)
                        pure rt
    pure (map fromRow rows)

listReleaseTrackersByDateRange :: (MonadFlow m) => UTCTime -> UTCTime -> m [TrackerWithTarget]
listReleaseTrackersByDateRange fromTime toTime = withDb $ \db -> do
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

{- | Find releases ready to be dispatched. Only picks CREATED status.
INPROGRESS releases are NOT re-dispatched — on server restart, they are
rolled back (matching Julia production behavior: rollbackReleaseInProgress).
-}
findRunnableReleaseTrackers :: (MonadFlow m) => UTCTime -> m [TrackerWithTarget]
findRunnableReleaseTrackers now = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (asc_ . rtCreatedAt) $ do
                        rt <- all_ (releaseTrackers autopilotDb)
                        guard_ (rtStatus rt ==. val_ "CREATED")
                        guard_ (rtIsApproved rt ==. val_ (Just True))
                        guard_ (isNothing_ (rtScheduleTime rt) ||. rtScheduleTime rt <=. just_ (val_ now))
                        pure rt
    pure (map fromRow rows)

{- | Find any non-terminal tracker for the given (app_group, service). Used by
the same-service concurrency guard at create time. Catches CREATED (whether
approved or not), INPROGRESS, PAUSED, ABORTING, REVERTING, RESTARTING — i.e.
anything that's still alive in the workflow state machine. Excludes terminal
states (COMPLETED, ABORTED, USER_ABORTED, DISCARDED, REVERTED, RECORDED,
GcltAborted) and VS-edit lock rows (LOCKED, UNLOCKED).
-}
findActiveTrackersForService :: (MonadFlow m) => Text -> Text -> m [TrackerWithTarget]
findActiveTrackersForService ag svc = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (desc_ . rtCreatedAt) $ do
                        rt <- all_ (releaseTrackers autopilotDb)
                        guard_ (rtAppGroup rt ==. val_ ag)
                        guard_ (rtService rt ==. val_ svc)
                        guard_
                            ( rtStatus rt
                                `in_` [ val_ "CREATED"
                                      , val_ "INPROGRESS"
                                      , val_ "PAUSED"
                                      , val_ "ABORTING"
                                      , val_ "REVERTING"
                                      , val_ "RESTARTING"
                                      ]
                            )
                        pure rt
    pure (map fromRow rows)

findInProgressReleaseTrackers :: (MonadFlow m) => m [TrackerWithTarget]
findInProgressReleaseTrackers = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (asc_ . rtCreatedAt) $ do
                        rt <- all_ (releaseTrackers autopilotDb)
                        -- Bug fix: PAUSED is an intentional user state. Restarting the
                        -- backend should NOT silently ABORT user-paused releases. Only
                        -- INPROGRESS/REVERTING releases need recovery (their workflow
                        -- thread was lost on restart). PAUSED releases hold no in-flight
                        -- kubectl state — the runner will pick them back up via the
                        -- normal poll once they transition back to INPROGRESS.
                        guard_ (rtStatus rt `in_` [val_ "INPROGRESS", val_ "REVERTING"])
                        pure rt
    pure (map fromRow rows)

findCleanupScheduledTrackers :: (MonadFlow m) => UTCTime -> m [TrackerWithTarget]
findCleanupScheduledTrackers now = withDb $ \db -> do
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

{- | Julia parity (watcher.jl scaleDownPodsInProgress / rollback.jl):
find terminal-state trackers whose NEW deployment leaked because the
abort/cleanup path never reached @restoreVsTrafficOnFailure@'s scale-down
(process kill, OOM, kubectl failure, etc).

Eligibility:
  * status IN (ABORTED, USER_ABORTED, DISCARDED)
  * release_context has @cleanupTargetDeployment@ set (the new dep name)
  * @cleanupStatus == "SCALE_DOWN_SCHEDULED"@
  * @cleanupAt <= now@ (or unset, in which case we treat it as overdue)

The poll worker 'scaleDownLeakedNewDeployment' issues @kubectl scale
--replicas=0@ on the target deployment and flips @cleanupStatus@ to
@SCALE_DOWN_COMPLETED@. The kubectl call is idempotent so re-runs on
already-scaled deployments are harmless.
-}
findLeakedNewDeploymentTrackers :: (MonadFlow m) => UTCTime -> m [TrackerWithTarget]
findLeakedNewDeploymentTrackers now = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (asc_ . rtUpdatedAt) $ do
                        rt <- all_ (releaseTrackers autopilotDb)
                        guard_ (rtStatus rt `in_` [val_ "ABORTED", val_ "USER_ABORTED", val_ "DISCARDED"])
                        pure rt
    let parsed = map fromRow rows
        isDue (_, mts) = case mts of
            Just (K8sState k8s) ->
                let ctx = context k8s
                 in case (cleanupTargetDeployment ctx, cleanupStatus ctx) of
                        (Just dep, Just "SCALE_DOWN_SCHEDULED") | not (T.null dep) ->
                            case cleanupAt ctx of
                                Just t -> t <= now
                                Nothing -> True
                        _ -> False
            _ -> False
    pure (filter isDue parsed)

{- | Julia parity (rollback.jl scaleDownPodsInProgress): walks
terminal-state trackers stuck in @SCALE_DOWN_INPROGRESS@ (worker crashed
mid-flight) and resets them to @SCALE_DOWN_SCHEDULED@ so the next runner
poll picks them up. Run once at startup before the poll loop.

Returns the number of trackers reset (for log visibility).
-}
resetStuckScaleDownInProgress :: (MonadFlow m) => m Int
resetStuckScaleDownInProgress = withDb $ \db ->
    withConn db $ \conn -> do
        n <-
            execute_
                conn
                "UPDATE release_tracker \
                \SET release_context = REPLACE(release_context, '\"SCALE_DOWN_INPROGRESS\"', '\"SCALE_DOWN_SCHEDULED\"') \
                \WHERE status IN ('ABORTED','USER_ABORTED','DISCARDED','COMPLETED') \
                \  AND release_context LIKE '%SCALE_DOWN_INPROGRESS%'"
        pure (fromIntegral n)

findAbortingReleaseTrackers :: (MonadFlow m) => m [TrackerWithTarget]
findAbortingReleaseTrackers = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (asc_ . rtUpdatedAt) $ do
                        rt <- all_ (releaseTrackers autopilotDb)
                        guard_ (rtStatus rt ==. val_ "ABORTING")
                        pure rt
    pure (map fromRow rows)

findOngoingReleaseTrackers :: (MonadFlow m) => m [TrackerWithTarget]
findOngoingReleaseTrackers = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (desc_ . rtUpdatedAt) $ do
                        rt <- all_ (releaseTrackers autopilotDb)
                        guard_ (rtStatus rt `in_` [val_ "INPROGRESS", val_ "PAUSED", val_ "ABORTING", val_ "REVERTING", val_ "RESTARTING"])
                        pure rt
    pure (map fromRow rows)

findTrackersWithStatusAndTime :: (MonadFlow m) => [Text] -> UTCTime -> m [TrackerWithTarget]
findTrackersWithStatusAndTime statusList ts = withDb $ \db -> do
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

findApprovedReleasesWithStatus :: (MonadFlow m) => [Text] -> m [TrackerWithTarget]
findApprovedReleasesWithStatus statusList = withDb $ \db -> do
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

findReleaseTrackersByCategory :: (MonadFlow m) => Text -> UTCTime -> UTCTime -> m [TrackerWithTarget]
findReleaseTrackersByCategory cat from to = withDb $ \db -> do
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

insertReleaseEvent :: (MonadFlow m) => Text -> Text -> Text -> Value -> m ()
insertReleaseEvent rid category label payload = withDb $ \db -> do
    now <- getCurrentTime
    runDB db $
        runInsert $
            insert (releaseEvents autopilotDb) $
                insertExpressions
                    [ ReleaseEventT
                        { reId = default_
                        , reReleaseId = val_ rid
                        , reCategory = val_ category
                        , reLabel = val_ label
                        , rePayload = val_ payload
                        , reCreatedAt = val_ now
                        }
                    ]

toRow :: UTCTime -> UTCTime -> ReleaseTracker -> Maybe TargetState -> ReleaseTrackerRow
toRow createdAt updatedAt ReleaseTracker{..} mts =
    ReleaseTrackerT
        { rtId = releaseId
        , rtOldVersion = oldVersion
        , rtNewVersion = newVersion
        , rtAppGroup = appGroup
        , rtService = service
        , rtPriority = priority
        , rtEnv = env
        , rtCategory = T.pack (show category)
        , rtStatus = releaseStatusToText status
        , rtReleaseWFStatus = T.pack (show releaseWFStatus)
        , rtMode = Just (modeToText mode)
        , rtCreatedBy = createdBy
        , rtApprovedBy = approvedBy
        , rtIsApproved = Just isApproved
        , rtIsInfraApproved = Just isInfraApproved
        , rtReleaseTag = Just (fromMaybe releaseId releaseTag)
        , rtScheduleTime = scheduleTime
        , rtStartTime = startTime
        , rtEndTime = endTime
        , rtRolloutStrategy = Just (encodeJsonText rolloutStrategy)
        , rtRolloutHistory = Just (encodeJsonText rolloutHistory)
        , rtTargetState = fmap encodeJsonText mts
        , rtInfo = info
        , rtDescription = description
        , rtChangeLog = changeLog
        , rtMetadata = fmap encodeJsonText metadata
        , rtGlobalId = globalId
        , rtSyncEnabled = syncEnabled
        , rtEnvOverrideData = envOverrideData
        , rtSlackThreadTs = slackThreadTs
        , rtCreatedAt = createdAt
        , rtUpdatedAt = updatedAt
        }

fromRow :: ReleaseTrackerRow -> TrackerWithTarget
fromRow ReleaseTrackerT{..} =
    let
        -- Deserialize the target_state column once into a generic Aeson Value,
        -- then try TargetState first and fall back to legacy K8sReleaseContext.
        -- This avoids paying for two full JSON parses on every row.
        mTargetState = case parseJsonTextMaybe rtTargetState :: Maybe Value of
            Nothing -> Nothing
            Just v -> case fromJSON v :: Aeson.Result TargetState of
                Aeson.Success ts -> Just ts
                Aeson.Error _ -> case fromJSON v :: Aeson.Result K8sReleaseContext of
                    Aeson.Success ctx -> Just $ K8sState $ emptyK8sState{context = ctx}
                    Aeson.Error _ -> Nothing
        -- Extract the K8s context as a JSON Value so the frontend can display
        -- cluster / namespace / pods scale-down status / etc.
        mReleaseContext = case mTargetState of
            Just (K8sState k8s) -> Just (toJSON (context k8s))
            _ -> Nothing
        tracker =
            ReleaseTracker
                { releaseId = rtId
                , appGroup = rtAppGroup
                , service = rtService
                , env = rtEnv
                , category = parseReleaseCategory rtCategory
                , status = parseReleaseStatus rtStatus
                , releaseWFStatus = parseReleaseWFStatus rtReleaseWFStatus
                , mode = parseMode rtMode
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
                , rolloutStrategy = parseJsonTextOr [] rtRolloutStrategy
                , rolloutHistory = parseJsonTextOr [] rtRolloutHistory
                , oldVersion = rtOldVersion
                , newVersion = rtNewVersion
                , info = rtInfo
                , description = rtDescription
                , changeLog = rtChangeLog
                , metadata = parseJsonTextMaybe rtMetadata
                , priority = rtPriority
                , globalId = rtGlobalId
                , syncEnabled = rtSyncEnabled
                , envOverrideData = rtEnvOverrideData
                , slackThreadTs = rtSlackThreadTs
                , releaseContext = mReleaseContext
                }
     in
        (tracker, mTargetState)

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
        _ ->
            DT.trace
                ("[parseReleaseCategory] WARNING: unknown category " <> show t <> ", defaulting to BackendService")
                BackendService

{- | Parse ReleaseWFStatus from DB text. Explicit case at the DB boundary
(haskell-reviewer Trap 7 — avoid 'read' which is strict about whitespace and
gives terrible error messages). Constructors are UPPER_SNAKE, so they match
the DB wire format 1:1.
-}
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
        _ ->
            DT.trace
                ("[parseReleaseWFStatus] WARNING: unknown status " <> show t <> ", defaulting to INIT")
                INIT

{- | Parse ReleaseStatus from DB text. Delegates to 'parseReleaseStatusText'
in "Products.Autopilot.Types.Release", which derives the lookup from the
'ReleaseStatus' 'Enum'\/'Bounded' instance — one source of truth for both
the DB layer and the Aeson JSON layer.
-}
parseReleaseStatus :: Text -> ReleaseStatus
parseReleaseStatus = parseReleaseStatusText

parseMode :: Maybe Text -> Mode
parseMode Nothing = AUTO
parseMode (Just t) =
    case T.toUpper t of
        "MANUAL" -> MANUAL
        "AUTO" -> AUTO
        _ ->
            DT.trace
                ("[parseMode] WARNING: unknown mode " <> show t <> ", defaulting to AUTO")
                AUTO

{- | Convert ReleaseStatus to UPPERCASE Text for DB storage.
Re-export of 'releaseStatusText' from "Products.Autopilot.Types.Release"
so callers in this module don't need to import the types module directly.
-}
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
        _ ->
            DT.trace
                ("[parseDecisionEngineHSStatus] WARNING: unknown status " <> show t <> ", defaulting to Uninitiated")
                Uninitiated

-- NOTE: target_state is currently a 'text' column. Migrating it to 'jsonb'
-- would let us drop the encode/decode round-trip entirely, but that
-- migration is out of scope for this file (no migrations live under
-- backend/dev/migrations/system-control/ for this change).
--
-- For now, encode goes Value -> Text via aeson's text builder (skips the
-- ByteString step), and decode goes Text -> ByteString via TE.encodeUtf8
-- straight into eitherDecodeStrict (skips the lazy ByteString step).
encodeJsonText :: (ToJSON a) => a -> Text
encodeJsonText = LT.toStrict . AesonText.encodeToLazyText

parseJsonTextOr :: (FromJSON a) => a -> Maybe Text -> a
parseJsonTextOr fallback Nothing = fallback
parseJsonTextOr fallback (Just t) =
    case Aeson.eitherDecodeStrict (TE.encodeUtf8 t) of
        Left _ -> fallback
        Right a -> a

parseJsonTextMaybe :: (FromJSON a) => Maybe Text -> Maybe a
parseJsonTextMaybe Nothing = Nothing
parseJsonTextMaybe (Just t) =
    case Aeson.eitherDecodeStrict (TE.encodeUtf8 t) of
        Left _ -> Nothing
        Right a -> Just a

findReleaseTrackerByGlobalId :: (MonadFlow m) => Text -> m (Maybe TrackerWithTarget)
findReleaseTrackerByGlobalId gid = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (desc_ . rtCreatedAt) $ do
                        rt <- all_ (releaseTrackers autopilotDb)
                        guard_ (rtGlobalId rt ==. val_ (Just gid))
                        pure rt
    pure $ fmap fromRow (safeHead rows)

deleteReleaseTracker :: (MonadFlow m) => Text -> m ()
deleteReleaseTracker rid = withDb $ \db -> withConn db $ \conn -> do
    _ <- execute conn "DELETE FROM release_tracker WHERE id = ?" (Only rid)
    pure ()

deleteReleaseEvents :: (MonadFlow m) => Text -> m ()
deleteReleaseEvents rid = withDb $ \db -> withConn db $ \conn -> do
    _ <- execute conn "DELETE FROM release_events WHERE re_release_id = ?" (Only rid)
    pure ()

safeHead :: [a] -> Maybe a
safeHead [] = Nothing
safeHead (x : _) = Just x

{- | Find completed/aborted trackers whose old deployment is due for scale-down.
A tracker is eligible if:
- status IN (COMPLETED, ABORTED, USER_ABORTED)
- end_time + delay hours < now
- old_version is not empty/unknown/new
- podsScaleDownStatus is NOT already ScaleDownCompleted
When delay is 0, all completed trackers with end_time set are immediately eligible.
-}
findCompletedTrackersForScaleDown :: (MonadFlow m) => UTCTime -> Double -> m [TrackerWithTarget]
findCompletedTrackersForScaleDown now delayHours = withDb $ \db -> do
    -- Push end_time + delay <= now into SQL so we don't pull every completed
    -- row across the wire only to discard most of them in Haskell.
    let cutoff = addUTCTime (realToFrac (negate (delayHours * 3600)) :: NominalDiffTime) now
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (asc_ . rtUpdatedAt) $ do
                        rt <- all_ (releaseTrackers autopilotDb)
                        -- Julia parity (watcher.jl:84-102): query selects all
                        -- terminal trackers; the SCALE_DOWN_SCHEDULED flag
                        -- check below acts as the actual gate. The flag is
                        -- only set by scheduleOldDeploymentScaleDown (called
                        -- from cleanupOldVersion / revert paths), so aborted
                        -- trackers — which never call that helper — are
                        -- never picked up.
                        guard_ (rtStatus rt `in_` [val_ "COMPLETED", val_ "ABORTED", val_ "USER_ABORTED"])
                        guard_ (rtEndTime rt <=. just_ (val_ cutoff))
                        pure rt
    let parsed = map fromRow rows
        -- end_time + delay <= now is now enforced in SQL above. The remaining
        -- predicates (old-version sanity + JSON podsScaleDownStatus) stay in
        -- Haskell because they require parsing the target_state JSON blob.
        -- Julia parity (watcher.jl filterUsingPodsStatus!): require an
        -- explicit SCALE_DOWN_SCHEDULED flag on the tracker. Anything else
        -- (Nothing, ScaleDownInProgress, ScaleDownCompleted, etc.) is
        -- excluded. The flag is set ONLY by scheduleOldDeploymentScaleDown
        -- which is called from cleanupOldVersion (terminal-success path)
        -- and revert paths — never from abort paths. Without this gate, an
        -- aborted release would have its OLD deployment scaled down ~3
        -- minutes after the abort, wiping out the live serving version.
        isEligible (tracker, mts) =
            let oldVer = NT.oldVersion tracker
                hasOldVersion = not (T.null oldVer) && T.toLower oldVer /= "unknown" && oldVer /= "new"
                isScheduled = case mts of
                    Just (K8sState k8s) -> podsScaleDownStatus (context k8s) == Just ScaleDownScheduled
                    _ -> False
             in hasOldVersion && isScheduled
    pure (filter isEligible parsed)

{- | Store the Slack thread_ts for the first message in a release's Slack
thread. Write-once: only the FIRST writer succeeds, subsequent writers
become no-ops. This closes a race (task #31) where two concurrent
notifications each discovered @slack_thread_ts IS NULL@, each created a
fresh Slack thread, and then raced to overwrite the stored thread_ts —
losing one thread to orphaning.

The @AND slack_thread_ts IS NULL@ guard in the WHERE clause means the
UPDATE is atomic: PostgreSQL's MVCC serializes the two concurrent writers
and the loser's row-match count is zero, so its write silently no-ops.
Callers do not need to check the row count — the contract is "best
effort, if someone else already set it the value is preserved".
-}
updateReleaseTrackerSlackThreadTs :: (MonadFlow m) => Text -> Text -> m ()
updateReleaseTrackerSlackThreadTs rid value = withDb $ \db ->
    withConn db $ \conn -> do
        _ <-
            execute
                conn
                "UPDATE release_tracker SET slack_thread_ts = ? \
                \WHERE id = ? AND slack_thread_ts IS NULL"
                (value, rid)
        pure ()

insertReleaseTrackerRow :: (MonadFlow m) => ReleaseTrackerRow -> m ()
insertReleaseTrackerRow row = withDb $ \db ->
    withConn db $ \conn ->
        withTransaction conn $ do
            -- Bug fix (Slack thread race): preserve slack_thread_ts when the
            -- caller's row is a stale snapshot. Used by VS edit create flow
            -- via createVsEditTrackerH → mkVsEditRow → insertReleaseTrackerRow.
            -- Without this guard a re-insert (e.g. on retry / discard sweep
            -- recreation) would clobber the thread_ts written by
            -- notifyVsEditCreated's saveThreadTs call.
            existingTs <-
                query
                    conn
                    "SELECT slack_thread_ts FROM release_tracker WHERE id = ?"
                    (Only (rtId row))
            let preservedTs = case existingTs of
                    [Only (Just ts)] -> Just ts
                    _ -> rtSlackThreadTs row
                mergedRow = row{rtSlackThreadTs = preservedTs}
            _ <- execute conn "DELETE FROM release_tracker WHERE id = ?" (Only (rtId row))
            runBeamPostgres conn $ runInsert $ insert (releaseTrackers autopilotDb) $ insertValues [mergedRow]

{- | Find all non-terminal trackers that have sync enabled and a global_id set.
Used by 'Products.Autopilot.SyncWatcher' to poll secondary cluster status.
Terminal statuses are excluded: COMPLETED, ABORTED, USER_ABORTED, DISCARDED,
REVERTED, GCLT_ABORTED.
-}
findActiveSyncTrackers :: (MonadFlow m) => m [ReleaseTracker]
findActiveSyncTrackers = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (asc_ . rtCreatedAt) $ do
                        rt <- all_ (releaseTrackers autopilotDb)
                        guard_ (rtSyncEnabled rt ==. val_ (Just "true"))
                        guard_ (isJust_ (rtGlobalId rt))
                        guard_
                            ( not_ $
                                rtStatus rt
                                    `in_` [ val_ "COMPLETED"
                                          , val_ "ABORTED"
                                          , val_ "USER_ABORTED"
                                          , val_ "DISCARDED"
                                          , val_ "REVERTED"
                                          , val_ "GCLT_ABORTED"
                                          ]
                            )
                        pure rt
    pure (map (fst . fromRow) rows)

{- | Sweep stale-DISCARDING trackers: any tracker that has been stuck in
the DISCARDING status longer than @ageMinutes@ minutes is force-flipped to
DISCARDED. Julia parity: @filterUsingScheduleTime!@ in
@release/watcher.jl@ instantly discards DISCARDING-status trackers; we
use a short grace period to absorb in-flight kubectl calls before
declaring them dead. Returns the number of trackers flipped.

Driven by the runner's poll loop with @discarding_sweep_minutes@
server_config (default 5 minutes).
-}
sweepStaleDiscardingTrackers :: (MonadFlow m) => Int -> m Int
sweepStaleDiscardingTrackers ageMinutes = withDb $ \db -> do
    now <- liftIO getCurrentTime
    let cutoff = addUTCTime (negate (fromIntegral (ageMinutes * 60) :: NominalDiffTime)) now
    -- Two-step: SELECT matching IDs, then UPDATE. Beam's plain runUpdate
    -- doesn't return a row count, so we count via the SELECT to keep the
    -- caller's logging useful.
    stuckIds <-
        runDB db $
            runSelectReturningList $
                select $ do
                    rt <- all_ (releaseTrackers autopilotDb)
                    guard_ (rtStatus rt ==. val_ "DISCARDING")
                    guard_ (rtUpdatedAt rt <=. val_ cutoff)
                    pure (rtId rt)
    if null stuckIds
        then pure 0
        else do
            runDB db $
                runUpdate $
                    update
                        (releaseTrackers autopilotDb)
                        ( \rt ->
                            mconcat
                                [ rtStatus rt <-. val_ "DISCARDED"
                                , rtEndTime rt <-. val_ (Just now)
                                , rtUpdatedAt rt <-. val_ now
                                ]
                        )
                        ( \rt ->
                            rtStatus rt
                                ==. val_ "DISCARDING"
                                &&. rtUpdatedAt rt
                                    <=. val_ cutoff
                        )
            pure (length stuckIds)

{- | Sweep VS-edit trackers stuck in APPLIED → auto-flip to COMPLETED
after @ageMinutes@ minutes. Julia parity: @release/watcher.jl:158-160@
auto-marks VS trackers COMPLETED after @getAutoCompleteVSTrackerDelay@.
Without this, an APPLIED VS tracker hangs forever in the operator UI's
"in-flight" view because nothing transitions APPLIED → COMPLETED.
Returns the count of trackers flipped.
-}
sweepAutoCompleteVsTrackers :: (MonadFlow m) => Int -> m Int
sweepAutoCompleteVsTrackers ageMinutes = withDb $ \db -> do
    now <- liftIO getCurrentTime
    let cutoff = addUTCTime (negate (fromIntegral (ageMinutes * 60) :: NominalDiffTime)) now
    stuckIds <-
        runDB db $
            runSelectReturningList $
                select $ do
                    rt <- all_ (releaseTrackers autopilotDb)
                    guard_ (rtCategory rt ==. val_ "VSEdit")
                    guard_ (rtStatus rt ==. val_ "APPLIED")
                    guard_ (rtUpdatedAt rt <=. val_ cutoff)
                    pure (rtId rt)
    if null stuckIds
        then pure 0
        else do
            runDB db $
                runUpdate $
                    update
                        (releaseTrackers autopilotDb)
                        ( \rt ->
                            mconcat
                                [ rtStatus rt <-. val_ "COMPLETED"
                                , rtEndTime rt <-. val_ (Just now)
                                , rtUpdatedAt rt <-. val_ now
                                ]
                        )
                        ( \rt ->
                            rtCategory rt
                                ==. val_ "VSEdit"
                                &&. rtStatus rt
                                    ==. val_ "APPLIED"
                                &&. rtUpdatedAt rt
                                    <=. val_ cutoff
                        )
            pure (length stuckIds)

{- | Find the most recent release tracker for the given (app_group,
service) that ended in @GCLT_ABORTED@ status. Julia parity:
@validateGCLTAbortInPreviousTracker@ in @api/release/create.jl@. Used
by createReleaseH to block a new release on a service whose previous
release was killed by the global changelog tracker — operator must
explicitly resolve before retrying.
-}
findLastGcltAbortedTracker :: (MonadFlow m) => Text -> Text -> Text -> m (Maybe ReleaseTracker)
findLastGcltAbortedTracker ag svc envT = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    limit_ 1 $
                        orderBy_ (desc_ . rtUpdatedAt) $ do
                            rt <- all_ (releaseTrackers autopilotDb)
                            guard_ (rtAppGroup rt ==. val_ ag)
                            guard_ (rtService rt ==. val_ svc)
                            guard_ (rtEnv rt ==. val_ envT)
                            guard_ (rtStatus rt ==. val_ "GCLT_ABORTED")
                            pure rt
    pure (fmap (fst . fromRow) (safeHead rows))

{- | Find the most recent release event for a given release and label.
Used by 'Products.Autopilot.SyncWatcher' to look up SYNC_SECONDARY_TRACKER_ID.
-}
findEventByLabel :: (MonadFlow m) => Text -> Text -> m (Maybe ReleaseEvent)
findEventByLabel rid lbl = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    limit_ 1 $
                        orderBy_ (desc_ . reCreatedAt) $ do
                            ev <- all_ (releaseEvents autopilotDb)
                            guard_ (reReleaseId ev ==. val_ rid)
                            guard_ (reLabel ev ==. val_ lbl)
                            pure ev
    pure (safeHead rows)
