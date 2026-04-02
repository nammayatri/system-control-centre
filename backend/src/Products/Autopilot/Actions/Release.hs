{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Products.Autopilot.Actions.Release
    ( -- * Release Handlers
      createReleaseH
    , getReleaseH
    , listReleasesH
    , approveReleaseH
    , triggerReleaseH
    , rollbackReleaseH
    , revertReleaseH
    , revertByGlobalIdH
    , immediateRevertByGlobalIdH
    , discardReleaseH
    , deleteReleaseH
    , updateTrackerH
    , immediateRevertH
    , restartReleaseH
    , fastForwardH
    , releaseDiffH
    , podHealthH
    , rolloutHistoryH
    , listEventsH
    , logsLinkH
    -- * Product/Service Handlers (used in Routes wiring)
    , listProductsH
    , upsertProductH
    , listServicesH
    , upsertServiceH
    -- * Helpers exported for other modules
    , isValidK8sVersion
    ) where

import Control.Applicative ((<|>))
import Control.Monad (void, when)
import Control.Monad.IO.Class (liftIO)
import Core.Config (Config (..))
import Core.DB.Connection (withConn)
import Database.PostgreSQL.Simple (Only (..), execute, withTransaction)
import Data.Char (isAlphaNum)
import Products.Autopilot.RuntimeConfig (isApproveAllReleases, isUnderMaintenance)
import Products.Autopilot.K8s.Deployment (deploymentExists)
import Core.Utils.FlowMonad (Flow, getConfig, getDBEnv)
import Data.Aeson (Value (..), eitherDecode, object, toJSON, (.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime, parseTimeM)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import Products.Autopilot.Discovery (listServicesFromVirtualService)
import Products.Autopilot.K8s.Execute (K8sError (..), K8sResult (..), executeWithRetry, runCmd, shellQuote)
import Products.Autopilot.K8s.Kubectl (getPrimarySubsetFromVirtualService)
import Products.Autopilot.K8s.VirtualService (getVirtualServiceJson)
import Products.Autopilot.Notifications
import GHC.Int (Int32)
import Products.Autopilot.Queries.ProductService
import Products.Autopilot.Queries.ReleaseTracker
import Products.Autopilot.Queries.VsEditTracker ()
import Products.Autopilot.Sync (triggerImmediateRevertSync)
import Products.Autopilot.Workflow.Helpers (captureDeploymentSnapshot, captureDeploymentPreview, captureVSSnapshot)
import Products.Autopilot.Types
import qualified Products.Autopilot.Types as NT
import Products.Autopilot.Types.API
import Products.Autopilot.Types.Target (TargetState (..))
import Products.Autopilot.Types.Target.Kubernetes
import qualified Products.Autopilot.Types.Target.Kubernetes as K8s
import qualified Shared.Types.Storage.Schema as S

-- ============================================================================
-- Product/Service Handlers
-- ============================================================================

upsertProductH :: UpsertProductReq -> Flow APIResponse
upsertProductH UpsertProductReq{..} = do
    db <- getDBEnv
    let rowId = fromMaybe 0 id
        repo = fromMaybe "" repoName
        branch = fromMaybe "master" releaseBranch
    liftIO $ upsertProduct db rowId product cluster namespace vsName repo productType productAcronym branch syncCluster needInfraApproval
    pure $ APIResponse "SUCCESS" "product_config upserted"

listProductsH :: Flow [ProductResponse]
listProductsH = do
    db <- getDBEnv
    rows <- liftIO $ listProducts db
    pure $
        map
            ( \p ->
                ProductResponse
                    { product = S.productName p
                    , cluster = getProductCluster p
                    , namespace = getProductNamespace p
                    , vsName = getProductVsName p
                    , productType = S.productType p
                    , productAcronym = S.productAcronym p
                    , syncCluster = getProductSyncCluster p
                    }
            )
            rows

listServicesH :: Text -> Flow [ServiceResponse]
listServicesH productName' = do
    cfg <- getConfig
    db <- getDBEnv
    products <- liftIO $ listProductsByName db productName'
    case products of
        [] -> pure []
        _ ->
            if any (\p -> S.productType p == "SCHEDULER") products
                then do
                    services <- liftIO $ listSchedulerServicesByProduct db productName'
                    pure $
                        map
                            (\s -> ServiceResponse (S.serviceName s) (getServiceHost s) (S.serviceType s) "DB")
                            services
                else do
                    cfgServices <- liftIO $ listReleaseConfigByProduct db productName'
                    let configuredHosts = fmap getServiceHost cfgServices
                        normalizeHost h = T.takeWhile (/= '.') h
                        hostMatches configured vsHost =
                            let v = normalizeHost vsHost
                             in configured == v || vsHost == configured
                        toResponse h =
                            case find (\s -> maybe False (`hostMatches` h) (getServiceHost s)) cfgServices of
                                Just svc -> ServiceResponse (S.serviceName svc) (getServiceHost svc) (S.serviceType svc) "VIRTUAL_SERVICE"
                                Nothing -> ServiceResponse h (Just h) "SERVICE" "VIRTUAL_SERVICE"
                        pickServices :: [S.ProductConfig] -> IO (Either Text [Text])
                        pickServices [] = pure (Right [])
                        pickServices (pCfg : rest) = do
                            res <- listServicesFromVirtualService cfg (getProductNamespace pCfg) (getProductVsName pCfg)
                            case res of
                                Left _ -> pickServices rest
                                Right hosts ->
                                    let filtered =
                                            filter
                                                (\h -> any (\cfgHost -> maybe False (`hostMatches` h) cfgHost) configuredHosts)
                                                hosts
                                        deduped = foldr (\h acc -> if h `elem` acc then acc else h : acc) [] filtered
                                     in if null filtered
                                            then pickServices rest
                                            else pure (Right deduped)
                    res <- liftIO $ pickServices products
                    case res of
                        Left _ ->
                            -- Fallback: if VirtualService discovery fails (e.g., no K8s locally),
                            -- return services directly from release_config
                            pure $
                                map
                                    (\s -> ServiceResponse (S.serviceName s) (getServiceHost s) (S.serviceType s) "DB")
                                    cfgServices
                        Right hosts
                            | null hosts ->
                                -- If K8s returned empty, also fallback to DB
                                pure $
                                    map
                                        (\s -> ServiceResponse (S.serviceName s) (getServiceHost s) (S.serviceType s) "DB")
                                        cfgServices
                            | otherwise -> pure $ map toResponse hosts

upsertServiceH :: UpsertServiceReq -> Flow APIResponse
upsertServiceH UpsertServiceReq{..} = do
    db <- getDBEnv
    let rowId = fromMaybe 0 id
    liftIO $ upsertService db rowId emails rolloutStrategyText decisionConfigText service product serviceType serviceHost bitbucketPath revertStrategyText
    pure $ APIResponse "SUCCESS" "release_config upserted"

-- ============================================================================
-- Release CRUD Handlers
-- ============================================================================

listReleasesH :: Maybe Text -> Maybe Text -> Flow [ReleaseTracker]
listReleasesH mFrom mTo = do
    db <- getDBEnv
    case (mFrom >>= parseISO, mTo >>= parseISO) of
        (Just fromTime, Just toTime) -> do
            pairs <- liftIO $ listReleaseTrackersByDateRange db fromTime toTime
            pure (map fst pairs)
        _ -> do
            -- No valid date range -- default to last 30 days as safety limit
            now <- liftIO getCurrentTime
            let thirtyDaysAgo = addUTCTime (-30 * 86400) now
            pairs <- liftIO $ listReleaseTrackersByDateRange db thirtyDaysAgo now
            pure (map fst pairs)
  where
    parseISO :: Text -> Maybe UTCTime
    parseISO t =
        parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" (T.unpack t)
            <|> parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (T.unpack t)
            <|> parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Q%Z" (T.unpack t)

createReleaseH :: Maybe Text -> Maybe Text -> K8sCreateReleaseReq -> Flow APIResponse
createReleaseH mXForwardedEmail mXPomeriumJwt req@K8sCreateReleaseReq{..} = do
    cfg <- getConfig
    db <- getDBEnv
    p <- liftIO $ findProductByName db product
    s <- liftIO $ findServiceByProductAndName db product service
    case (p, s) of
        (Nothing, _) -> pure $ APIResponse "ERROR" "Product not configured"
        (_, Nothing) -> pure $ APIResponse "ERROR" "Service not configured for product"
        (Just pCfg, Just sCfg) -> do
            -- Safety check: old_version == new_version
            if oldVersion == newVersion
                then pure $ APIResponse "ERROR" "old_version and new_version cannot be the same"
            -- Safety check: maintenance mode
            else do
              maintenance <- liftIO $ isUnderMaintenance db
              if maintenance
                then pure $ APIResponse "ERROR" "System is under maintenance. Release creation is disabled."
              -- Safety check: version format (K8s label: [a-z0-9]([-a-z0-9]*[a-z0-9])?)
              else if not (isValidK8sVersion newVersion)
                then pure $ APIResponse "ERROR" ("Invalid version format for K8s label: " <> newVersion <> ". Must match [a-z0-9]([-a-z0-9]*[a-z0-9])?")
              -- Existing cluster check
              else if maybe False (/= getProductCluster pCfg) requestedCluster
                then pure $ APIResponse "ERROR" "Requested cluster does not match product config"
              else do
                -- Safety check: duplicate deployment in K8s
                let targetSvcHostForCheck = fromMaybe service (getServiceHost sCfg)
                    newDepNameCheck = targetSvcHostForCheck <> "-" <> newVersion
                depAlreadyExists <- liftIO $ deploymentExists cfg (getProductNamespace pCfg) newDepNameCheck
                if depAlreadyExists && not (fromMaybe False newService)
                    then pure $ APIResponse "ERROR" ("Deployment with version " <> newVersion <> " already exists: " <> newDepNameCheck)
                    else do
                    rid <- liftIO (UUID.toText <$> UUID.nextRandom)
                    let targetSvcHost = fromMaybe service (getServiceHost sCfg)
                        metadataDockerImage =
                            case metadata of
                                Just (Object obj) ->
                                    case KM.lookup (K.fromText "docker-image") obj of
                                        Just (String t) | not (T.null t) -> Just t
                                        _ ->
                                            case KM.lookup (K.fromText "dockerImage") obj of
                                                Just (String t) | not (T.null t) -> Just t
                                                _ -> Nothing
                                _ -> Nothing
                        metadataInternalVsName =
                            case metadata of
                                Just (Object obj) ->
                                    case KM.lookup (K.fromText "internal-vs-name") obj of
                                        Just (String t) | not (T.null t) -> Just t
                                        _ ->
                                            case KM.lookup (K.fromText "internalVsName") obj of
                                                Just (String t) | not (T.null t) -> Just t
                                                _ -> Nothing
                                _ -> Nothing
                    resolvedOldVersion <-
                        if fromMaybe False newService
                            then do
                                -- New service: no old version to discover, set to "new"
                                liftIO $ putStrLn $ "[createReleaseH] New service flag set, skipping old version discovery"
                                pure (if T.null oldVersion then "new" else oldVersion)
                            else
                                if T.toLower oldVersion == "unknown" || T.null oldVersion
                                    then do
                                        discovered <- liftIO $ getPrimarySubsetFromVirtualService cfg (getProductNamespace pCfg) (getProductVsName pCfg) targetSvcHost
                                        pure $ case discovered of
                                            Right (Just subset) -> subset
                                            _ -> oldVersion
                                    else pure oldVersion
                    let derivedContext =
                            K8sReleaseContext
                                { cluster = getProductCluster pCfg
                                , namespace = getProductNamespace pCfg
                                , deploymentName = targetSvcHost <> "-" <> newVersion
                                , serviceName = targetSvcHost
                                , destinationRuleName = targetSvcHost <> "-destinations"
                                , virtualServiceName = getProductVsName pCfg
                                , internalVirtualServiceName = metadataInternalVsName
                                , containerName = targetSvcHost
                                , oldVersion = resolvedOldVersion
                                , newVersion = newVersion
                                , dockerImage = metadataDockerImage
                                , matches = []
                                , podsScaleDownDelay = Nothing
                                , podsScaleDownTimestamp = Nothing
                                , podsScaleDownStatus = Nothing
                                , oldVersionPodCount = Nothing
                                , revert = Nothing
                                , abRunId = Nothing
                                , abStatus = Nothing
                                , cleanupAt = Nothing
                                , cleanupTargetDeployment = Nothing
                                , cleanupStatus = Nothing
                                , deployFilePath = deployFilePath
                                , serviceFilePath = serviceFilePath
                                , drFilePath = drFilePath
                                , vsFilePath = vsFilePath
                                , prevAbHsDecision = Nothing
                                , postMonitoringDecisionMap = Nothing
                                , syncClusterUdf2 = syncClusterUdf2
                                , syncClusterRolloutStrategy = fmap (\v -> T.pack (LBS.unpack (A.encode v))) syncClusterRolloutStrategy
                                , syncXForwardedEmail = mXForwardedEmail
                                , syncXPomeriumJwt = mXPomeriumJwt
                                }
                        reqMode = case mode of
                            Just "MANUAL" -> Manual
                            Just "manual" -> Manual
                            _ -> Auto
                    approveAll <- liftIO $ isApproveAllReleases db
                    now <- liftIO getCurrentTime
                    let initialApproval = case isApproved of
                            Just True -> True
                            _ -> approveAll && fromMaybe False isSystemTriggered
                        -- Auto-generate release tag if not provided
                        autoTag = case releaseTag of
                            Just t | not (T.null t) -> Just t
                            _ ->
                                let datePart = T.pack (formatTime defaultTimeLocale "%Y%m%d" now)
                                    modeText = case reqMode of Auto -> "AUTO"; Manual -> "MANUAL"
                                    priText = T.pack (show (fromMaybe 0 priority))
                                 in Just (T.intercalate "_" [product, datePart, newVersion, service, modeText, env, priText])
                        tracker =
                            ReleaseTracker
                                { releaseId = rid
                                , product = product
                                , service = service
                                , env = env
                                , category = trackerType
                                , status = Created
                                , releaseWFStatus = Init
                                , mode = reqMode
                                , createdBy = createdBy
                                , approvedBy = approvedBy
                                , isApproved = initialApproval
                                , isInfraApproved = fromMaybe (fromMaybe False (S.productNeedInfraApproval pCfg >>= \need -> if need then Just False else Just True)) isInfraApproved
                                , releaseTag = autoTag
                                , dateCreated = Nothing -- DB sets via DEFAULT now()
                                , lastUpdated = Nothing -- DB sets via DEFAULT now()
                                , scheduleTime = scheduleTime
                                , startTime = Nothing
                                , endTime = Nothing
                                , rolloutStrategy = rolloutStrategy
                                , rolloutHistory = []
                                , oldVersion = resolvedOldVersion
                                , newVersion = newVersion
                                , info = info
                                , description = description
                                , changeLog = changeLog
                                , metadata = metadata
                                , priority = fromMaybe 0 priority
                                , globalId = globalId
                                , udf1 = case isReleaseSync of
                                    Just True -> Just "true"
                                    _ -> udf1
                                , udf2 = udf2
                                , udf3 = udf3
                                }
                        targetState =
                            K8sState $
                                emptyK8sState
                                    { context = derivedContext
                                    , newService = fromMaybe False newService
                                    , isArtRecorder = fromMaybe 0 isArtRecorder
                                    , cronjobSuspend = fromMaybe False cronjobSuspend
                                    }
                    liftIO $ insertReleaseTracker db tracker (Just targetState)
                    liftIO $ insertReleaseEvent db rid "BUSINESS" "TRACKER_CREATED" (toJSON tracker)
                    -- Capture BEFORE snapshots at creation time (so diff is available immediately)
                    -- Also generate a preview AFTER by modifying version/image in the old deployment YAML
                    let ns = getProductNamespace pCfg
                        vsN = getProductVsName pCfg
                        oldDepName = targetSvcHost <> "-" <> resolvedOldVersion
                    liftIO $ captureDeploymentSnapshot cfg db rid ns oldDepName "DEPLOYMENT_BEFORE"
                    liftIO $ captureVSSnapshot cfg db rid ns vsN "VS_BEFORE"
                    -- Generate preview AFTER: take old deployment, replace version + image
                    liftIO $ captureDeploymentPreview cfg db rid ns oldDepName newVersion
                        (fromMaybe "" metadataDockerImage) "DEPLOYMENT_AFTER"
                    liftIO $ notifyReleaseCreated db tracker
                    pure $ APIResponse "SUCCESS" ("Tracker created: " <> rid)

getReleaseH :: Text -> Flow (Maybe ReleaseTracker)
getReleaseH rid = do
    db <- getDBEnv
    m <- liftIO $ findReleaseTracker db rid
    pure (fmap fst m)

approveReleaseH :: Text -> ApproveReleaseReq -> Flow (Maybe ReleaseTracker)
approveReleaseH rid req = do
    db <- getDBEnv
    m <- liftIO $ findReleaseTracker db rid
    case m of
        Nothing -> pure Nothing
        Just (tracker, mTargetState) -> do
            let approver = req.approvedBy
                infraApproval = req.isInfraApproved
                updated =
                    (tracker :: ReleaseTracker)
                        { NT.approvedBy = Just approver
                        , NT.isApproved = True
                        , NT.isInfraApproved = fromMaybe (NT.isInfraApproved tracker) infraApproval
                        }
            liftIO $ insertReleaseTracker db updated mTargetState
            liftIO $ insertReleaseEvent db rid "BUSINESS" "TRACKER_APPROVED" (toJSON approver)
            liftIO $ notifyReleaseApproved db updated
            pure (Just updated)

triggerReleaseH :: Text -> TriggerReleaseReq -> Flow APIResponse
triggerReleaseH rid TriggerReleaseReq{..} = do
    db <- getDBEnv
    m <- liftIO $ findReleaseTracker db rid
    case m of
        Nothing -> pure $ APIResponse "ERROR" "Release not found"
        Just (tracker, mTargetState) -> do
            if isTerminalStatus (NT.status tracker)
                then pure $ APIResponse "ERROR" ("Cannot trigger from terminal status: " <> T.pack (show (NT.status tracker)))
                else do
                    now <- liftIO getCurrentTime
                    let updated = (tracker :: ReleaseTracker){NT.scheduleTime = Just now, NT.status = Created}
                    liftIO $ insertReleaseTracker db updated mTargetState
                    liftIO $ insertReleaseEvent db rid "BUSINESS" "TRACKER_TRIGGERED" (toJSON reason)
                    pure $ APIResponse "SUCCESS" "Release scheduled for execution"

rollbackReleaseH :: Text -> TriggerReleaseReq -> Flow APIResponse
rollbackReleaseH rid TriggerReleaseReq{..} = do
    db <- getDBEnv
    m <- liftIO $ findReleaseTracker db rid
    case m of
        Nothing -> pure $ APIResponse "ERROR" "Release not found"
        Just (tracker, mTargetState) -> do
            if not (validateStatusTransition (NT.status tracker) Aborting)
                then pure $ APIResponse "ERROR" ("Cannot rollback from status: " <> T.pack (show (NT.status tracker)))
                else do
                    let updated = (tracker :: ReleaseTracker){NT.status = Aborting, NT.releaseWFStatus = RollingBack}
                    liftIO $ insertReleaseTracker db updated mTargetState
                    liftIO $ insertReleaseEvent db rid "BUSINESS" "ROLLBACK_REQUESTED" (toJSON reason)
                    pure $ APIResponse "SUCCESS" "Rollback marked"

revertReleaseH :: Text -> RevertReleaseReq -> Flow APIResponse
revertReleaseH rid req = do
    cfg <- getConfig
    db <- getDBEnv
    m <- liftIO $ findReleaseTracker db rid
    case m of
        Nothing -> pure $ APIResponse "ERROR" "Release not found"
        Just (tracker, mTargetState) -> do
            let oldCtx = case mTargetState of
                    Just (K8sState k8s) -> context k8s
                    _ -> defaultK8sReleaseContext
                ctxOldVersion = oldCtx.oldVersion
                ctxNewVersion = oldCtx.newVersion
                ctxServiceName = oldCtx.serviceName
            -- Safety check: verify old deployment exists before creating revert
            let oldDepName = ctxServiceName <> "-" <> ctxOldVersion
            oldDepExists <- liftIO $ deploymentExists cfg (oldCtx.namespace) oldDepName
            if not oldDepExists && not (T.null ctxOldVersion) && ctxOldVersion /= "new" && ctxOldVersion /= "unknown"
                then pure $ APIResponse "ERROR" ("Old deployment not found in K8s: " <> oldDepName <> ". Cannot revert.")
                else do
                    now <- liftIO getCurrentTime
                    newRid <- liftIO (UUID.toText <$> UUID.nextRandom)
                    let trackerCreatedBy = NT.createdBy tracker
                        isImmediate = fromMaybe False (immediate req)
                        origUdf1 = maybe False (\t -> T.toLower t == "true") (NT.udf1 tracker)
                        shouldSyncRevert = fromMaybe False ((req :: RevertReleaseReq).isRevertSync) && origUdf1
                        revertedContext =
                            oldCtx
                                { deploymentName = ctxServiceName <> "-" <> ctxOldVersion
                                , oldVersion = ctxNewVersion
                                , newVersion = ctxOldVersion
                                , abRunId = Nothing
                                , abStatus = Nothing
                                , cleanupAt = Nothing
                                , cleanupTargetDeployment = Nothing
                                , cleanupStatus = Nothing
                                , podsScaleDownDelay = Nothing
                                , podsScaleDownTimestamp = Nothing
                                , podsScaleDownStatus = Nothing
                                , revert = Just 1
                                , prevAbHsDecision = Nothing
                                , postMonitoringDecisionMap = Nothing
                                }
                        revertedTargetState = K8sState $ emptyK8sState{context = revertedContext}
                        revertedTracker =
                            (tracker :: ReleaseTracker)
                                { NT.releaseId = newRid
                                , NT.status = Created
                                , NT.releaseWFStatus = Init
                                , NT.createdBy = fromMaybe trackerCreatedBy ((req :: RevertReleaseReq).requestedBy)
                                , NT.approvedBy = if isImmediate then Just (fromMaybe trackerCreatedBy ((req :: RevertReleaseReq).requestedBy)) else Nothing
                                , NT.isApproved = isImmediate
                                , NT.scheduleTime = Just now
                                , NT.startTime = Nothing
                                , NT.endTime = Nothing
                                , NT.rolloutHistory = []
                                , NT.releaseTag = fmap (<> "_REVERT") (NT.releaseTag tracker)
                                , NT.info = (req :: RevertReleaseReq).info
                                , NT.udf1 = if shouldSyncRevert then Just "true" else Nothing
                                }
                    liftIO $ insertReleaseTracker db revertedTracker (Just revertedTargetState)
                    liftIO $
                        insertReleaseEvent
                            db
                            newRid
                            "BUSINESS"
                            "REVERT_TRACKER_CREATED"
                            ( object
                                [ "originalId" .= rid
                                , "shouldSyncRevert" .= shouldSyncRevert
                                , "isImmediate" .= isImmediate
                                , "origUdf1" .= (origUdf1 :: Bool)
                                ]
                            )
                    liftIO $ notifyReleaseReverted db revertedTracker
                    when (isImmediate && shouldSyncRevert) $
                        liftIO $
                            triggerImmediateRevertSync cfg db tracker mTargetState
                    pure $ APIResponse "SUCCESS" ("Revert tracker created: " <> newRid)

revertByGlobalIdH :: Text -> Flow APIResponse
revertByGlobalIdH gid = do
    db <- getDBEnv
    m <- liftIO $ findReleaseTrackerByGlobalId db gid
    case m of
        Nothing -> pure $ APIResponse "ERROR" ("No release found with global_id=" <> gid)
        Just (tracker, _) -> revertReleaseH (releaseId tracker) (RevertReleaseReq Nothing Nothing Nothing Nothing)

immediateRevertByGlobalIdH :: Text -> Flow APIResponse
immediateRevertByGlobalIdH gid = do
    db <- getDBEnv
    m <- liftIO $ findReleaseTrackerByGlobalId db gid
    case m of
        Nothing -> pure $ APIResponse "ERROR" ("No release found with global_id=" <> gid)
        Just (tracker, _) -> revertReleaseH (releaseId tracker) (RevertReleaseReq Nothing Nothing (Just True) Nothing)

discardReleaseH :: Text -> DiscardReleaseReq -> Flow APIResponse
discardReleaseH rid DiscardReleaseReq{..} = do
    db <- getDBEnv
    m <- liftIO $ findReleaseTracker db rid
    case m of
        Nothing -> pure $ APIResponse "ERROR" "Release not found"
        Just (tracker, mTargetState) ->
            if not (validateStatusTransition (NT.status tracker) Discarded)
                then pure $ APIResponse "ERROR" ("Cannot discard from status: " <> T.pack (show (NT.status tracker)))
                else do
                    let updated = (tracker :: ReleaseTracker){NT.status = Discarded}
                    liftIO $ insertReleaseTracker db updated mTargetState
                    liftIO $
                        insertReleaseEvent
                            db
                            rid
                            "BUSINESS"
                            "STATUS_UPDATED"
                            (toJSON ("Tracker marked as DISCARDED" <> maybe "" (": " <>) reason))
                    liftIO $ notifyReleaseDiscarded db updated
                    pure $ APIResponse "SUCCESS" "Release discarded"

deleteReleaseH :: Text -> Flow APIResponse
deleteReleaseH rid = do
    db <- getDBEnv
    mTracker <- liftIO $ findReleaseTracker db rid
    case mTracker of
        Nothing -> pure $ APIResponse "ERROR" "Release not found"
        Just (tracker, _) -> do
            -- Block deletion of active releases (InProgress, Aborting, Reverting, Paused, Restarting)
            let activeStatuses = [InProgress, Aborting, Reverting, Paused, Restarting]
            if NT.status tracker `elem` activeStatuses
                then pure $ APIResponse "ERROR" ("Cannot delete release in " <> T.pack (show (NT.status tracker)) <> " status. Abort or complete it first.")
                else do
                    liftIO $ withConn db $ \conn -> withTransaction conn $ do
                        execute conn "DELETE FROM release_events WHERE re_release_id = ?" (Only rid)
                        execute conn "DELETE FROM release_tracker WHERE id = ?" (Only rid)
                    liftIO $ notifyReleaseDeleted db tracker
                    pure $ APIResponse "SUCCESS" ("Release deleted: " <> rid)

updateTrackerH :: Text -> K8sUpdateTrackerReq -> Flow APIResponse
updateTrackerH rid req = do
    db <- getDBEnv
    m <- liftIO $ findReleaseTracker db rid
    case m of
        Nothing -> pure $ APIResponse "ERROR" "Release not found"
        Just (tracker, mTargetState) -> do
            let (updatedTracker, updatedTargetState) = applyUpdates tracker mTargetState req
            case (req :: K8sUpdateTrackerReq).status of
                Just newStatusText -> do
                    let newStatus = parseReleaseStatus newStatusText
                    if not (validateStatusTransition (NT.status tracker) newStatus)
                        then pure $ APIResponse "ERROR" ("Invalid status transition: " <> T.pack (show (NT.status tracker)) <> " -> " <> newStatusText)
                        else do
                            liftIO $ insertReleaseTracker db updatedTracker updatedTargetState
                            liftIO $ insertReleaseEvent db rid "BUSINESS" "TRACKER_UPDATED" (toJSON updatedTracker)
                            -- Send status-specific Slack notifications
                            case newStatus of
                                Paused -> liftIO $ notifyReleasePaused db updatedTracker
                                InProgress -> liftIO $ notifyReleaseResumed db updatedTracker
                                Aborting -> liftIO $ notifyReleaseAborted db updatedTracker
                                Completed -> liftIO $ notifyReleaseCompleted db updatedTracker
                                _ -> liftIO $ notifyReleaseUpdated db updatedTracker ("status changed to " <> newStatusText)
                            pure $ APIResponse "SUCCESS" "Tracker updated"
                Nothing -> do
                    liftIO $ insertReleaseTracker db updatedTracker updatedTargetState
                    liftIO $ insertReleaseEvent db rid "BUSINESS" "TRACKER_UPDATED" (toJSON updatedTracker)
                    liftIO $ notifyReleaseUpdated db updatedTracker "status/fields updated"
                    pure $ APIResponse "SUCCESS" "Tracker updated"

applyUpdates :: ReleaseTracker -> Maybe TargetState -> K8sUpdateTrackerReq -> (ReleaseTracker, Maybe TargetState)
applyUpdates tracker mts req =
    let t1 = case req.status of
            Just s -> (tracker :: ReleaseTracker){NT.status = parseReleaseStatus s}
            Nothing -> tracker
        t2 = case req.mode of
            Just "MANUAL" -> t1{NT.mode = Manual}
            Just "AUTO" -> t1{NT.mode = Auto}
            _ -> t1
        t3 = case req.releaseManager of
            Just rm -> t2{NT.createdBy = rm}
            Nothing -> t2
        t4 = case req.priority of
            Just p -> t3{NT.priority = p}
            Nothing -> t3
        t5 = case req.scheduleTime of
            Just st -> t4{NT.scheduleTime = Just st}
            Nothing -> t4
        t6 = case req.description of
            Just d -> t5{NT.description = Just d}
            Nothing -> t5
        t7 = case req.info of
            Just i -> t6{NT.info = Just i}
            Nothing -> t6
        t8 = case req.rolloutStrategy of
            Just rs -> t7{NT.rolloutStrategy = rs}
            Nothing -> t7
        t9 = case req.changeLog of
            Just cl -> t8{NT.changeLog = Just cl}
            Nothing -> t8
        t10 = case req.isApproved of
            Just a -> t9{NT.isApproved = a}
            Nothing -> t9
        t11 = case req.isInfraApproved of
            Just a -> t10{NT.isInfraApproved = a}
            Nothing -> t10
        t12 = case req.udf1 of
            Just u -> t11{NT.udf1 = Just u}
            Nothing -> t11
        t13 = case req.udf2 of
            Just u -> t12{NT.udf2 = Just u}
            Nothing -> t12
        t14 = case req.udf3 of
            Just u -> t13{NT.udf3 = Just u}
            Nothing -> t13
        ts1 = case req.dockerImage of
            Just img -> updateK8sContext mts (\ctx -> ctx{dockerImage = Just img})
            Nothing -> mts
        ts2 = case req.podsScaleDownDelay of
            Just d -> updateK8sContext ts1 (\ctx -> ctx{podsScaleDownDelay = Just d})
            Nothing -> ts1
     in (t14, ts2)

updateK8sContext :: Maybe TargetState -> (K8sReleaseContext -> K8sReleaseContext) -> Maybe TargetState
updateK8sContext (Just (K8sState k8s)) f = Just $ K8sState $ k8s{context = f (context k8s)}
updateK8sContext other _ = other

listEventsH :: Text -> Flow [ReleaseEventResponse]
listEventsH rid = do
    db <- getDBEnv
    events <- liftIO $ listReleaseEvents db rid
    pure $
        fmap
            ( \e ->
                ReleaseEventResponse
                    { reCategory = S.reCategory e
                    , reLabel = S.reLabel e
                    , reData = S.rePayload e
                    , reTimestamp = S.reCreatedAt e
                    }
            )
            events

rolloutHistoryH :: Text -> Flow Value
rolloutHistoryH rid = do
    db <- getDBEnv
    m <- liftIO $ findReleaseTracker db rid
    case m of
        Nothing -> pure $ object ["error" .= ("Release not found" :: Text)]
        Just (tracker, _) -> pure $ toJSON (NT.rolloutHistory tracker)

-- ============================================================================
-- Logs Link Endpoint (GET /releases/:id/logslink)
-- ============================================================================

logsLinkH :: Text -> Flow Value
logsLinkH rid = do
    db <- getDBEnv
    m <- liftIO $ findReleaseTracker db rid
    case m of
        Nothing -> pure $ object ["error" .= ("Release not found" :: Text)]
        Just (_tracker, _) ->
            -- Return placeholder links -- production generates Grafana URLs from config
            pure $
                object
                    [ "grafana_dashboard" .= ("" :: Text)
                    , "kibana_logs" .= ("" :: Text)
                    , "pod_logs" .= ("" :: Text)
                    ]

-- ============================================================================
-- Diff Endpoint (GET /releases/:id/diff)
-- ============================================================================

releaseDiffH :: Text -> Maybe Text -> Flow DiffResponse
releaseDiffH rid mType = do
    cfg <- getConfig
    db <- getDBEnv
    m <- liftIO $ findReleaseTracker db rid
    case m of
        Nothing -> pure $ DiffResponse "" "" "Release not found"
        Just (tracker, mTargetState) -> do
            -- Check for stored SNAPSHOT events first
            events <- liftIO $ listReleaseEvents db rid
            let snapshotEvents = filter (\e -> S.reCategory e == "SNAPSHOT") events
                diffType = fromMaybe "deployment" mType
                (beforeLabel, afterLabel, diffLabel) = case diffType of
                    "vs" -> ("VS_BEFORE", "VS_AFTER", "VirtualService diff" :: Text)
                    "configmap" -> ("CONFIGMAP_BEFORE", "CONFIGMAP_AFTER", "ConfigMap diff")
                    _ -> ("DEPLOYMENT_BEFORE", "DEPLOYMENT_AFTER", "Deployment diff")
                findSnapshot label = find (\e -> S.reLabel e == label) snapshotEvents
                mBefore = findSnapshot beforeLabel
                mAfter = findSnapshot afterLabel
            let payloadToText :: Value -> Text
                payloadToText (String s) = s  -- Already YAML text from snapshot capture, return as-is
                payloadToText other = TE.decodeUtf8 (LBS.toStrict (A.encode other))
            case (mBefore, mAfter) of
                (Just beforeEvt, Just afterEvt) ->
                    pure $ DiffResponse
                        (payloadToText (S.rePayload beforeEvt))
                        (payloadToText (S.rePayload afterEvt))
                        diffLabel
                (Just beforeEvt, Nothing) ->
                    pure $ DiffResponse
                        (payloadToText (S.rePayload beforeEvt))
                        ""
                        (diffLabel <> " (in progress -- after snapshot pending)")
                _ -> do
                    -- Fall back to live K8s diff (original behavior)
                    let mCtx = case mTargetState of
                            Just (K8sState k8s) -> Just (context k8s)
                            _ -> Nothing
                    case mCtx of
                        Nothing ->
                            pure $ DiffResponse "" "" "No K8s context available"
                        Just ctx -> do
                            let ns = ctx.namespace
                                svcHost = ctx.serviceName
                                oldDep = svcHost <> "-" <> ctx.oldVersion
                                newDep = svcHost <> "-" <> ctx.newVersion
                            -- Get old deployment envs
                            oldEnvResult <- liftIO $ runCmd (unwords [kubectlBin cfg, "-n", T.unpack ns, "get deployment", T.unpack oldDep, "-o jsonpath='{.spec.template.spec.containers[0].env}'"])
                            -- Get new deployment envs (or udf2 env switch data)
                            let newEnvSource = NT.udf2 tracker
                            case newEnvSource of
                                Just udf2Envs | not (T.null udf2Envs) -> do
                                    -- udf2 contains the new env switch data
                                    let oldEnvText = case oldEnvResult of
                                            Right (K8sResult out) -> cleanJsonpath out
                                            Left _ -> ""
                                    pure $ DiffResponse oldEnvText udf2Envs "Diff from env switch (udf2)"
                                _ -> do
                                    -- Fetch new deployment envs from K8s
                                    newEnvResult <- liftIO $ runCmd (unwords [kubectlBin cfg, "-n", T.unpack ns, "get deployment", T.unpack newDep, "-o jsonpath='{.spec.template.spec.containers[0].env}'"])
                                    let oldEnvText = case oldEnvResult of
                                            Right (K8sResult out) -> cleanJsonpath out
                                            Left _ -> ""
                                        newEnvText = case newEnvResult of
                                            Right (K8sResult out) -> cleanJsonpath out
                                            Left _ -> ""
                                    if T.null oldEnvText && T.null newEnvText
                                        then pure $ DiffResponse "" "" "No diff data available"
                                        else pure $ DiffResponse oldEnvText newEnvText "Deployment env diff"
  where
    cleanJsonpath :: Text -> Text
    cleanJsonpath out = T.strip (T.dropWhile (== '\'') (T.dropWhileEnd (== '\'') (T.strip out)))

-- ============================================================================
-- Pod Health Endpoint (GET /releases/:id/pods/health)
-- ============================================================================

podHealthH :: Text -> Flow PodHealthResponse
podHealthH rid = do
    cfg <- getConfig
    db <- getDBEnv
    m <- liftIO $ findReleaseTracker db rid
    case m of
        Nothing -> pure emptyPodHealth
        Just (_tracker, mTargetState) -> do
            let mCtx = case mTargetState of
                    Just (K8sState k8s) -> Just (context k8s)
                    _ -> Nothing
            case mCtx of
                Nothing -> pure emptyPodHealth
                Just ctx -> do
                    let ns = ctx.namespace
                        svcHost = ctx.serviceName
                    podResult <- liftIO $ runCmd (unwords [kubectlBin cfg, "-n", shellQuote ns, "get pods -l", "app=" <> shellQuote svcHost, "-o json"])
                    case podResult of
                        Left (K8sError _) -> pure emptyPodHealth
                        Right (K8sResult out) ->
                            case A.decodeStrict' (encodeUtf8 out) :: Maybe Value of
                                Nothing -> pure emptyPodHealth
                                Just podJson -> pure $ parsePodHealth podJson

emptyPodHealth :: PodHealthResponse
emptyPodHealth = PodHealthResponse [] (PodSummary 0 0 0 0 0)

parsePodHealth :: Value -> PodHealthResponse
parsePodHealth (Object root) =
    case KM.lookup (K.fromText "items") root of
        Just (Array items) ->
            let pods = map parseSinglePod (foldr (:) [] items)
                total = length pods
                running = length (filter (\p -> piStatus p == "Running") pods)
                pending = length (filter (\p -> piStatus p == "Pending") pods)
                failed = length (filter (\p -> piStatus p == "Failed") pods)
                unknown' = total - running - pending - failed
             in PodHealthResponse pods (PodSummary total running pending failed unknown')
        _ -> emptyPodHealth
parsePodHealth _ = emptyPodHealth

parseSinglePod :: Value -> PodInfo
parseSinglePod (Object podObj) =
    let nameVal = case getObj' "metadata" podObj >>= getTxt' "name" of
            Just n -> n
            Nothing -> ""
        phaseVal = case getObj' "status" podObj >>= getTxt' "phase" of
            Just p -> p
            Nothing -> "Unknown"
        -- Check container readiness
        readyVal = case getObj' "status" podObj >>= getArr' "containerStatuses" of
            Just statuses -> all isContainerReady statuses
            Nothing -> False
        -- Get restart count
        restartsVal = case getObj' "status" podObj >>= getArr' "containerStatuses" of
            Just statuses -> sum (map getRestartCount statuses)
            Nothing -> 0 :: Int
        -- Get creation timestamp as age
        ageVal = case getObj' "metadata" podObj >>= getTxt' "creationTimestamp" of
            Just ts -> ts
            Nothing -> ""
        -- Get version from pod label (preferred) or container image tag (fallback)
        versionVal = case getObj' "metadata" podObj >>= getObj' "labels" >>= getTxt' "version" of
            Just v -> v
            Nothing -> case getObj' "spec" podObj >>= getArr' "containers" of
                Just (c : _) -> extractImageTag c
                _ -> ""
     in PodInfo nameVal phaseVal readyVal restartsVal ageVal versionVal
parseSinglePod _ = PodInfo "" "Unknown" False 0 "" ""

isContainerReady :: Value -> Bool
isContainerReady (Object cs) = case KM.lookup (K.fromText "ready") cs of
    Just (Bool b) -> b
    _ -> False
isContainerReady _ = False

getRestartCount :: Value -> Int
getRestartCount (Object cs) = case KM.lookup (K.fromText "restartCount") cs of
    Just (Number n) -> round n
    _ -> 0
getRestartCount _ = 0

extractImageTag :: Value -> Text
extractImageTag (Object c) = case KM.lookup (K.fromText "image") c of
    Just (String img) ->
        -- Extract tag: image might be repo/name:tag or repo/name-version
        let afterColon = T.takeWhileEnd (/= ':') img
            afterDash = T.takeWhileEnd (/= '-') img
         in if T.isInfixOf ":" img then afterColon else afterDash
    _ -> ""
extractImageTag _ = ""

-- Helpers for pod parsing (avoid clash with existing ones)
getObj' :: Text -> KM.KeyMap Value -> Maybe (KM.KeyMap Value)
getObj' key obj = case KM.lookup (K.fromText key) obj of Just (Object o) -> Just o; _ -> Nothing

getArr' :: Text -> KM.KeyMap Value -> Maybe [Value]
getArr' key obj = case KM.lookup (K.fromText key) obj of Just (Array a) -> Just (foldr (:) [] a); _ -> Nothing

getTxt' :: Text -> KM.KeyMap Value -> Maybe Text
getTxt' key obj = case KM.lookup (K.fromText key) obj of Just (String t) -> Just t; _ -> Nothing

-- (getStr' removed -- pod parsing now uses typed PodInfo)

-- ============================================================================
-- Immediate Revert (POST /releases/:id/revert/immediate)
-- ============================================================================

immediateRevertH :: Text -> ImmediateRevertReq -> Flow APIResponse
immediateRevertH rid req = do
    cfg <- getConfig
    db <- getDBEnv
    m <- liftIO $ findReleaseTracker db rid
    case m of
        Nothing -> pure $ APIResponse "ERROR" "Release not found"
        Just (tracker, mTargetState) -> do
            let currentStatus = NT.status tracker
            if currentStatus /= Completed && currentStatus /= InProgress
                then pure $ APIResponse "ERROR" ("Cannot immediate-revert from status: " <> T.pack (show currentStatus))
                else do
                    let mCtx = case mTargetState of
                            Just (K8sState k8s) -> Just (context k8s)
                            _ -> Nothing
                    case mCtx of
                        Nothing -> pure $ APIResponse "ERROR" "No K8s context available for revert"
                        Just ctx -> do
                            -- Production behavior: swap image on the NEW deployment (which VS already points to)
                            -- Do NOT touch VirtualService -- old deployment may be scaled down already
                            let nsQ = shellQuote ((\(K8sReleaseContext{K8s.namespace = n}) -> n) ctx)
                                depQ = shellQuote (deploymentName ctx)
                                -- Use docker image from context (full registry path), fallback to fetching from old deployment
                                oldImage = fromMaybe (NT.oldVersion tracker) (K8s.dockerImage ctx)
                                oldImageQ = shellQuote oldImage
                                cNameQ = shellQuote ((\(K8sReleaseContext{K8s.containerName = c}) -> c) ctx)
                            -- Step 1: Set image to old version on the new deployment
                            let setImageCmd = unwords [kubectlBin cfg, "set", "image", "deployment/" <> depQ, cNameQ <> "=" <> oldImageQ, "-n", nsQ]
                            imgResult <- liftIO $ executeWithRetry cfg setImageCmd
                            case imgResult of
                                Left (K8sError err) -> pure $ APIResponse "ERROR" ("Failed to set image: " <> err)
                                Right _ -> do
                                    -- Step 2: Rollout restart to force pod restart with old image
                                    let restartCmd = unwords [kubectlBin cfg, "rollout", "restart", "deployment/" <> depQ, "-n", nsQ]
                                    _ <- liftIO $ executeWithRetry cfg restartCmd
                                    -- Step 3: Update tracker status
                                    let updated = (tracker :: ReleaseTracker){NT.status = Reverted}
                                    liftIO $ insertReleaseTracker db updated mTargetState
                                    liftIO $ insertReleaseEvent db rid "BUSINESS" "IMMEDIATE_REVERT" (object ["requestedBy" .= (req :: ImmediateRevertReq).requestedBy, "info" .= (req :: ImmediateRevertReq).info])
                                    liftIO $ notifyImmediateReverted db updated
                                    -- Step 4: Optionally trigger sync revert
                                    let shouldSync = fromMaybe False (isRevertSync (req :: ImmediateRevertReq))
                                    when shouldSync $
                                        liftIO $ triggerImmediateRevertSync cfg db tracker mTargetState
                                    pure $ APIResponse "SUCCESS" "Immediate revert: image swapped + pods restarting"

-- ============================================================================
-- Restart Release (POST /releases/:id/restart)
-- ============================================================================

restartReleaseH :: Text -> RestartReleaseReq -> Flow APIResponse
restartReleaseH rid req = do
    db <- getDBEnv
    m <- liftIO $ findReleaseTracker db rid
    case m of
        Nothing -> pure $ APIResponse "ERROR" "Release not found"
        Just (tracker, mTargetState) -> do
            let currentStatus = NT.status tracker
            if currentStatus /= Aborted && currentStatus /= UserAborted && currentStatus /= Reverted
                then pure $ APIResponse "ERROR" ("Cannot restart from status: " <> T.pack (show currentStatus) <> ". Valid: Aborted, UserAborted, Reverted")
                else do
                    now <- liftIO getCurrentTime
                    let updated = (tracker :: ReleaseTracker)
                            { NT.status = Created
                            , NT.releaseWFStatus = Init
                            , NT.startTime = Nothing
                            , NT.endTime = Nothing
                            , NT.scheduleTime = Just now
                            , NT.rolloutHistory = []
                            }
                    liftIO $ insertReleaseTracker db updated mTargetState
                    liftIO $ insertReleaseEvent db rid "BUSINESS" "RELEASE_RESTARTED"
                        (object
                            [ "requestedBy" .= (req :: RestartReleaseReq).requestedBy
                            , "reason" .= (req :: RestartReleaseReq).reason
                            , "previousStatus" .= T.pack (show currentStatus)
                            ])
                    liftIO $ notifyReleaseRestarted db updated
                    pure $ APIResponse "SUCCESS" "Release restarted"

-- ============================================================================
-- Fast Forward (POST /releases/:id/fast-forward)
-- ============================================================================

fastForwardH :: Text -> FastForwardReq -> Flow APIResponse
fastForwardH rid req = do
    db <- getDBEnv
    m <- liftIO $ findReleaseTracker db rid
    case m of
        Nothing -> pure $ APIResponse "ERROR" "Release not found"
        Just (tracker, mTargetState) -> do
            let currentStatus = NT.status tracker
            if currentStatus /= InProgress
                then pure $ APIResponse "ERROR" ("Cannot fast-forward from status: " <> T.pack (show currentStatus) <> ". Must be InProgress")
                else do
                    -- Mark the current rollout history step as completed by zeroing out the cooloff
                    let history = NT.rolloutHistory tracker
                        updatedHistory = case history of
                            [] -> []
                            steps ->
                                let lastIdx = length steps - 1
                                    updateStep i step =
                                        if i == lastIdx
                                            then step{historyCooloffSeconds = 0}
                                            else step
                                 in zipWith updateStep [0 ..] steps
                        updated = (tracker :: ReleaseTracker){NT.rolloutHistory = updatedHistory}
                    liftIO $ insertReleaseTracker db updated mTargetState
                    liftIO $ insertReleaseEvent db rid "BUSINESS" "FAST_FORWARD"
                        (object
                            [ "requestedBy" .= (req :: FastForwardReq).requestedBy
                            , "reason" .= (req :: FastForwardReq).reason
                            ])
                    liftIO $ notifyReleaseFastForwarded db updated
                    pure $ APIResponse "SUCCESS" "Fast forward: cooloff period skipped, runner will advance on next poll"

-- ============================================================================
-- Validation Helpers
-- ============================================================================

-- | Validate that a version string matches the K8s label format: [a-z0-9]([-a-z0-9]*[a-z0-9])?
-- Empty strings are rejected. The check is case-insensitive (lowered before validation).
isValidK8sVersion :: Text -> Bool
isValidK8sVersion ver
    | T.null ver = False
    | otherwise =
        let lowered = T.toLower ver
            chars = T.unpack lowered
            isValidChar c = isAlphaNum c || c == '-'
            startsOk = case chars of (c:_) -> isAlphaNum c; [] -> False
            endsOk = case chars of [] -> False; _ -> isAlphaNum (Prelude.last chars)
        in all isValidChar chars && startsOk && endsOk
