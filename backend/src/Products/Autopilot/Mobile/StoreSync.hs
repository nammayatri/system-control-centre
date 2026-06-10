{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | Periodic sync of live store versions into @release_tracker@.

Polls Google Play (production track) and App Store Connect for every
enabled app in @app_catalog@. If the store version is newer than the
latest COMPLETED row in @release_tracker@, inserts a synthetic
COMPLETED row so the "latest build" badges on the frontend stay fresh
even for releases shipped outside SCC.

Entry point: 'runStoreSync' — designed to be called from a long-interval
background loop in 'Products.Autopilot.Runner'.
-}
module Products.Autopilot.Mobile.StoreSync (
    runStoreSync,
    storeSyncLoop,
) where

import Control.Exception (SomeException)
import qualified Control.Monad.Catch as MC
import Control.Monad.IO.Class (liftIO)
import Core.Environment (Flow, MonadFlow, forkFlow, logError, logInfo, logWarning)
import Core.Types.Time (threadDelaySec)
import Data.Aeson (object, (.=))
import Data.Char (isAlphaNum)
import Data.Int (Int32)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import Products.Autopilot.Mobile.Queries.AppCatalog (
    LatestBuildRow (..),
    fetchLatestBuildsPerApp,
    listEnabledAppCatalog,
 )
import Products.Autopilot.Mobile.Types (
    MobileBuildContext (..),
    MobileBuildTargetState (..),
    MobileBuildWFStatus (..),
    isDebugBuildType,
 )
import Products.Autopilot.Mobile.Types.Storage (AppCatalog, AppCatalogT (..))
import Products.Autopilot.Mobile.Versioning.Apple (
    AscCreds,
    fetchAscVersions,
    loadAscCreds,
    renderAscErr,
 )
import Products.Autopilot.Mobile.Versioning.Play (
    PlayCreds (..),
    TrackInfo (..),
    fetchPlayTracks,
    loadPlayCreds,
    renderPlayErr,
 )
import Products.Autopilot.Queries.ReleaseTracker (
    encodeJsonText,
    insertReleaseEvent,
    insertReleaseTrackerRowIfAbsent,
 )
import Products.Autopilot.RuntimeConfig (getMobileBuildType, getStoreSyncIntervalMinutes, isStoreSyncEnabled)
import Products.Autopilot.Types.Storage.Schema (ReleaseTrackerT (..))
import Products.Autopilot.Types.Target (TargetState (..))

type BuildMap = Map.Map (Text, Text, Text) LatestBuildRow

storeSyncLoop :: Flow ()
storeSyncLoop = do
    logInfo "[STORE_SYNC] Background loop started"
    loop
  where
    loop = do
        result <- MC.try @_ @SomeException $ do
            -- Store sync polls PRODUCTION stores and records release builds, so
            -- it only makes sense in a release env. In a debug env it's a no-op
            -- regardless of store_sync_enabled — never pull production data into
            -- a debug deployment.
            buildType <- getMobileBuildType
            enabled <- isStoreSyncEnabled
            if isDebugBuildType buildType
                then logInfo "[STORE_SYNC] Debug build env, skipping (release-only)"
                else
                    if enabled
                        then runStoreSync
                        else logInfo "[STORE_SYNC] Disabled via server_config, skipping"
            interval <- getStoreSyncIntervalMinutes
            threadDelaySec (interval * 60)
        case result of
            Left e ->
                logError $
                    "[STORE_SYNC] Iteration failed (continuing): " <> T.pack (show e)
            Right () -> pure ()
        loop

runStoreSync :: Flow ()
runStoreSync = do
    logInfo "[STORE_SYNC] Starting store sync"
    apps <- listEnabledAppCatalog
    builds <- fetchLatestBuildsPerApp
    let buildMap =
            Map.fromList
                [ ((lbrAppGroup b, lbrSurface b, lbrPlatform b), b)
                | b <- builds
                ]
    mPlayCreds <- loadPlayCreds
    mAscCreds <- loadAscCreds
    mapM_ (syncApp mPlayCreds mAscCreds buildMap) apps
    logInfo $ "[STORE_SYNC] Finished — checked " <> T.pack (show (length apps)) <> " app(s)"

syncApp ::
    Maybe PlayCreds ->
    Maybe AscCreds ->
    BuildMap ->
    AppCatalog ->
    Flow ()
syncApp mPlayCreds mAscCreds buildMap ac = do
    let key = (acName ac, acSurface ac, acPlatform ac)
        existing = Map.lookup key buildMap
    case acPlatform ac of
        "android" -> case mPlayCreds of
            Nothing ->
                logWarning $ "[STORE_SYNC] No Play Console creds — skipping " <> acName ac
            Just creds -> syncAndroid creds ac existing
        "ios" -> case mAscCreds of
            Nothing ->
                logWarning $ "[STORE_SYNC] No ASC creds — skipping " <> acName ac
            Just creds -> syncIos creds ac existing
        p ->
            logWarning $ "[STORE_SYNC] Unknown platform " <> p <> " for " <> acName ac

syncAndroid :: PlayCreds -> AppCatalog -> Maybe LatestBuildRow -> Flow ()
syncAndroid creds ac existing = do
    pkgName <- case acPackageName ac of
        Just p | not (T.null p) -> pure p
        _ -> do
            logWarning $ "[STORE_SYNC] No package name for " <> acName ac <> ", skipping"
            pure ""
    if T.null pkgName
        then pure ()
        else do
            result <- fetchPlayTracks creds pkgName
            case result of
                Left e ->
                    logWarning $
                        "[STORE_SYNC] Play API error for "
                            <> acName ac
                            <> ": "
                            <> renderPlayErr e
                Right (_internal, production) ->
                    when (isNewerAndroid production existing) $ do
                        logInfo $
                            "[STORE_SYNC] New Play version for "
                                <> acName ac
                                <> ": "
                                <> tiName production
                                <> "+"
                                <> T.pack (show (tiCode production))
                        insertSyntheticRelease ac (tiName production) (Just (tiCode production))
  where
    when True a = a
    when False _ = pure ()

syncIos :: AscCreds -> AppCatalog -> Maybe LatestBuildRow -> Flow ()
syncIos creds ac existing = do
    bundleId <- case acPackageName ac of
        Just p | not (T.null p) -> pure p
        _ -> do
            logWarning $ "[STORE_SYNC] No bundle id for " <> acName ac <> ", skipping"
            pure ""
    if T.null bundleId
        then pure ()
        else do
            result <- fetchAscVersions creds bundleId
            case result of
                Left e ->
                    logWarning $
                        "[STORE_SYNC] ASC API error for "
                            <> acName ac
                            <> ": "
                            <> renderAscErr e
                Right Nothing ->
                    logInfo $ "[STORE_SYNC] No ASC version found for " <> acName ac
                Right (Just ver) ->
                    when' (isNewerIos ver existing) $ do
                        logInfo $
                            "[STORE_SYNC] New ASC version for "
                                <> acName ac
                                <> ": "
                                <> ver
                        insertSyntheticRelease ac ver Nothing
  where
    when' True a = a
    when' False _ = pure ()

isNewerAndroid :: TrackInfo -> Maybe LatestBuildRow -> Bool
isNewerAndroid store Nothing = tiName store /= "0.0.0"
isNewerAndroid store (Just lb)
    | tiName store /= lbrVersion lb = tiName store /= "0.0.0"
    | otherwise = tiCode store > fromMaybe 0 (lbrVersionCode lb)

isNewerIos :: Text -> Maybe LatestBuildRow -> Bool
isNewerIos _ Nothing = True
isNewerIos ver (Just lb) = ver /= lbrVersion lb

-- Store sync only ever observes production store releases, so synthetic
-- rows are always "release" build type.
insertSyntheticRelease ::
    (MonadFlow m) =>
    AppCatalog ->
    Text ->
    Maybe Int32 ->
    m ()
insertSyntheticRelease ac version mCode = do
    rid <- liftIO (UUID.toText <$> UUID.nextRandom)
    groupId <- liftIO (UUID.toText <$> UUID.nextRandom)
    now <- liftIO getCurrentTime
    let segment = normalizeAppSegment (acName ac)
        -- Match the surface's tag scheme (see Workflow.execConfirmTag):
        --   consumer: {normalize(app)}/prod/{platform}/v{version}+{code}
        --   provider: {acName}-v{version}-{code}
        derivedTag = case mCode of
            Just code
                | acSurface ac == "driver" ->
                    Just (acName ac <> "-v" <> version <> "-" <> T.pack (show code))
                | otherwise ->
                    Just (segment <> "/prod/" <> acPlatform ac <> "/v" <> version <> "+" <> T.pack (show code))
            Nothing -> Nothing
        ctx =
            MobileBuildContext
                { mbcVersionCode = mCode
                , mbcChangeLog = "Synced from store"
                , mbcBuildType = "release"
                , mbcReleaseGroupId = groupId
                , mbcMatrixJobName = acName ac <> "-Release"
                , mbcOtaNamespace = Nothing
                , mbcTagPushed = derivedTag
                , mbcDestination = Nothing
                }
        targetState =
            MobileBuildTargetState
                { mbWfStatus = MBCompleted
                , mbContext = ctx
                , mbExternalRunId = Nothing
                , mbMatrixJobStatus = Just "completed"
                , mbBuildStartedAt = Just now
                , mbBuildCompletedAt = Just now
                , mbResolveAttempts = Nothing
                }
        encodedCtx = encodeJsonText (MobileBuildState targetState)
        row =
            ReleaseTrackerT
                { rtId = rid
                , rtOldVersion = ""
                , rtNewVersion = version
                , rtAppGroup = acName ac
                , rtService = acSurface ac
                , rtPriority = 0
                , rtEnv = acPlatform ac
                , rtCategory = "MobileBuild"
                , rtStatus = "COMPLETED"
                , rtReleaseWFStatus = "COMPLETED"
                , rtMode = Just "STORE_SYNC"
                , rtCreatedBy = "store-sync"
                , rtApprovedBy = Nothing
                , rtIsApproved = Just True
                , rtIsInfraApproved = Just True
                , rtReleaseTag = Just rid
                , rtScheduleTime = Nothing
                , rtStartTime = Just now
                , rtEndTime = Just now
                , rtRolloutStrategy = Nothing
                , rtRolloutHistory = Nothing
                , rtTargetState = Just encodedCtx
                , rtInfo = Nothing
                , rtDescription = Just "Imported from store API"
                , rtChangeLog = Nothing
                , rtMetadata = Nothing
                , rtGlobalId = Nothing
                , rtSyncEnabled = Nothing
                , rtEnvOverrideData = Nothing
                , rtSlackThreadTs = Nothing
                , rtDispatchId = Nothing
                , rtExternalRunId = Nothing
                , rtCommitSha = Nothing
                , rtSourceRef = Nothing
                , rtRevertsReleaseId = Nothing
                , rtAbValidation = Nothing
                , rtAbValidationStatus = Nothing
                , rtCreatedAt = now
                , rtUpdatedAt = now
                }
    -- ON CONFLICT DO NOTHING against uq_release_tracker_store_sync: if a
    -- concurrent pass / replica already recorded this app+version, skip cleanly.
    inserted <- insertReleaseTrackerRowIfAbsent row
    if not inserted
        then
            logInfo $
                "[STORE_SYNC] Skipped duplicate synthetic release for "
                    <> acName ac
                    <> " v"
                    <> version
                    <> " (already recorded)"
        else do
            insertReleaseEvent rid "BUSINESS" "STORE_SYNC" $
                object
                    [ "app" .= acName ac
                    , "platform" .= acPlatform ac
                    , "version" .= version
                    , "version_code" .= mCode
                    , "build_type" .= ("release" :: Text)
                    ]
            logInfo $
                "[STORE_SYNC] Inserted synthetic release "
                    <> rid
                    <> " for "
                    <> acName ac
                    <> " v"
                    <> version
                    <> maybe "" (\t -> " (tag: " <> t <> ")") derivedTag

normalizeAppSegment :: Text -> Text
normalizeAppSegment = collapseDashes . T.map step . T.toLower
  where
    step c
        | isAlphaNum c = c
        | otherwise = '-'
    collapseDashes :: Text -> Text
    collapseDashes t =
        T.dropWhile (== '-') $
            T.dropWhileEnd (== '-') $
                T.intercalate "-" $
                    filter (not . T.null) (T.splitOn "-" t)
