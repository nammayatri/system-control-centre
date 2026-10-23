{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Turns schedules into ledger rows.

Level-triggered, not edge-triggered: every tick asks "is a window open for this
schedule right now, and does every serving HPA have an apply for it?" and creates
the missing rows. Nothing here remembers that a window was missed, so downtime
cannot lose one: if the backend was down at 10:00 and is back at 10:07 with the
window still open, the apply is created at 10:07. Restores are not decided here at
all: each apply row carries its own @window_end@ and the worker restores it on
time even if the schedule has since been edited or deleted.

Only one pod runs this at a time (a lease in @hpa_loop_lease@); if it dies another
takes over within the lease length.
-}
module Products.Autopilot.Hpa.Reconcile (
    reconcileLoop,
    reconcileTick,
    evaluateSchedule,
)
where

import Control.Monad (forM_, forever, when)
import Control.Monad.Catch (throwM, try)
import Control.Monad.IO.Class (liftIO)
import Core.Config (Config (..))
import Core.Environment (Flow, getConfig, logWarning)
import Core.Types.Time (Seconds (..), threadDelay)
import Data.Aeson (Value (..))
import Data.Aeson qualified as A
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime, getCurrentTime)
import Products.Autopilot.Hpa.Kube (Kube, mkKube)
import Products.Autopilot.Hpa.Resolver
import Products.Autopilot.Hpa.Service
import Products.Autopilot.Hpa.Spec (HpaObject (..))
import Products.Autopilot.Hpa.Store
import Products.Autopilot.Hpa.Types
import Products.Autopilot.Hpa.Util (decodeValue, isAsync, newId)
import Products.Autopilot.Hpa.Window
import Products.Autopilot.Hpa.Worker (supervise)

reconcileLoop :: Text -> Flow ()
reconcileLoop holder = supervise "reconciler" $ forever $ do
    cfg <- getConfig
    let cloud = cloudProvider cfg
    leader <- acquireLoopLease "reconcile" cloud holder 60
    when leader (reconcileTick (mkKube cfg) cloud)
    liftIO (threadDelay (Seconds 15))

reconcileTick :: Kube -> Text -> Flow ()
reconcileTick kube cloud = do
    now <- liftIO getCurrentTime
    schedules <- listActiveSchedules cloud
    forM_ schedules $ \s -> do
        r <- try $ do
            gap <- evalGap cloud now s
            mine <- claimScheduleEval cloud (srId s) gap
            when mine (evaluateSchedule kube cloud now s)
        case r of
            Right () -> pure ()
            Left e
                | isAsync e -> throwM e
                | otherwise -> logWarning ("[hpa] reconcile " <> srId s <> " failed: " <> T.pack (show e))

{- | How long to leave a schedule alone between cluster evaluations. While a window is open and
every serving HPA already has its apply there is nothing to do but notice a release moving
traffic, so look once a minute rather than every tick; otherwise react within seconds.
-}
evalGap :: Text -> UTCTime -> ScheduleRow -> Flow Int
evalGap cloud now s = case decodeValue (srKind s) of
    Right kind | Just w <- activeWindow kind now -> do
        applies <- appliesForSchedule cloud (srId s)
        pure (if any ((== Just (wStart w)) . arWindowStart) applies then 60 else 10)
    _ -> pure 10

evaluateSchedule :: Kube -> Text -> UTCTime -> ScheduleRow -> Flow ()
evaluateSchedule kube cloud now s =
    case (decodeValue (srKind s), decodeValue (srChange s), decodeValue (srPolicy s)) of
        (Right kind, Right change, Right (policy :: HealthPolicy)) -> case activeWindow kind now of
            Just w -> ensureApplies kube cloud s change policy w
            Nothing -> case kind of
                Once _ (Just end) | end <= now -> do
                    _ <- setScheduleStatus cloud (srId s) (scheduleStatusText SchedExpired)
                    pure ()
                _ -> pure ()
        (k, c, p) ->
            logWarning
                ( "[hpa] schedule "
                    <> srId s
                    <> " is unreadable, skipping: "
                    <> T.intercalate "; " ([e | Left e <- [fmap (const ()) k]] <> [e | Left e <- [fmap (const ()) c]] <> [e | Left e <- [fmap (const ()) p]])
                )

ensureApplies :: Kube -> Text -> ScheduleRow -> HpaChange -> HealthPolicy -> Window -> Flow ()
ensureApplies kube cloud s change policy w = do
    mctx <- loadServiceCtx (srAppGroup s) (srService s)
    case mctx of
        Nothing -> logWarning ("[hpa] schedule " <> srId s <> ": service " <> srAppGroup s <> "/" <> srService s <> " is not configured")
        Just ctx -> do
            res <- liftIO (resolveServiceHpasWith kube (scNamespace ctx) (scVsName ctx) (scHost ctx) (scOtherHosts ctx))
            case res of
                Left e -> logWarning ("[hpa] schedule " <> srId s <> ": cannot resolve HPAs: " <> e)
                Right r -> do
                    forM_ (servingTargets r) $ \t -> do
                        aid <- newId
                        ok <-
                            insertApply
                                ApplyNew
                                    { anId = aid
                                    , anCloud = cloud
                                    , anScheduleId = Just (srId s)
                                    , anTrigger = applyTriggerText TrigScheduled
                                    , anAppGroup = srAppGroup s
                                    , anService = srService s
                                    , anNamespace = scNamespace ctx
                                    , anHpaName = hoName (rhHpa t)
                                    , anChange = A.toJSON change
                                    , anPolicy = A.toJSON policy
                                    , anWindowStart = Just (wStart w)
                                    , anWindowEnd = wEnd w
                                    , anCreatedBy = "scheduler:" <> srId s
                                    }
                        when ok $
                            addEvent
                                cloud
                                (Just aid)
                                (Just (srId s))
                                (srAppGroup s)
                                (srService s)
                                "scheduled"
                                ("window opened; will apply to " <> hoName (rhHpa t))
                                Null
                    -- Applies still holding an HPA that has since been deleted (a release replaced it)
                    -- are sent through restore, which closes them once it sees the HPA is gone.
                    existing <- appliesForSchedule cloud (srId s)
                    let names = map (hoName . rhHpa) (resHpas r)
                    forM_ [a | a <- existing, arStatus a == "APPLIED", arHpaName a `notElem` names] $ \a ->
                        forceTransition (arId a) cloud [Applied] Restoring (Just "the HPA no longer exists")

