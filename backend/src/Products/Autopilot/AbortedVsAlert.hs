{-# LANGUAGE OverloadedStrings #-}

{- | Safety net for the one rollback failure nobody notices: a release that
reached a terminal ABORTED state while its VirtualService is still routing
traffic to the *new* (bad) version.

-}
module Products.Autopilot.AbortedVsAlert (
    sweepAbortedVsNotRestored,
    abortedVsAlertLabel,
    abortedVsClearedLabel,
)
where

import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar)
import Control.Monad (forM_, unless)
import Control.Monad.Catch qualified as MC
import Control.Monad.IO.Class (liftIO)
import Core.Config (Config)
import Core.Environment (Flow, logInfo, logWarning)
import Data.Aeson (object, (.=))
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (NominalDiffTime, UTCTime, addUTCTime, diffUTCTime)
import Products.Autopilot.K8s.Execute (K8sError (..))
import Products.Autopilot.K8s.VirtualService (isSubsetReceivingTraffic)
import Products.Autopilot.Notifications (notifyFixedChannelAlert, notifyGenericThreadMessage, releaseLink)
import Products.Autopilot.Queries.ReleaseTracker (existsNewerTrackerForService, findAbortedTrackersSince, findActiveTrackersForService, findEventByLabel, insertReleaseEvent)
import Products.Autopilot.RuntimeConfig (
    getAbortedVsNotRestoredAlertChannel,
    getAbortedVsNotRestoredAlertLookbackHours,
    getAbortedVsNotRestoredAlertMinutes,
    isAbortedVsNotRestoredAlertEnabled,
    isK8sEnabled,
 )
import Products.Autopilot.Types.Release (ReleaseTracker (..), releaseStatusText)
import Products.Autopilot.Types.Target (TargetState (..))
import Products.Autopilot.Types.Target.Kubernetes (K8sDeploymentState (..), K8sReleaseContext (..))
import Products.Autopilot.Types.Target.Kubernetes qualified as K8s
import System.IO.Unsafe (unsafePerformIO)
import Prelude

abortedVsAlertLabel :: Text
abortedVsAlertLabel = "VS_NOT_RESTORED_ALERTED"

{- | Event label marking "checked, nothing wrong here". Without it a clean
abort would be re-verified with fresh kubectl calls on every tick for the
whole lookback window; with it each aborted release costs one check.
-}
abortedVsClearedLabel :: Text
abortedVsClearedLabel = "VS_RESTORE_CHECK_CLEARED"

-- | What the live VirtualServices say about the new version's traffic.
data TrafficVerdict
    = -- | New version still weighted > 0 on these VS names.
      StillOnNew [Text]
    | -- | Every VS checked routes 0% to the new version.
      Restored
    | -- | Nothing could be read (kubectl/API failure) — never alert on this.
      Unknown Text

-- | True while a sweep is running; see 'sweepAbortedVsNotRestored'.
{-# NOINLINE sweepInFlight #-}
sweepInFlight :: MVar Bool
sweepInFlight = unsafePerformIO (newMVar False)

claimSweep :: IO Bool
claimSweep = modifyMVar sweepInFlight $ \busy -> pure (True, not busy)

releaseSweep :: IO ()
releaseSweep = modifyMVar_ sweepInFlight (const (pure False))

sweepAbortedVsNotRestored :: Config -> UTCTime -> Flow ()
sweepAbortedVsNotRestored cfg now = do
    enabled <- isAbortedVsNotRestoredAlertEnabled
    k8sOn <- isK8sEnabled
    if not (enabled && k8sOn)
        then pure ()
        else do
            claimed <- liftIO claimSweep
            if not claimed
                then logInfo "[VS_NOT_RESTORED] Previous sweep still running — skipping this tick"
                else runSweep cfg now `MC.finally` liftIO releaseSweep

runSweep :: Config -> UTCTime -> Flow ()
runSweep cfg now = do
    channel <- getAbortedVsNotRestoredAlertChannel
    ageMins <- getAbortedVsNotRestoredAlertMinutes
    lookbackHours <- getAbortedVsNotRestoredAlertLookbackHours
    let minAge = fromIntegral (ageMins * 60) :: NominalDiffTime
        lookbackStart = addUTCTime (negate (fromIntegral lookbackHours * 3600)) now
    candidates <- findAbortedTrackersSince lookbackStart
    let overdue = [c | c <- candidates, isOverdue minAge now c]
    unless (null overdue) $
        logInfo $
            "[VS_NOT_RESTORED] Checking " <> tshow (length overdue) <> " aborted release(s) older than " <> tshow ageMins <> "m"
    forM_ overdue $ \(rt, mts) -> checkOne cfg channel now ageMins rt mts

{- | Age is measured from @end_time@ (when the abort finalized), falling back
to @last_updated@ for rows that predate end_time being set.
-}
isOverdue :: NominalDiffTime -> UTCTime -> (ReleaseTracker, Maybe TargetState) -> Bool
isOverdue minAge now (rt, _) = case endTime rt of
    Just t -> diffUTCTime now t >= minAge
    Nothing -> maybe False (\t -> diffUTCTime now t >= minAge) (lastUpdated rt)

checkOne :: Config -> Text -> UTCTime -> Int -> ReleaseTracker -> Maybe TargetState -> Flow ()
checkOne cfg channel now ageMins rt (Just (K8sState k8s))
    | not (hasVsToRestore k8s) = pure ()
    | otherwise = do
        settled <- alreadySettled (releaseId rt)
        unless settled $ do
            -- A VS subset is a version, not a release: re-running the same
            -- version after fixing whatever caused the abort points the VS at
            -- the very subset this release used. Traffic on that subset then
            -- belongs to the newer release, so any later release for this
            -- service ends this one's claim on the VS.
            superseded <- supersededByLaterRelease rt
            if superseded
                then do
                    logInfo $
                        "[VS_NOT_RESTORED] "
                            <> releaseId rt
                            <> " superseded by a later release for the same service — VS state no longer attributable to this abort"
                    clearRelease rt "superseded"
                else do
                    verdict <- liftIO $ newVersionTrafficVerdict cfg (context k8s)
                    case verdict of
                        Restored -> clearRelease rt "restored"
                        Unknown err ->
                            logWarning $
                                "[VS_NOT_RESTORED] Could not read VS for " <> releaseId rt <> " — skipping this pass: " <> err
                        StillOnNew vsNames -> raiseAlert channel now ageMins rt (context k8s) vsNames
checkOne _ _ _ _ _ _ = pure ()

-- | Already alerted, or already checked and found clean.
alreadySettled :: Text -> Flow Bool
alreadySettled rid = do
    alerted <- isJust <$> findEventByLabel rid abortedVsAlertLabel
    if alerted
        then pure True
        else isJust <$> findEventByLabel rid abortedVsClearedLabel

supersededByLaterRelease :: ReleaseTracker -> Flow Bool
supersededByLaterRelease rt = do
    newer <- case endTime rt of
        Nothing -> pure False
        Just abortedAt -> existsNewerTrackerForService (appGroup rt) (service rt) (env rt) (releaseId rt) abortedAt
    if newer
        then pure True
        else do
            active <- findActiveTrackersForService (appGroup rt) (service rt)
            pure $ any (\(o, _) -> env o == env rt && releaseId o /= releaseId rt) active

-- | Record that this release needs no further checking, and why.
clearRelease :: ReleaseTracker -> Text -> Flow ()
clearRelease rt reason =
    insertReleaseEvent
        (releaseId rt)
        "BUSINESS"
        abortedVsClearedLabel
        (object ["result" .= reason])

{- | Only releases that actually flipped a VS to a new subset can leave
traffic stranded: brand-new services, schedulers (no VS) and rows without a
distinct old version have nothing to restore.
-}
hasVsToRestore :: K8sDeploymentState -> Bool
hasVsToRestore k8s =
    let ctx = context k8s
        oldVer = K8s.oldVersion ctx
     in not (newService k8s)
            && not (T.null (virtualServiceName ctx))
            && not (T.null oldVer)
            && oldVer `notElem` ["new", "unknown"]
            && oldVer /= K8s.newVersion ctx

newVersionTrafficVerdict :: Config -> K8sReleaseContext -> IO TrafficVerdict
newVersionTrafficVerdict cfg ctx = do
    let vsNames = filter (not . T.null) (virtualServiceName ctx : maybe [] pure (internalVirtualServiceName ctx))
    results <- mapM checkVs vsNames
    let live = [name | (name, Right True) <- results]
        readable = [name | (name, Right _) <- results]
        firstErr = case [e | (_, Left (K8sError e)) <- results] of
            (e : _) -> e
            [] -> "no virtual service configured"
    pure $
        if not (null live)
            then StillOnNew live
            else
                if null readable
                    then Unknown firstErr
                    else Restored
  where
    checkVs name = do
        res <- isSubsetReceivingTraffic cfg (namespace ctx) name (serviceName ctx) (K8s.newVersion ctx)
        pure (name, res)

raiseAlert :: Text -> UTCTime -> Int -> ReleaseTracker -> K8sReleaseContext -> [Text] -> Flow ()
raiseAlert channel now ageMins rt ctx vsNames = do
    let abortedAt = fromMaybe now (endTime rt)
        minutesStale = round (diffUTCTime now abortedAt / 60) :: Int
        details =
            T.intercalate
                "\n"
                [ releaseStatusText (status rt) <> " " <> tshow minutesStale <> "m ago, VS traffic still on *" <> K8s.newVersion ctx <> "*"
                , "old → new: " <> K8s.oldVersion ctx <> " → " <> K8s.newVersion ctx
                , "namespace: " <> namespace ctx <> " | service: " <> serviceName ctx
                , "virtualservice(s) routing to new: " <> T.intercalate ", " vsNames
                , "The rollback never restored traffic to the old version — verify and flip the VS manually."
                ]
    link <- liftIO (releaseLink rt)
    notifyFixedChannelAlert
        channel
        ( "\128680 Aborted release still serving the new version — "
            <> appGroup rt
            <> " | "
            <> service rt
            <> " ("
            <> releaseId rt
            <> ")\n"
            <> details
            <> "\n"
            <> link
        )
    notifyGenericThreadMessage
        rt
        ( "\128680 This release is "
            <> releaseStatusText (status rt)
            <> " but its VirtualService ("
            <> T.intercalate ", " vsNames
            <> ") is still routing traffic to "
            <> K8s.newVersion ctx
            <> " "
            <> tshow minutesStale
            <> " minutes after the abort. Manual VS restore required."
        )
    insertReleaseEvent
        (releaseId rt)
        "BUSINESS"
        abortedVsAlertLabel
        ( object
            [ "status" .= releaseStatusText (status rt)
            , "oldVersion" .= K8s.oldVersion ctx
            , "newVersion" .= K8s.newVersion ctx
            , "namespace" .= namespace ctx
            , "virtualServices" .= vsNames
            , "minutesSinceAbort" .= minutesStale
            , "thresholdMinutes" .= ageMins
            , "channel" .= channel
            ]
        )
    logWarning $
        "[VS_NOT_RESTORED] Alerted on "
            <> releaseId rt
            <> " — VS "
            <> T.intercalate ", " vsNames
            <> " still routing to "
            <> K8s.newVersion ctx

tshow :: (Show a) => a -> Text
tshow = T.pack . show
