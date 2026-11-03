{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Turns schedules into ledger rows.

Level-triggered, as in the HPA scheduler: every tick asks "is a window open for this schedule right now, and
does it have its apply?" and creates the missing row. Nothing here remembers that a window was missed, so
downtime cannot lose one: if the backend was down at the start of a window and is back while it is still
open, the apply is created then. Restores are not decided here at all: each apply row carries its own
@window_end@ and the worker restores it on time even if the schedule has since been edited or deleted.

Only one pod runs this at a time (a lease in @hpa_loop_lease@, shared with the HPA loops).
-}
module Products.Autopilot.Scaler.Reconcile (
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
import Products.Autopilot.Hpa.Store (acquireLoopLease)
import Products.Autopilot.Hpa.Types (ApplyTrigger (..), ScheduleStatus (..), applyTriggerText, scheduleStatusText)
import Products.Autopilot.Hpa.Types qualified as H
import Products.Autopilot.Hpa.Util (decodeValue, isAsync, newId)
import Products.Autopilot.Hpa.Window
import Products.Autopilot.Hpa.Worker (supervise)
import Products.Autopilot.Scaler.Store
import Products.Autopilot.Scaler.Types

reconcileLoop :: Text -> Flow ()
reconcileLoop holder = supervise "scaler reconciler" $ forever $ do
    cfg <- getConfig
    let cloud = cloudProvider cfg
    leader <- acquireLoopLease "scaler-reconcile" cloud holder 60
    when leader (reconcileTick cloud)
    liftIO (threadDelay (Seconds 15))

reconcileTick :: Text -> Flow ()
reconcileTick cloud = do
    now <- liftIO getCurrentTime
    schedules <- listActiveSchedules cloud
    forM_ schedules $ \s -> do
        r <- try $ do
            gap <- evalGap cloud now s
            mine <- claimScheduleEval cloud (srId s) gap
            when mine (evaluateSchedule cloud now s)
        case r of
            Right () -> pure ()
            Left e
                | isAsync e -> throwM e
                | otherwise -> logWarning ("[scaler] reconcile " <> srId s <> " failed: " <> T.pack (show e))

{- | How long to leave a schedule alone between evaluations. While its window is open and the apply exists there
is nothing to do, so look once a minute; otherwise react within seconds.
-}
evalGap :: Text -> UTCTime -> ScheduleRow -> Flow Int
evalGap cloud now s = case decodeValue (srTiming s) of
    Right kind | Just w <- activeWindow kind now -> do
        applies <- appliesForSchedule cloud (srId s)
        pure (if any ((== Just (wStart w)) . arWindowStart) applies then 60 else 10)
    _ -> pure 10

evaluateSchedule :: Text -> UTCTime -> ScheduleRow -> Flow ()
evaluateSchedule cloud now s =
    case (decodeValue (srTiming s), decodeValue (srChange s), parseTargetKind (srTargetKind s)) of
        (Right (timing :: H.ScheduleKind), Right (change :: ScaleChange), Just kind) -> case activeWindow timing now of
            Just w -> ensureApply cloud s kind change w
            Nothing -> case timing of
                H.Once _ (Just end) | end <= now -> do
                    _ <- setScheduleStatus cloud (srId s) (scheduleStatusText SchedExpired)
                    pure ()
                _ -> pure ()
        _ -> logWarning ("[scaler] schedule " <> srId s <> " is unreadable, skipping")

ensureApply :: Text -> ScheduleRow -> TargetKind -> ScaleChange -> Window -> Flow ()
ensureApply cloud s kind change w = do
    aid <- newId
    ok <-
        insertApply
            ApplyNew
                { anId = aid
                , anCloud = cloud
                , anScheduleId = Just (srId s)
                , anTrigger = applyTriggerText TrigScheduled
                , anKind = kind
                , anTargetId = srTargetId s
                , anChange = A.toJSON change
                , anWindowStart = Just (wStart w)
                , anWindowEnd = wEnd w
                , anCreatedBy = "scheduler:" <> srId s
                }
    when ok $
        addEvent cloud (Just aid) (Just (srId s)) kind (srTargetId s) "scheduled" ("window opened for schedule " <> srName s) Null
