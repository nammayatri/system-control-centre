{-# LANGUAGE OverloadedStrings #-}

{- | Persistence for the HPA scheduler (migration 0055). Raw SQL, like the
release-bot store: hot columns are real columns, flexible parts are JSONB.

Every function takes the runner's @cloud@ and filters on it: one database serves
several clusters and a runner must never see or act on another cloud's rows.

Concurrency rules this module enforces in SQL (not in Haskell):

* an apply is claimed with @FOR UPDATE SKIP LOCKED@ and a lease; a dead worker's
  lease simply expires and the row is claimable again;
* every status change is a compare-and-set on the previous status, so two actors
  (worker, API handler, another pod) can never both win;
* the partial unique indexes make a second in-flight apply for the same HPA, or a
  second apply of the same schedule window, impossible rather than merely unlikely.
-}
module Products.Autopilot.Hpa.Store (
    -- * Rows
    ScheduleRow (..),
    ApplyRow (..),
    ApplyNew (..),
    ApplyPatch (..),
    emptyPatch,

    -- * Schedules
    insertSchedule,
    getSchedule,
    listSchedules,
    listActiveSchedules,
    updateSchedule,
    setScheduleStatus,
    deleteSchedule,
    claimScheduleEval,

    -- * Applies
    insertApply,
    getApply,
    listApplies,
    appliesForSchedule,
    inflightAppliesForService,
    claimNextApply,
    heartbeatApply,
    releaseApply,
    transitionApply,
    forceTransition,
    patchApply,

    -- * Events
    addEvent,
    listEventsForApply,
    listEventsForService,

    -- * Loop leader lease
    acquireLoopLease,

    -- * Observer data
    watchedServices,
    addWatch,
    removeWatch,
    listWatched,
    lastSnapshotHash,
    insertSnapshot,
    SampleRow (..),
    insertSample,
    upsertScaleEvent,
    pruneObserverData,

    -- * Reads for the panel
    samplesFor,
    snapshotsFor,
    scaleEventsFor,
    latestSampleTime,

    -- * Guardrails
    getGuardrailRow,
    listGuardrails,
    putGuardrailRow,
)
where

import Core.DB.Connection (withConn)
import Core.Environment (MonadFlow, withDb)
import Data.Aeson (ToJSON (..), Value, (.=))
import Data.Aeson qualified as A
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Database.PostgreSQL.Simple (Connection, Only (..), Query, execute, query)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Database.PostgreSQL.Simple.Types (In (..), (:.) (..))
import Products.Autopilot.Hpa.Types (applyStatusText, blockingStatusTexts, terminalStatusTexts, validApplyTransition)
import Products.Autopilot.Hpa.Types qualified as T

db :: (MonadFlow m) => (Connection -> IO a) -> m a
db f = withDb (\d -> withConn d f)

-- ---------------------------------------------------------------------------
-- Rows

data ScheduleRow = ScheduleRow
    { srId :: Text
    , srCloud :: Text
    , srAppGroup :: Text
    , srService :: Text
    , srName :: Text
    , srStatus :: Text
    , srKind :: Value
    , srChange :: Value
    , srPolicy :: Value
    , srCreatedBy :: Text
    , srCreatedAt :: UTCTime
    , srUpdatedAt :: UTCTime
    }
    deriving (Show)

instance FromRow ScheduleRow where
    fromRow =
        ScheduleRow
            <$> field <*> field <*> field <*> field <*> field <*> field
            <*> field <*> field <*> field <*> field <*> field <*> field

instance ToJSON ScheduleRow where
    toJSON r =
        A.object
            [ "id" .= srId r
            , "appGroup" .= srAppGroup r
            , "service" .= srService r
            , "name" .= srName r
            , "status" .= srStatus r
            , "kind" .= srKind r
            , "change" .= srChange r
            , "healthPolicy" .= srPolicy r
            , "createdBy" .= srCreatedBy r
            , "createdAt" .= srCreatedAt r
            , "updatedAt" .= srUpdatedAt r
            ]

scheduleCols :: Query
scheduleCols = "id, cloud, app_group, service, name, status, kind, change, health_policy, created_by, created_at, updated_at"

data ApplyRow = ApplyRow
    { arId :: Text
    , arCloud :: Text
    , arScheduleId :: Maybe Text
    , arTrigger :: Text
    , arAppGroup :: Text
    , arService :: Text
    , arNamespace :: Text
    , arHpaName :: Text
    , arStatus :: Text
    , arStep :: Maybe Text
    , arChange :: Value
    , arPolicy :: Value
    , arBeforeSpec :: Maybe Value
    , arBeforeRaw :: Maybe Value
    , arAfterSpec :: Maybe Value
    , arWindowStart :: Maybe UTCTime
    , arWindowEnd :: Maybe UTCTime
    , arAttempt :: Int
    , arDeferCount :: Int
    , arClaimedBy :: Maybe Text
    , arLeaseExpires :: Maybe UTCTime
    , arNextRunAt :: UTCTime
    , arObserveUntil :: Maybe UTCTime
    , arUnhealthySince :: Maybe UTCTime
    , arRollbackReason :: Maybe Text
    , arError :: Maybe Text
    , arCreatedBy :: Text
    , arCreatedAt :: UTCTime
    , arUpdatedAt :: UTCTime
    , arFinishedAt :: Maybe UTCTime
    }
    deriving (Show)

instance FromRow ApplyRow where
    fromRow =
        ApplyRow
            <$> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field
            <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field
            <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field

-- | Full detail minus the (large) raw before-object, which is only for manual recovery.
instance ToJSON ApplyRow where
    toJSON r =
        A.object
            [ "id" .= arId r
            , "scheduleId" .= arScheduleId r
            , "trigger" .= arTrigger r
            , "appGroup" .= arAppGroup r
            , "service" .= arService r
            , "namespace" .= arNamespace r
            , "hpaName" .= arHpaName r
            , "status" .= arStatus r
            , "step" .= arStep r
            , "change" .= arChange r
            , "healthPolicy" .= arPolicy r
            , "beforeSpec" .= arBeforeSpec r
            , "afterSpec" .= arAfterSpec r
            , "windowStart" .= arWindowStart r
            , "windowEnd" .= arWindowEnd r
            , "attempt" .= arAttempt r
            , "deferCount" .= arDeferCount r
            , "claimedBy" .= arClaimedBy r
            , "leaseExpiresAt" .= arLeaseExpires r
            , "nextRunAt" .= arNextRunAt r
            , "observeUntil" .= arObserveUntil r
            , "unhealthySince" .= arUnhealthySince r
            , "rollbackReason" .= arRollbackReason r
            , "error" .= arError r
            , "createdBy" .= arCreatedBy r
            , "createdAt" .= arCreatedAt r
            , "updatedAt" .= arUpdatedAt r
            , "finishedAt" .= arFinishedAt r
            ]

applyCols :: Query
applyCols =
    "id, cloud, schedule_id, trigger_kind, app_group, service, namespace, hpa_name, status, step, change, health_policy, \
    \before_spec, before_raw, after_spec, window_start, window_end, attempt, defer_count, claimed_by, lease_expires_at, \
    \next_run_at, observe_until, unhealthy_since, rollback_reason, error, created_by, created_at, updated_at, finished_at"

-- ---------------------------------------------------------------------------
-- Schedules

insertSchedule :: (MonadFlow m) => Text -> Text -> Text -> Text -> Text -> Value -> Value -> Value -> Text -> m ()
insertSchedule cloud sid app svc name kind change policy by = db $ \c -> do
    _ <-
        execute
            c
            "INSERT INTO hpa_schedule (id, cloud, app_group, service, name, kind, change, health_policy, created_by) \
            \VALUES (?, ?, ?, ?, ?, ?::jsonb, ?::jsonb, ?::jsonb, ?)"
            (sid, cloud, app, svc, name, kind, change, policy, by)
    pure ()

getSchedule :: (MonadFlow m) => Text -> Text -> m (Maybe ScheduleRow)
getSchedule cloud sid = db $ \c ->
    listToMaybe
        <$> query
            c
            ("SELECT " <> scheduleCols <> " FROM hpa_schedule WHERE cloud = ? AND id = ? AND deleted_at IS NULL")
            (cloud, sid)

listSchedules :: (MonadFlow m) => Text -> Maybe Text -> Maybe Text -> m [ScheduleRow]
listSchedules cloud mApp mSvc = db $ \c ->
    query
        c
        ( "SELECT " <> scheduleCols <> " FROM hpa_schedule WHERE cloud = ? AND deleted_at IS NULL \
          \AND (?::text IS NULL OR app_group = ?) AND (?::text IS NULL OR service = ?) ORDER BY created_at DESC"
        )
        (cloud, mApp, mApp, mSvc, mSvc)

listActiveSchedules :: (MonadFlow m) => Text -> m [ScheduleRow]
listActiveSchedules cloud = db $ \c ->
    query
        c
        ("SELECT " <> scheduleCols <> " FROM hpa_schedule WHERE cloud = ? AND deleted_at IS NULL AND status = 'ACTIVE' ORDER BY created_at")
        (Only cloud)

updateSchedule :: (MonadFlow m) => Text -> Text -> Text -> Value -> Value -> Value -> m Bool
updateSchedule cloud sid name kind change policy = db $ \c -> do
    n <-
        execute
            c
            "UPDATE hpa_schedule SET name = ?, kind = ?::jsonb, change = ?::jsonb, health_policy = ?::jsonb, \
            \updated_at = now(), status = CASE WHEN status = 'EXPIRED' THEN 'ACTIVE' ELSE status END \
            \WHERE cloud = ? AND id = ? AND deleted_at IS NULL"
            (name, kind, change, policy, cloud, sid)
    pure (n > 0)

setScheduleStatus :: (MonadFlow m) => Text -> Text -> Text -> m Bool
setScheduleStatus cloud sid st = db $ \c -> do
    n <-
        execute
            c
            "UPDATE hpa_schedule SET status = ?, updated_at = now() WHERE cloud = ? AND id = ? AND deleted_at IS NULL"
            (st, cloud, sid)
    pure (n > 0)

deleteSchedule :: (MonadFlow m) => Text -> Text -> m Bool
deleteSchedule cloud sid = db $ \c -> do
    n <-
        execute
            c
            "UPDATE hpa_schedule SET deleted_at = now(), updated_at = now() WHERE cloud = ? AND id = ? AND deleted_at IS NULL"
            (cloud, sid)
    pure (n > 0)

{- | Cheap compare-and-set so several pods do not all evaluate the same
schedule against the cluster at once. 'False' = someone evaluated it within
the last @minGapSeconds@.
-}
claimScheduleEval :: (MonadFlow m) => Text -> Text -> Int -> m Bool
claimScheduleEval cloud sid minGapSeconds = db $ \c -> do
    n <-
        execute
            c
            "UPDATE hpa_schedule SET last_eval_at = now() WHERE cloud = ? AND id = ? \
            \AND (last_eval_at IS NULL OR last_eval_at < now() - (?::int * interval '1 second'))"
            (cloud, sid, minGapSeconds)
    pure (n > 0)

-- ---------------------------------------------------------------------------
-- Applies

data ApplyNew = ApplyNew
    { anId :: Text
    , anCloud :: Text
    , anScheduleId :: Maybe Text
    , anTrigger :: Text
    , anAppGroup :: Text
    , anService :: Text
    , anNamespace :: Text
    , anHpaName :: Text
    , anChange :: Value
    , anPolicy :: Value
    , anWindowStart :: Maybe UTCTime
    , anWindowEnd :: Maybe UTCTime
    , anCreatedBy :: Text
    }

{- | 'False' when the unique indexes refused it: this HPA already has an in-flight
apply, or this schedule window was already applied to it.
-}
insertApply :: (MonadFlow m) => ApplyNew -> m Bool
insertApply a = db $ \c -> do
    n <-
        execute
            c
            "INSERT INTO hpa_apply (id, cloud, schedule_id, trigger_kind, app_group, service, namespace, hpa_name, \
            \status, change, health_policy, window_start, window_end, created_by) \
            \VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'PENDING', ?::jsonb, ?::jsonb, ?, ?, ?) ON CONFLICT DO NOTHING"
            ( (anId a, anCloud a, anScheduleId a, anTrigger a, anAppGroup a, anService a, anNamespace a, anHpaName a)
                :. (anChange a, anPolicy a, anWindowStart a, anWindowEnd a, anCreatedBy a)
            )
    pure (n > 0)

getApply :: (MonadFlow m) => Text -> Text -> m (Maybe ApplyRow)
getApply cloud aid = db $ \c ->
    listToMaybe <$> query c ("SELECT " <> applyCols <> " FROM hpa_apply WHERE cloud = ? AND id = ?") (cloud, aid)

listApplies :: (MonadFlow m) => Text -> Maybe Text -> Maybe Text -> Maybe Text -> Int -> m [ApplyRow]
listApplies cloud mApp mSvc mStatus limit = db $ \c ->
    query
        c
        ( "SELECT " <> applyCols <> " FROM hpa_apply WHERE cloud = ? AND (?::text IS NULL OR app_group = ?) \
          \AND (?::text IS NULL OR service = ?) AND (?::text IS NULL OR status = ?) ORDER BY created_at DESC LIMIT ?"
        )
        (cloud, mApp, mApp, mSvc, mSvc, mStatus, mStatus, limit)

appliesForSchedule :: (MonadFlow m) => Text -> Text -> m [ApplyRow]
appliesForSchedule cloud sid = db $ \c ->
    query c ("SELECT " <> applyCols <> " FROM hpa_apply WHERE cloud = ? AND schedule_id = ? ORDER BY created_at DESC") (cloud, sid)

inflightAppliesForService :: (MonadFlow m) => Text -> Text -> Text -> m [ApplyRow]
inflightAppliesForService cloud app svc = db $ \c ->
    query
        c
        ("SELECT " <> applyCols <> " FROM hpa_apply WHERE cloud = ? AND app_group = ? AND service = ? AND status IN ? ORDER BY created_at")
        (cloud, app, svc, In blockingStatusTexts)

{- | Claim the oldest due apply that needs a worker. A row is due when its status
is a work state (or APPLIED with its window over) and no live lease holds it. A
non-null expired lease means the previous worker died mid-step, which is counted in
@attempt@; clean hand-offs clear the lease so they never count.
-}
claimNextApply :: (MonadFlow m) => Text -> Text -> Int -> m (Maybe ApplyRow)
claimNextApply cloud worker leaseSecs = db $ \c ->
    listToMaybe
        <$> query
            c
            ( "WITH c AS ( SELECT id AS cid FROM hpa_apply WHERE cloud = ? AND next_run_at <= now() \
              \ AND (lease_expires_at IS NULL OR lease_expires_at < now()) \
              \ AND ( status IN ('PENDING', 'APPLYING', 'OBSERVING', 'RESTORING', 'ROLLING_BACK') \
              \       OR (status = 'APPLIED' AND window_end IS NOT NULL AND window_end <= now()) ) \
              \ ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED ) \
              \UPDATE hpa_apply a SET claimed_by = ?, lease_expires_at = now() + (?::int * interval '1 second'), \
              \ attempt = CASE WHEN a.lease_expires_at IS NOT NULL THEN a.attempt + 1 ELSE a.attempt END, updated_at = now() \
              \FROM c WHERE a.id = c.cid RETURNING "
                <> applyCols
            )
            (cloud, worker, leaseSecs)

heartbeatApply :: (MonadFlow m) => Text -> Text -> Int -> m Bool
heartbeatApply aid worker leaseSecs = db $ \c -> do
    n <-
        execute
            c
            "UPDATE hpa_apply SET lease_expires_at = now() + (?::int * interval '1 second') WHERE id = ? AND claimed_by = ?"
            (leaseSecs, aid, worker)
    pure (n > 0)

-- | Give the row back: clear the lease and say when it is next due.
releaseApply :: (MonadFlow m) => Text -> Text -> Int -> m ()
releaseApply aid worker nextRunInSecs = db $ \c -> do
    _ <-
        execute
            c
            "UPDATE hpa_apply SET claimed_by = NULL, lease_expires_at = NULL, \
            \next_run_at = now() + (?::int * interval '1 second'), updated_at = now() WHERE id = ? AND claimed_by = ?"
            (nextRunInSecs, aid, worker)
    pure ()

{- | Compare-and-set status change by the lease holder. Refuses transitions the state
machine does not allow. 'False' = lost the race (status moved, or lease is not ours).
-}
transitionApply :: (MonadFlow m) => Text -> Text -> T.ApplyStatus -> T.ApplyStatus -> Maybe T.ApplyStep -> m Bool
transitionApply aid worker from to step
    | not (validApplyTransition from to) = pure False
    | otherwise = db $ \c -> do
        n <-
            execute
                c
                "UPDATE hpa_apply SET status = ?, step = COALESCE(?, step), updated_at = now(), \
                \finished_at = CASE WHEN ? THEN now() ELSE finished_at END, \
                \attempt = CASE WHEN ? THEN attempt ELSE 0 END \
                \WHERE id = ? AND status = ? AND claimed_by = ?"
                (applyStatusText to, fmap T.applyStepText step, T.isTerminalApply to, to == T.NeedsAttention, aid, applyStatusText from, worker)
        pure (n > 0)

{- | Status change by someone who does not hold the lease (an API request, or a
reaper). Same state-machine guard and compare-and-set on the old status; also pulls
@next_run_at@ forward so a worker picks it up promptly.
-}
forceTransition :: (MonadFlow m) => Text -> Text -> [T.ApplyStatus] -> T.ApplyStatus -> Maybe Text -> m Bool
forceTransition aid cloud froms to reason = db $ \c -> do
    let allowed = [f | f <- froms, validApplyTransition f to]
    if null allowed
        then pure False
        else do
            n <-
                execute
                    c
                    "UPDATE hpa_apply SET status = ?, rollback_reason = COALESCE(?, rollback_reason), next_run_at = now(), \
                    \updated_at = now(), finished_at = CASE WHEN ? THEN now() ELSE finished_at END, \
                    \attempt = CASE WHEN ? = 'FAILED' THEN attempt ELSE 0 END \
                    \WHERE id = ? AND cloud = ? AND status IN ?"
                    (applyStatusText to, reason, T.isTerminalApply to, applyStatusText to, aid, cloud, In (map applyStatusText allowed))
            pure (n > 0)

{- | Fields a worker can set on a row it holds. @Nothing@ leaves a column alone;
the nested @Maybe@ ones can also clear it (@Just Nothing@).
-}
data ApplyPatch = ApplyPatch
    { apStep :: Maybe T.ApplyStep
    , apBeforeSpec :: Maybe Value
    , apBeforeRaw :: Maybe Value
    , apAfterSpec :: Maybe Value
    , apObserveUntil :: Maybe (Maybe UTCTime)
    , apUnhealthySince :: Maybe (Maybe UTCTime)
    , apError :: Maybe (Maybe Text)
    , apRollbackReason :: Maybe Text
    , apBumpDefer :: Bool
    , apBumpAttempt :: Bool
    -- ^ Count a transient failure towards the give-up limit.
    , apResetAttempt :: Bool
    -- ^ A step succeeded: forget earlier transient failures (they must not add up over hours of observing).
    }

emptyPatch :: ApplyPatch
emptyPatch = ApplyPatch Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing False False False

-- | Apply a patch if @worker@ still holds the lease. 'False' = it does not.
patchApply :: (MonadFlow m) => Text -> Text -> ApplyPatch -> m Bool
patchApply aid worker p = db $ \c -> do
    n <-
        execute
            c
            "UPDATE hpa_apply SET \
            \ step = COALESCE(?, step), \
            \ before_spec = COALESCE(before_spec, ?::jsonb), \
            \ before_raw = COALESCE(before_raw, ?::jsonb), \
            \ after_spec = COALESCE(?::jsonb, after_spec), \
            \ observe_until = CASE WHEN ? THEN ?::timestamptz ELSE observe_until END, \
            \ unhealthy_since = CASE WHEN ? THEN ?::timestamptz ELSE unhealthy_since END, \
            \ error = CASE WHEN ? THEN ?::text ELSE error END, \
            \ rollback_reason = COALESCE(?, rollback_reason), \
            \ defer_count = defer_count + (CASE WHEN ? THEN 1 ELSE 0 END), \
            \ attempt = CASE WHEN ? THEN 0 ELSE attempt + (CASE WHEN ? THEN 1 ELSE 0 END) END, \
            \ updated_at = now() \
            \WHERE id = ? AND claimed_by = ?"
            ( ( fmap T.applyStepText (apStep p)
              , apBeforeSpec p
              , apBeforeRaw p
              , apAfterSpec p
              , isJust' (apObserveUntil p)
              , join' (apObserveUntil p)
              , isJust' (apUnhealthySince p)
              )
                :. ( join' (apUnhealthySince p)
                   , isJust' (apError p)
                   , join' (apError p)
                   , apRollbackReason p
                   , apBumpDefer p
                   , apResetAttempt p
                   , apBumpAttempt p
                   , aid
                   , worker
                   )
            )
    pure (n > 0)
  where
    isJust' = maybe False (const True)
    join' = maybe Nothing id

-- ---------------------------------------------------------------------------
-- Events

addEvent :: (MonadFlow m) => Text -> Maybe Text -> Maybe Text -> Text -> Text -> Text -> Text -> Value -> m ()
addEvent cloud applyId scheduleId app svc kind msg dat = db $ \c -> do
    _ <-
        execute
            c
            "INSERT INTO hpa_event (cloud, apply_id, schedule_id, app_group, service, kind, message, data) \
            \VALUES (?, ?, ?, ?, ?, ?, ?, ?::jsonb)"
            (cloud, applyId, scheduleId, app, svc, kind, msg, dat)
    pure ()

eventSelect :: Query
eventSelect =
    "SELECT jsonb_build_object('id', id, 'applyId', apply_id, 'scheduleId', schedule_id, 'ts', ts, 'kind', kind, \
    \'message', message, 'data', data) FROM hpa_event"

listEventsForApply :: (MonadFlow m) => Text -> Text -> m [Value]
listEventsForApply cloud aid = db $ \c ->
    map fromOnly <$> query c (eventSelect <> " WHERE cloud = ? AND apply_id = ? ORDER BY id") (cloud, aid)

listEventsForService :: (MonadFlow m) => Text -> Text -> Text -> Int -> m [Value]
listEventsForService cloud app svc limit = db $ \c ->
    map fromOnly
        <$> query c (eventSelect <> " WHERE cloud = ? AND app_group = ? AND service = ? ORDER BY id DESC LIMIT ?") (cloud, app, svc, limit)

-- ---------------------------------------------------------------------------
-- Loop leader lease

{- | Try to become (or stay) the leader of a background loop for @cloud@. The row is
taken when free, expired, or already ours. Call every tick with a lease several ticks long.
-}
acquireLoopLease :: (MonadFlow m) => Text -> Text -> Text -> Int -> m Bool
acquireLoopLease name cloud holder secs = db $ \c -> do
    n <-
        execute
            c
            "INSERT INTO hpa_loop_lease (name, cloud, holder, lease_until) \
            \VALUES (?, ?, ?, now() + (?::int * interval '1 second')) \
            \ON CONFLICT (name, cloud) DO UPDATE SET holder = EXCLUDED.holder, lease_until = EXCLUDED.lease_until \
            \WHERE hpa_loop_lease.holder = EXCLUDED.holder OR hpa_loop_lease.lease_until < now()"
            (name, cloud, holder, secs)
    pure (n > 0)

-- ---------------------------------------------------------------------------
-- Observer data

-- | Services to sample: explicitly watched, with a live schedule, or with an in-flight apply.
watchedServices :: (MonadFlow m) => Text -> m [(Text, Text)]
watchedServices cloud = db $ \c ->
    query
        c
        "SELECT app_group, service FROM hpa_watch WHERE cloud = ? \
        \UNION SELECT app_group, service FROM hpa_schedule WHERE cloud = ? AND deleted_at IS NULL AND status <> 'EXPIRED' \
        \UNION SELECT app_group, service FROM hpa_apply WHERE cloud = ? AND status NOT IN ?"
        (cloud, cloud, cloud, In terminalStatusTexts)

addWatch :: (MonadFlow m) => Text -> Text -> Text -> Text -> m ()
addWatch cloud app svc by = db $ \c -> do
    _ <-
        execute
            c
            "INSERT INTO hpa_watch (cloud, app_group, service, created_by) VALUES (?, ?, ?, ?) ON CONFLICT DO NOTHING"
            (cloud, app, svc, by)
    pure ()

removeWatch :: (MonadFlow m) => Text -> Text -> Text -> m ()
removeWatch cloud app svc = db $ \c -> do
    _ <- execute c "DELETE FROM hpa_watch WHERE cloud = ? AND app_group = ? AND service = ?" (cloud, app, svc)
    pure ()

listWatched :: (MonadFlow m) => Text -> Text -> m [Text]
listWatched cloud app = db $ \c ->
    map fromOnly <$> query c "SELECT service FROM hpa_watch WHERE cloud = ? AND app_group = ?" (cloud, app)

lastSnapshotHash :: (MonadFlow m) => Text -> Text -> Text -> m (Maybe Text)
lastSnapshotHash cloud ns hpa = db $ \c ->
    fmap fromOnly . listToMaybe
        <$> query
            c
            "SELECT spec_hash FROM hpa_snapshot WHERE cloud = ? AND namespace = ? AND hpa_name = ? ORDER BY id DESC LIMIT 1"
            (cloud, ns, hpa)

insertSnapshot ::
    (MonadFlow m) => Text -> Text -> Text -> Text -> Text -> Value -> Text -> Text -> Maybe Text -> Maybe Text -> Text -> m ()
insertSnapshot cloud app svc ns hpa spec hash source managedBy applyId rv = db $ \c -> do
    _ <-
        execute
            c
            "INSERT INTO hpa_snapshot (cloud, app_group, service, namespace, hpa_name, spec, spec_hash, source, managed_by, apply_id, resource_version) \
            \VALUES (?, ?, ?, ?, ?, ?::jsonb, ?, ?, ?, ?, ?)"
            ((cloud, app, svc, ns, hpa, spec) :. (hash, source, managedBy, applyId, rv))
    pure ()

data SampleRow = SampleRow
    { smCloud :: Text
    , smAppGroup :: Text
    , smService :: Text
    , smNamespace :: Text
    , smHpaName :: Text
    , smTs :: UTCTime
    , smMin :: Int
    , smMax :: Int
    , smCurrent :: Int
    , smDesired :: Int
    , smCpuPct :: Maybe Double
    , smMemPct :: Maybe Double
    , smMetrics :: Value
    }

insertSample :: (MonadFlow m) => SampleRow -> m ()
insertSample s = db $ \c -> do
    _ <-
        execute
            c
            "INSERT INTO hpa_sample (cloud, app_group, service, namespace, hpa_name, ts, min_replicas, max_replicas, \
            \current_replicas, desired_replicas, cpu_pct, memory_pct, metrics) \
            \VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?::jsonb) ON CONFLICT DO NOTHING"
            ( (smCloud s, smAppGroup s, smService s, smNamespace s, smHpaName s, smTs s, smMin s)
                :. (smMax s, smCurrent s, smDesired s, smCpuPct s, smMemPct s, smMetrics s)
            )
    pure ()

-- | Insert or refresh a Kubernetes event by uid (events are aggregated server-side: same uid, rising count).
upsertScaleEvent ::
    (MonadFlow m) => Text -> Text -> Text -> Text -> Text -> Text -> Maybe Text -> Text -> Text -> Maybe Int -> Int -> UTCTime -> UTCTime -> m ()
upsertScaleEvent cloud app svc ns hpa uid typ reason msg newSize cnt firstTs lastTs = db $ \c -> do
    _ <-
        execute
            c
            "INSERT INTO hpa_scale_event (uid, cloud, app_group, service, namespace, hpa_name, type, reason, message, new_size, count, first_ts, last_ts) \
            \VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) \
            \ON CONFLICT (uid) DO UPDATE SET count = EXCLUDED.count, last_ts = EXCLUDED.last_ts, message = EXCLUDED.message, new_size = EXCLUDED.new_size"
            ((uid, cloud, app, svc, ns, hpa, typ) :. (reason, msg, newSize, cnt, firstTs, lastTs))
    pure ()

-- | Drop observer data older than the given number of days. Returns rows deleted.
pruneObserverData :: (MonadFlow m) => Text -> Int -> m Int
pruneObserverData cloud days = db $ \c -> do
    a <- execute c "DELETE FROM hpa_sample WHERE cloud = ? AND ts < now() - (?::int * interval '1 day')" (cloud, days)
    b <- execute c "DELETE FROM hpa_scale_event WHERE cloud = ? AND last_ts < now() - (?::int * interval '1 day')" (cloud, days)
    d <- execute c "DELETE FROM hpa_event WHERE cloud = ? AND ts < now() - (?::int * interval '1 day') AND apply_id IS NULL" (cloud, days * 4)
    pure (fromIntegral (a + b + d))

-- ---------------------------------------------------------------------------
-- Reads for the panel

{- | Time series for a service, averaged into buckets of @bucketSecs@ so a long range
stays a few hundred points. Replicas take the bucket max (spikes must stay visible),
utilisation the mean.
-}
samplesFor :: (MonadFlow m) => Text -> Text -> Text -> UTCTime -> UTCTime -> Int -> m [Value]
samplesFor cloud app svc from to bucketSecs = db $ \c ->
    map fromOnly
        <$> query
            c
            "SELECT jsonb_build_object('ts', b, 'hpaName', hpa_name, 'min', mn, 'max', mx, 'current', cur, 'desired', des, 'cpuPct', cpu, 'memoryPct', mem) \
            \FROM ( SELECT to_timestamp(floor(extract(epoch FROM ts) / ?::int) * ?::int) AS b, hpa_name, \
            \ max(min_replicas) AS mn, max(max_replicas) AS mx, max(current_replicas) AS cur, max(desired_replicas) AS des, \
            \ avg(cpu_pct) AS cpu, avg(memory_pct) AS mem \
            \ FROM hpa_sample WHERE cloud = ? AND app_group = ? AND service = ? AND ts >= ? AND ts < ? \
            \ GROUP BY b, hpa_name ORDER BY b, hpa_name ) t"
            (bucketSecs, bucketSecs, cloud, app, svc, from, to)

snapshotsFor :: (MonadFlow m) => Text -> Text -> Text -> Int -> m [Value]
snapshotsFor cloud app svc limit = db $ \c ->
    map fromOnly
        <$> query
            c
            "SELECT jsonb_build_object('id', id, 'hpaName', hpa_name, 'ts', ts, 'spec', spec, 'source', source, \
            \'managedBy', managed_by, 'applyId', apply_id, 'resourceVersion', resource_version) \
            \FROM hpa_snapshot WHERE cloud = ? AND app_group = ? AND service = ? ORDER BY id DESC LIMIT ?"
            (cloud, app, svc, limit)

scaleEventsFor :: (MonadFlow m) => Text -> Text -> Text -> UTCTime -> UTCTime -> Int -> m [Value]
scaleEventsFor cloud app svc from to limit = db $ \c ->
    map fromOnly
        <$> query
            c
            "SELECT jsonb_build_object('uid', uid, 'hpaName', hpa_name, 'type', type, 'reason', reason, 'message', message, \
            \'newSize', new_size, 'count', count, 'firstTs', first_ts, 'lastTs', last_ts) \
            \FROM hpa_scale_event WHERE cloud = ? AND app_group = ? AND service = ? AND last_ts >= ? AND last_ts < ? \
            \ORDER BY last_ts DESC LIMIT ?"
            (cloud, app, svc, from, to, limit)

latestSampleTime :: (MonadFlow m) => Text -> Text -> Text -> m (Maybe UTCTime)
latestSampleTime cloud app svc = db $ \c ->
    (>>= fromOnly) . listToMaybe
        <$> query c "SELECT max(ts) FROM hpa_sample WHERE cloud = ? AND app_group = ? AND service = ?" (cloud, app, svc)

-- ---------------------------------------------------------------------------
-- Guardrails

getGuardrailRow :: (MonadFlow m) => Text -> Text -> Text -> m (Maybe Value)
getGuardrailRow cloud app svc = db $ \c ->
    fmap fromOnly . listToMaybe
        <$> query c "SELECT data FROM hpa_guardrail WHERE cloud = ? AND app_group = ? AND service = ?" (cloud, app, svc)

putGuardrailRow :: (MonadFlow m) => Text -> Text -> Text -> Value -> Text -> m ()
putGuardrailRow cloud app svc dat by = db $ \c -> do
    _ <-
        execute
            c
            "INSERT INTO hpa_guardrail (cloud, app_group, service, data, updated_by) VALUES (?, ?, ?, ?::jsonb, ?) \
            \ON CONFLICT (cloud, app_group, service) DO UPDATE SET data = EXCLUDED.data, updated_by = EXCLUDED.updated_by, updated_at = now()"
            (cloud, app, svc, dat, by)
    pure ()

-- | Every guardrail of a product, by service.
listGuardrails :: (MonadFlow m) => Text -> Text -> m [(Text, Value)]
listGuardrails cloud app = db $ \c ->
    query c "SELECT service, data FROM hpa_guardrail WHERE cloud = ? AND app_group = ?" (cloud, app)
