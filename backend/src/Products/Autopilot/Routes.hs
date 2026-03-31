{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

module Products.Autopilot.Routes where

import Control.Applicative ((<|>))
import Control.Concurrent (forkIO)
import Control.Exception (SomeException, try)
import Control.Monad (void, when)
import Control.Monad.IO.Class (liftIO)
import Core.Config (Config (..))
import Products.Autopilot.RuntimeConfig (isApproveAllReleases)
import Core.Utils.FlowMonad (Flow, getConfig, getDBEnv)
import Data.Aeson (Value (..), eitherDecode, object, toJSON, (.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.List (find)
import qualified Data.Map.Strict as Map
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
import Products.Autopilot.K8s.Deployment (getDeploymentEnvs)
import Products.Autopilot.K8s.Execute (K8sError (..), K8sResult (..), executeWithRetry, runCmd)
import Products.Autopilot.K8s.Kubectl (getPrimarySubsetFromVirtualService)
import Products.Autopilot.K8s.VirtualService (getVirtualServiceJson)
import Products.Autopilot.Notifications
import GHC.Int (Int32)
import Products.Autopilot.Queries.ProductService
import Products.Autopilot.Queries.ReleaseTracker
import Products.Autopilot.Queries.ServerConfig (listAllServerConfigs, upsertServerConfig)
import Products.Autopilot.Queries.VsEditTracker
import Products.Autopilot.Sync (triggerImmediateRevertSync)
import Products.Autopilot.Types
import qualified Products.Autopilot.Types as NT
import Products.Autopilot.Types.API
import Products.Autopilot.Types.Target (TargetState (..), emptyConfigState)
import Products.Autopilot.Types.Target.Kubernetes
import qualified Products.Autopilot.Types.Target.Kubernetes as K8s
import Servant
import Shared.Config.Registry (allConfigEntries, findConfigEntry, validateConfigValue)
import Shared.Config.Types (ConfigEntry (..), ConfigGroup (..), configGroupToText, configTypeDefault, configTypeTag)
import qualified Shared.Types.Storage.Schema as S
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

type CoreAPI =
    "products" :> Get '[JSON] [ProductResponse]
        :<|> "products" :> ReqBody '[JSON] UpsertProductReq :> Post '[JSON] APIResponse
        :<|> "products" :> Capture "product" Text :> "services" :> Get '[JSON] [ServiceResponse]
        :<|> "services" :> ReqBody '[JSON] UpsertServiceReq :> Post '[JSON] APIResponse
        :<|> "releases" :> QueryParam "from" Text :> QueryParam "to" Text :> Get '[JSON] [ReleaseTracker]
        :<|> "releases" :> "create" :> Header "X-Forwarded-Email" Text :> Header "x-pomerium-jwt-assertion" Text :> ReqBody '[JSON] K8sCreateReleaseReq :> Post '[JSON] APIResponse
        :<|> "releases" :> Capture "releaseId" Text :> Get '[JSON] (Maybe ReleaseTracker)
        :<|> "releases" :> Capture "releaseId" Text :> "approve" :> ReqBody '[JSON] ApproveReleaseReq :> Post '[JSON] (Maybe ReleaseTracker)
        :<|> "releases" :> Capture "releaseId" Text :> "trigger" :> ReqBody '[JSON] TriggerReleaseReq :> Post '[JSON] APIResponse
        :<|> "releases" :> Capture "releaseId" Text :> "rollback" :> ReqBody '[JSON] TriggerReleaseReq :> Post '[JSON] APIResponse
        :<|> "releases" :> Capture "releaseId" Text :> "revert" :> ReqBody '[JSON] RevertReleaseReq :> Post '[JSON] APIResponse
        :<|> "release" :> "revert" :> "global" :> Capture "globalId" Text :> Put '[JSON] APIResponse
        :<|> "release" :> "revert" :> "immediate" :> "global" :> Capture "globalId" Text :> Put '[JSON] APIResponse
        :<|> "releases" :> Capture "releaseId" Text :> "discard" :> ReqBody '[JSON] DiscardReleaseReq :> Post '[JSON] APIResponse
        :<|> "releases" :> Capture "releaseId" Text :> "update" :> ReqBody '[JSON] K8sUpdateTrackerReq :> Post '[JSON] APIResponse
        :<|> "releases" :> Capture "releaseId" Text :> "events" :> Get '[JSON] [Value]
        :<|> "releases" :> Capture "releaseId" Text :> "delete" :> Post '[JSON] APIResponse
        :<|> "tracker" :> "configmap" :> "list" :> QueryParam "from" Text :> QueryParam "to" Text :> Get '[JSON] Value
        :<|> "tracker" :> "configmap" :> Capture "id" Text :> Get '[JSON] Value
        :<|> "tracker" :> "configmap" :> ReqBody '[JSON] Value :> Post '[JSON] APIResponse
        :<|> "tracker" :> "configmap" :> Capture "id" Text :> ReqBody '[JSON] Value :> Put '[JSON] APIResponse
        :<|> "configmap" :> QueryParam "PRODUCT" Text :> QueryParam "NAME" Text :> Get '[JSON] Value
        :<|> "configmap" :> "secondary" :> QueryParam "PRODUCT" Text :> QueryParam "NAME" Text :> Get '[JSON] Value
        :<|> "server-config" :> Get '[JSON] Value
        :<|> "server-config" :> ReqBody '[JSON] Value :> Post '[JSON] APIResponse
        :<|> "envs" :> QueryParam "product" Text :> QueryParam "env" Text :> QueryParam "service" Text :> Get '[JSON] Value
        :<|> "envs" :> "secondary" :> QueryParam "product" Text :> QueryParam "env" Text :> QueryParam "service" Text :> Get '[JSON] Value
        -- New endpoints
        :<|> "releases" :> Capture "releaseId" Text :> "diff" :> QueryParam "type" Text :> Get '[JSON] Value
        :<|> "releases" :> Capture "releaseId" Text :> "pods" :> "health" :> Get '[JSON] Value
        :<|> "releases" :> Capture "releaseId" Text :> "revert" :> "immediate" :> ReqBody '[JSON] ImmediateRevertReq :> Post '[JSON] APIResponse
        :<|> "releases" :> Capture "releaseId" Text :> "restart" :> ReqBody '[JSON] RestartReleaseReq :> Post '[JSON] APIResponse
        :<|> "releases" :> Capture "releaseId" Text :> "fast-forward" :> ReqBody '[JSON] FastForwardReq :> Post '[JSON] APIResponse
        :<|> "resources" :> QueryParam "PRODUCT" Text :> QueryParam "SERVICE" Text :> Get '[JSON] Value
        -- Product Config CRUD
        :<|> "products" :> "config" :> Get '[JSON] [ProductConfigResponse]
        :<|> "products" :> "config" :> ReqBody '[JSON] UpsertProductReq :> Post '[JSON] APIResponse
        :<|> "products" :> "config" :> Capture "id" Int32 :> Get '[JSON] Value
        :<|> "products" :> "config" :> Capture "id" Int32 :> ReqBody '[JSON] UpsertProductReq :> Put '[JSON] APIResponse
        :<|> "products" :> "config" :> Capture "id" Int32 :> Delete '[JSON] APIResponse
        -- Release Config CRUD
        :<|> "services" :> "config" :> QueryParam "product" Text :> Get '[JSON] [ReleaseConfigResponse]
        :<|> "services" :> "config" :> ReqBody '[JSON] UpsertServiceReq :> Post '[JSON] APIResponse
        :<|> "services" :> "config" :> Capture "id" Int32 :> Get '[JSON] Value
        :<|> "services" :> "config" :> Capture "id" Int32 :> ReqBody '[JSON] UpsertServiceReq :> Put '[JSON] APIResponse
        :<|> "services" :> "config" :> Capture "id" Int32 :> Delete '[JSON] APIResponse
        -- VS Edit Tracker (static paths BEFORE captures to avoid ambiguity)
        :<|> "vs-edit-tracker" :> ReqBody '[JSON] CreateVsEditTrackerReq :> Post '[JSON] Value
        :<|> "vs-edit-tracker" :> "list" :> QueryParam "from" Text :> QueryParam "to" Text :> Get '[JSON] [Value]
        :<|> "vs-edit-tracker" :> "current-vs" :> QueryParam "product" Text :> QueryParam "service" Text :> Get '[JSON] Value
        :<|> "vs-edit-tracker" :> "lock" :> ReqBody '[JSON] VsLockReq :> Post '[JSON] APIResponse
        :<|> "vs-edit-tracker" :> "unlock" :> ReqBody '[JSON] VsUnlockReq :> Post '[JSON] APIResponse
        :<|> "vs-edit-tracker" :> "revert" :> Capture "id" Text :> Put '[JSON] APIResponse
        :<|> "vs-edit-tracker" :> Capture "id" Text :> Get '[JSON] Value
        :<|> "vs-edit-tracker" :> Capture "id" Text :> ReqBody '[JSON] UpdateVsEditTrackerReq :> Put '[JSON] APIResponse

coreServer :: ServerT CoreAPI Flow
coreServer =
    listProductsH
        :<|> upsertProductH
        :<|> listServicesH
        :<|> upsertServiceH
        :<|> listReleasesH
        :<|> createReleaseH
        :<|> getReleaseH
        :<|> approveReleaseH
        :<|> triggerReleaseH
        :<|> rollbackReleaseH
        :<|> revertReleaseH
        :<|> revertByGlobalIdH
        :<|> immediateRevertByGlobalIdH
        :<|> discardReleaseH
        :<|> updateTrackerH
        :<|> listEventsH
        :<|> deleteReleaseH
        -- ConfigMap
        :<|> listConfigMapsH
        :<|> getConfigMapH
        :<|> createConfigMapH
        :<|> updateConfigMapH
        -- ConfigMap K8s lookup
        :<|> fetchConfigMapFromK8sH
        :<|> fetchSecondaryConfigMapH
        -- Server config
        :<|> listServerConfigH
        :<|> upsertServerConfigH
        -- Envs
        :<|> fetchEnvsH
        :<|> fetchSecondaryEnvsH
        -- New endpoints
        :<|> releaseDiffH
        :<|> podHealthH
        :<|> immediateRevertH
        :<|> restartReleaseH
        :<|> fastForwardH
        :<|> fetchResourcesH
        -- Product Config CRUD
        :<|> listProductConfigsH
        :<|> createProductConfigH
        :<|> getProductConfigH
        :<|> updateProductConfigH
        :<|> deleteProductConfigH
        -- Release Config CRUD
        :<|> listReleaseConfigsH
        :<|> createReleaseConfigH
        :<|> getReleaseConfigH
        :<|> updateReleaseConfigH
        :<|> deleteReleaseConfigH
        -- VS Edit Tracker (order must match API type: static paths before captures)
        :<|> createVsEditTrackerH
        :<|> listVsEditTrackersH
        :<|> fetchCurrentVsH
        :<|> lockVsEditTrackerH
        :<|> unlockVsEditTrackerH
        :<|> revertVsEditTrackerH
        :<|> getVsEditTrackerH
        :<|> updateVsEditTrackerH

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

listReleasesH :: Maybe Text -> Maybe Text -> Flow [ReleaseTracker]
listReleasesH mFrom mTo = do
    db <- getDBEnv
    case (mFrom >>= parseISO, mTo >>= parseISO) of
        (Just fromTime, Just toTime) -> do
            pairs <- liftIO $ listReleaseTrackersByDateRange db fromTime toTime
            pure (map fst pairs)
        _ -> do
            -- No valid date range — return all (last 30 days as safety)
            pairs <- liftIO $ listReleaseTrackers db
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
        (Just pCfg, Just sCfg) ->
            if maybe False (/= getProductCluster pCfg) requestedCluster
                then pure $ APIResponse "ERROR" "Requested cluster does not match product config"
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
            now <- liftIO getCurrentTime
            newRid <- liftIO (UUID.toText <$> UUID.nextRandom)
            let oldCtx = case mTargetState of
                    Just (K8sState k8s) -> context k8s
                    _ -> defaultK8sReleaseContext
                ctxOldVersion = oldCtx.oldVersion
                ctxNewVersion = oldCtx.newVersion
                ctxServiceName = oldCtx.serviceName
                trackerCreatedBy = NT.createdBy tracker
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
    -- Fetch tracker before deleting so we can notify
    mTracker <- liftIO $ findReleaseTracker db rid
    -- Delete events first (FK constraint)
    liftIO $ deleteReleaseEvents db rid
    -- Delete the release
    liftIO $ deleteReleaseTracker db rid
    case mTracker of
        Just (tracker, _) -> liftIO $ notifyReleaseDeleted db tracker
        Nothing -> pure ()
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

listEventsH :: Text -> Flow [Value]
listEventsH rid = do
    db <- getDBEnv
    events <- liftIO $ listReleaseEvents db rid
    pure $
        fmap
            ( \e ->
                object
                    [ "category" .= S.reCategory e
                    , "label" .= S.reLabel e
                    , "data" .= S.rePayload e
                    , "timestamp" .= S.reCreatedAt e
                    ]
            )
            events

listConfigMapsH :: Maybe Text -> Maybe Text -> Flow Value
listConfigMapsH mFrom mTo = do
    db <- getDBEnv
    now <- liftIO getCurrentTime
    let tryParse t = case parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" (T.unpack t) of
            Just v -> Just v
            Nothing -> parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Q%z" (T.unpack t)
        from = fromMaybe (addUTCTime (-2592000) now) (mFrom >>= tryParse)
        to = fromMaybe now (mTo >>= tryParse)
    pairs <- liftIO $ findReleaseTrackersByCategory db "BackendConfig" from to
    pure $ object ["list" .= map (toConfigMapJson . fst) pairs]

getConfigMapH :: Text -> Flow Value
getConfigMapH cmId' = do
    db <- getDBEnv
    m <- liftIO $ findReleaseTracker db cmId'
    case m of
        Nothing -> pure Null
        Just (rt, _) -> pure (toConfigMapJson rt)

createConfigMapH :: Value -> Flow APIResponse
createConfigMapH body = do
    db <- getDBEnv
    rid <- liftIO (UUID.toText <$> UUID.nextRandom)
    case extractCmFields body of
        Left err -> pure $ APIResponse "ERROR" err
        Right (product', service', env', cluster', desc, changeLog', config', releaseManager', priority', _scheduleTime', name') -> do
            let cmMetadata =
                    object $
                        concat
                            [ maybe [] (\c -> ["config" .= c]) config'
                            , maybe [] (\c -> ["file" .= c]) config'
                            , maybe [] (\n -> ["name" .= n]) name'
                            , maybe [] (\c -> ["cluster" .= c]) (if T.null cluster' then Nothing else Just cluster')
                            ]
                tracker =
                    ReleaseTracker
                        { releaseId = rid
                        , product = product'
                        , service = fromMaybe service' name'
                        , env = env'
                        , category = BackendConfig
                        , status = Created
                        , releaseWFStatus = Init
                        , mode = Auto
                        , createdBy = releaseManager'
                        , approvedBy = Nothing
                        , isApproved = False
                        , isInfraApproved = False
                        , releaseTag = Nothing
                        , dateCreated = Nothing
                        , lastUpdated = Nothing
                        , scheduleTime = Nothing
                        , startTime = Nothing
                        , endTime = Nothing
                        , rolloutStrategy = []
                        , rolloutHistory = []
                        , oldVersion = ""
                        , newVersion = ""
                        , info = Nothing
                        , description = desc
                        , changeLog = changeLog'
                        , metadata = Just cmMetadata
                        , priority = fromIntegral priority'
                        , globalId = Nothing
                        , udf1 = Nothing
                        , udf2 = Nothing
                        , udf3 = Nothing
                        }
                targetState = ConfigState emptyConfigState
            liftIO $ insertReleaseTracker db tracker (Just targetState)
            liftIO $ insertReleaseEvent db rid "BUSINESS" "TRACKER_CREATED" (toJSON tracker)
            liftIO $ notifyConfigMapCreated db tracker
            -- Handle sync to secondary cluster
            let isSync = case body of
                    Object o -> isTruthy "isSync" o
                    _ -> False
            cfg <- getConfig
            when (isSync && not (null (syncClusterUrl cfg))) $ do
                let rawUrl = syncClusterUrl cfg
                    normalised =
                        let u = if "http" `T.isPrefixOf` T.pack rawUrl then rawUrl else "http://" <> rawUrl
                         in if last u == '/' then u else u <> "/"
                    baseAuth = syncClusterBaseAuth cfg
                    authArgs = if null baseAuth then [] else ["-H", "Authorization: Basic " <> baseAuth]
                    secondaryFile = case body of
                        Object o -> getStrM "secondary_file" o
                        _ -> Nothing
                    syncBody = case body of
                        Object o ->
                            let o1 = KM.insert (K.fromText "isSync") (Bool False) o
                                o2 = case secondaryFile of
                                    Just sf -> KM.insert (K.fromText "file") (String sf) o1
                                    Nothing -> o1
                                o3 = KM.delete (K.fromText "secondary_file") o2
                             in Object o3
                        v -> v
                    postUrl = normalised <> "tracker/configmap"
                    postCurlArgs =
                        [ "-s"
                        , "-X"
                        , "POST"
                        , postUrl
                        , "-H"
                        , "Content-Type: application/json"
                        , "-d"
                        , LBS.unpack (A.encode syncBody)
                        , "--max-time"
                        , "30"
                        ]
                            <> authArgs
                liftIO $
                    insertReleaseEvent
                        db
                        rid
                        "BUSINESS"
                        "CONFIGMAP_SYNC_REQUEST"
                        (toJSON (T.pack (LBS.unpack (A.encode syncBody))))
                liftIO $ void $ forkIO $ do
                    putStrLn $ "[CONFIGMAP-SYNC] Posting to secondary: " <> postUrl
                    syncResult <- try (readProcessWithExitCode "curl" postCurlArgs "") :: IO (Either SomeException (ExitCode, String, String))
                    case syncResult of
                        Right (ExitSuccess, out, _) -> do
                            putStrLn $ "[CONFIGMAP-SYNC] Success, response: " <> out
                            insertReleaseEvent db rid "BUSINESS" "CONFIGMAP_SYNC_RESPONSE" (toJSON (T.pack out))
                        Right (ExitFailure code, _, err) -> do
                            putStrLn $ "[CONFIGMAP-SYNC] Failed (exit=" <> show code <> "): " <> err
                            insertReleaseEvent db rid "BUSINESS" "CONFIGMAP_SYNC_FAILED" (toJSON (T.pack err))
                        Left e -> do
                            putStrLn $ "[CONFIGMAP-SYNC] Exception: " <> show e
                            insertReleaseEvent db rid "BUSINESS" "CONFIGMAP_SYNC_FAILED" (toJSON (T.pack (show e)))
            pure $ APIResponse "SUCCESS" ("ConfigMap tracker created: " <> rid)

updateConfigMapH :: Text -> Value -> Flow APIResponse
updateConfigMapH cmId' body = do
    db <- getDBEnv
    m <- liftIO $ findReleaseTracker db cmId'
    case m of
        Nothing -> pure $ APIResponse "ERROR" "ConfigMap tracker not found"
        Just (rt, mts) -> do
            let updated = applyCmUpdates rt body
            liftIO $ insertReleaseTracker db updated mts
            liftIO $ notifyConfigMapUpdated db updated "status updated"
            pure $ APIResponse "SUCCESS" "ConfigMap tracker updated"

-- | Convert a ReleaseTracker (category=BackendConfig) to backward-compatible ConfigMap JSON
toConfigMapJson :: ReleaseTracker -> Value
toConfigMapJson rt =
    let meta = case NT.metadata rt of
            Just (Object o) -> o
            _ -> KM.empty
        getMetaStr k = case KM.lookup (K.fromText k) meta of
            Just (String t) -> Just t
            _ -> Nothing
        configVal = getMetaStr "config"
        fileVal = getMetaStr "file"
        nameVal = getMetaStr "name"
        clusterVal = fromMaybe "" (getMetaStr "cluster")
        statusText = case NT.status rt of
            Created -> "CREATED" :: Text
            InProgress -> "INPROGRESS"
            Completed -> "COMPLETED"
            Aborted -> "ABORTED"
            UserAborted -> "ABORTED"
            _ -> T.pack (show (NT.status rt))
     in object
            [ "id" .= NT.releaseId rt
            , "service" .= NT.service rt
            , "product" .= NT.product rt
            , "name" .= nameVal
            , "status" .= statusText
            , "description" .= fromMaybe "" (NT.description rt)
            , "env" .= NT.env rt
            , "cluster" .= clusterVal
            , "date_created" .= NT.dateCreated rt
            , "last_updated" .= NT.lastUpdated rt
            , "start_time" .= NT.startTime rt
            , "end_time" .= NT.endTime rt
            , "release_manager" .= NT.createdBy rt
            , "is_approved" .= (if NT.isApproved rt then (1 :: Int) else 0)
            , "is_infra_approved" .= (if NT.isInfraApproved rt then (1 :: Int) else 0)
            , "events" .= ([] :: [Value])
            , "release_tag" .= NT.releaseTag rt
            , "config" .= configVal
            , "file" .= fileVal
            , "commit" .= getMetaStr "commit"
            , "change_log" .= fromMaybe "" (NT.changeLog rt)
            , "priority" .= NT.priority rt
            , "schedule_time" .= NT.scheduleTime rt
            , "slack_thread_id" .= ("" :: Text)
            ]

extractCmFields :: Value -> Either Text (Text, Text, Text, Text, Maybe Text, Maybe Text, Maybe Text, Text, Int, Maybe UTCTime, Maybe Text)
extractCmFields (Object obj) =
    Right
        ( getStr "product" obj
        , getStr "service" obj
        , fromMaybe "UAT" (getStrM "env" obj)
        , fromMaybe "" (getStrM "cluster" obj)
        , getStrM "description" obj
        , getStrM "change_log" obj
        , firstJust (getStrM "file" obj) (getStrM "config" obj)
        , fromMaybe "local_admin" (getStrM "release_manager" obj)
        , fromMaybe 0 (getStrM "priority" obj >>= safeReadInt)
        , Nothing
        , getStrM "name" obj
        )
extractCmFields _ = Left "Invalid JSON body"

applyCmUpdates :: ReleaseTracker -> Value -> ReleaseTracker
applyCmUpdates rt (Object obj) =
    let rt1 = case getStrM "status" obj of
            Just "CREATED" -> rt{NT.status = Created}
            Just "INPROGRESS" -> rt{NT.status = InProgress}
            Just "COMPLETED" -> rt{NT.status = Completed}
            Just "ABORTED" -> rt{NT.status = Aborted}
            _ -> rt
        rt2 = maybe rt1 (\s -> rt1{NT.description = Just s}) (getStrM "description" obj)
        rt3 = maybe rt2 (\s -> rt2{NT.changeLog = Just s}) (getStrM "change_log" obj)
        rt4 = if isTruthy "is_approved" obj then rt3{NT.isApproved = True} else rt3
        rt5 = if isTruthy "is_infra_approved" obj then rt4{NT.isInfraApproved = True} else rt4
        -- Update metadata fields (config/file/commit)
        oldMeta = case NT.metadata rt5 of
            Just (Object o) -> o
            _ -> KM.empty
        newMeta1 = case firstJust (getStrM "file" obj) (getStrM "config" obj) of
            Just c ->
                KM.insert (K.fromText "config") (String c) $
                    KM.insert (K.fromText "file") (String c) oldMeta
            Nothing -> oldMeta
        newMeta2 = case getStrM "commit" obj of
            Just c -> KM.insert (K.fromText "commit") (String c) newMeta1
            Nothing -> newMeta1
        rt6 = rt5{NT.metadata = Just (Object newMeta2)}
     in rt6
applyCmUpdates rt _ = rt

isTruthy :: Text -> KM.KeyMap Value -> Bool
isTruthy k obj = case KM.lookup (K.fromText k) obj of
    Just (String t) -> t `elem` ["true", "1", "True", "yes"]
    Just (Number n) -> n > 0
    Just (Bool b) -> b
    _ -> False

getStr :: Text -> KM.KeyMap Value -> Text
getStr k obj = case KM.lookup (K.fromText k) obj of Just (String t) -> t; _ -> ""

getStrM :: Text -> KM.KeyMap Value -> Maybe Text
getStrM k obj = case KM.lookup (K.fromText k) obj of Just (String t) | not (T.null t) -> Just t; _ -> Nothing

safeReadInt :: Text -> Maybe Int
safeReadInt t = case reads (T.unpack t) of ((n, _) : _) -> Just n; _ -> Nothing

firstJust :: Maybe a -> Maybe a -> Maybe a
firstJust (Just x) _ = Just x
firstJust Nothing b = b

listServerConfigH :: Flow Value
listServerConfigH = do
    db <- getDBEnv
    rows <- liftIO $ listAllServerConfigs db
    -- Build a map of DB rows by name
    let dbMap :: Map.Map Text (Int, Text, Text, Text, Int, Maybe Text)
        dbMap = Map.fromList [(n, row) | row@(_, _, n, _, _, _) <- rows]
        -- Merge registry entries with DB state
        mergedConfigs = map (mergeEntry dbMap) allConfigEntries
        -- Also include DB rows that are NOT in registry (unknown/legacy configs)
        registryKeys = map ceKey allConfigEntries
        extraDbConfigs = [mkUnknownObj row | row@(_, _, n, _, _, _) <- rows, n `notElem` registryKeys]
        allConfigs = mergedConfigs ++ extraDbConfigs
        -- Group by group name
        grouped = Map.toAscList $ Map.fromListWith (++) [(g, [c]) | (g, c) <- allConfigs]
        groupObjs = map (\(gName, cs) -> object ["name" .= gName, "configs" .= cs]) grouped
    -- Also return flat configs list for backward compat
    let flatConfigs = map toFlatObj rows
    pure $ object ["groups" .= groupObjs, "configs" .= flatConfigs]
  where
    mergeEntry dbMap entry =
        let key = ceKey entry
            groupName = configGroupToText (ceGroup entry)
            typTag = configTypeTag (ceType entry)
            defVal = configTypeDefault (ceType entry)
            prod = ceProduct entry
            desc = ceDescription entry
         in case Map.lookup key dbMap of
                Just (_rowId, _typ, _name, val, enabled, dbProd) ->
                    ( groupName
                    , object
                        [ "key" .= key
                        , "value" .= val
                        , "type" .= typTag
                        , "default" .= defVal
                        , "description" .= desc
                        , "product" .= (dbProd <|> prod)
                        , "enabled" .= (enabled == 1)
                        , "id" .= _rowId
                        ]
                    )
                Nothing ->
                    ( groupName
                    , object
                        [ "key" .= key
                        , "value" .= defVal
                        , "type" .= typTag
                        , "default" .= defVal
                        , "description" .= desc
                        , "product" .= prod
                        , "enabled" .= True
                        , "id" .= (0 :: Int)
                        ]
                    )
    mkUnknownObj (_rowId, typ, name, val, enabled, prod) =
        ( "General" :: Text
        , object
            [ "key" .= name
            , "value" .= val
            , "type" .= typ
            , "default" .= ("" :: Text)
            , "description" .= ("" :: Text)
            , "product" .= prod
            , "enabled" .= (enabled == 1)
            , "id" .= _rowId
            ]
        )
    toFlatObj (_rowId, typ, name, val, enabled, prod) =
        object
            [ "id" .= _rowId
            , "type" .= typ
            , "name" .= name
            , "value" .= val
            , "enabled" .= enabled
            , "product" .= prod
            ]

upsertServerConfigH :: Value -> Flow APIResponse
upsertServerConfigH (Object obj) = do
    db <- getDBEnv
    let name = getStr "name" obj
        value = fromMaybe "" (getStrM "value" obj)
        enabled = maybe True (\t -> t == "1" || T.toLower t == "true") (getStrM "enabled" obj)
    if T.null name
        then pure $ APIResponse "ERROR" "name is required"
        else case findConfigEntry name of
            Nothing ->
                pure $ APIResponse "ERROR" ("Unknown config key: " <> name)
            Just entry ->
                case validateConfigValue entry value of
                    Left err ->
                        pure $ APIResponse "ERROR" ("Validation failed for " <> name <> ": " <> err)
                    Right _ -> do
                        let typ = configTypeTag (ceType entry)
                            product_ = ceProduct entry
                        liftIO $ upsertServerConfig db name typ value enabled product_
                        pure $ APIResponse "SUCCESS" ("server_config upserted: " <> name)
upsertServerConfigH _ = pure $ APIResponse "ERROR" "Invalid JSON body"

fetchConfigMapFromK8sH :: Maybe Text -> Maybe Text -> Flow Value
fetchConfigMapFromK8sH mProduct mName = do
    cfg <- getConfig
    db <- getDBEnv
    case mProduct of
        Nothing -> pure $ object ["configMap" .= toJSON ([] :: [Text])]
        Just productName -> do
            p <- liftIO $ findProductByName db productName
            case p of
                Nothing -> pure $ object ["configMap" .= toJSON ([] :: [Text])]
                Just pCfg -> do
                    let ns = getProductNamespace pCfg
                    case mName of
                        Nothing -> do
                            res <- liftIO $ runCmd (unwords [kubectlBin cfg, "-n", T.unpack ns, "get configmap", "-o jsonpath='{.items[*].metadata.name}'"])
                            case res of
                                Left _ -> pure $ object ["configMap" .= toJSON ([] :: [Text])]
                                Right (K8sResult out) ->
                                    let cleaned = T.strip (T.dropWhile (== '\'') (T.dropWhileEnd (== '\'') (T.strip out)))
                                        names = filter (not . T.null) (T.words cleaned)
                                     in pure $ object ["configMap" .= names]
                        Just name' -> do
                            res <- liftIO $ runCmd (unwords [kubectlBin cfg, "-n", T.unpack ns, "get configmap", T.unpack name', "-o jsonpath='{.data}'"])
                            case res of
                                Left _ -> pure $ object ["configMap" .= ("" :: Text)]
                                Right (K8sResult out) ->
                                    let cleaned = T.strip (T.dropWhile (== '\'') (T.dropWhileEnd (== '\'') (T.strip out)))
                                     in pure $ object ["configMap" .= cleaned]

fetchSecondaryConfigMapH :: Maybe Text -> Maybe Text -> Flow Value
fetchSecondaryConfigMapH mProduct mName = do
    cfg <- getConfig
    let rawUrl = syncClusterUrl cfg
    if null rawUrl
        then pure $ object ["configMap" .= toJSON ([] :: [Text])]
        else do
            let normalised =
                    let u = if "http" `T.isPrefixOf` T.pack rawUrl then rawUrl else "http://" <> rawUrl
                     in if last u == '/' then u else u <> "/"
                baseAuth = syncClusterBaseAuth cfg
                authArgs = if null baseAuth then [] else ["-H", "Authorization: Basic " <> baseAuth]
                queryParams = case (mProduct, mName) of
                    (Just p, Just n) -> "?PRODUCT=" <> T.unpack p <> "&NAME=" <> T.unpack n
                    (Just p, Nothing) -> "?PRODUCT=" <> T.unpack p
                    _ -> ""
                getUrl = normalised <> "configmap" <> queryParams
                getCurlArgs = ["-s", "-X", "GET", getUrl, "--max-time", "15"] <> authArgs
            liftIO $ putStrLn $ "[SYNC-CONFIGMAP] Fetching secondary configmap from: " <> getUrl
            getResult <- liftIO (try (readProcessWithExitCode "curl" getCurlArgs "") :: IO (Either SomeException (ExitCode, String, String)))
            case getResult of
                Right (ExitSuccess, out, _) | not (null out) ->
                    case A.decodeStrict' (encodeUtf8 (T.pack out)) :: Maybe Value of
                        Just v -> pure v
                        Nothing -> do
                            liftIO $ putStrLn $ "[SYNC-CONFIGMAP] Response not valid JSON"
                            pure $ object ["configMap" .= toJSON ([] :: [Text])]
                Right (ExitFailure code, _, err) -> do
                    liftIO $ putStrLn $ "[SYNC-CONFIGMAP] GET failed (exit=" <> show code <> "): " <> err
                    pure $ object ["configMap" .= toJSON ([] :: [Text])]
                _ -> pure $ object ["configMap" .= toJSON ([] :: [Text])]

fetchEnvsH :: Maybe Text -> Maybe Text -> Maybe Text -> Flow Value
fetchEnvsH mProduct mEnv mService = do
    cfg <- getConfig
    db <- getDBEnv
    case (mProduct, mService) of
        (Just product', Just service') -> do
            p <- liftIO $ findProductByName db product'
            case p of
                Nothing -> pure $ toJSON ([] :: [Value])
                Just pCfg -> do
                    svc <- liftIO $ findServiceByProductAndName db product' service'
                    let svcHost = case svc of
                            Just s -> fromMaybe service' (getServiceHost s)
                            Nothing -> service'
                    envResult <- liftIO $ getDeploymentEnvs cfg (getProductNamespace pCfg) (getProductVsName pCfg) svcHost
                    case envResult of
                        Left _ -> pure $ toJSON ([] :: [Value])
                        Right envJson -> pure envJson
        _ -> pure $ toJSON ([] :: [Value])

{- | Proxy env fetch to sync cluster URL for secondary cloud.
Tries the namma-ap endpoint format (GET /envs) first, then falls back to
ny-autopilot format (POST /release/getenvs/).
-}
fetchSecondaryEnvsH :: Maybe Text -> Maybe Text -> Maybe Text -> Flow Value
fetchSecondaryEnvsH mProduct mEnv mService = do
    cfg <- getConfig
    case (mProduct, mEnv, mService) of
        (Just product', Just env', Just service') -> do
            let rawUrl = syncClusterUrl cfg
            if null rawUrl
                then pure $ toJSON ([] :: [Value])
                else do
                    let normalised =
                            let u = if "http" `T.isPrefixOf` T.pack rawUrl then rawUrl else "http://" <> rawUrl
                             in if last u == '/' then u else u <> "/"
                        baseAuth = syncClusterBaseAuth cfg
                        authArgs = if null baseAuth then [] else ["-H", "Authorization: Basic " <> baseAuth]
                        getUrl = normalised <> "envs?product=" <> T.unpack product' <> "&env=" <> T.unpack env' <> "&service=" <> T.unpack service'
                        getCurlArgs = ["-s", "-X", "GET", getUrl, "--max-time", "15"] <> authArgs
                    liftIO $ putStrLn $ "[SYNC-ENV] Fetching secondary envs from: " <> getUrl
                    getResult <- liftIO (try (readProcessWithExitCode "curl" getCurlArgs "") :: IO (Either SomeException (ExitCode, String, String)))
                    case getResult of
                        Right (ExitSuccess, out, _) | not (null out) && out /= "[]" -> do
                            liftIO $ putStrLn $ "[SYNC-ENV] GET success, response length=" <> show (length out)
                            case A.decodeStrict' (encodeUtf8 (T.pack out)) :: Maybe Value of
                                Just v -> pure v
                                Nothing -> do
                                    liftIO $ putStrLn $ "[SYNC-ENV] GET response not valid JSON, trying ny-autopilot format"
                                    tryNyAutopilotFormat normalised baseAuth authArgs product' env' service'
                        Right (ExitSuccess, out, _) -> do
                            liftIO $ putStrLn $ "[SYNC-ENV] GET returned empty/[], trying ny-autopilot format"
                            tryNyAutopilotFormat normalised baseAuth authArgs product' env' service'
                        Right (ExitFailure code, _, err) -> do
                            liftIO $ putStrLn $ "[SYNC-ENV] GET failed (exit=" <> show code <> "): " <> err <> ", trying ny-autopilot format"
                            tryNyAutopilotFormat normalised baseAuth authArgs product' env' service'
                        Left e -> do
                            liftIO $ putStrLn $ "[SYNC-ENV] GET exception: " <> show e <> ", trying ny-autopilot format"
                            tryNyAutopilotFormat normalised baseAuth authArgs product' env' service'
        _ -> pure $ toJSON ([] :: [Value])
  where
    tryNyAutopilotFormat normalised baseAuth authArgs product' env' service' = do
        let postUrl = normalised <> "release/getenvs/"
            bodyJson =
                A.encode $
                    object
                        [ "product" .= product'
                        , "env" .= env'
                        , "service" .= service'
                        , "secondary" .= True
                        ]
            postCurlArgs =
                [ "-s"
                , "-X"
                , "POST"
                , postUrl
                , "-H"
                , "Content-Type: application/json"
                , "-d"
                , LBS.unpack bodyJson
                , "--max-time"
                , "15"
                ]
                    <> authArgs
        liftIO $ putStrLn $ "[SYNC-ENV] Trying ny-autopilot format: POST " <> postUrl
        postResult <- liftIO (try (readProcessWithExitCode "curl" postCurlArgs "") :: IO (Either SomeException (ExitCode, String, String)))
        case postResult of
            Right (ExitSuccess, out, _) ->
                case A.decodeStrict' (encodeUtf8 (T.pack out)) of
                    Just v -> pure v
                    Nothing -> pure $ toJSON ([] :: [Value])
            _ -> pure $ toJSON ([] :: [Value])

-- ============================================================================
-- Diff Endpoint (GET /releases/:id/diff)
-- ============================================================================

releaseDiffH :: Text -> Maybe Text -> Flow Value
releaseDiffH rid mType = do
    cfg <- getConfig
    db <- getDBEnv
    m <- liftIO $ findReleaseTracker db rid
    case m of
        Nothing -> pure $ object ["oldfile" .= ("" :: Text), "newfile" .= ("" :: Text), "message" .= ("Release not found" :: Text)]
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
                payloadToText (String s) = case eitherDecode (LBS.pack (T.unpack s)) :: Either String Value of
                    Right v -> TE.decodeUtf8 (LBS.toStrict (A.encode v))
                    Left _ -> s
                payloadToText other = TE.decodeUtf8 (LBS.toStrict (A.encode other))
            case (mBefore, mAfter) of
                (Just beforeEvt, Just afterEvt) ->
                    pure $ object
                        [ "oldfile" .= payloadToText (S.rePayload beforeEvt)
                        , "newfile" .= payloadToText (S.rePayload afterEvt)
                        , "message" .= diffLabel
                        ]
                (Just beforeEvt, Nothing) ->
                    pure $ object
                        [ "oldfile" .= payloadToText (S.rePayload beforeEvt)
                        , "newfile" .= ("" :: Text)
                        , "message" .= (diffLabel <> " (in progress — after snapshot pending)")
                        ]
                _ -> do
                    -- Fall back to live K8s diff (original behavior)
                    let mCtx = case mTargetState of
                            Just (K8sState k8s) -> Just (context k8s)
                            _ -> Nothing
                    case mCtx of
                        Nothing ->
                            pure $ object ["oldfile" .= ("" :: Text), "newfile" .= ("" :: Text), "message" .= ("No K8s context available" :: Text)]
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
                                    pure $ object ["oldfile" .= oldEnvText, "newfile" .= udf2Envs, "message" .= ("Diff from env switch (udf2)" :: Text)]
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
                                        then pure $ object ["oldfile" .= ("" :: Text), "newfile" .= ("" :: Text), "message" .= ("No diff data available" :: Text)]
                                        else pure $ object ["oldfile" .= oldEnvText, "newfile" .= newEnvText, "message" .= ("Deployment env diff" :: Text)]
  where
    cleanJsonpath :: Text -> Text
    cleanJsonpath out = T.strip (T.dropWhile (== '\'') (T.dropWhileEnd (== '\'') (T.strip out)))

-- ============================================================================
-- Pod Health Endpoint (GET /releases/:id/pods/health)
-- ============================================================================

podHealthH :: Text -> Flow Value
podHealthH rid = do
    cfg <- getConfig
    db <- getDBEnv
    m <- liftIO $ findReleaseTracker db rid
    case m of
        Nothing -> pure $ object ["error" .= ("Release not found" :: Text)]
        Just (_tracker, mTargetState) -> do
            let mCtx = case mTargetState of
                    Just (K8sState k8s) -> Just (context k8s)
                    _ -> Nothing
            case mCtx of
                Nothing -> pure $ object ["error" .= ("No K8s context available" :: Text)]
                Just ctx -> do
                    let ns = ctx.namespace
                        svcHost = ctx.serviceName
                    podResult <- liftIO $ runCmd (unwords [kubectlBin cfg, "-n", T.unpack ns, "get pods -l app=" <> T.unpack svcHost, "-o json"])
                    case podResult of
                        Left (K8sError err) -> pure $ object ["error" .= err]
                        Right (K8sResult out) ->
                            case A.decodeStrict' (encodeUtf8 out) :: Maybe Value of
                                Nothing -> pure $ object ["error" .= ("Failed to parse pod JSON" :: Text)]
                                Just podJson -> pure $ parsePodHealth podJson

parsePodHealth :: Value -> Value
parsePodHealth (Object root) =
    case KM.lookup (K.fromText "items") root of
        Just (Array items) ->
            let pods = map parseSinglePod (foldr (:) [] items)
                total = length pods
                running = length (filter (\p -> getStr' "status" p == "Running") pods)
                pending = length (filter (\p -> getStr' "status" p == "Pending") pods)
                failed = length (filter (\p -> getStr' "status" p == "Failed") pods)
                unknown = total - running - pending - failed
             in object
                    [ "pods" .= pods
                    , "summary" .= object
                        [ "total" .= total
                        , "running" .= running
                        , "pending" .= pending
                        , "failed" .= failed
                        , "unknown" .= unknown
                        ]
                    ]
        _ -> object ["pods" .= ([] :: [Value]), "summary" .= object ["total" .= (0 :: Int), "running" .= (0 :: Int), "pending" .= (0 :: Int), "failed" .= (0 :: Int), "unknown" .= (0 :: Int)]]
parsePodHealth _ = object ["pods" .= ([] :: [Value]), "summary" .= object ["total" .= (0 :: Int), "running" .= (0 :: Int), "pending" .= (0 :: Int), "failed" .= (0 :: Int), "unknown" .= (0 :: Int)]]

parseSinglePod :: Value -> Value
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
        -- Get version from container image tag
        versionVal = case getObj' "spec" podObj >>= getArr' "containers" of
            Just (c : _) -> extractImageTag c
            _ -> ""
     in object
            [ "name" .= nameVal
            , "status" .= phaseVal
            , "ready" .= readyVal
            , "restarts" .= restartsVal
            , "age" .= ageVal
            , "version" .= versionVal
            ]
parseSinglePod _ = object ["name" .= ("" :: Text), "status" .= ("Unknown" :: Text), "ready" .= False, "restarts" .= (0 :: Int), "age" .= ("" :: Text), "version" .= ("" :: Text)]

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

getStr' :: Text -> Value -> Text
getStr' key (Object obj) = case KM.lookup (K.fromText key) obj of Just (String t) -> t; _ -> ""
getStr' _ _ = ""

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
                            -- Do NOT touch VirtualService — old deployment may be scaled down already
                            let ns = T.unpack ((\(K8sReleaseContext{namespace = n}) -> n) ctx)
                                newDepName = T.unpack (deploymentName ctx)
                                oldImage = T.unpack (NT.oldVersion tracker)
                                cName = T.unpack ((\(K8sReleaseContext{containerName = c}) -> c) ctx)
                            -- Step 1: Set image to old version on the new deployment
                            let setImageCmd = unwords [kubectlBin cfg, "set", "image", "deployment/" <> newDepName, cName <> "=" <> oldImage, "-n", ns]
                            imgResult <- liftIO $ executeWithRetry cfg setImageCmd
                            case imgResult of
                                Left (K8sError err) -> pure $ APIResponse "ERROR" ("Failed to set image: " <> err)
                                Right _ -> do
                                    -- Step 2: Rollout restart to force pod restart with old image
                                    let restartCmd = unwords [kubectlBin cfg, "rollout", "restart", "deployment/" <> newDepName, "-n", ns]
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
-- Resources Endpoint (GET /resources?PRODUCT=&SERVICE=)
-- ============================================================================

fetchResourcesH :: Maybe Text -> Maybe Text -> Flow Value
fetchResourcesH mProduct mService = do
    cfg <- getConfig
    db <- getDBEnv
    case (mProduct, mService) of
        (Just productName, Just serviceName') -> do
            p <- liftIO $ findProductByName db productName
            case p of
                Nothing -> pure $ object ["error" .= ("Product not found" :: Text)]
                Just pCfg -> do
                    svc <- liftIO $ findServiceByProductAndName db productName serviceName'
                    let svcHost = case svc of
                            Just s -> fromMaybe serviceName' (getServiceHost s)
                            Nothing -> serviceName'
                        ns = getProductNamespace pCfg
                        vsName' = getProductVsName pCfg
                    -- Get the running version from VS
                    versionResult <- liftIO $ getPrimarySubsetFromVirtualService cfg ns vsName' svcHost
                    case versionResult of
                        Left err -> pure $ object ["error" .= err]
                        Right Nothing -> pure $ object ["error" .= ("No running version found" :: Text)]
                        Right (Just runningVersion) -> do
                            let fullDepName = svcHost <> "-" <> runningVersion
                            resResult <- liftIO $ runCmd (unwords [kubectlBin cfg, "-n", T.unpack ns, "get deployment", T.unpack fullDepName, "-o jsonpath='{.spec.template.spec.containers[0].resources}'"])
                            case resResult of
                                Left (K8sError err) -> pure $ object ["error" .= err]
                                Right (K8sResult out) ->
                                    let cleaned = T.strip (T.dropWhile (== '\'') (T.dropWhileEnd (== '\'') (T.strip out)))
                                     in case A.decodeStrict' (encodeUtf8 cleaned) :: Maybe Value of
                                            Just v -> pure v
                                            Nothing -> pure $ object ["requests" .= object [], "limits" .= object []]
        _ -> pure $ object ["error" .= ("PRODUCT and SERVICE query params required" :: Text)]

-- ============================================================================
-- Product Config CRUD (GET/POST/GET/:id/PUT/:id/DELETE/:id /products/config)
-- ============================================================================

listProductConfigsH :: Flow [ProductConfigResponse]
listProductConfigsH = do
    db <- getDBEnv
    rows <- liftIO $ listProducts db
    pure $ map toProductConfigResponse rows

toProductConfigResponse :: S.ProductConfig -> ProductConfigResponse
toProductConfigResponse p =
    ProductConfigResponse
        { id = S.productConfigId p
        , product = S.productName p
        , repoName = S.productRepoName p
        , productType = S.productType p
        , productAcronym = S.productAcronym p
        , releaseBranch = S.productReleaseBranch p
        , needInfraApproval = S.productNeedInfraApproval p
        , cluster = Just (getProductCluster p)
        , namespace = Just (getProductNamespace p)
        , vsName = Just (getProductVsName p)
        , syncCluster = getProductSyncCluster p
        }

createProductConfigH :: UpsertProductReq -> Flow APIResponse
createProductConfigH req = upsertProductH req

getProductConfigH :: Int32 -> Flow Value
getProductConfigH pid = do
    db <- getDBEnv
    m <- liftIO $ findProductConfigById db pid
    case m of
        Nothing -> pure $ object ["error" .= ("Product config not found" :: Text)]
        Just p -> pure $ toJSON (toProductConfigResponse p)

updateProductConfigH :: Int32 -> UpsertProductReq -> Flow APIResponse
updateProductConfigH _ req = upsertProductH req

deleteProductConfigH :: Int32 -> Flow APIResponse
deleteProductConfigH pid = do
    db <- getDBEnv
    liftIO $ deleteProductConfig db pid
    pure $ APIResponse "SUCCESS" "Product config deleted"

-- ============================================================================
-- Release Config CRUD (GET/POST/GET/:id/PUT/:id/DELETE/:id /services/config)
-- ============================================================================

listReleaseConfigsH :: Maybe Text -> Flow [ReleaseConfigResponse]
listReleaseConfigsH mProduct = do
    db <- getDBEnv
    rows <- case mProduct of
        Just p -> liftIO $ listReleaseConfigByProduct db p
        Nothing -> liftIO $ listAllReleaseConfigs db
    pure $ map toReleaseConfigResponse rows

toReleaseConfigResponse :: S.ReleaseConfig -> ReleaseConfigResponse
toReleaseConfigResponse r =
    ReleaseConfigResponse
        { id = S.releaseConfigId r
        , serviceName = S.serviceName r
        , serviceProduct = S.serviceProduct r
        , serviceType = S.serviceType r
        , emails = S.releaseConfigEmails r
        , rolloutStrategy = S.releaseConfigRolloutStrategy r
        , decisionConfig = S.releaseConfigDecisionConfig r
        , flags = S.releaseConfigFlags r
        , slackWebhookUrls = S.releaseConfigSlackWebhookUrls r
        , serviceAcronym = S.serviceAcronym r
        , bitbucketPath = S.releaseConfigBitbucketPath r
        , microserviceType = S.releaseConfigMicroserviceType r
        , revertStrategy = S.releaseConfigRevertStrategy r
        , jiraWebhookUrl = S.releaseConfigJiraWebhookUrl r
        , serviceHost = getServiceHost r
        }

createReleaseConfigH :: UpsertServiceReq -> Flow APIResponse
createReleaseConfigH req = upsertServiceH req

getReleaseConfigH :: Int32 -> Flow Value
getReleaseConfigH rid = do
    db <- getDBEnv
    m <- liftIO $ findReleaseConfigById db rid
    case m of
        Nothing -> pure $ object ["error" .= ("Release config not found" :: Text)]
        Just r -> pure $ toJSON (toReleaseConfigResponse r)

updateReleaseConfigH :: Int32 -> UpsertServiceReq -> Flow APIResponse
updateReleaseConfigH _ req = upsertServiceH req

deleteReleaseConfigH :: Int32 -> Flow APIResponse
deleteReleaseConfigH rid = do
    db <- getDBEnv
    liftIO $ deleteReleaseConfig db rid
    pure $ APIResponse "SUCCESS" "Release config deleted"

-- ============================================================================
-- VS Edit Tracker CRUD
-- ============================================================================

vsEditTrackerToJson :: S.VsEditTracker -> Value
vsEditTrackerToJson t =
    object
        [ "id" .= S.vetId t
        , "product" .= S.vetProduct t
        , "service" .= S.vetService t
        , "env" .= S.vetEnv t
        , "vs_name" .= S.vetVsName t
        , "old_vs_data" .= S.vetOldVsData t
        , "new_vs_data" .= S.vetNewVsData t
        , "status" .= S.vetStatus t
        , "created_by" .= S.vetCreatedBy t
        , "approved_by" .= S.vetApprovedBy t
        , "is_locked" .= S.vetIsLocked t
        , "locked_by" .= S.vetLockedBy t
        , "locked_at" .= S.vetLockedAt t
        , "lock_expiry" .= S.vetLockExpiry t
        , "monitoring_end_time" .= S.vetMonitoringEndTime t
        , "info" .= S.vetInfo t
        , "created_at" .= S.vetCreatedAt t
        , "updated_at" .= S.vetUpdatedAt t
        ]

createVsEditTrackerH :: CreateVsEditTrackerReq -> Flow Value
createVsEditTrackerH CreateVsEditTrackerReq{..} = do
    db <- getDBEnv
    now <- liftIO getCurrentTime
    tid <- liftIO (UUID.toText <$> UUID.nextRandom)
    -- Check for existing active lock
    mLock <- liftIO $ findActiveLock db product vsName env now
    case mLock of
        Just existing ->
            pure $ object
                [ "error" .= ("VS is already locked by " <> fromMaybe "unknown" (S.vetLockedBy existing) :: Text)
                , "locked_by" .= S.vetLockedBy existing
                , "lock_expiry" .= S.vetLockExpiry existing
                ]
        Nothing -> do
            let lockExpiry = addUTCTime (15 * 60) now -- 15 min default
                row = S.VsEditTrackerT
                    { vetId = tid
                    , vetProduct = product
                    , vetService = service
                    , vetEnv = env
                    , vetVsName = vsName
                    , vetOldVsData = oldVsData
                    , vetNewVsData = Nothing
                    , vetStatus = "CREATED"
                    , vetCreatedBy = createdBy
                    , vetApprovedBy = Nothing
                    , vetIsLocked = Just True
                    , vetLockedBy = Just createdBy
                    , vetLockedAt = Just now
                    , vetLockExpiry = Just lockExpiry
                    , vetMonitoringEndTime = Nothing
                    , vetInfo = info
                    , vetCreatedAt = now
                    , vetUpdatedAt = now
                    }
            liftIO $ insertVsEditTracker db row
            pure $ vsEditTrackerToJson row

listVsEditTrackersH :: Maybe Text -> Maybe Text -> Flow [Value]
listVsEditTrackersH mFrom mTo = do
    db <- getDBEnv
    let tryParse t = case parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" (T.unpack t) of
            Just v -> Just v
            Nothing -> parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Q%z" (T.unpack t)
        from = mFrom >>= tryParse
        to = mTo >>= tryParse
    rows <- liftIO $ listVsEditTrackers db from to
    pure $ map vsEditTrackerToJson rows

getVsEditTrackerH :: Text -> Flow Value
getVsEditTrackerH tid = do
    db <- getDBEnv
    m <- liftIO $ findVsEditTrackerById db tid
    case m of
        Nothing -> pure $ object ["error" .= ("VS edit tracker not found" :: Text)]
        Just t -> pure $ vsEditTrackerToJson t

updateVsEditTrackerH :: Text -> UpdateVsEditTrackerReq -> Flow APIResponse
updateVsEditTrackerH tid UpdateVsEditTrackerReq{..} = do
    db <- getDBEnv
    now <- liftIO getCurrentTime
    m <- liftIO $ findVsEditTrackerById db tid
    case m of
        Nothing -> pure $ APIResponse "ERROR" "VS edit tracker not found"
        Just existing -> do
            let updated = existing
                    { S.vetNewVsData = case newVsData of
                        Just d -> Just d
                        Nothing -> S.vetNewVsData existing
                    , S.vetStatus = fromMaybe (S.vetStatus existing) status
                    , S.vetApprovedBy = case approvedBy of
                        Just a -> Just a
                        Nothing -> S.vetApprovedBy existing
                    , S.vetInfo = case info of
                        Just i -> Just i
                        Nothing -> S.vetInfo existing
                    , S.vetUpdatedAt = now
                    }
            liftIO $ updateVsEditTracker db updated
            case status of
                Just "APPLIED" -> liftIO $ notifyVsEditApplied db (S.vetProduct existing) (S.vetService existing) (fromMaybe "admin" approvedBy)
                _ -> pure ()
            pure $ APIResponse "SUCCESS" "VS edit tracker updated"

lockVsEditTrackerH :: VsLockReq -> Flow APIResponse
lockVsEditTrackerH VsLockReq{..} = do
    db <- getDBEnv
    cfg <- getConfig
    now <- liftIO getCurrentTime
    -- Resolve vsName from product_config if not provided
    mProdCfg <- liftIO $ findProductByNameAndCluster db product ""
    let resolvedVsName = fromMaybe (maybe "" getProductVsName mProdCfg) vsName
        resolvedEnv = fromMaybe (envName cfg) env
        resolvedService = fromMaybe "" service
        resolvedLockedBy = fromMaybe "admin" lockedBy
    -- Check for existing active lock
    mLock <- liftIO $ findActiveLock db product resolvedVsName resolvedEnv now
    case mLock of
        Just existing ->
            pure $ APIResponse "ERROR" ("VS already locked by " <> fromMaybe "unknown" (S.vetLockedBy existing))
        Nothing -> do
            tid <- liftIO (UUID.toText <$> UUID.nextRandom)
            let durationSecs = fromIntegral (fromMaybe 15 lockDurationMinutes) * 60
                lockExpiry = addUTCTime durationSecs now
                row = S.VsEditTrackerT
                    { vetId = tid
                    , vetProduct = product
                    , vetService = resolvedService
                    , vetEnv = resolvedEnv
                    , vetVsName = resolvedVsName
                    , vetOldVsData = oldVsData
                    , vetNewVsData = Nothing
                    , vetStatus = "LOCKED"
                    , vetCreatedBy = resolvedLockedBy
                    , vetApprovedBy = Nothing
                    , vetIsLocked = Just True
                    , vetLockedBy = Just resolvedLockedBy
                    , vetLockedAt = Just now
                    , vetLockExpiry = Just lockExpiry
                    , vetMonitoringEndTime = Nothing
                    , vetInfo = Nothing
                    , vetCreatedAt = now
                    , vetUpdatedAt = now
                    }
            liftIO $ insertVsEditTracker db row
            liftIO $ notifyVsEditLocked db product (fromMaybe "" service) (fromMaybe "admin" lockedBy)
            pure $ APIResponse "SUCCESS" ("VS locked. Tracker ID: " <> tid)

unlockVsEditTrackerH :: VsUnlockReq -> Flow APIResponse
unlockVsEditTrackerH VsUnlockReq{..} = do
    db <- getDBEnv
    now <- liftIO getCurrentTime
    -- Can unlock by trackerId OR by product+vsName+env
    case trackerId of
        Just tid -> do
            m <- liftIO $ findVsEditTrackerById db tid
            case m of
                Nothing -> pure $ APIResponse "ERROR" "Tracker not found"
                Just existing -> do
                    let updated = existing { S.vetIsLocked = Just False, S.vetLockExpiry = Just now, S.vetUpdatedAt = now, S.vetStatus = "UNLOCKED" }
                    liftIO $ updateVsEditTracker db updated
                    liftIO $ notifyVsEditUnlocked db (S.vetProduct existing) (S.vetService existing)
                    pure $ APIResponse "SUCCESS" "VS unlocked"
        Nothing -> do
            let p = fromMaybe "" product
                v = fromMaybe "" vsName
                e = fromMaybe "" env
            mLock <- liftIO $ findActiveLock db p v e now
            case mLock of
                Nothing -> pure $ APIResponse "ERROR" "No active lock found"
                Just existing -> do
                    let updated = existing { S.vetIsLocked = Just False, S.vetLockExpiry = Just now, S.vetUpdatedAt = now, S.vetStatus = "UNLOCKED" }
                    liftIO $ updateVsEditTracker db updated
                    liftIO $ notifyVsEditUnlocked db (S.vetProduct existing) (S.vetService existing)
                    pure $ APIResponse "SUCCESS" "VS unlocked"

revertVsEditTrackerH :: Text -> Flow APIResponse
revertVsEditTrackerH tid = do
    db <- getDBEnv
    now <- liftIO getCurrentTime
    m <- liftIO $ findVsEditTrackerById db tid
    case m of
        Nothing -> pure $ APIResponse "ERROR" "VS edit tracker not found"
        Just existing -> do
            case S.vetOldVsData existing of
                Nothing -> pure $ APIResponse "ERROR" "No old VS data to revert to"
                Just _oldData -> do
                    let updated = existing
                            { S.vetStatus = "REVERTED"
                            , S.vetUpdatedAt = now
                            }
                    liftIO $ updateVsEditTracker db updated
                    liftIO $ notifyVsEditReverted db (S.vetProduct existing) (S.vetService existing)
                    pure $ APIResponse "SUCCESS" "VS edit tracker marked as REVERTED"

-- | Fetch the current live VirtualService JSON from K8s
-- Uses the product_config's vsName (e.g. "atlas-vs"), NOT the service name
fetchCurrentVsH :: Maybe Text -> Maybe Text -> Flow Value
fetchCurrentVsH mProduct _mService = do
    cfg <- getConfig
    db <- getDBEnv
    case mProduct of
        Just prod -> do
            mProdCfg <- liftIO $ findProductByNameAndCluster db prod ""
            case mProdCfg of
                Nothing -> pure $ object ["error" .= ("No product_config found for " <> prod), "message" .= ("Configure product first" :: Text)]
                Just pCfg -> do
                    let ns = getProductNamespace pCfg
                        vsN = getProductVsName pCfg
                    if T.null vsN
                        then pure $ object ["error" .= ("No vsName configured for product " <> prod), "message" .= ("Set vsName in product config" :: Text)]
                        else do
                            result <- liftIO $ getVirtualServiceJson cfg ns vsN
                            case result of
                                Left err -> pure $ object ["error" .= show err, "message" .= ("Failed to fetch VirtualService" :: Text)]
                                Right vsText -> case eitherDecode (LBS.pack (T.unpack vsText)) of
                                    Right vsJson -> pure vsJson
                                    Left _ -> pure $ object ["data" .= vsText]
        _ -> pure $ object ["error" .= ("product query param required" :: Text)]
        _ -> pure $ object ["error" .= ("product and service query params required" :: Text)]
