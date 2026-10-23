{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Executes rows of the apply ledger (@hpa_apply@).

The contract that makes this safe when threads, pods or the whole process die:

* All state is in the row. A worker holds a /lease/ on it, heartbeats the lease from
  a separate thread, and releases it when done. If the worker dies the lease
  expires and any worker, on any pod, claims the row again.
* One call of 'processApply' does one step and ends; the next claim continues. No
  step relies on in-memory state from a previous step.
* Every step starts from what the cluster /actually/ holds ('decideApplyAction',
  'planRestore'), not from what the dead worker meant to do, so resuming after a
  crash at any point is correct: before the change, after it, or half-recorded.
* The original spec is written to the row exactly once, before the first change.
* Status changes are compare-and-set on the old status and the lease holder, so a
  worker that lost its lease cannot move the row.
* A row that keeps failing (crashes or transient errors) is parked in
  NEEDS_ATTENTION after 'maxAttempts' instead of retrying forever.
-}
module Products.Autopilot.Hpa.Worker (
    WorkerEnv (..),
    mkWorkerEnv,
    processApply,
    runWorkers,
    workerLoop,
    supervise,
    maxAttempts,
    leaseSeconds,
    heartbeatSeconds,
)
where

import Control.Concurrent.Async (mapConcurrently_, withAsync)
import Control.Monad (forever, void, when)
import Control.Monad.Catch (throwM, try)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)
import Core.Config (Config (..))
import Core.Environment (Flow, getConfig, logError, logInfo, logWarning, runFlow)
import Core.Types.Time (Seconds (..), threadDelay)
import Data.Aeson (ToJSON (..), Value (..), (.=))
import Data.Aeson qualified as A
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Products.Autopilot.Hpa.Change
import Products.Autopilot.Hpa.Health
import Products.Autopilot.Hpa.Kube
import Products.Autopilot.Hpa.Resolver (editableReason)
import Products.Autopilot.Hpa.Service (loadGuardrail, loadServiceCtx, releaseConflict)
import Products.Autopilot.Hpa.Util (decodeValue, isAsync, tshow)
import Products.Autopilot.Hpa.Spec
import Products.Autopilot.Hpa.Store
import Products.Autopilot.Hpa.Types

data WorkerEnv = WorkerEnv
    { weKube :: Kube
    , weCloud :: Text
    , weWorker :: Text
    , weConfig :: Config
    }

mkWorkerEnv :: Text -> Flow WorkerEnv
mkWorkerEnv wid = do
    cfg <- getConfig
    pure (WorkerEnv (mkKube cfg) (cloudProvider cfg) wid cfg)

-- | How long a claim lasts without a heartbeat. Several heartbeats long, so one slow DB call does not lose the row.
leaseSeconds :: Int
leaseSeconds = 90

heartbeatSeconds :: Int
heartbeatSeconds = 20

-- | Crashes plus transient errors before a row is parked for a human.
maxAttempts :: Int
maxAttempts = 6

jsonText :: Value -> Text
jsonText = TE.decodeUtf8 . BL.toStrict . A.encode

loadSpec :: Maybe Value -> Maybe HpaSpec
loadSpec mv = mv >>= either (const Nothing) Just . decodeValue

-- ---------------------------------------------------------------------------
-- Small helpers over the row

emit :: WorkerEnv -> ApplyRow -> Text -> Text -> Value -> Flow ()
emit env row kind msg dat =
    addEvent (weCloud env) (Just (arId row)) (arScheduleId row) (arAppGroup row) (arService row) kind msg dat

release :: WorkerEnv -> ApplyRow -> Int -> Flow ()
release env row secs = releaseApply (arId row) (weWorker env) secs

patch :: WorkerEnv -> ApplyRow -> ApplyPatch -> Flow Bool
patch env row = patchApply (arId row) (weWorker env)

move :: WorkerEnv -> ApplyRow -> ApplyStatus -> ApplyStatus -> Maybe ApplyStep -> Flow Bool
move env row = transitionApply (arId row) (weWorker env)

{- | Close a row in a terminal state, with an event. The lease is given back either way.
A lost compare-and-set means someone else already moved it, which is fine.
-}
terminate :: WorkerEnv -> ApplyRow -> ApplyStatus -> ApplyStatus -> Text -> Text -> Value -> Flow ()
terminate env row from to kind msg dat = do
    _ <- patch env row emptyPatch {apError = Just (if to == Failed then Just msg else Nothing)}
    ok <- move env row from to Nothing
    if ok
        then emit env row kind msg dat
        else logWarning ("[hpa] " <> arId row <> ": lost the race closing as " <> applyStatusText to)
    release env row 0

-- | Park the row for a human. Never retried automatically.
escalate :: WorkerEnv -> ApplyRow -> Text -> Flow ()
escalate env row msg = do
    logError ("[hpa] " <> arId row <> " needs attention: " <> msg)
    _ <- patch env row emptyPatch {apError = Just (Just msg)}
    case parseApplyStatus (arStatus row) of
        Just st -> do
            ok <- move env row st NeedsAttention Nothing
            when ok (emit env row "needs_attention" msg Null)
        Nothing -> pure ()
    release env row 3600

{- | A failure that may go away (network, a conflict, a busy API server). Counted, and
retried after @secs@; after 'maxAttempts' the row is parked.
-}
transient :: WorkerEnv -> ApplyRow -> Int -> Text -> Flow ()
transient env row secs msg = do
    logWarning ("[hpa] " <> arId row <> " transient failure: " <> msg)
    _ <- patch env row emptyPatch {apError = Just (Just msg), apBumpAttempt = True}
    release env row secs

-- | Postpone behind a running release. Logged to the timeline on the first deferral and every tenth.
defer :: WorkerEnv -> ApplyRow -> Text -> Flow ()
defer env row why = do
    _ <- patch env row emptyPatch {apBumpDefer = True}
    when (arDeferCount row == 0 || (arDeferCount row + 1) `mod` 10 == 0) $
        emit env row "deferred" why (A.object ["deferrals" .= (arDeferCount row + 1)])
    release env row 60

recordSnapshot :: WorkerEnv -> ApplyRow -> HpaObject -> Text -> Flow ()
recordSnapshot env row h source = do
    insertSnapshot
        (weCloud env)
        (arAppGroup row)
        (arService row)
        (arNamespace row)
        (arHpaName row)
        (toJSON (hoSpec h))
        (specHash (hoSpec h))
        source
        (lookup annScheduleId (hoAnnotations h))
        (Just (arId row))
        (hoResourceVersion h)

{- | Record the spec the HPA had before we touched it, unless the history already ends
with that exact spec (the observer may have captured it). Without this the first
change to a service that was never sampled would have nothing to diff against.
-}
recordOriginal :: WorkerEnv -> ApplyRow -> HpaObject -> Flow ()
recordOriginal env row h = do
    previous <- lastSnapshotHash (weCloud env) (arNamespace row) (arHpaName row)
    when (previous /= Just (specHash (hoSpec h))) (recordSnapshot env row h "BEFORE")

-- ---------------------------------------------------------------------------
-- Dispatch

processApply :: WorkerEnv -> ApplyRow -> Flow ()
processApply env row
    | arAttempt row >= maxAttempts =
        escalate env row ("gave up after " <> tshow (arAttempt row) <> " attempts" <> maybe "" (", last error: " <>) (arError row))
    | otherwise = case parseApplyStatus (arStatus row) of
        Just Pending -> handlePending env row
        Just Applying -> handleApplying env row
        Just Observing -> handleObserving env row
        Just Applied -> handleWindowEnd env row
        Just Restoring -> handleRestoring env Restore row
        Just RollingBack -> handleRestoring env Rollback row
        _ -> do
            logWarning ("[hpa] " <> arId row <> ": claimed in status " <> arStatus row <> "; releasing")
            release env row 3600

-- ---------------------------------------------------------------------------
-- PENDING: decide whether to start at all

handlePending :: WorkerEnv -> ApplyRow -> Flow ()
handlePending env row = do
    now <- liftIO getCurrentTime
    case (decodeValue (arChange row), decodeValue (arPolicy row)) of
        (Left e, _) -> terminate env row Pending Failed "failed" ("the stored change is unreadable: " <> e) Null
        (_, Left e) -> terminate env row Pending Failed "failed" ("the stored health policy is unreadable: " <> e) Null
        (Right change, Right (_ :: HealthPolicy))
            | maybe False (<= now) (arWindowEnd row) ->
                terminate env row Pending Skipped "skipped" "the window ended before the change could be applied" Null
            | otherwise -> pendingChecks env row change

pendingChecks :: WorkerEnv -> ApplyRow -> HpaChange -> Flow ()
pendingChecks env row change = do
    mctx <- loadServiceCtx (arAppGroup row) (arService row)
    case mctx of
        Nothing -> terminate env row Pending Skipped "skipped" "the service is no longer configured" Null
        Just _ -> do
            live <- liftIO (getHpa (weKube env) (arNamespace row) (arHpaName row))
            case live of
                Left (KubeNotFound _) -> terminate env row Pending Skipped "skipped" "the HPA no longer exists" Null
                Left e -> transient env row 30 (kubeErrText e)
                Right h -> pendingWithLive env row change h

pendingWithLive :: WorkerEnv -> ApplyRow -> HpaChange -> HpaObject -> Flow ()
pendingWithLive env row change h = case editableReason h of
    Just why -> terminate env row Pending Skipped "skipped" why Null
    Nothing -> case applyChangeTyped (hoSpec h) change of
        Left errs ->
            terminate env row Pending Failed "failed" ("the change cannot be applied to the current spec: " <> T.intercalate "; " errs) Null
        Right after
            | after == hoSpec h -> terminate env row Pending Skipped "skipped" "the HPA already has these values" Null
            | otherwise -> do
                g <- loadGuardrail (weCloud env) (arAppGroup row) (arService row)
                case checkGuardrail g (hoSpec h) after of
                    issues@(_ : _) ->
                        terminate env row Pending Skipped "refused" ("refused by guardrail: " <> T.intercalate "; " issues) Null
                    [] -> do
                        conflict <- releaseConflict (arAppGroup row) (arService row)
                        case conflict of
                            Just why -> defer env row ("waiting for " <> why)
                            Nothing -> do
                                ok <- move env row Pending Applying (Just StepPrecheck)
                                if ok
                                    then do
                                        emit env row "started" "starting to apply the change" (A.object ["change" .= change])
                                        release env row 0
                                    else release env row 0

-- ---------------------------------------------------------------------------
-- APPLYING: snapshot, patch, verify. Resumable at every point.

handleApplying :: WorkerEnv -> ApplyRow -> Flow ()
handleApplying env row = case (decodeValue (arChange row), decodeValue (arPolicy row)) of
    (Left e, _) -> terminate env row Applying Failed "failed" ("the stored change is unreadable: " <> e) Null
    (_, Left e) -> terminate env row Applying Failed "failed" ("the stored health policy is unreadable: " <> e) Null
    (Right change, Right policy) -> do
        live <- liftIO (getHpa (weKube env) (arNamespace row) (arHpaName row))
        case live of
            Left (KubeNotFound _) -> terminate env row Applying Failed "failed" "the HPA disappeared while applying" Null
            Left e -> transient env row 30 (kubeErrText e)
            Right h -> do
                established <- establishBefore env row h
                case established of
                    Nothing -> pure () -- lost the lease; whoever has the row now carries on
                    Just (Left e) -> escalate env row e
                    Just (Right (before, beforeObj)) -> case applyChangeTyped before change of
                        Left errs ->
                            terminate env row Applying Failed "failed" ("the change is no longer valid: " <> T.intercalate "; " errs) Null
                        Right after -> do
                            _ <- patch env row emptyPatch {apAfterSpec = Just (toJSON after)}
                            case decideApplyAction before after change (hoSpec h) of
                                Diverged fields ->
                                    escalate
                                        env
                                        row
                                        ("these fields were changed by someone else during the apply: " <> T.intercalate ", " fields)
                                AlreadyApplied -> verifyStep env row change policy after
                                NeedsPatch -> patchStep env row change policy beforeObj after h

{- | The original spec and object, saved exactly once and BEFORE any change is made.
@Nothing@ = the lease was lost while saving.
-}
establishBefore :: WorkerEnv -> ApplyRow -> HpaObject -> Flow (Maybe (Either Text (HpaSpec, HpaObject)))
establishBefore env row h = case (loadSpec (arBeforeSpec row), arBeforeRaw row) of
    (Just spec, Just raw) -> pure . Just $ case parseHpaObject raw of
        Right o -> Right (spec, o)
        Left e -> Left ("the stored original object is unreadable: " <> e)
    _ -> do
        ok <-
            patch
                env
                row
                emptyPatch
                    { apStep = Just StepSnapshot
                    , apBeforeSpec = Just (toJSON (hoSpec h))
                    , apBeforeRaw = Just (hoRaw h)
                    }
        when ok (recordOriginal env row h)
        pure (if ok then Just (Right (hoSpec h, h)) else Nothing)

patchStep :: WorkerEnv -> ApplyRow -> HpaChange -> HealthPolicy -> HpaObject -> HpaSpec -> HpaObject -> Flow ()
patchStep env row change policy beforeObj after h = do
    _ <- patch env row emptyPatch {apStep = Just StepPatch}
    let anns =
            [ (annScheduleId, fromMaybe "manual" (arScheduleId row))
            , (annApplyId, arId row)
            , (annBaseSpec, jsonText (baseSpecJson beforeObj))
            ]
    case buildChangedObject h change anns of
        Left errs -> terminate env row Applying Failed "failed" ("could not build the change: " <> T.intercalate "; " errs) Null
        Right obj -> do
            r <- liftIO (replaceHpa (weKube env) (arNamespace row) obj)
            case r of
                Right () -> do
                    emit env row "patched" "change sent to the cluster" Null
                    verifyStep env row change policy after
                Left (KubeConflict m) -> transient env row 5 ("the HPA was modified concurrently: " <> m)
                Left (KubeNotFound _) -> terminate env row Applying Failed "failed" "the HPA disappeared while applying" Null
                Left e -> transient env row 30 (kubeErrText e)

verifyStep :: WorkerEnv -> ApplyRow -> HpaChange -> HealthPolicy -> HpaSpec -> Flow ()
verifyStep env row change policy after = do
    _ <- patch env row emptyPatch {apStep = Just StepVerify}
    r <- liftIO (getHpa (weKube env) (arNamespace row) (arHpaName row))
    case r of
        Left (KubeNotFound _) -> terminate env row Applying Failed "failed" "the HPA disappeared while verifying" Null
        Left e -> transient env row 30 (kubeErrText e)
        Right h -> case verifyApplied after change (hoSpec h) of
            [] -> do
                recordSnapshot env row h "APPLY"
                now <- liftIO getCurrentTime
                if hpObserveSeconds policy > 0
                    then do
                        _ <-
                            patch
                                env
                                row
                                emptyPatch
                                    { apObserveUntil = Just (Just (addUTCTime (fromIntegral (hpObserveSeconds policy)) now))
                                    , apUnhealthySince = Just Nothing
                                    , apError = Just Nothing
                                    }
                        ok <- move env row Applying Observing (Just StepObserve)
                        when ok $
                            emit
                                env
                                row
                                "applied"
                                ("change applied and verified; watching for " <> tshow (hpObserveSeconds policy) <> "s")
                                Null
                        release env row 15
                    else do
                        _ <- patch env row emptyPatch {apError = Just Nothing}
                        ok <- move env row Applying Applied Nothing
                        when ok (emit env row "applied" "change applied and verified" Null)
                        release env row 0
            mismatches -> do
                let why = "verification failed: " <> T.intercalate "; " mismatches
                _ <- patch env row emptyPatch {apRollbackReason = Just why}
                ok <- move env row Applying RollingBack (Just StepRollback)
                when ok (emit env row "verify_failed" why Null)
                release env row 0

-- ---------------------------------------------------------------------------
-- OBSERVING: health gate

handleObserving :: WorkerEnv -> ApplyRow -> Flow ()
handleObserving env row = case (decodeValue (arChange row), decodeValue (arPolicy row), loadSpec (arAfterSpec row)) of
    (Right change, Right policy, Just after) -> observe env row change policy after
    _ -> escalate env row "the stored change, policy or intended spec is unreadable while observing"

observe :: WorkerEnv -> ApplyRow -> HpaChange -> HealthPolicy -> HpaSpec -> Flow ()
observe env row change policy after = do
    now <- liftIO getCurrentTime
    if maybe False (<= now) (arWindowEnd row)
        then do
            ok <- move env row Observing Restoring (Just StepRestore)
            when ok (emit env row "window_ended" "the window ended while observing; restoring" Null)
            release env row 0
        else do
            live <- liftIO (getHpa (weKube env) (arNamespace row) (arHpaName row))
            case live of
                Left (KubeNotFound _) -> do
                    -- Nothing left to watch; the restore step records that the HPA is gone.
                    ok <- move env row Observing Restoring (Just StepRestore)
                    when ok (emit env row "hpa_gone" "the HPA no longer exists" Null)
                    release env row 0
                Left e -> transient env row 30 (kubeErrText e)
                Right h -> assess env row now change policy after h

assess :: WorkerEnv -> ApplyRow -> UTCTime -> HpaChange -> HealthPolicy -> HpaSpec -> HpaObject -> Flow ()
assess env row now change policy after h = do
    let target = strName (hsTarget (hoSpec h))
    readiness <- liftIO (getDeploymentReadiness (weKube env) (arNamespace row) target)
    proms <-
        if null (hpPromChecks policy)
            then pure []
            else liftIO (runPromChecks (weConfig env) (arNamespace row) (arService row) target (hpPromChecks policy))
    let base = assessHealth policy (HealthInputs h (either (const Nothing) Just readiness) proms)
        drift = ["the change was altered after it was applied: " <> m | m <- verifyApplied after change (hoSpec h)]
        report = base {hrIssues = hrIssues base <> drift}
        (verdict, since') = judge policy now (arUnhealthySince row) report
    -- A successful read means earlier transient errors are behind us.
    void (patch env row emptyPatch {apUnhealthySince = if since' /= arUnhealthySince row then Just since' else Nothing, apResetAttempt = True})
    case verdict of
        VerdictBreach -> do
            let why = "health check failed: " <> T.intercalate "; " (hrIssues report)
            if hpAutoRollback policy
                then do
                    _ <- patch env row emptyPatch {apRollbackReason = Just why}
                    ok <- move env row Observing RollingBack (Just StepRollback)
                    when ok (emit env row "health_breach" (why <> "; rolling back") (A.object ["issues" .= hrIssues report]))
                    release env row 0
                else do
                    ok <- move env row Observing Applied Nothing
                    when ok (emit env row "health_breach_ignored" (why <> "; auto-rollback is off") (A.object ["issues" .= hrIssues report]))
                    release env row 0
        VerdictWatching -> do
            when (arUnhealthySince row == Nothing) $
                emit env row "health_degraded" ("watching: " <> T.intercalate "; " (hrIssues report)) (A.object ["issues" .= hrIssues report])
            release env row 30
        VerdictOk
            | maybe True (<= now) (arObserveUntil row) -> do
                ok <- move env row Observing Applied Nothing
                when ok (emit env row "observed_healthy" "observation finished; the change is healthy" (A.object ["notes" .= hrNotes report]))
                release env row 0
            | otherwise -> release env row 20

-- ---------------------------------------------------------------------------
-- APPLIED -> window over

handleWindowEnd :: WorkerEnv -> ApplyRow -> Flow ()
handleWindowEnd env row = do
    ok <- move env row Applied Restoring (Just StepRestore)
    when ok (emit env row "window_ended" "the window ended; restoring the original values" Null)
    release env row 0

-- ---------------------------------------------------------------------------
-- RESTORING / ROLLING_BACK

data RestoreKind = Restore | Rollback
    deriving (Eq)

handleRestoring :: WorkerEnv -> RestoreKind -> ApplyRow -> Flow ()
handleRestoring env kind row = do
    let (from, to, label, doneKind) = case kind of
            Restore -> (Restoring, Restored, "restore", "restored")
            Rollback -> (RollingBack, RolledBack, "rollback", "rolled_back")
    case decodeValue (arChange row) of
        Left e -> escalate env row ("the stored change is unreadable: " <> e)
        Right change -> case loadSpec (arBeforeSpec row) of
            Nothing -> terminate env row from to doneKind ("nothing to " <> label <> ": the HPA was never changed") Null
            Just before -> do
                let after = case loadSpec (arAfterSpec row) of
                        Just a -> Just a
                        Nothing -> either (const Nothing) Just (applyChangeTyped before change)
                case after of
                    Nothing -> escalate env row "cannot work out the intended spec for the restore"
                    Just a -> do
                        -- A capacity cut mid-rollout is worse than extra capacity for a while.
                        conflict <- if kind == Restore then releaseConflict (arAppGroup row) (arService row) else pure Nothing
                        case conflict of
                            Just why -> defer env row ("restore waiting for " <> why)
                            Nothing -> restoreNow env kind row (from, to, doneKind) change before a

restoreNow :: WorkerEnv -> RestoreKind -> ApplyRow -> (ApplyStatus, ApplyStatus, Text) -> HpaChange -> HpaSpec -> HpaSpec -> Flow ()
restoreNow env kind row (from, to, doneKind) change before after = do
    _ <- patch env row emptyPatch {apStep = Just (if kind == Restore then StepRestore else StepRollback)}
    live <- liftIO (getHpa (weKube env) (arNamespace row) (arHpaName row))
    case live of
        Left (KubeNotFound _) -> terminate env row from to doneKind "the HPA no longer exists; nothing to put back" Null
        Left e -> transient env row 30 (kubeErrText e)
        Right h -> do
            let plan = planRestore before after change h
                hasManaged = any ((`elem` managedAnnotationKeys) . fst) (hoAnnotations h)
                details =
                    A.object
                        [ "restored" .= rpRestored plan
                        , "leftAlone" .= rpDrifted plan
                        , "alreadyOriginal" .= rpAlreadyOriginal plan
                        ]
                summary = summarise plan
            if null (rpRestored plan) && not hasManaged
                then do
                    recordSnapshot env row h (snapshotSource kind)
                    terminate env row from to doneKind summary details
                else do
                    r <- liftIO (replaceHpa (weKube env) (arNamespace row) (rpObject plan))
                    case r of
                        Right () -> confirmRestore env kind row (from, to, doneKind) change before plan details summary
                        Left (KubeConflict m) -> transient env row 5 ("the HPA was modified concurrently: " <> m)
                        Left (KubeNotFound _) -> terminate env row from to doneKind "the HPA no longer exists; nothing to put back" Null
                        Left e -> transient env row 30 (kubeErrText e)

confirmRestore ::
    WorkerEnv -> RestoreKind -> ApplyRow -> (ApplyStatus, ApplyStatus, Text) -> HpaChange -> HpaSpec -> RestorePlan -> Value -> Text -> Flow ()
confirmRestore env kind row (from, to, doneKind) change before plan details summary = do
    r <- liftIO (getHpa (weKube env) (arNamespace row) (arHpaName row))
    case r of
        Left (KubeNotFound _) -> terminate env row from to doneKind "the HPA no longer exists; nothing to put back" Null
        Left e -> transient env row 30 (kubeErrText e)
        Right h2 -> do
            let restoredFields = [f | f <- touchedFields change, fieldLabel f `elem` rpRestored plan]
                stuck = [fieldLabel f | f <- restoredFields, not (fieldMatches (fieldValue f before) (fieldValue f (hoSpec h2)))]
            if null stuck
                then do
                    recordSnapshot env row h2 (snapshotSource kind)
                    terminate env row from to doneKind summary details
                else escalate env row ("restored values did not stick (something else is changing them): " <> T.intercalate ", " stuck)

snapshotSource :: RestoreKind -> Text
snapshotSource Restore = "RESTORE"
snapshotSource Rollback = "ROLLBACK"

summarise :: RestorePlan -> Text
summarise plan =
    T.intercalate "; " $
        [ "put back: " <> T.intercalate ", " (rpRestored plan) | not (null (rpRestored plan)) ]
            <> [ "left alone (changed by someone else since): " <> T.intercalate ", " (rpDrifted plan) | not (null (rpDrifted plan)) ]
            <> [ "already at the original value: " <> T.intercalate ", " (rpAlreadyOriginal plan) | not (null (rpAlreadyOriginal plan)) ]

-- ---------------------------------------------------------------------------
-- Loops

{- | Run a loop body forever. Synchronous exceptions are logged and the body is
restarted after a pause, so a bug in one tick cannot silently end the loop;
asynchronous ones (shutdown, cancellation) propagate.
-}
supervise :: Text -> Flow () -> Flow ()
supervise name body = forever $ do
    r <- try body
    case r of
        Left e
            | isAsync e -> throwM e
            | otherwise -> logError ("[hpa] " <> name <> " crashed, restarting in 10s: " <> tshow e)
        Right () -> logWarning ("[hpa] " <> name <> " returned unexpectedly, restarting")
    liftIO (threadDelay (Seconds 10))

{- | Claim and process applies until cancelled. The heartbeat runs in its own thread for
as long as the step does; if this thread dies the heartbeat dies with it and the lease expires.
-}
workerLoop :: WorkerEnv -> Flow ()
workerLoop env = supervise ("worker " <> weWorker env) $ forever $ do
    mrow <- claimNextApply (weCloud env) (weWorker env) leaseSeconds
    case mrow of
        Nothing -> liftIO (threadDelay (Seconds 3))
        Just row -> do
            st <- ask
            liftIO . withAsync (runFlow st (heartbeat env (arId row))) $ \_ ->
                runFlow st (guarded env row)

guarded :: WorkerEnv -> ApplyRow -> Flow ()
guarded env row = do
    r <- try (processApply env row)
    case r of
        Right () -> pure ()
        Left e
            | isAsync e -> throwM e
            | otherwise -> do
                logError ("[hpa] " <> arId row <> " step failed: " <> tshow e)
                _ <- patch env row emptyPatch {apError = Just (Just (T.take 500 (tshow e))), apBumpAttempt = True}
                release env row 15

heartbeat :: WorkerEnv -> Text -> Flow ()
heartbeat env aid = do
    liftIO (threadDelay (Seconds heartbeatSeconds))
    r <- try (heartbeatApply aid (weWorker env) leaseSeconds)
    case r of
        Right False -> logWarning ("[hpa] " <> aid <> ": lost the lease")
        Right True -> heartbeat env aid
        Left e
            | isAsync e -> throwM e
            | otherwise -> do
                logWarning ("[hpa] " <> aid <> ": heartbeat failed, will retry: " <> tshow e)
                heartbeat env aid

-- | Start @n@ workers, each with its own identity, and run until cancelled.
runWorkers :: Int -> Flow ()
runWorkers n = do
    st <- ask
    base <- liftIO (T.take 8 . UUID.toText <$> UUID.nextRandom)
    logInfo ("[hpa] starting " <> tshow n <> " apply workers (" <> base <> ")")
    liftIO . mapConcurrently_ (\i -> runFlow st (mkWorkerEnv (base <> "-" <> tshow i) >>= workerLoop)) $ [1 .. n]
