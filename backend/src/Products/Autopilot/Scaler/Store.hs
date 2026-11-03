{-# LANGUAGE OverloadedStrings #-}

{- | Persistence for the capacity scaler (migration 0060). Raw SQL, same rules as the HPA store:

* every function takes the runner's @cloud@ and filters on it;
* an apply is claimed with @FOR UPDATE SKIP LOCKED@ and a lease, so a dead worker's claim simply expires;
* every status change is a compare-and-set on the previous status;
* the unique indexes make a second in-flight apply for a target, or a second apply of the same schedule
  window, impossible rather than merely unlikely.

Targets live in two tables, @redis_config@ and @db_config@; everything else is shared and keyed by
@(target_kind, target_id)@.
-}
module Products.Autopilot.Scaler.Store (
    -- * Targets
    insertTarget,
    getTarget,
    listTargets,
    updateTarget,
    deleteTarget,
    targetInUse,

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
    schedulesForTarget,
    updateSchedule,
    setScheduleStatus,
    deleteSchedule,
    claimScheduleEval,

    -- * Applies
    insertApply,
    getApply,
    listApplies,
    appliesForSchedule,
    inflightApplies,
    claimNextApply,
    heartbeatApply,
    holdsLease,
    releaseApply,
    transitionApply,
    forceTransition,
    patchApply,

    -- * Events
    addEvent,
    listEventsForApply,
    listEventsForTarget,

    -- * Guardrails
    getGuardrailRow,
    putGuardrailRow,

    -- * Autoscaler edit history
    addAutoscalerHistory,
    listAutoscalerHistory,
    getAutoscalerHistory,
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
import Products.Autopilot.Hpa.Types (applyStatusText, blockingStatusTexts, validApplyTransition)
import Products.Autopilot.Hpa.Types qualified as T
import Products.Autopilot.Scaler.Types

db :: (MonadFlow m) => (Connection -> IO a) -> m a
db f = withDb (\d -> withConn d f)

kindT :: TargetKind -> Text
kindT = targetKindText

-- ---------------------------------------------------------------------------
-- Targets

data RedisRow = RedisRow Text Text Text Text Text (Maybe Text) (Maybe Text)

instance FromRow RedisRow where
    fromRow = RedisRow <$> field <*> field <*> field <*> field <*> field <*> field <*> field

data DbRow = DbRow Text Text Text Text Text Text (Maybe Text) (Maybe Text)

instance FromRow DbRow where
    fromRow = DbRow <$> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field

redisTarget :: RedisRow -> Target
redisTarget (RedisRow i n p l inst j jl) = Target i KindRedis n p l Nothing inst j jl

dbTarget :: DbRow -> Target
dbTarget (DbRow i n p l c pool j jl) = Target i KindDb n p l (Just c) pool j jl

redisCols, dbCols :: Query
redisCols = "id, name, project, location, instance, autoscaler_job, autoscaler_location"
dbCols = "id, name, project, location, cluster, read_pool, autoscaler_job, autoscaler_location"

-- | 'False' when a live target for the same resource is already registered.
insertTarget :: (MonadFlow m) => Text -> Target -> Text -> m Bool
insertTarget cloud t by = db $ \c -> case tgKind t of
    KindRedis -> do
        n <-
            execute
                c
                "INSERT INTO redis_config (id, cloud, name, project, location, instance, autoscaler_job, autoscaler_location, created_by) \
                \VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT DO NOTHING"
                (tgId t, cloud, tgName t, tgProject t, tgLocation t, tgResource t, tgJob t, tgJobLocation t, by)
        pure (n > 0)
    KindDb -> do
        n <-
            execute
                c
                "INSERT INTO db_config (id, cloud, name, project, location, cluster, read_pool, autoscaler_job, autoscaler_location, created_by) \
                \VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT DO NOTHING"
                (tgId t, cloud, tgName t, tgProject t, tgLocation t, maybe "" id (tgParent t), tgResource t, tgJob t, tgJobLocation t, by)
        pure (n > 0)

getTarget :: (MonadFlow m) => Text -> TargetKind -> Text -> m (Maybe Target)
getTarget cloud kind tid = db $ \c -> case kind of
    KindRedis ->
        fmap redisTarget . listToMaybe
            <$> query c ("SELECT " <> redisCols <> " FROM redis_config WHERE cloud = ? AND id = ? AND deleted_at IS NULL") (cloud, tid)
    KindDb ->
        fmap dbTarget . listToMaybe
            <$> query c ("SELECT " <> dbCols <> " FROM db_config WHERE cloud = ? AND id = ? AND deleted_at IS NULL") (cloud, tid)

listTargets :: (MonadFlow m) => Text -> Maybe TargetKind -> m [Target]
listTargets cloud mKind = db $ \c -> do
    rs <-
        if mKind == Just KindDb
            then pure []
            else map redisTarget <$> query c ("SELECT " <> redisCols <> " FROM redis_config WHERE cloud = ? AND deleted_at IS NULL ORDER BY name") (Only cloud)
    ds <-
        if mKind == Just KindRedis
            then pure []
            else map dbTarget <$> query c ("SELECT " <> dbCols <> " FROM db_config WHERE cloud = ? AND deleted_at IS NULL ORDER BY name") (Only cloud)
    pure (rs <> ds)

-- | Edit the label and the autoscaler job. The resource itself is not editable: register a new target.
updateTarget :: (MonadFlow m) => Text -> Target -> m Bool
updateTarget cloud t = db $ \c -> do
    n <- case tgKind t of
        KindRedis ->
            execute
                c
                "UPDATE redis_config SET name = ?, autoscaler_job = ?, autoscaler_location = ?, updated_at = now() \
                \WHERE cloud = ? AND id = ? AND deleted_at IS NULL"
                (tgName t, tgJob t, tgJobLocation t, cloud, tgId t)
        KindDb ->
            execute
                c
                "UPDATE db_config SET name = ?, autoscaler_job = ?, autoscaler_location = ?, updated_at = now() \
                \WHERE cloud = ? AND id = ? AND deleted_at IS NULL"
                (tgName t, tgJob t, tgJobLocation t, cloud, tgId t)
    pure (n > 0)

deleteTarget :: (MonadFlow m) => Text -> TargetKind -> Text -> m Bool
deleteTarget cloud kind tid = db $ \c -> do
    n <- case kind of
        KindRedis -> execute c "UPDATE redis_config SET deleted_at = now(), updated_at = now() WHERE cloud = ? AND id = ? AND deleted_at IS NULL" (cloud, tid)
        KindDb -> execute c "UPDATE db_config SET deleted_at = now(), updated_at = now() WHERE cloud = ? AND id = ? AND deleted_at IS NULL" (cloud, tid)
    pure (n > 0)

-- | Live schedules plus in-flight applies that still refer to the target; a target in use cannot be removed.
targetInUse :: (MonadFlow m) => Text -> TargetKind -> Text -> m Int
targetInUse cloud kind tid = db $ \c -> do
    a <- query c "SELECT count(*)::int FROM scaler_schedule WHERE cloud = ? AND target_kind = ? AND target_id = ? AND deleted_at IS NULL" (cloud, kindT kind, tid)
    b <-
        query
            c
            "SELECT count(*)::int FROM scaler_apply WHERE cloud = ? AND target_kind = ? AND target_id = ? AND status IN ?"
            (cloud, kindT kind, tid, In blockingStatusTexts)
    pure (sum (map fromOnly (a <> b)))

-- ---------------------------------------------------------------------------
-- Rows

data ScheduleRow = ScheduleRow
    { srId :: Text
    , srCloud :: Text
    , srTargetKind :: Text
    , srTargetId :: Text
    , srName :: Text
    , srStatus :: Text
    , srTiming :: Value
    , srChange :: Value
    , srCreatedBy :: Text
    , srCreatedAt :: UTCTime
    , srUpdatedAt :: UTCTime
    }
    deriving (Show)

instance FromRow ScheduleRow where
    fromRow =
        ScheduleRow
            <$> field <*> field <*> field <*> field <*> field <*> field
            <*> field <*> field <*> field <*> field <*> field

instance ToJSON ScheduleRow where
    toJSON r =
        A.object
            [ "id" .= srId r
            , "targetKind" .= srTargetKind r
            , "targetId" .= srTargetId r
            , "name" .= srName r
            , "status" .= srStatus r
            , "timing" .= srTiming r
            , "change" .= srChange r
            , "createdBy" .= srCreatedBy r
            , "createdAt" .= srCreatedAt r
            , "updatedAt" .= srUpdatedAt r
            ]

scheduleCols :: Query
scheduleCols = "id, cloud, target_kind, target_id, name, status, timing, change, created_by, created_at, updated_at"

data ApplyRow = ApplyRow
    { arId :: Text
    , arCloud :: Text
    , arScheduleId :: Maybe Text
    , arTrigger :: Text
    , arTargetKind :: Text
    , arTargetId :: Text
    , arStatus :: Text
    , arStep :: Maybe Text
    , arChange :: Value
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
            <*> field <*> field <*> field <*> field <*> field <*> field

-- | Everything except the raw copy of the autoscaler job, which is for manual recovery only.
instance ToJSON ApplyRow where
    toJSON r =
        A.object
            [ "id" .= arId r
            , "scheduleId" .= arScheduleId r
            , "trigger" .= arTrigger r
            , "targetKind" .= arTargetKind r
            , "targetId" .= arTargetId r
            , "status" .= arStatus r
            , "step" .= arStep r
            , "change" .= arChange r
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
            , "rollbackReason" .= arRollbackReason r
            , "error" .= arError r
            , "createdBy" .= arCreatedBy r
            , "createdAt" .= arCreatedAt r
            , "updatedAt" .= arUpdatedAt r
            , "finishedAt" .= arFinishedAt r
            ]

applyCols :: Query
applyCols =
    "id, cloud, schedule_id, trigger_kind, target_kind, target_id, status, step, change, \
    \before_spec, before_raw, after_spec, window_start, window_end, attempt, defer_count, claimed_by, lease_expires_at, \
    \next_run_at, observe_until, rollback_reason, error, created_by, created_at, updated_at, finished_at"

-- ---------------------------------------------------------------------------
-- Schedules

insertSchedule :: (MonadFlow m) => Text -> Text -> TargetKind -> Text -> Text -> Value -> Value -> Text -> m ()
insertSchedule cloud sid kind tid name timing change by = db $ \c -> do
    _ <-
        execute
            c
            "INSERT INTO scaler_schedule (id, cloud, target_kind, target_id, name, timing, change, created_by) \
            \VALUES (?, ?, ?, ?, ?, ?::jsonb, ?::jsonb, ?)"
            (sid, cloud, kindT kind, tid, name, timing, change, by)
    pure ()

getSchedule :: (MonadFlow m) => Text -> Text -> m (Maybe ScheduleRow)
getSchedule cloud sid = db $ \c ->
    listToMaybe
        <$> query
            c
            ("SELECT " <> scheduleCols <> " FROM scaler_schedule WHERE cloud = ? AND id = ? AND deleted_at IS NULL")
            (cloud, sid)

listSchedules :: (MonadFlow m) => Text -> Maybe TargetKind -> Maybe Text -> m [ScheduleRow]
listSchedules cloud mKind mTarget = db $ \c ->
    query
        c
        ( "SELECT " <> scheduleCols <> " FROM scaler_schedule WHERE cloud = ? AND deleted_at IS NULL \
          \AND (?::text IS NULL OR target_kind = ?) AND (?::text IS NULL OR target_id = ?) ORDER BY created_at DESC"
        )
        (cloud, fmap kindT mKind, fmap kindT mKind, mTarget, mTarget)

listActiveSchedules :: (MonadFlow m) => Text -> m [ScheduleRow]
listActiveSchedules cloud = db $ \c ->
    query
        c
        ("SELECT " <> scheduleCols <> " FROM scaler_schedule WHERE cloud = ? AND deleted_at IS NULL AND status = 'ACTIVE' ORDER BY created_at")
        (Only cloud)

-- | Live (not deleted, not expired) schedules on one target, for the overlap check.
schedulesForTarget :: (MonadFlow m) => Text -> TargetKind -> Text -> m [ScheduleRow]
schedulesForTarget cloud kind tid = db $ \c ->
    query
        c
        ( "SELECT " <> scheduleCols <> " FROM scaler_schedule WHERE cloud = ? AND target_kind = ? AND target_id = ? \
          \AND deleted_at IS NULL AND status <> 'EXPIRED' ORDER BY created_at"
        )
        (cloud, kindT kind, tid)

updateSchedule :: (MonadFlow m) => Text -> Text -> Text -> Value -> Value -> m Bool
updateSchedule cloud sid name timing change = db $ \c -> do
    n <-
        execute
            c
            "UPDATE scaler_schedule SET name = ?, timing = ?::jsonb, change = ?::jsonb, updated_at = now(), \
            \status = CASE WHEN status = 'EXPIRED' THEN 'ACTIVE' ELSE status END \
            \WHERE cloud = ? AND id = ? AND deleted_at IS NULL"
            (name, timing, change, cloud, sid)
    pure (n > 0)

setScheduleStatus :: (MonadFlow m) => Text -> Text -> Text -> m Bool
setScheduleStatus cloud sid st = db $ \c -> do
    n <-
        execute
            c
            "UPDATE scaler_schedule SET status = ?, updated_at = now() WHERE cloud = ? AND id = ? AND deleted_at IS NULL"
            (st, cloud, sid)
    pure (n > 0)

deleteSchedule :: (MonadFlow m) => Text -> Text -> m Bool
deleteSchedule cloud sid = db $ \c -> do
    n <-
        execute
            c
            "UPDATE scaler_schedule SET deleted_at = now(), updated_at = now() WHERE cloud = ? AND id = ? AND deleted_at IS NULL"
            (cloud, sid)
    pure (n > 0)

-- | Compare-and-set so several pods do not all evaluate one schedule at once.
claimScheduleEval :: (MonadFlow m) => Text -> Text -> Int -> m Bool
claimScheduleEval cloud sid minGapSeconds = db $ \c -> do
    n <-
        execute
            c
            "UPDATE scaler_schedule SET last_eval_at = now() WHERE cloud = ? AND id = ? \
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
    , anKind :: TargetKind
    , anTargetId :: Text
    , anChange :: Value
    , anWindowStart :: Maybe UTCTime
    , anWindowEnd :: Maybe UTCTime
    , anCreatedBy :: Text
    }

{- | 'False' when the unique indexes refused it: this target already has an in-flight apply, or this schedule
window was already applied to it.
-}
insertApply :: (MonadFlow m) => ApplyNew -> m Bool
insertApply a = db $ \c -> do
    n <-
        execute
            c
            "INSERT INTO scaler_apply (id, cloud, schedule_id, trigger_kind, target_kind, target_id, status, change, \
            \window_start, window_end, created_by) \
            \VALUES (?, ?, ?, ?, ?, ?, 'PENDING', ?::jsonb, ?, ?, ?) ON CONFLICT DO NOTHING"
            ( (anId a, anCloud a, anScheduleId a, anTrigger a, kindT (anKind a), anTargetId a)
                :. (anChange a, anWindowStart a, anWindowEnd a, anCreatedBy a)
            )
    pure (n > 0)

getApply :: (MonadFlow m) => Text -> Text -> m (Maybe ApplyRow)
getApply cloud aid = db $ \c ->
    listToMaybe <$> query c ("SELECT " <> applyCols <> " FROM scaler_apply WHERE cloud = ? AND id = ?") (cloud, aid)

listApplies :: (MonadFlow m) => Text -> Maybe TargetKind -> Maybe Text -> Maybe Text -> Int -> m [ApplyRow]
listApplies cloud mKind mTarget mStatus limit = db $ \c ->
    query
        c
        ( "SELECT " <> applyCols <> " FROM scaler_apply WHERE cloud = ? AND (?::text IS NULL OR target_kind = ?) \
          \AND (?::text IS NULL OR target_id = ?) AND (?::text IS NULL OR status = ?) ORDER BY created_at DESC LIMIT ?"
        )
        (cloud, fmap kindT mKind, fmap kindT mKind, mTarget, mTarget, mStatus, mStatus, limit)

appliesForSchedule :: (MonadFlow m) => Text -> Text -> m [ApplyRow]
appliesForSchedule cloud sid = db $ \c ->
    query c ("SELECT " <> applyCols <> " FROM scaler_apply WHERE cloud = ? AND schedule_id = ? ORDER BY created_at DESC") (cloud, sid)

inflightApplies :: (MonadFlow m) => Text -> TargetKind -> Text -> m [ApplyRow]
inflightApplies cloud kind tid = db $ \c ->
    query
        c
        ( "SELECT " <> applyCols <> " FROM scaler_apply WHERE cloud = ? AND target_kind = ? AND target_id = ? \
          \AND status IN ? ORDER BY created_at"
        )
        (cloud, kindT kind, tid, In blockingStatusTexts)

{- | Claim the oldest due apply that needs a worker. A row is due when its status is a work state (or APPLIED
with its window over) and no live lease holds it. A non-null expired lease means the previous worker died
mid-step, which is counted in @attempt@.
-}
claimNextApply :: (MonadFlow m) => Text -> Text -> Int -> m (Maybe ApplyRow)
claimNextApply cloud worker leaseSecs = db $ \c ->
    listToMaybe
        <$> query
            c
            ( "WITH c AS ( SELECT id AS cid FROM scaler_apply WHERE cloud = ? AND next_run_at <= now() \
              \ AND (lease_expires_at IS NULL OR lease_expires_at < now()) \
              \ AND ( status IN ('PENDING', 'APPLYING', 'OBSERVING', 'RESTORING', 'ROLLING_BACK') \
              \       OR (status = 'APPLIED' AND window_end IS NOT NULL AND window_end <= now()) ) \
              \ ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED ) \
              \UPDATE scaler_apply a SET claimed_by = ?, lease_expires_at = now() + (?::int * interval '1 second'), \
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
            "UPDATE scaler_apply SET lease_expires_at = now() + (?::int * interval '1 second') WHERE id = ? AND claimed_by = ?"
            (leaseSecs, aid, worker)
    pure (n > 0)

-- | Does @worker@ still hold a live lease on the row? Checked right before every write to Google Cloud.
holdsLease :: (MonadFlow m) => Text -> Text -> m Bool
holdsLease aid worker = db $ \c -> do
    rs <-
        query
            c
            "SELECT 1 FROM scaler_apply WHERE id = ? AND claimed_by = ? AND lease_expires_at > now()"
            (aid, worker)
    pure (not (null (rs :: [Only Int])))

-- | Give the row back: clear the lease and say when it is next due.
releaseApply :: (MonadFlow m) => Text -> Text -> Int -> m ()
releaseApply aid worker nextRunInSecs = db $ \c -> do
    _ <-
        execute
            c
            "UPDATE scaler_apply SET claimed_by = NULL, lease_expires_at = NULL, \
            \next_run_at = now() + (?::int * interval '1 second'), updated_at = now() WHERE id = ? AND claimed_by = ?"
            (nextRunInSecs, aid, worker)
    pure ()

{- | Compare-and-set status change by the lease holder. Refuses transitions the state machine does not
allow. 'False' = lost the race (status moved, or the lease is not ours).
-}
transitionApply :: (MonadFlow m) => Text -> Text -> T.ApplyStatus -> T.ApplyStatus -> Maybe T.ApplyStep -> m Bool
transitionApply aid worker from to step
    | not (validApplyTransition from to) = pure False
    | otherwise = db $ \c -> do
        n <-
            execute
                c
                "UPDATE scaler_apply SET status = ?, step = COALESCE(?, step), updated_at = now(), \
                \finished_at = CASE WHEN ? THEN now() ELSE finished_at END, \
                \attempt = CASE WHEN ? THEN attempt ELSE 0 END \
                \WHERE id = ? AND status = ? AND claimed_by = ?"
                (applyStatusText to, fmap T.applyStepText step, T.isTerminalApply to, to == T.NeedsAttention, aid, applyStatusText from, worker)
        pure (n > 0)

{- | Status change by someone who does not hold the lease (an API request). Same state-machine guard and
compare-and-set on the old status; also pulls @next_run_at@ forward.
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
                    "UPDATE scaler_apply SET status = ?, rollback_reason = COALESCE(?, rollback_reason), next_run_at = now(), \
                    \updated_at = now(), finished_at = CASE WHEN ? THEN now() ELSE finished_at END, \
                    \attempt = CASE WHEN ? = 'FAILED' THEN attempt ELSE 0 END \
                    \WHERE id = ? AND cloud = ? AND status IN ?"
                    (applyStatusText to, reason, T.isTerminalApply to, applyStatusText to, aid, cloud, In (map applyStatusText allowed))
            pure (n > 0)

{- | Fields a worker can set on a row it holds. @Nothing@ leaves a column alone; the nested @Maybe@ ones can
also clear it (@Just Nothing@).
-}
data ApplyPatch = ApplyPatch
    { apStep :: Maybe T.ApplyStep
    , apBeforeSpec :: Maybe Value
    , apBeforeRaw :: Maybe Value
    , apAfterSpec :: Maybe Value
    , apObserveUntil :: Maybe (Maybe UTCTime)
    , apError :: Maybe (Maybe Text)
    , apRollbackReason :: Maybe Text
    , apBumpDefer :: Bool
    , apBumpAttempt :: Bool
    , apResetAttempt :: Bool
    }

emptyPatch :: ApplyPatch
emptyPatch = ApplyPatch Nothing Nothing Nothing Nothing Nothing Nothing Nothing False False False

{- | Apply a patch if @worker@ still holds the lease. 'False' = it does not. @before_spec@ and @before_raw@
are only ever written once (the original values must never be overwritten).
-}
patchApply :: (MonadFlow m) => Text -> Text -> ApplyPatch -> m Bool
patchApply aid worker p = db $ \c -> do
    n <-
        execute
            c
            "UPDATE scaler_apply SET \
            \ step = COALESCE(?, step), \
            \ before_spec = COALESCE(before_spec, ?::jsonb), \
            \ before_raw = COALESCE(before_raw, ?::jsonb), \
            \ after_spec = COALESCE(?::jsonb, after_spec), \
            \ observe_until = CASE WHEN ? THEN ?::timestamptz ELSE observe_until END, \
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
              , isSet (apObserveUntil p)
              , flat (apObserveUntil p)
              )
                :. ( isSet (apError p)
                   , flat (apError p)
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
    isSet = maybe False (const True)
    flat = maybe Nothing id

-- ---------------------------------------------------------------------------
-- Events

addEvent :: (MonadFlow m) => Text -> Maybe Text -> Maybe Text -> TargetKind -> Text -> Text -> Text -> Value -> m ()
addEvent cloud applyId scheduleId kind tid evKind msg dat = db $ \c -> do
    _ <-
        execute
            c
            "INSERT INTO scaler_event (cloud, apply_id, schedule_id, target_kind, target_id, kind, message, data) \
            \VALUES (?, ?, ?, ?, ?, ?, ?, ?::jsonb)"
            (cloud, applyId, scheduleId, kindT kind, tid, evKind, msg, dat)
    pure ()

eventSelect :: Query
eventSelect =
    "SELECT jsonb_build_object('id', id, 'applyId', apply_id, 'scheduleId', schedule_id, 'ts', ts, 'kind', kind, \
    \'message', message, 'data', data) FROM scaler_event"

listEventsForApply :: (MonadFlow m) => Text -> Text -> m [Value]
listEventsForApply cloud aid = db $ \c ->
    map fromOnly <$> query c (eventSelect <> " WHERE cloud = ? AND apply_id = ? ORDER BY id") (cloud, aid)

listEventsForTarget :: (MonadFlow m) => Text -> TargetKind -> Text -> Int -> m [Value]
listEventsForTarget cloud kind tid limit = db $ \c ->
    map fromOnly
        <$> query c (eventSelect <> " WHERE cloud = ? AND target_kind = ? AND target_id = ? ORDER BY id DESC LIMIT ?") (cloud, kindT kind, tid, limit)

-- ---------------------------------------------------------------------------
-- Guardrails

getGuardrailRow :: (MonadFlow m) => Text -> TargetKind -> Text -> m (Maybe Value)
getGuardrailRow cloud kind tid = db $ \c ->
    fmap fromOnly . listToMaybe
        <$> query c "SELECT data FROM scaler_guardrail WHERE cloud = ? AND target_kind = ? AND target_id = ?" (cloud, kindT kind, tid)

putGuardrailRow :: (MonadFlow m) => Text -> TargetKind -> Text -> Value -> Text -> m ()
putGuardrailRow cloud kind tid dat by = db $ \c -> do
    _ <-
        execute
            c
            "INSERT INTO scaler_guardrail (cloud, target_kind, target_id, data, updated_by) VALUES (?, ?, ?, ?::jsonb, ?) \
            \ON CONFLICT (cloud, target_kind, target_id) DO UPDATE SET data = EXCLUDED.data, \
            \updated_by = EXCLUDED.updated_by, updated_at = now()"
            (cloud, kindT kind, tid, dat, by)
    pure ()

-- ---------------------------------------------------------------------------
-- Autoscaler edit history

addAutoscalerHistory :: (MonadFlow m) => Text -> TargetKind -> Text -> Text -> Text -> Maybe Text -> Maybe Value -> Maybe Value -> m ()
addAutoscalerHistory cloud kind tid actor action note before after = db $ \c -> do
    _ <-
        execute
            c
            "INSERT INTO scaler_autoscaler_history (cloud, target_kind, target_id, actor, action, note, before, after) \
            \VALUES (?, ?, ?, ?, ?, ?, ?::jsonb, ?::jsonb)"
            (cloud, kindT kind, tid, actor, action, note, before, after)
    pure ()

listAutoscalerHistory :: (MonadFlow m) => Text -> TargetKind -> Text -> Int -> m [Value]
listAutoscalerHistory cloud kind tid limit = db $ \c ->
    map fromOnly
        <$> query
            c
            "SELECT jsonb_build_object('id', id, 'ts', ts, 'actor', actor, 'action', action, 'note', note, 'before', before, 'after', after) \
            \FROM scaler_autoscaler_history WHERE cloud = ? AND target_kind = ? AND target_id = ? ORDER BY id DESC LIMIT ?"
            (cloud, kindT kind, tid, limit)

-- | One history row's (before, after) entries, for reverting.
getAutoscalerHistory :: (MonadFlow m) => Text -> TargetKind -> Text -> Int -> m (Maybe (Maybe Value, Maybe Value))
getAutoscalerHistory cloud kind tid hid = db $ \c ->
    listToMaybe
        <$> query
            c
            "SELECT before, after FROM scaler_autoscaler_history WHERE cloud = ? AND target_kind = ? AND target_id = ? AND id = ?"
            (cloud, kindT kind, tid, hid)
