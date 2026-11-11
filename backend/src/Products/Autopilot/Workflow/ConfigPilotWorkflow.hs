{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module Products.Autopilot.Workflow.ConfigPilotWorkflow
  ( configPilotSpec,
    abortConfigPilotRelease,
    configPilotStaggerInfo,
    concludedItems,
  )
where

import Control.Exception (throwIO)
import Control.Monad (forM_, unless, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State.Strict (gets, modify)
import Control.Monad.Trans.Class (lift)
import Core.AppError (WorkflowError (..))
import Core.Config (Config)
import Core.Environment (Flow, getConfig, logInfo, logWarning)
import Core.Types.Time (Seconds (..), threadDelay)
import Core.Workflow.Spec (WorkflowSpec (..))
import Core.Workflow.Stage (Stage)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.Foldable (toList)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Products.Autopilot.ConfigPilot.Client
  ( ConfigPilotItem (..),
    ConfigPilotMeta (..),
    abortItem,
    concludeItem,
    parseConfigPilotMeta,
    upsertItemRollout,
  )
import Products.Autopilot.DecisionEngine
  ( DecisionResult (..),
    PromCheckResult (..),
    checkPromQueries,
    getHSDecisionIgnoringSplit,
    initiateABDecisionForRelease,
    stopDecisionEngineHS,
  )
import Products.Autopilot.EventLog (logAbortTriggered, logDecisionResult, logStatusUpdated)
import Products.Autopilot.Notifications
  ( notifyDecisionThreadMessage,
    notifyGenericThreadMessage,
    notifyReleaseCompleted,
    notifyReleaseProgress,
  )
import Products.Autopilot.Queries.ProductService (findServiceByProductAndName)
import Products.Autopilot.Queries.ReleaseTracker
  ( checkpointReleaseTrackerChecked,
    findReleaseTracker,
    insertReleaseEvent,
    touchReleaseHeartbeat,
  )
import Products.Autopilot.RuntimeConfig (getCollectMetricsDelay, isABHSDecisionEnabledForAppGroupService)
import Products.Autopilot.Types.Release
  ( Decision (..),
    Mode (..),
    ReleaseStatus (..),
    ReleaseTracker (..),
    RolloutHistory (..),
    RolloutStep (..),
    decisionPriority,
  )
import Products.Autopilot.Types.Storage.Schema qualified as S
import Products.Autopilot.Types.Workflow (ReleaseWFStatus (..))
import Products.Autopilot.Workflow.BackendServiceWorkflow
  ( abortWithReason,
    casUpdateOrBail,
    maxLoopDurationSec,
    maxLoopIterations,
    mkRolloutHistory,
    safeIndex,
    unsnocList,
    updateLastHistoryEntry,
  )
import Products.Autopilot.Workflow.Helpers (getRT, persistWorkflowState, updateRT)
import Products.Autopilot.Workflow.StageHelpers (mkLegacyStateFlowStage)
import Products.Autopilot.Workflow.Types (ReleaseState (..), StateFlow)
import Prelude

configPilotSpec :: WorkflowSpec ReleaseState
configPilotSpec =
  WorkflowSpec
    { wsName = "ConfigPilot",
      wsStages = [cpInit, cpPrepare, cpDeploy, cpMonitor, cpFinalize, cpDone],
      wsRollback = \_err -> pure (),
      wsPersist = persistWorkflowState
    }

cpInit, cpPrepare, cpDeploy, cpMonitor, cpFinalize, cpDone :: Stage ReleaseState
cpInit = mkLegacyStateFlowStage "init" INIT validateRelease
cpPrepare = mkLegacyStateFlowStage "prepare" PREPARING initiateAb
cpDeploy = mkLegacyStateFlowStage "deploy" DEPLOYING progressiveRollout
cpMonitor = mkLegacyStateFlowStage "monitor" MONITORING monitorFinalStep
cpFinalize = mkLegacyStateFlowStage "finalize" FINALIZING concludeAll
cpDone = mkLegacyStateFlowStage "done" DONE notifyComplete

logInfoS, logWarningS :: Text -> StateFlow ()
logInfoS = lift . logInfo
logWarningS = lift . logWarning

getCfg :: StateFlow Config
getCfg = lift getConfig

getMeta :: StateFlow ConfigPilotMeta
getMeta = do
  rt <- getRT
  case parseConfigPilotMeta rt of
    Right m -> pure m
    Left e -> abortWithReason e

concludedItems :: ReleaseTracker -> [Text]
concludedItems rt = case metadata rt of
  Just (Object o) -> case KM.lookup "concluded" o of
    Just (Array a) -> [t | String t <- toList a]
    _ -> []
  _ -> []

withConcluded :: Text -> ReleaseTracker -> ReleaseTracker
withConcluded ct rt =
  let o = case metadata rt of
        Just (Object o') -> o'
        _ -> KM.empty
   in rt {metadata = Just (Object (KM.insert "concluded" (toJSON (ct : concludedItems rt)) o))}

configPilotStaggerInfo :: ReleaseTracker -> (Double, Maybe UTCTime)
configPilotStaggerInfo rt = case unsnocList (rolloutHistory rt) of
  Nothing -> (0, startTime rt)
  Just (_, lastH) -> (fromIntegral (historyRolloutPercent lastH), Just (historyStartedAt lastH))

validateRelease :: StateFlow ()
validateRelease = do
  rt <- getRT
  meta <- getMeta
  logInfoS $ "Validating ConfigPilot release " <> releaseId rt <> " items=" <> T.pack (show (length (items meta)))
  when (null (rolloutStrategy rt)) $ abortWithReason "empty rolloutStrategy"
  updateRT $ \r -> r {status = INPROGRESS}

initiateAb :: StateFlow ()
initiateAb = do
  rt <- getRT
  cfg <- getCfg
  abInit <- lift $ initiateABDecisionForRelease cfg rt
  case drDecision abInit of
    Abort -> do
      let reason = maybe "AB initiate failed" id (drReason abInit)
      insertReleaseEvent (releaseId rt) "DECISION_ENGINE" "AB_INITIATE_FAILED" (object ["reason" .= reason])
      abortWithReason ("AB initiate failed: " <> reason)
    _ -> pure ()

applyStep :: Config -> ConfigPilotMeta -> ReleaseTracker -> Int -> StateFlow ()
applyStep cfg meta rt pct =
  forM_ (items meta) $ \item -> do
    r <- upsertItemRollout cfg meta item (releaseId rt) pct
    case r of
      Right () -> logInfoS $ "  applied " <> configType item <> " v" <> T.pack (show (version item)) <> " at " <> T.pack (show pct) <> "%"
      Left e -> do
        insertReleaseEvent (releaseId rt) "BUSINESS" "CONFIG_ROLLOUT_FAILED" (toJSON e)
        abortWithReason e

progressiveRollout :: StateFlow ()
progressiveRollout = do
  rt <- getRT
  cfg <- getCfg
  meta <- getMeta
  case rolloutStrategy rt of
    [] -> abortWithReason "empty rolloutStrategy"
    strategy@(firstStep : _) -> do
      let total = length strategy
      loopStart <- liftIO getCurrentTime
      case unsnocList (rolloutHistory rt) of
        Just (_, lastH) -> do
          logInfoS $ "Resuming ConfigPilot rollout from step " <> T.pack (show (length (rolloutHistory rt))) <> "/" <> T.pack (show total)
          rolloutLoop cfg meta (length (rolloutHistory rt)) total (historyStartedAt lastH) 0 loopStart
        Nothing -> do
          applyStep cfg meta rt (rolloutPercent firstStep)
          stepStart <- liftIO getCurrentTime
          updateRT $ \r -> r {rolloutHistory = rolloutHistory r <> [mkRolloutHistory (rolloutPercent firstStep) (cooloffMinutes firstStep) 0 stepStart Nothing]}
          currentRT <- getRT
          currentTS <- gets targetState
          casUpdateOrBail "configPilot/first" currentRT currentTS (status rt)
          lift $ notifyReleaseProgress currentRT (rolloutPercent firstStep)
          rolloutLoop cfg meta 1 total stepStart 0 stepStart

rolloutLoop :: Config -> ConfigPilotMeta -> Int -> Int -> UTCTime -> Int -> UTCTime -> StateFlow ()
rolloutLoop cfg meta idx _total stepStart iter loopStart = do
  nowGuard <- liftIO getCurrentTime
  when (iter > maxLoopIterations || realToFrac (diffUTCTime nowGuard loopStart) > maxLoopDurationSec) $
    abortWithReason "Stuck rollout: max loop bail-out"
  rt <- getRT
  delay <- getCollectMetricsDelay
  fresh <- findReleaseTracker (releaseId rt)
  case fresh of
    Nothing -> liftIO $ throwIO $ WorkflowError "rollout" "Tracker deleted during rollout"
    Just (freshRT, freshMts) -> do
      updateRT $ \_ -> freshRT
      forM_ freshMts $ \ts -> modify $ \s -> s {targetState = Just ts}
      touchReleaseHeartbeat (releaseId freshRT)
      let strategy = rolloutStrategy freshRT
          freshTotal = length strategy
          freshStatus = status freshRT
          same = rolloutLoop cfg meta idx freshTotal stepStart (iter + 1) loopStart
      case freshStatus of
        ABORTING -> liftIO $ throwIO $ WorkflowError "rollout" "Release aborted"
        USER_ABORTED -> liftIO $ throwIO $ WorkflowError "rollout" "Release user-aborted during rollout"
        ABORTED -> liftIO $ throwIO $ WorkflowError "rollout" "Release aborted during rollout"
        COMPLETED -> pure ()
        PAUSED -> threadDelay (Seconds delay) >> same
        INPROGRESS
          | idx >= freshTotal -> pure ()
          | otherwise -> do
              now <- liftIO getCurrentTime
              currentStep <- case safeIndex strategy (idx - 1) of
                Just s -> pure s
                Nothing -> abortWithReason "rolloutStrategy index out of range (current step)"
              let exceeded = realToFrac (diffUTCTime now stepStart) >= (fromIntegral (cooloffMinutes currentStep) * 60 :: Double)
              if not exceeded
                then threadDelay (Seconds delay) >> same
                else do
                  advance <- gateForMode cfg freshRT freshStatus ("STAGE_" <> T.pack (show idx))
                  if not advance
                    then threadDelay (Seconds delay) >> same
                    else do
                      updateLastHistoryEntry $ \h -> h {historyCompletedAt = Just now, historyDecision = Just Continue}
                      nextStep <- case safeIndex strategy idx of
                        Just s -> pure s
                        Nothing -> abortWithReason "rolloutStrategy index out of range (next step)"
                      applyStep cfg meta freshRT (rolloutPercent nextStep)
                      newStart <- liftIO getCurrentTime
                      updateRT $ \r -> r {rolloutHistory = rolloutHistory r <> [mkRolloutHistory (rolloutPercent nextStep) (cooloffMinutes nextStep) 0 newStart Nothing]}
                      currentRT <- getRT
                      currentTS <- gets targetState
                      casUpdateOrBail "configPilot/advance" currentRT currentTS freshStatus
                      lift $ notifyReleaseProgress currentRT (rolloutPercent nextStep)
                      rolloutLoop cfg meta (idx + 1) freshTotal newStart (iter + 1) loopStart
        _ -> liftIO $ throwIO $ WorkflowError "rollout" ("Unexpected status: " <> T.pack (show freshStatus))

gateForMode :: Config -> ReleaseTracker -> ReleaseStatus -> Text -> StateFlow Bool
gateForMode cfg freshRT freshStatus label = case mode freshRT of
  MANUAL -> pure True
  AUTO -> do
    let fastForwarded = case unsnocList (rolloutHistory freshRT) of
          Just (_, lastH) -> historyManualOverride lastH
          Nothing -> False
    if fastForwarded then pure True else runConfigGate cfg freshRT freshStatus label

runConfigGate :: Config -> ReleaseTracker -> ReleaseStatus -> Text -> StateFlow Bool
runConfigGate cfg freshRT freshStatus label = do
  mSvc <- findServiceByProductAndName (appGroup freshRT) (service freshRT)
  promResult <- checkPromQueries cfg freshRT (mSvc >>= S.dcDecisionConfig)
  case promResult of
    PromAbort reason -> do
      logAbortTriggered (releaseId freshRT) "SYSTEM" "Prometheus Check" reason
      lift $ notifyGenericThreadMessage freshRT ("Prometheus check ABORT: " <> reason)
      markAbortingAndThrow (label <> "/promAbort") freshStatus ("Prometheus ABORT: " <> reason)
    PromWarn reason -> lift $ notifyGenericThreadMessage freshRT ("Prometheus warning: " <> reason)
    PromOK -> pure ()
  enabled <- isABHSDecisionEnabledForAppGroupService (appGroup freshRT) (service freshRT)
  hs <-
    if enabled
      then getHSDecisionIgnoringSplit cfg freshRT
      else pure (DecisionResult Continue Nothing "HEALTH_SCORE")
  let decision = drDecision hs
      reasonText = maybe "" id (drReason hs)
      resultText = "HS=" <> T.pack (show decision)
  updateLastHistoryEntry $ \h ->
    h
      { historyDecision = Just decision,
        historyDecisionReason = Just resultText,
        historyDecisionHs = Just decision,
        historyDecisionHsReason = drReason hs
      }
  rtNow <- getRT
  tsNow <- gets targetState
  casUpdateOrBail (label <> "/decisionHist") rtNow tsNow freshStatus
  logDecisionResult rtNow decision resultText [reasonText | not (T.null reasonText)]
  when (decision /= Continue) $ do
    _ <-
      lift $
        notifyDecisionThreadMessage
          rtNow
          ("ROLLOUT_DECISION_" <> label)
          (T.pack (show decision))
          (if T.null reasonText then Nothing else Just reasonText)
          ("Decision: " <> T.pack (show decision) <> " - " <> resultText <> (if T.null reasonText then "" else " | " <> reasonText))
    pure ()
  case decision of
    Continue -> pure True
    Abort -> do
      logAbortTriggered (releaseId rtNow) "DECISION_ENGINE" "AB/HS Decision Engine" resultText
      markAbortingAndThrow (label <> "/decisionAbort") freshStatus "Decision engine: ABORT"
    _ -> pure (decisionPriority decision >= decisionPriority Continue)

markAbortingAndThrow :: Text -> ReleaseStatus -> Text -> StateFlow a
markAbortingAndThrow tag freshStatus msg = do
  logStatusUpdated' msg
  updateRT $ \r -> r {status = ABORTING}
  currentRT <- getRT
  currentTS <- gets targetState
  casUpdateOrBail tag currentRT currentTS freshStatus
  liftIO $ throwIO $ WorkflowError "decision" msg
  where
    logStatusUpdated' m = do
      rt <- getRT
      logStatusUpdated rt ("ABORTING the config release: " <> m)

monitorFinalStep :: StateFlow ()
monitorFinalStep = do
  rt0 <- getRT
  cfg <- getCfg
  loopStart <- liftIO getCurrentTime
  go rt0 cfg 0 loopStart
  where
    go rt0 cfg iter loopStart = do
      nowGuard <- liftIO getCurrentTime
      when (iter > maxLoopIterations || realToFrac (diffUTCTime nowGuard loopStart) > maxLoopDurationSec) $
        abortWithReason "Stuck final monitor: max loop bail-out"
      delay <- getCollectMetricsDelay
      fresh <- findReleaseTracker (releaseId rt0)
      case fresh of
        Nothing -> liftIO $ throwIO $ WorkflowError "monitor" "Tracker deleted during monitor"
        Just (freshRT, freshMts) -> do
          updateRT $ \_ -> freshRT
          forM_ freshMts $ \ts -> modify $ \s -> s {targetState = Just ts}
          touchReleaseHeartbeat (releaseId freshRT)
          let freshStatus = status freshRT
              again = threadDelay (Seconds delay) >> go rt0 cfg (iter + 1 :: Int) loopStart
          case freshStatus of
            ABORTING -> liftIO $ throwIO $ WorkflowError "monitor" "Release aborted"
            USER_ABORTED -> liftIO $ throwIO $ WorkflowError "monitor" "Release user-aborted"
            ABORTED -> liftIO $ throwIO $ WorkflowError "monitor" "Release aborted"
            COMPLETED -> pure ()
            PAUSED -> again
            INPROGRESS -> do
              now <- liftIO getCurrentTime
              case unsnocList (rolloutHistory freshRT) of
                Nothing -> abortWithReason "no rollout history at final monitor"
                Just (_, lastH) -> do
                  let exceeded = realToFrac (diffUTCTime now (historyStartedAt lastH)) >= (fromIntegral (historyCooloffMinutes lastH) * 60 :: Double)
                  if not exceeded
                    then again
                    else do
                      ok <- gateForMode cfg freshRT freshStatus "FINAL"
                      if not ok
                        then again
                        else do
                          updateLastHistoryEntry $ \h -> h {historyCompletedAt = Just now, historyDecision = Just Continue}
                          currentRT <- getRT
                          currentTS <- gets targetState
                          casUpdateOrBail "configPilot/finalHist" currentRT currentTS freshStatus
            _ -> liftIO $ throwIO $ WorkflowError "monitor" ("Unexpected status: " <> T.pack (show freshStatus))

concludeAll :: StateFlow ()
concludeAll = do
  rt <- getRT
  cfg <- getCfg
  meta <- getMeta
  lift $ stopDecisionEngineHS cfg (releaseId rt)
  forM_ (items meta) $ \item -> do
    cur <- getRT
    unless (configType item `elem` concludedItems cur) $ do
      r <- concludeItem cfg meta item
      case r of
        Left e -> do
          insertReleaseEvent (releaseId cur) "BUSINESS" "CONFIG_CONCLUDE_FAILED" (toJSON e)
          liftIO $ throwIO $ WorkflowError "conclude" e
        Right () -> do
          updateRT (withConcluded (configType item))
          updated <- getRT
          ts <- gets targetState
          casUpdateOrBail "configPilot/conclude" updated ts INPROGRESS
          insertReleaseEvent (releaseId cur) "BUSINESS" "CONFIG_CONCLUDED" (object ["configType" .= configType item, "version" .= version item])

notifyComplete :: StateFlow ()
notifyComplete = do
  rt <- getRT
  now <- liftIO getCurrentTime
  updateRT $ \r -> r {status = COMPLETED, endTime = Just now}
  currentRT <- getRT
  currentTS <- gets targetState
  landed <- checkpointReleaseTrackerChecked currentRT currentTS
  if landed
    then do
      logStatusUpdated currentRT "Config release completed at 100%"
      lift $ notifyReleaseCompleted currentRT currentTS
    else logWarningS $ "  [notifyComplete] " <> releaseId rt <> " moved off INPROGRESS before completion persisted"

abortConfigPilotRelease :: Config -> ReleaseTracker -> Flow Bool
abortConfigPilotRelease cfg rt = case parseConfigPilotMeta rt of
  Left e -> do
    logWarning $ "[configPilot/abort] " <> releaseId rt <> ": " <> e
    pure True
  Right meta -> do
    stopDecisionEngineHS cfg (releaseId rt)
    let pending = [i | i <- items meta, configType i `notElem` concludedItems rt]
    results <- mapM (\i -> (,) i <$> abortItem cfg meta i) pending
    let failures = [(configType i, e) | (i, Left e) <- results]
    forM_ failures $ \(ct, e) ->
      insertReleaseEvent (releaseId rt) "BUSINESS" "CONFIG_ABORT_FAILED" (object ["configType" .= ct, "error" .= e])
    pure (null failures)
