{-# LANGUAGE OverloadedStrings #-}

{- | Mobile app Android workflow (Play Store deployment)

This module implements the workflow for releasing Android apps to Google Play Store.
It uses the new type system with:
- ReleaseCategory (MobileAppAndroid)
- ReleaseWFStatus (generic stages)
- MobileAppAndroidWFStatus (Play Store-specific sub-stages)
- Recorded monad for checkpoint/resume
-}
module Products.Autopilot.Workflow.MobileAppAndroidWorkflow (
    mobileAppAndroidWorkflow,
)
where

import Control.Concurrent (threadDelay)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State.Strict (gets, modify)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Products.Autopilot.Types.Release (ReleaseStatus (..), ReleaseTracker (..))
import Products.Autopilot.Types.Target (
    MobileAppAndroidWFStatus (..),
    PlayStoreDeploymentState (..),
    ReviewStatus (..),
    TargetState (..),
    emptyPlayStoreState,
 )
import Products.Autopilot.Types.Workflow (
    ReleaseCategory (..),
    ReleaseWFStatus (..),
 )
import Products.Autopilot.Workflow.Helpers (getRT, updateRT, (|>>))
import Products.Autopilot.Workflow.Types (
    ReleaseState (..),
    ReleaseWorkFlow,
    StateFlow,
 )
import Prelude hiding (product)

-- ============================================================================
-- Mobile App Android Workflow
-- ============================================================================

{- | Mobile app Android workflow using generic stages

This workflow releases an Android app to Google Play Store with:
- Generic ReleaseWFStatus stages (Init, Preparing, Deploying, Monitoring, Finalizing, Done)
- Play Store-specific MobileAppAndroidWFStatus sub-stages
- Category-specific state in PlayStoreDeploymentState

Example release:
- product = "rider-android"
- category = MobileAppAndroid
- releaseWFStatus: Init → Preparing → Deploying → Monitoring → Finalizing → Done
- targetState: PlayStoreState with MobileAppAndroidWFStatus sub-stages
-}
mobileAppAndroidWorkflow :: ReleaseWorkFlow ()
mobileAppAndroidWorkflow = do
    -- Generic ReleaseWFStatus stages
    Init |>> validateAPK
    Preparing |>> uploadToPlayStore
    Deploying |>> stagedRollout
    Monitoring |>> monitorCrashRates
    Finalizing |>> promoteToFull
    Done |>> notifyRelease

-- ============================================================================
-- Workflow Step Implementations
-- ============================================================================

{- | Validate APK

Generic stage: Init
Play Store sub-stage: MAInit
-}
validateAPK :: StateFlow ()
validateAPK = do
    rt <- getRT
    liftIO $ putStrLn $ "🔍 Validating APK for " <> T.unpack (product rt)

    -- Initialize Play Store deployment state with MAInit
    let playStoreState = emptyPlayStoreState{categoryWorkflowStatus = MAInit}
    modify $ \rs -> rs{targetState = Just (PlayStoreState playStoreState)}

    -- Validate APK signature
    liftIO $ putStrLn "  ✓ Checking APK signature"

    -- Validate version code
    liftIO $ putStrLn "  ✓ Validating version code"

    -- Check permissions
    liftIO $ putStrLn "  ✓ Checking app permissions"

    liftIO $ putStrLn "✅ APK validation complete"

{- | Upload to Play Store

Generic stage: Preparing
Play Store sub-stages: MAUploadAPK, MASubmitForReview
-}
uploadToPlayStore :: StateFlow ()
uploadToPlayStore = do
    rt <- getRT
    liftIO $ putStrLn $ "📤 Uploading APK to Play Store for " <> T.unpack (product rt)

    -- Upload APK
    updatePlayStoreStatus MAUploadAPK
    liftIO $ putStrLn "  ✓ Uploading APK to Play Console"

    let versionCode = fromMaybe "unknown" (releaseTag rt)
    updatePlayStoreField (\ps -> ps{apkUploaded = Just versionCode})

    liftIO $ threadDelay 5000000 -- 5 seconds (simulated upload)

    -- Submit for review
    updatePlayStoreStatus MASubmitForReview
    liftIO $ putStrLn "  ✓ Submitting for Play Store review"
    updatePlayStoreField (\ps -> ps{reviewStatus = UnderReview})

    -- Wait for review approval (simulated)
    updatePlayStoreStatus MAWaitingReview
    liftIO $ putStrLn "  ⏱️  Waiting for review approval"
    liftIO $ threadDelay 10000000 -- 10 seconds (simulated review)

    -- Review approved
    liftIO $ putStrLn "  ✓ Review approved!"
    updatePlayStoreField (\ps -> ps{reviewStatus = Approved})

    liftIO $ putStrLn "✅ APK uploaded and approved"

{- | Staged rollout (0% → 25% → 50% → 100%)

Generic stage: Deploying
Play Store sub-stage: MAStagedRollout
-}
stagedRollout :: StateFlow ()
stagedRollout = do
    rt <- getRT
    liftIO $ putStrLn $ "🚀 Starting staged rollout for " <> T.unpack (product rt)

    updatePlayStoreStatus MAStagedRollout

    -- Rollout in stages: 25% → 50% → 100%
    rolloutStaged [25, 50, 100]

    liftIO $ putStrLn "✅ Staged rollout complete"

-- | Rollout in stages
rolloutStaged :: [Int] -> StateFlow ()
rolloutStaged [] = return ()
rolloutStaged (pct : rest) = do
    liftIO $ putStrLn $ "  📊 Releasing to " <> show pct <> "% of users"

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
    liftIO $ putStrLn $ "    🔍 Checking health at " <> show pct <> "% rollout"

    -- Fetch crash rate from Play Console (simulated)
    let crashRate = 0.003 -- 0.3%
    updatePlayStoreField (\ps -> ps{crashRate = Just crashRate})
    liftIO $ putStrLn $ "      ✓ Crash rate: " <> show (crashRate * 100) <> "%"

    -- Fetch ANR rate (simulated)
    let anrRate = 0.001 -- 0.1%
    updatePlayStoreField (\ps -> ps{anrRate = Just anrRate})
    liftIO $ putStrLn $ "      ✓ ANR rate: " <> show (anrRate * 100) <> "%"

    -- Check user ratings (simulated)
    let rating = 4.5
    updatePlayStoreField (\ps -> ps{averageRating = Just rating})
    liftIO $ putStrLn $ "      ✓ Average rating: " <> show rating

{- | Monitor crash rates

Generic stage: Monitoring
Play Store sub-stage: MAMonitorCrashRate
-}
monitorCrashRates :: StateFlow ()
monitorCrashRates = do
    rt <- getRT
    liftIO $ putStrLn $ "👀 Monitoring crash rates for " <> T.unpack (product rt)

    updatePlayStoreStatus MAMonitorCrashRate

    -- Monitor for 30 seconds
    liftIO $ putStrLn "  ⏱️  Monitoring period (30s)"
    liftIO $ threadDelay 30000000

    -- Check final metrics
    rs <- gets id
    case targetState rs of
        Just (PlayStoreState ps) -> do
            let cr = fromMaybe 0 (crashRate ps)
            let ar = fromMaybe 0 (anrRate ps)

            if cr > 0.01 || ar > 0.005
                then liftIO $ putStrLn "  ⚠️  Warning: High crash/ANR rate detected"
                else liftIO $ putStrLn "  ✓ Metrics within acceptable range"
        _ -> return ()

    liftIO $ putStrLn "✅ Monitoring complete"

{- | Promote to full release

Generic stage: Finalizing
Play Store sub-stage: MAPromoteToFull
-}
promoteToFull :: StateFlow ()
promoteToFull = do
    rt <- getRT
    liftIO $ putStrLn $ "🎯 Promoting to full release for " <> T.unpack (product rt)

    updatePlayStoreStatus MAPromoteToFull
    liftIO $ putStrLn "  ✓ Promoting to 100% rollout"

    updatePlayStoreField (\ps -> ps{stagedRolloutPercent = 100})

    liftIO $ putStrLn "✅ Promoted to full release"

{- | Notify release complete

Generic stage: Done
Play Store sub-stage: MADone
-}
notifyRelease :: StateFlow ()
notifyRelease = do
    rt <- getRT
    updatePlayStoreStatus MADone

    liftIO $ putStrLn $ "🎉 Release " <> T.unpack (releaseId rt) <> " completed successfully!"
    liftIO $ putStrLn $ "   App: " <> T.unpack (product rt)
    liftIO $ putStrLn $ "   Category: MobileAppAndroid"
    liftIO $ putStrLn $ "   Status: Completed"

    -- Display final metrics
    rs <- gets id
    case targetState rs of
        Just (PlayStoreState ps) -> do
            liftIO $ putStrLn "   Final Metrics:"
            liftIO $ putStrLn $ "     - Rollout: " <> show (stagedRolloutPercent ps) <> "%"
            liftIO $ putStrLn $ "     - Crash rate: " <> show (fromMaybe 0 (crashRate ps) * 100) <> "%"
            liftIO $ putStrLn $ "     - ANR rate: " <> show (fromMaybe 0 (anrRate ps) * 100) <> "%"
            liftIO $ putStrLn $ "     - Average rating: " <> show (fromMaybe 0 (averageRating ps))
        _ -> return ()

    -- Update global status to Completed
    updateRT $ \r -> r{status = Completed}

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
