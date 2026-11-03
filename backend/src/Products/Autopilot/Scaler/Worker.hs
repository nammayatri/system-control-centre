{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Executes rows of the apply ledger (@scaler_apply@) for any registered target (a Valkey instance or an
AlloyDB read pool).

The contract is the HPA worker's: all state is in the row, a worker holds a lease and heartbeats it, one call
does one step, and every step decides from what the target /actually/ holds, so a worker that dies at any
point is replaced by one that finishes the job exactly once.

Lifecycle of an apply:

* @PENDING@: look at the live target, check the guardrail, decide whether there is anything to do.
* @APPLYING@: save the original values once; pin the autoscaler's minimum (if asked) BEFORE resizing so it
  cannot scale in meanwhile; start the resize. The intent to pin is recorded before the write, so a crash in
  between still leaves the value ours to put back.
* @OBSERVING@: wait for the resize to finish (minutes); start the next one (replicas after shards) if needed.
* @APPLIED@: the capacity is in place; held until the window ends.
* @RESTORING@ / @ROLLING_BACK@: put the autoscaler's minimum back, but only if it still holds the value we
  wrote. A restore may also shrink capacity back (opt-in); a rollback never does, because taking capacity
  away is the risky direction.

Every write to Google Cloud is made only while the lease is still held. A row that keeps failing is parked in
@NEEDS_ATTENTION@ for a human instead of retrying forever; an apply that fails after pinning goes through
ROLLING_BACK so the autoscaler is never left pinned by a dead apply.
-}
module Products.Autopilot.Scaler.Worker (
    WorkerEnv (..),
    mkWorkerEnv,
    processApply,
    runWorkers,
    workerLoop,
    loadGuardrail,
)
where

import Control.Applicative ((<|>))
import Control.Concurrent.Async (mapConcurrently_, withAsync)
import Control.Monad (forever, void, when)
import Control.Monad.Catch (throwM, try)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)
import Core.Config (Config (..))
import Core.Environment (Flow, getConfig, logError, logInfo, logWarning, runFlow)
import Core.Types.Time (Seconds (..), threadDelay)
import Data.Aeson (Value (..), toJSON, (.=))
import Data.Aeson qualified as A
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (addUTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Products.Autopilot.Hpa.Types (ApplyStatus (..), ApplyStep (..), applyStatusText, parseApplyStatus)
import Products.Autopilot.Hpa.Util (decodeValue, isAsync, tshow)
import Products.Autopilot.Hpa.Worker (heartbeatSeconds, leaseSeconds, maxAttempts, supervise)
import Products.Autopilot.Scaler.Gcp
import Products.Autopilot.Scaler.Logic
import Products.Autopilot.Scaler.Store
import Products.Autopilot.Scaler.Types

data WorkerEnv = WorkerEnv
    { weGcp :: Gcp
    , weCloud :: Text
    , weWorker :: Text
    }

mkWorkerEnv :: Text -> Flow WorkerEnv
mkWorkerEnv wid = do
    cfg <- getConfig
    pure (WorkerEnv mkGcp (cloudProvider cfg) wid)

-- | How long a resize may take before a human is asked to look.
observeMinutes :: Int
observeMinutes = 90

loadGuardrail :: Text -> TargetKind -> Text -> Flow Guardrail
loadGuardrail cloud kind tid = do
    mv <- getGuardrailRow cloud kind tid
    pure $ case mv of
        Nothing -> defaultGuardrail
        Just v -> case decodeValue v of
            Right g -> g
            Left (_ :: Text) -> defaultGuardrail {grFrozen = True, grFrozenReason = Just "the stored guardrail is unreadable"}

loadSnapshot :: ApplyRow -> Maybe ScaleSnapshot
loadSnapshot row = arBeforeSpec row >>= either (const Nothing) Just . decodeValue

loadAfter :: ApplyRow -> ScaleAfter
loadAfter row = maybe emptyAfter id (arAfterSpec row >>= either (const Nothing) Just . decodeValue)

-- ---------------------------------------------------------------------------
-- Small helpers over the row

emit :: WorkerEnv -> ApplyRow -> Target -> Text -> Text -> Value -> Flow ()
emit env row tg kind msg dat = addEvent (weCloud env) (Just (arId row)) (arScheduleId row) (tgKind tg) (tgId tg) kind msg dat

release :: WorkerEnv -> ApplyRow -> Int -> Flow ()
release env row secs = releaseApply (arId row) (weWorker env) secs

patch :: WorkerEnv -> ApplyRow -> ApplyPatch -> Flow Bool
patch env row = patchApply (arId row) (weWorker env)

move :: WorkerEnv -> ApplyRow -> ApplyStatus -> ApplyStatus -> Maybe ApplyStep -> Flow Bool
move env row = transitionApply (arId row) (weWorker env)

{- | Run a write to Google Cloud only while this worker still holds the lease. A worker that lost it (a slow
call, a stalled database) does nothing, and the new holder carries on.
-}
writeGuard :: WorkerEnv -> ApplyRow -> Flow a -> Flow (Maybe a)
writeGuard env row act = do
    ok <- holdsLease (arId row) (weWorker env)
    if ok
        then Just <$> act
        else do
            logWarning ("[scaler] " <> arId row <> ": lost the lease; not writing")
            pure Nothing

{- | Close a row in a terminal state, with an event. The lease is given back either way. A lost
compare-and-set means someone else already moved it, which is fine.
-}
terminate :: WorkerEnv -> ApplyRow -> Target -> ApplyStatus -> ApplyStatus -> Text -> Text -> Value -> Flow ()
terminate env row tg from to kind msg dat = do
    _ <- patch env row emptyPatch {apError = Just (if to == Failed then Just msg else Nothing)}
    ok <- move env row from to Nothing
    if ok
        then emit env row tg kind msg dat
        else logWarning ("[scaler] " <> arId row <> ": lost the race closing as " <> applyStatusText to)
    release env row 0

-- | Park the row for a human. Never retried automatically.
escalate :: WorkerEnv -> ApplyRow -> Target -> Text -> Flow ()
escalate env row tg msg = do
    logError ("[scaler] " <> arId row <> " needs attention: " <> msg)
    _ <- patch env row emptyPatch {apError = Just (Just msg)}
    case parseApplyStatus (arStatus row) of
        Just st -> do
            ok <- move env row st NeedsAttention Nothing
            when ok (emit env row tg "needs_attention" msg Null)
        Nothing -> pure ()
    release env row 3600

{- | A failure that may go away (network, a quota, a permission just granted). Counted, and retried after
@secs@; after 'maxAttempts' the row is parked.
-}
transient :: WorkerEnv -> ApplyRow -> Int -> Text -> Flow ()
transient env row secs msg = do
    logWarning ("[scaler] " <> arId row <> " transient failure: " <> msg)
    _ <- patch env row emptyPatch {apError = Just (Just msg), apBumpAttempt = True}
    release env row secs

{- | The target is busy with something else (another resize). Wait without counting it as a failure; logged
to the timeline on the first deferral and every tenth.
-}
deferBusy :: WorkerEnv -> ApplyRow -> Target -> Text -> Flow ()
deferBusy env row tg why = do
    _ <- patch env row emptyPatch {apBumpDefer = True}
    when (arDeferCount row == 0 || (arDeferCount row + 1) `mod` 10 == 0) $
        emit env row tg "deferred" why (A.object ["deferrals" .= (arDeferCount row + 1)])
    release env row 60

-- | Undo what has been done so far: the row goes through ROLLING_BACK, which restores the autoscaler.
rollbackNow :: WorkerEnv -> ApplyRow -> Target -> ApplyStatus -> Text -> Flow ()
rollbackNow env row tg from why = do
    _ <- patch env row emptyPatch {apRollbackReason = Just why}
    ok <- move env row from RollingBack (Just StepRollback)
    when ok (emit env row tg "rolling_back" why Null)
    release env row 0

{- | Fail an apply for good, but never leave the autoscaler pinned by it: if a pin was intended or written, the
row rolls back (which puts the minimum back) instead of closing as FAILED.
-}
failOrRollback :: WorkerEnv -> ApplyRow -> Target -> ApplyStatus -> ScaleAfter -> Text -> Flow ()
failOrRollback env row tg from after msg
    | saPinIntent after /= Nothing || saPinned after /= Nothing = rollbackNow env row tg from msg
    | otherwise = terminate env row tg from Failed "failed" msg Null

-- ---------------------------------------------------------------------------
-- Dispatch

processApply :: WorkerEnv -> ApplyRow -> Flow ()
processApply env row = case parseTargetKind (arTargetKind row) of
    Nothing -> do
        logError ("[scaler] " <> arId row <> ": unknown target kind " <> arTargetKind row)
        release env row 3600
    Just kind -> do
        mt <- getTarget (weCloud env) kind (arTargetId row)
        case mt of
            Nothing -> do
                -- A target cannot be removed while it is in use, so this is an operator fixing the database by hand.
                let tg = Target (arTargetId row) kind "(removed)" "" "" Nothing "" Nothing Nothing
                if arStatus row == "PENDING"
                    then terminate env row tg Pending Skipped "skipped" "the target was removed" Null
                    else escalate env row tg "the target was removed while this change was in flight"
            Just tg -> processFor env row tg

processFor :: WorkerEnv -> ApplyRow -> Target -> Flow ()
processFor env row tg
    | arAttempt row >= maxAttempts =
        escalate env row tg ("gave up after " <> tshow (arAttempt row) <> " attempts" <> maybe "" (", last error: " <>) (arError row))
    | otherwise = case parseApplyStatus (arStatus row) of
        Just Pending -> handlePending env row tg
        Just Applying -> handleApplying env row tg
        Just Observing -> handleObserving env row tg
        Just Applied -> handleWindowEnd env row tg
        Just Restoring -> handleRestoring env Restore row tg
        Just RollingBack -> handleRestoring env Rollback row tg
        _ -> do
            logWarning ("[scaler] " <> arId row <> ": claimed in status " <> arStatus row <> "; releasing")
            release env row 3600

-- ---------------------------------------------------------------------------
-- PENDING: decide whether to start at all

handlePending :: WorkerEnv -> ApplyRow -> Target -> Flow ()
handlePending env row tg = do
    now <- liftIO getCurrentTime
    case decodeValue (arChange row) of
        Left (e :: Text) -> terminate env row tg Pending Failed "failed" ("the stored change is unreadable: " <> e) Null
        Right change
            | maybe False (<= now) (arWindowEnd row) ->
                terminate env row tg Pending Skipped "skipped" "the window ended before the change could be applied" Null
            | scBlockScaleIn change && tgJob tg == Nothing ->
                terminate env row tg Pending Failed "failed" "scale-in is to be blocked but this target has no autoscaler job configured" Null
            | otherwise -> do
                live <- liftIO (gcpGetState (weGcp env) tg)
                case live of
                    Left (GcpNotFound _) -> terminate env row tg Pending Skipped "skipped" "the instance no longer exists" Null
                    Left e -> transient env row 30 (gcpErrText e)
                    Right st -> pendingWithLive env row tg change st

pendingWithLive :: WorkerEnv -> ApplyRow -> Target -> ScaleChange -> InstanceState -> Flow ()
pendingWithLive env row tg change st
    | modeKind (isMode st) /= tgKind tg =
        terminate env row tg Pending Failed "failed" "the instance is not the kind of target it was registered as" Null
    | otherwise = case validateChange (isMode st) change of
        issues@(_ : _) ->
            terminate env row tg Pending Failed "failed" ("the change does not fit this target: " <> T.intercalate "; " issues) Null
        [] -> do
            g <- loadGuardrail (weCloud env) (tgKind tg) (tgId tg)
            case planCapacity g st change of
                Left issues ->
                    terminate env row tg Pending Skipped "refused" ("refused by guardrail: " <> T.intercalate "; " issues) Null
                Right plan
                    | planIsNoop plan && not (scBlockScaleIn change) ->
                        terminate env row tg Pending Skipped "skipped" "the target already has this capacity" Null
                    | otherwise -> do
                        ok <- move env row Pending Applying (Just StepPrecheck)
                        when ok (emit env row tg "started" ("starting: " <> describePlan (isMode st) plan) (A.object ["change" .= change]))
                        release env row 0

-- ---------------------------------------------------------------------------
-- APPLYING: snapshot, pin the autoscaler, start the resize. Resumable at every point.

handleApplying :: WorkerEnv -> ApplyRow -> Target -> Flow ()
handleApplying env row tg = case decodeValue (arChange row) of
    Left (e :: Text) -> terminate env row tg Applying Failed "failed" ("the stored change is unreadable: " <> e) Null
    Right change -> do
        live <- liftIO (gcpGetState (weGcp env) tg)
        case live of
            Left (GcpNotFound _) -> failOrRollback env row tg Applying (loadAfter row) "the instance disappeared while applying"
            Left e -> transient env row 30 (gcpErrText e)
            Right st -> do
                est <- establishBefore env row tg change st
                case est of
                    EstLost -> pure ()
                    EstPermanent e -> terminate env row tg Applying Failed "failed" e Null
                    EstRetry e -> transient env row 30 e
                    EstOk snap after -> do
                        pinned <- pinStep env row tg change snap after
                        case pinned of
                            PinStop -> pure ()
                            PinDone after' -> drive env row tg Applying change st after'

data Established
    = -- | The lease was lost while saving; whoever has the row now carries on.
      EstLost
    | EstPermanent Text
    | EstRetry Text
    | EstOk ScaleSnapshot ScaleAfter

{- | The original values, saved exactly once and BEFORE any change is made. When the change pins the
autoscaler, its job is read first: a payload for another target, or one we cannot read, fails the apply
before anything is touched.
-}
establishBefore :: WorkerEnv -> ApplyRow -> Target -> ScaleChange -> InstanceState -> Flow Established
establishBefore env row tg change st = case loadSnapshot row of
    Just snap -> pure (EstOk snap (loadAfter row))
    Nothing
        | scBlockScaleIn change -> do
            r <- liftIO (gcpGetJob (weGcp env) tg)
            case r of
                Left (GcpNotFound m) -> pure (EstPermanent ("the autoscaler job was not found: " <> m))
                Left e -> pure (EstRetry (gcpErrText e))
                Right job -> case decodeJobData (sjData job) >>= readMinimum (autoscalerKeys tg) of
                    Left e -> pure (EstPermanent e)
                    Right n -> save (Just n) (Just (sjRaw job))
        | otherwise -> save Nothing Nothing
  where
    save mMin mRaw = do
        let snap = ScaleSnapshot (isUnits st) (isReplicas st) mMin
        ok <- patch env row emptyPatch {apStep = Just StepSnapshot, apBeforeSpec = Just (toJSON snap), apBeforeRaw = mRaw}
        pure (if ok then EstOk snap emptyAfter else EstLost)

data PinOutcome
    = -- | The step already released or closed the row.
      PinStop
    | PinDone ScaleAfter

{- | Raise the autoscaler's minimum to the target so it cannot scale in while the window is open. Decided from
the live job, so a crash between the write and its record is harmless; the intent is recorded first, so a
rollback in that gap still knows the value is ours.
-}
pinStep :: WorkerEnv -> ApplyRow -> Target -> ScaleChange -> ScaleSnapshot -> ScaleAfter -> Flow PinOutcome
pinStep env row tg change snap after = case (scBlockScaleIn change, scUnits change, ssMinimum snap) of
    (True, Just target, Just original)
        | original < target -> do
            r <- liftIO (gcpGetJob (weGcp env) tg)
            case r of
                Left (GcpNotFound _) -> do
                    failOrRollback env row tg Applying after "the autoscaler job disappeared while applying"
                    pure PinStop
                Left e -> do
                    transient env row 30 (gcpErrText e)
                    pure PinStop
                Right current -> case decodeJobData (sjData current) >>= pinMinimum keys target of
                    Left e -> do
                        escalate env row tg e
                        pure PinStop
                    Right (AlreadyHeld cur)
                        -- Ours only if we meant to write it (a crash after the write, before it was recorded).
                        | cur == target && saPinIntent after == Just target -> record (after {saPinned = Just target}) Nothing
                        | otherwise -> pure (PinDone after)
                    Right (Pin _ payload) -> do
                        intended <- recordIntent target
                        case intended of
                            Nothing -> pure PinStop
                            Just a1 -> do
                                w <- writeGuard env row (liftIO (gcpSetJobData (weGcp env) tg current (encodeJobData payload)))
                                case w of
                                    Nothing -> pure PinStop
                                    Just (Right ()) -> record (a1 {saPinned = Just target}) (Just ("autoscaler " <> akMinKey keys <> " pinned at " <> tshow target))
                                    Just (Left e) -> do
                                        transient env row 30 (gcpErrText e)
                                        pure PinStop
    _ -> pure (PinDone after)
  where
    keys = autoscalerKeys tg
    recordIntent target
        | saPinIntent after == Just target = pure (Just after)
        | otherwise = do
            let a1 = after {saPinIntent = Just target}
            ok <- patch env row emptyPatch {apAfterSpec = Just (toJSON a1)}
            pure (if ok then Just a1 else Nothing)
    record after' mMsg = do
        ok <- patch env row emptyPatch {apAfterSpec = Just (toJSON after')}
        case (ok, mMsg) of
            (True, Just m) -> emit env row tg "pinned" m Null
            _ -> pure ()
        pure (if ok then PinDone after' else PinStop)

{- | The capacity step, shared by APPLYING and OBSERVING: from the LIVE target decide whether the capacity is in
place (APPLIED), a resize is still running (wait), or the next resize must start.
-}
drive :: WorkerEnv -> ApplyRow -> Target -> ApplyStatus -> ScaleChange -> InstanceState -> ScaleAfter -> Flow ()
drive env row tg from change st after = do
    now <- liftIO getCurrentTime
    deadline <- case arObserveUntil row of
        Just t -> pure t
        Nothing -> do
            let t = addUTCTime (fromIntegral (observeMinutes * 60)) now
            _ <- patch env row emptyPatch {apObserveUntil = Just (Just t)}
            pure t
    g <- loadGuardrail (weCloud env) (tgKind tg) (tgId tg)
    case planCapacity g st change of
        Left issues -> rollbackNow env row tg from ("stopped by guardrail: " <> T.intercalate "; " issues)
        Right plan
            -- Reached beats timed out: a worker that was away for hours must not park a finished resize.
            | planIsNoop plan && not (instanceBusy st) -> do
                ok <- move env row from Applied (Just StepObserve)
                when ok (emit env row tg "applied" ("capacity in place: " <> stateText st) (toJSON st))
                release env row 0
            | now > deadline -> escalate env row tg ("the target did not reach the requested capacity within " <> tshow observeMinutes <> " minutes")
            | instanceBusy st -> waitForResize
            | otherwise -> startResize plan
  where
    stateText s = T.pack (show (isUnits s)) <> " " <> unitName (isMode s) <> ", " <> T.pack (show (isReplicas s)) <> " replicas"

    -- Still resizing (ours, or someone else's). Not a failure.
    waitForResize = do
        failed <- priorOperationFailure (weGcp env) tg after
        case failed of
            Just e -> escalate env row tg ("the resize failed: " <> e)
            Nothing
                | from == Applying -> deferBusy env row tg ("the target is " <> isState st <> "; waiting for it to be idle")
                | otherwise -> release env row 30

    startResize plan = do
        failed <- priorOperationFailure (weGcp env) tg after
        case failed of
            Just e -> escalate env row tg ("the previous resize failed: " <> e)
            Nothing -> case nextUpdate plan of
                Nothing -> release env row 0
                Just upd -> do
                    w <- writeGuard env row (liftIO (gcpResize (weGcp env) tg upd))
                    case w of
                        Nothing -> pure ()
                        Just (Right op) -> do
                            let after' =
                                    after
                                        { saTargetUnits = cpUnits plan <|> saTargetUnits after
                                        , saTargetReplicas = cpReplicas plan <|> saTargetReplicas after
                                        , saOperation = Just (opName op)
                                        }
                            _ <- patch env row emptyPatch {apStep = Just StepPatch, apAfterSpec = Just (toJSON after')}
                            emit env row tg "resize_started" (describeUpdate (isMode st) upd) (A.object ["operation" .= opName op])
                            when (from == Applying) (void (move env row Applying Observing (Just StepObserve)))
                            release env row 20
                        Just (Left (GcpConflict m)) -> deferBusy env row tg ("the target is busy: " <> m)
                        Just (Left (GcpNotFound _)) -> failOrRollback env row tg from after "the instance disappeared while resizing"
                        Just (Left e) -> transient env row 30 (gcpErrText e)

-- | A resize we started earlier that finished with an error must not be retried blindly.
priorOperationFailure :: Gcp -> Target -> ScaleAfter -> Flow (Maybe Text)
priorOperationFailure gcp tg after = case saOperation after of
    Nothing -> pure Nothing
    Just name -> do
        r <- liftIO (gcpGetOperation gcp tg name)
        pure $ case r of
            Right op | opDone op -> opError op
            _ -> Nothing

-- | Units first, then replicas: each is its own resize.
nextUpdate :: CapacityPlan -> Maybe InstanceUpdate
nextUpdate plan = maybe (UpdateReplicas <$> cpReplicas plan) (Just . UpdateUnits) (cpUnits plan)

unitName :: InstanceMode -> Text
unitName ModeReadPool = "nodes"
unitName _ = "shards"

describeUpdate :: InstanceMode -> InstanceUpdate -> Text
describeUpdate mode (UpdateUnits n) = "resizing to " <> tshow n <> " " <> unitName mode
describeUpdate _ (UpdateReplicas n) = "resizing to " <> tshow n <> " replicas"

-- ---------------------------------------------------------------------------
-- OBSERVING: wait for the resize

handleObserving :: WorkerEnv -> ApplyRow -> Target -> Flow ()
handleObserving env row tg = case (decodeValue (arChange row), loadSnapshot row) of
    (Left (e :: Text), _) -> escalate env row tg ("the stored change is unreadable: " <> e)
    (_, Nothing) -> escalate env row tg "observing without a saved original; refusing to continue"
    (Right change, Just _) -> do
        live <- liftIO (gcpGetState (weGcp env) tg)
        case live of
            Left (GcpNotFound _) -> escalate env row tg "the instance disappeared while a resize was running"
            Left e -> transient env row 30 (gcpErrText e)
            Right st -> drive env row tg Observing change st (loadAfter row)

-- ---------------------------------------------------------------------------
-- APPLIED: the window is over

handleWindowEnd :: WorkerEnv -> ApplyRow -> Target -> Flow ()
handleWindowEnd env row tg = do
    ok <- move env row Applied Restoring (Just StepRestore)
    when ok (emit env row tg "window_ended" "the window is over; restoring" Null)
    release env row 0

-- ---------------------------------------------------------------------------
-- RESTORING / ROLLING_BACK

data RestoreKind = Restore | Rollback
    deriving (Eq)

data Unpin
    = -- | The step already released or closed the row.
      UnpinStop
    | UnpinOk Text

handleRestoring :: WorkerEnv -> RestoreKind -> ApplyRow -> Target -> Flow ()
handleRestoring env kind row tg = case (decodeValue (arChange row), loadSnapshot row) of
    (Left (e :: Text), _) -> escalate env row tg ("the stored change is unreadable: " <> e)
    (_, Nothing) -> terminate env row tg from to doneKind "nothing had been changed yet" Null
    (Right change, Just snap) -> do
        un <- unpin env row tg change snap (loadAfter row)
        case un of
            UnpinStop -> pure ()
            UnpinOk note
                | kind == Restore && scShrinkOnEnd change -> shrinkPhase env row tg snap (loadAfter row) note
                | otherwise -> terminate env row tg from to doneKind note Null
  where
    (from, to, doneKind) = case kind of
        Restore -> (Restoring, Restored, "restored")
        Rollback -> (RollingBack, RolledBack, "rolled_back")

{- | Put the autoscaler's minimum back, but only if it still holds the value we wrote; a value anyone else has
set since is theirs and is left alone. A pin we only intended (crashed before recording) is put back too,
provided the live value is exactly the one we meant to write.
-}
unpin :: WorkerEnv -> ApplyRow -> Target -> ScaleChange -> ScaleSnapshot -> ScaleAfter -> Flow Unpin
unpin env row tg change snap after = case (scBlockScaleIn change, ssMinimum snap, saPinned after <|> saPinIntent after) of
    (True, Just original, Just pinned) -> do
        r <- liftIO (gcpGetJob (weGcp env) tg)
        case r of
            Left (GcpNotFound _) -> pure (UnpinOk "the autoscaler job no longer exists; nothing to put back")
            Left e -> stop (transient env row 30 (gcpErrText e))
            Right current -> case decodeJobData (sjData current) >>= restoreMinimum keys pinned original of
                Left e -> stop (escalate env row tg e)
                Right RestoreAlready -> pure (UnpinOk ("autoscaler " <> akMinKey keys <> " is back at " <> tshow original))
                Right (RestoreDrifted n) ->
                    pure (UnpinOk ("autoscaler " <> akMinKey keys <> " left at " <> tshow n <> " (changed by someone else since we set " <> tshow pinned <> ")"))
                Right (RestoreWrite payload) -> do
                    w <- writeGuard env row (liftIO (gcpSetJobData (weGcp env) tg current (encodeJobData payload)))
                    case w of
                        Nothing -> pure UnpinStop
                        Just (Left e) -> stop (transient env row 30 (gcpErrText e))
                        Just (Right ()) -> do
                            back <- liftIO (gcpGetJob (weGcp env) tg)
                            case back of
                                Right j | Right original' <- decodeJobData (sjData j) >>= readMinimum keys, original' == original ->
                                    pure (UnpinOk ("autoscaler " <> akMinKey keys <> " put back to " <> tshow original))
                                Right _ -> stop (transient env row 15 "the autoscaler minimum did not read back as restored")
                                Left e -> stop (transient env row 30 (gcpErrText e))
    _ -> pure (UnpinOk "the autoscaler was not touched")
  where
    keys = autoscalerKeys tg
    stop act = act >> pure UnpinStop

{- | Opt-in: take back the capacity this window added, but only while the target still holds exactly what we
set. Stays in RESTORING until the target is idle and at the original size, with a deadline, and never
re-issues a shrink whose operation failed.
-}
shrinkPhase :: WorkerEnv -> ApplyRow -> Target -> ScaleSnapshot -> ScaleAfter -> Text -> Flow ()
shrinkPhase env row tg snap after note = do
    now <- liftIO getCurrentTime
    -- The deadline is fixed the first time we get here and kept in the row.
    (after1, deadline) <- case saShrinkDeadline after of
        Just d -> pure (after, d)
        Nothing -> do
            let d = addUTCTime (fromIntegral (observeMinutes * 60)) now
                a = after {saShrinkDeadline = Just d, saOperation = Nothing}
            _ <- patch env row emptyPatch {apAfterSpec = Just (toJSON a)}
            pure (a, d)
    live <- liftIO (gcpGetState (weGcp env) tg)
    case live of
        Left (GcpNotFound _) -> terminate env row tg Restoring Restored "restored" (note <> "; the instance no longer exists") Null
        Left e -> transient env row 30 (gcpErrText e)
        Right st -> do
            let plan = shrinkPlan st snap after1
            failed <- priorOperationFailure (weGcp env) tg after1
            case failed of
                Just e -> escalate env row tg ("the shrink failed: " <> e)
                Nothing
                    | instanceBusy st && now > deadline -> escalate env row tg ("the target stayed busy for " <> tshow observeMinutes <> " minutes while shrinking")
                    | instanceBusy st -> release env row 30
                    | planIsNoop plan -> terminate env row tg Restoring Restored "restored" (note <> "; capacity is back at the original size") (toJSON st)
                    | now > deadline -> escalate env row tg ("the target did not shrink within " <> tshow observeMinutes <> " minutes")
                    | otherwise -> case nextUpdate plan of
                        Nothing -> release env row 30
                        Just upd -> do
                            w <- writeGuard env row (liftIO (gcpResize (weGcp env) tg upd))
                            case w of
                                Nothing -> pure ()
                                Just (Right op) -> do
                                    _ <- patch env row emptyPatch {apAfterSpec = Just (toJSON after1 {saOperation = Just (opName op)})}
                                    emit env row tg "shrink_started" (describeUpdate (isMode st) upd) (A.object ["operation" .= opName op])
                                    release env row 30
                                Just (Left (GcpConflict m)) -> deferBusy env row tg ("the target is busy: " <> m)
                                Just (Left (GcpNotFound _)) -> terminate env row tg Restoring Restored "restored" (note <> "; the instance no longer exists") Null
                                Just (Left e) -> transient env row 30 (gcpErrText e)

-- ---------------------------------------------------------------------------
-- Loops

{- | Claim and process applies until cancelled. The heartbeat runs in its own thread for as long as the step
does; if this thread dies the heartbeat dies with it and the lease expires.
-}
workerLoop :: WorkerEnv -> Flow ()
workerLoop env = supervise ("scaler worker " <> weWorker env) $ forever $ do
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
                logError ("[scaler] " <> arId row <> " step failed: " <> tshow e)
                _ <- patch env row emptyPatch {apError = Just (Just (T.take 500 (tshow e))), apBumpAttempt = True}
                release env row 15

heartbeat :: WorkerEnv -> Text -> Flow ()
heartbeat env aid = do
    liftIO (threadDelay (Seconds heartbeatSeconds))
    r <- try (heartbeatApply aid (weWorker env) leaseSeconds)
    case r of
        Right False -> logWarning ("[scaler] " <> aid <> ": lost the lease")
        Right True -> heartbeat env aid
        Left e
            | isAsync e -> throwM e
            | otherwise -> do
                logWarning ("[scaler] " <> aid <> ": heartbeat failed, will retry: " <> tshow e)
                heartbeat env aid

-- | Start @n@ workers, each with its own identity, and run until cancelled.
runWorkers :: Int -> Flow ()
runWorkers n = do
    st <- ask
    base <- liftIO (T.take 8 . UUID.toText <$> UUID.nextRandom)
    logInfo ("[scaler] starting " <> tshow n <> " apply workers (" <> base <> ")")
    liftIO . mapConcurrently_ (\i -> runFlow st (mkWorkerEnv (base <> "-" <> tshow i) >>= workerLoop)) $ [1 .. n]
