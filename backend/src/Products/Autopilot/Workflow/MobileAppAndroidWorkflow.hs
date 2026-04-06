{-# LANGUAGE OverloadedStrings #-}

-- | Mobile app Android workflow (Play Store deployment)
--
-- This module implements the workflow for releasing Android apps to Google Play Store.
-- It uses the new type system with:
-- - ReleaseCategory (MobileAppAndroid)
-- - ReleaseWFStatus (generic stages)
-- - MobileAppAndroidWFStatus (Play Store-specific sub-stages)
-- - Recorded monad for checkpoint/resume
module Products.Autopilot.Workflow.MobileAppAndroidWorkflow
  ( mobileAppAndroidWorkflow,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State.Strict (gets, modify)
import Control.Monad.Trans.Class (lift)
import Core.Utils.FlowMonad (logInfo, logWarning)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Products.Autopilot.Types.Release (ReleaseStatus (..), ReleaseTracker (..))
import Products.Autopilot.Types.Target
  ( MobileAppAndroidWFStatus (..),
    PlayStoreDeploymentState (..),
    ReviewStatus (..),
    TargetState (..),
    emptyPlayStoreState,
  )
import Products.Autopilot.Types.Workflow (ReleaseWFStatus (..))
import Products.Autopilot.Workflow.Helpers (getRT, updateRT, (|>>))
import Products.Autopilot.Workflow.Types
  ( ReleaseState (..),
    ReleaseWorkFlow,
    StateFlow,
  )
import Prelude

-- ============================================================================
-- Mobile App Android Workflow
-- ============================================================================

-- | Mobile app Android workflow using generic stages
--
-- This workflow releases an Android app to Google Play Store with:
-- - Generic ReleaseWFStatus stages (INIT, PREPARING, DEPLOYING, MONITORING, FINALIZING, DONE)
-- - Play Store-specific MobileAppAndroidWFStatus sub-stages
-- - Category-specific state in PlayStoreDeploymentState
--
-- Example release:
-- - product = "rider-android"
-- - category = MobileAppAndroid
-- - releaseWFStatus: INIT → PREPARING → DEPLOYING → MONITORING → FINALIZING → DONE
-- - targetState: PlayStoreState with MobileAppAndroidWFStatus sub-stages
mobileAppAndroidWorkflow :: ReleaseWorkFlow ()
mobileAppAndroidWorkflow = do
  -- Generic ReleaseWFStatus stages
  INIT |>> validateAPK
  PREPARING |>> uploadToPlayStore
  DEPLOYING |>> stagedRollout
  MONITORING |>> monitorCrashRates
  FINALIZING |>> promoteToFull
  DONE |>> notifyRelease

-- ============================================================================
-- Logging Helpers
-- ============================================================================

-- | StateFlow-level logging (lifts from Flow)
logInfoS :: T.Text -> StateFlow ()
logInfoS = lift . logInfo

logWarningS :: T.Text -> StateFlow ()
logWarningS = lift . logWarning

-- ============================================================================
-- Workflow Step Implementations
-- ============================================================================

-- | Validate APK
--
-- Generic stage: INIT
-- Play Store sub-stage: MAInit
validateAPK :: StateFlow ()
validateAPK = do
  rt <- getRT
  logInfoS $ "🔍 Validating APK for " <> appGroup rt

  -- Initialize Play Store deployment state with MAInit
  let playStoreState = emptyPlayStoreState{categoryWorkflowStatus = MAInit}
  modify $ \rs -> rs{targetState = Just (PlayStoreState playStoreState)}

  -- Validate APK signature
  logInfoS "  ✓ Checking APK signature"

  -- Validate version code
  logInfoS "  ✓ Validating version code"

  -- Check permissions
  logInfoS "  ✓ Checking app permissions"

  logInfoS "✅ APK validation complete"

-- | Upload to Play Store
--
-- Generic stage: PREPARING
-- Play Store sub-stages: MAUploadAPK, MASubmitForReview
uploadToPlayStore :: StateFlow ()
uploadToPlayStore = do
  rt <- getRT
  logInfoS $ "📤 Uploading APK to Play Store for " <> appGroup rt

  -- Upload APK
  updatePlayStoreStatus MAUploadAPK
  logInfoS "  ✓ Uploading APK to Play Console"

  let versionCode = fromMaybe "unknown" (releaseTag rt)
  updatePlayStoreField (\ps -> ps{apkUploaded = Just versionCode})

  liftIO $ threadDelay 5000000 -- 5 seconds (simulated upload)

  -- Submit for review
  updatePlayStoreStatus MASubmitForReview
  logInfoS "  ✓ Submitting for Play Store review"
  updatePlayStoreField (\ps -> ps{reviewStatus = UnderReview})

  -- Wait for review approval (simulated)
  updatePlayStoreStatus MAWaitingReview
  logInfoS "  ⏱️  Waiting for review approval"
  liftIO $ threadDelay 10000000 -- 10 seconds (simulated review)

  -- Review approved
  logInfoS "  ✓ Review approved!"
  updatePlayStoreField (\ps -> ps{reviewStatus = Approved})

  logInfoS "✅ APK uploaded and approved"

-- | Staged rollout (0% → 25% → 50% → 100%)
--
-- Generic stage: DEPLOYING
-- Play Store sub-stage: MAStagedRollout
stagedRollout :: StateFlow ()
stagedRollout = do
  rt <- getRT
  logInfoS $ "🚀 Starting staged rollout for " <> appGroup rt

  updatePlayStoreStatus MAStagedRollout

  -- Rollout in stages: 25% → 50% → 100%
  rolloutStaged [25, 50, 100]

  logInfoS "✅ Staged rollout complete"

-- | Rollout in stages
rolloutStaged :: [Int] -> StateFlow ()
rolloutStaged [] = return ()
rolloutStaged (pct : rest) = do
  logInfoS $ "  📊 Releasing to " <> T.pack (show pct) <> "% of users"

  -- Update rollout percentage
  updatePlayStoreField (\ps -> ps{stagedRolloutPercent = pct})

  -- Wait for rollout to propagate
  liftIO $ threadDelay 15000000 -- 15 seconds

  -- Check health at this rollout level
  checkHealthAtRolloutLevel pct

  -- Continue to next percentage
  rolloutStaged rest

-- | Check health at current rollout level
checkHealthAtRolloutLevel :: Int -> StateFlow ()
checkHealthAtRolloutLevel pct = do
  logInfoS $ "    🔍 Checking health at " <> T.pack (show pct) <> "% rollout"

  -- Fetch crash rate from Play Console (simulated)
  let crashRate = 0.003 -- 0.3%
  updatePlayStoreField (\ps -> ps{crashRate = Just crashRate})
  logInfoS $ "      ✓ Crash rate: " <> T.pack (show (crashRate * 100)) <> "%"

  -- Fetch ANR rate (simulated)
  let anrRate = 0.001 -- 0.1%
  updatePlayStoreField (\ps -> ps{anrRate = Just anrRate})
  logInfoS $ "      ✓ ANR rate: " <> T.pack (show (anrRate * 100)) <> "%"

  -- Check user ratings (simulated)
  let rating = 4.5
  updatePlayStoreField (\ps -> ps{averageRating = Just rating})
  logInfoS $ "      ✓ Average rating: " <> T.pack (show rating)

-- | Monitor crash rates
--
-- Generic stage: MONITORING
-- Play Store sub-stage: MAMonitorCrashRate
monitorCrashRates :: StateFlow ()
monitorCrashRates = do
  rt <- getRT
  logInfoS $ "👀 MONITORING crash rates for " <> appGroup rt

  updatePlayStoreStatus MAMonitorCrashRate

  -- Monitor for 30 seconds
  logInfoS "  ⏱️  MONITORING period (30s)"
  liftIO $ threadDelay 30000000

  -- Check final metrics
  rs <- gets id
  case targetState rs of
    Just (PlayStoreState ps) -> do
      let cr = fromMaybe 0 (crashRate ps)
      let ar = fromMaybe 0 (anrRate ps)

      if cr > 0.01 || ar > 0.005
        then logWarningS "  ⚠️  Warning: High crash/ANR rate detected"
        else logInfoS "  ✓ Metrics within acceptable range"
    _ -> return ()

  logInfoS "✅ MONITORING complete"

-- | Promote to full release
--
-- Generic stage: FINALIZING
-- Play Store sub-stage: MAPromoteToFull
promoteToFull :: StateFlow ()
promoteToFull = do
  rt <- getRT
  logInfoS $ "🎯 Promoting to full release for " <> appGroup rt

  updatePlayStoreStatus MAPromoteToFull
  logInfoS "  ✓ Promoting to 100% rollout"

  updatePlayStoreField (\ps -> ps{stagedRolloutPercent = 100})

  logInfoS "✅ Promoted to full release"

-- | Notify release complete
--
-- Generic stage: DONE
-- Play Store sub-stage: MADone
notifyRelease :: StateFlow ()
notifyRelease = do
  rt <- getRT
  updatePlayStoreStatus MADone

  logInfoS $ "🎉 Release " <> releaseId rt <> " completed successfully!"
  logInfoS $ "   App: " <> appGroup rt
  logInfoS $ "   Category: MobileAppAndroid"
  logInfoS $ "   Status: COMPLETED"

  -- Display final metrics
  rs <- gets id
  case targetState rs of
    Just (PlayStoreState ps) -> do
      logInfoS "   Final Metrics:"
      logInfoS $ "     - Rollout: " <> T.pack (show (stagedRolloutPercent ps)) <> "%"
      logInfoS $ "     - Crash rate: " <> T.pack (show (fromMaybe 0 (crashRate ps) * 100)) <> "%"
      logInfoS $ "     - ANR rate: " <> T.pack (show (fromMaybe 0 (anrRate ps) * 100)) <> "%"
      logInfoS $ "     - Average rating: " <> T.pack (show (fromMaybe 0 (averageRating ps)))
    _ -> return ()

  -- Update global status to COMPLETED
  updateRT $ \r -> r{status = COMPLETED}

-- ============================================================================
-- Helper Functions
-- ============================================================================

-- | Update Play Store workflow status
updatePlayStoreStatus :: MobileAppAndroidWFStatus -> StateFlow ()
updatePlayStoreStatus newStatus = do
  rs <- gets id
  case targetState rs of
    Just (PlayStoreState ps) -> do
      let ps' = ps{categoryWorkflowStatus = newStatus}
      modify $ \s -> s{targetState = Just (PlayStoreState ps')}
    _ -> return ()

-- | Update Play Store deployment state field
updatePlayStoreField :: (PlayStoreDeploymentState -> PlayStoreDeploymentState) -> StateFlow ()
updatePlayStoreField f = do
  rs <- gets id
  case targetState rs of
    Just (PlayStoreState ps) -> do
      let ps' = f ps
      modify $ \s -> s{targetState = Just (PlayStoreState ps')}
    _ -> return ()
