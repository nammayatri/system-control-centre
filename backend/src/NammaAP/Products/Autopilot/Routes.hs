{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

module NammaAP.Products.Autopilot.Routes where

import qualified Data.Aeson as A
import Data.Aeson (Value (..), toJSON, object, (.=))
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, getCurrentTime, addUTCTime)
import Data.Time.Format (parseTimeM, defaultTimeLocale)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import Control.Concurrent (forkIO)
import Control.Exception (SomeException, try)
import Control.Monad (when, void)
import Control.Monad.IO.Class (liftIO)
import Data.Text.Encoding (encodeUtf8)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import NammaAP.Products.Autopilot.Discovery (listServicesFromVirtualService)
import NammaAP.Products.Autopilot.K8s.Kubectl (getPrimarySubsetFromVirtualService)
import NammaAP.Products.Autopilot.K8s.Deployment (getDeploymentEnvs)
import NammaAP.Products.Autopilot.K8s.Execute (runCmd, K8sResult (..))
import NammaAP.Core.Config (Config (..))
import NammaAP.Core.Config.Runtime (isApproveAllReleases)
import NammaAP.Products.Autopilot.Sync (triggerImmediateRevertSync)
import NammaAP.Products.Autopilot.Queries.ProductService
import NammaAP.Products.Autopilot.Queries.ReleaseTracker
import NammaAP.Products.Autopilot.Queries.ServerConfig (listAllServerConfigs, upsertServerConfig)
import NammaAP.Products.Autopilot.Types
import qualified NammaAP.Products.Autopilot.Types as NT
import NammaAP.Products.Autopilot.Types.Target (TargetState(..), emptyConfigState)
import NammaAP.Products.Autopilot.Types.Target.Kubernetes
import NammaAP.Products.Autopilot.Types.API
import qualified NammaAP.Shared.Types.Storage.Schema as S
import NammaAP.Core.Utils.FlowMonad (Flow, getConfig, getDBEnv)
import Servant

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

upsertProductH :: UpsertProductReq -> Flow APIResponse
upsertProductH UpsertProductReq {..} = do
  db <- getDBEnv
  liftIO $ upsertProduct db id product cluster namespace vsName repoName productType productAcronym releaseBranch syncCluster needInfraApproval
  pure $ APIResponse "SUCCESS" "product_config upserted"

listProductsH :: Flow [ProductResponse]
listProductsH = do
  db <- getDBEnv
  rows <- liftIO $ listProducts db
  pure $
    map
      ( \p ->
          ProductResponse
            { product = S.productName p,
              cluster = getProductCluster p,
              namespace = getProductNamespace p,
              vsName = getProductVsName p,
              productType = S.productType p,
              productAcronym = S.productAcronym p,
              syncCluster = getProductSyncCluster p
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
upsertServiceH UpsertServiceReq {..} = do
  db <- getDBEnv
  liftIO $ upsertService db id emails rolloutStrategyText decisionConfigText service product serviceType serviceHost bitbucketPath revertStrategyText
  pure $ APIResponse "SUCCESS" "release_config upserted"

listReleasesH :: Maybe Text -> Maybe Text -> Flow [ReleaseTracker]
listReleasesH _ _ = do
  db <- getDBEnv
  pairs <- liftIO $ listReleaseTrackers db
  pure (map fst pairs)

createReleaseH :: Maybe Text -> Maybe Text -> K8sCreateReleaseReq -> Flow APIResponse
createReleaseH mXForwardedEmail mXPomeriumJwt req@K8sCreateReleaseReq {..} = do
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
          let initialApproval = case isApproved of
                Just True -> True
                _ -> approveAll && fromMaybe False isSystemTriggered
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
                  , releaseTag = releaseTag
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
              targetState = K8sState $ emptyK8sState
                { context = derivedContext
                , newService = fromMaybe False newService
                , isArtRecorder = fromMaybe 0 isArtRecorder
                , cronjobSuspend = fromMaybe False cronjobSuspend
                }
          liftIO $ insertReleaseTracker db tracker (Just targetState)
          liftIO $ insertReleaseEvent db rid "BUSINESS" "TRACKER_CREATED" (toJSON tracker)
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
          updated = (tracker :: ReleaseTracker)
            { NT.approvedBy = Just approver
            , NT.isApproved = True
            , NT.isInfraApproved = fromMaybe (NT.isInfraApproved tracker) infraApproval
            }
      liftIO $ insertReleaseTracker db updated mTargetState
      liftIO $ insertReleaseEvent db rid "BUSINESS" "TRACKER_APPROVED" (toJSON approver)
      pure (Just updated)

triggerReleaseH :: Text -> TriggerReleaseReq -> Flow APIResponse
triggerReleaseH rid TriggerReleaseReq {..} = do
  db <- getDBEnv
  m <- liftIO $ findReleaseTracker db rid
  case m of
    Nothing -> pure $ APIResponse "ERROR" "Release not found"
    Just (tracker, mTargetState) -> do
      now <- liftIO getCurrentTime
      let updated = (tracker :: ReleaseTracker) {NT.scheduleTime = Just now, NT.status = Created}
      liftIO $ insertReleaseTracker db updated mTargetState
      liftIO $ insertReleaseEvent db rid "BUSINESS" "TRACKER_TRIGGERED" (toJSON reason)
      pure $ APIResponse "SUCCESS" "Release scheduled for execution"

rollbackReleaseH :: Text -> TriggerReleaseReq -> Flow APIResponse
rollbackReleaseH rid TriggerReleaseReq {..} = do
  db <- getDBEnv
  m <- liftIO $ findReleaseTracker db rid
  case m of
    Nothing -> pure $ APIResponse "ERROR" "Release not found"
    Just (tracker, mTargetState) -> do
      if not (validateStatusTransition (NT.status tracker) Aborting)
        then pure $ APIResponse "ERROR" ("Cannot rollback from status: " <> T.pack (show (NT.status tracker)))
        else do
          let updated = (tracker :: ReleaseTracker) {NT.status = Aborting, NT.releaseWFStatus = RollingBack}
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
          shouldSyncRevert = fromMaybe False (isRevertSync req) && origUdf1
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
          revertedTargetState = K8sState $ emptyK8sState { context = revertedContext }
          revertedTracker =
            (tracker :: ReleaseTracker)
              { NT.releaseId = newRid
              , NT.status = Created
              , NT.releaseWFStatus = Init
              , NT.createdBy = fromMaybe trackerCreatedBy (requestedBy req)
              , NT.approvedBy = if isImmediate then Just (fromMaybe trackerCreatedBy (requestedBy req)) else Nothing
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
      liftIO $ insertReleaseEvent db newRid "BUSINESS" "REVERT_TRACKER_CREATED"
        (object [ "originalId" .= rid
                , "shouldSyncRevert" .= shouldSyncRevert
                , "isImmediate" .= isImmediate
                , "origUdf1" .= origUdf1
                ])
      when (isImmediate && shouldSyncRevert) $
        liftIO $ triggerImmediateRevertSync cfg db tracker mTargetState
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
discardReleaseH rid DiscardReleaseReq {..} = do
  db <- getDBEnv
  m <- liftIO $ findReleaseTracker db rid
  case m of
    Nothing -> pure $ APIResponse "ERROR" "Release not found"
    Just (tracker, mTargetState) ->
      if not (validateStatusTransition (NT.status tracker) Discarded)
        then pure $ APIResponse "ERROR" ("Cannot discard from status: " <> T.pack (show (NT.status tracker)))
        else do
          let updated = (tracker :: ReleaseTracker) {NT.status = Discarded}
          liftIO $ insertReleaseTracker db updated mTargetState
          liftIO $ insertReleaseEvent db rid "BUSINESS" "STATUS_UPDATED"
            (toJSON ("Tracker marked as DISCARDED" <> maybe "" (": " <>) reason))
          pure $ APIResponse "SUCCESS" "Release discarded"

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
              pure $ APIResponse "SUCCESS" "Tracker updated"
        Nothing -> do
          liftIO $ insertReleaseTracker db updatedTracker updatedTargetState
          liftIO $ insertReleaseEvent db rid "BUSINESS" "TRACKER_UPDATED" (toJSON updatedTracker)
          pure $ APIResponse "SUCCESS" "Tracker updated"

applyUpdates :: ReleaseTracker -> Maybe TargetState -> K8sUpdateTrackerReq -> (ReleaseTracker, Maybe TargetState)
applyUpdates tracker mts req =
  let t1 = case req.status of
              Just s -> (tracker :: ReleaseTracker) {NT.status = parseReleaseStatus s}
              Nothing -> tracker
      t2 = case req.mode of
              Just "MANUAL" -> t1 {NT.mode = Manual}
              Just "AUTO" -> t1 {NT.mode = Auto}
              _ -> t1
      t3 = case req.releaseManager of
              Just rm -> t2 {NT.createdBy = rm}
              Nothing -> t2
      t4 = case req.priority of
              Just p -> t3 {NT.priority = p}
              Nothing -> t3
      t5 = case req.scheduleTime of
              Just st -> t4 {NT.scheduleTime = Just st}
              Nothing -> t4
      t6 = case req.description of
              Just d -> t5 {NT.description = Just d}
              Nothing -> t5
      t7 = case req.info of
              Just i -> t6 {NT.info = Just i}
              Nothing -> t6
      t8 = case req.rolloutStrategy of
              Just rs -> t7 {NT.rolloutStrategy = rs}
              Nothing -> t7
      t9 = case req.changeLog of
              Just cl -> t8 {NT.changeLog = Just cl}
              Nothing -> t8
      t10 = case req.isApproved of
              Just a -> t9 {NT.isApproved = a}
              Nothing -> t9
      t11 = case req.isInfraApproved of
              Just a -> t10 {NT.isInfraApproved = a}
              Nothing -> t10
      t12 = case req.udf1 of
              Just u -> t11 {NT.udf1 = Just u}
              Nothing -> t11
      t13 = case req.udf2 of
              Just u -> t12 {NT.udf2 = Just u}
              Nothing -> t12
      t14 = case req.udf3 of
              Just u -> t13 {NT.udf3 = Just u}
              Nothing -> t13
      ts1 = case req.dockerImage of
              Just img -> updateK8sContext mts (\ctx -> ctx {dockerImage = Just img})
              Nothing -> mts
      ts2 = case req.podsScaleDownDelay of
              Just d -> updateK8sContext ts1 (\ctx -> ctx {podsScaleDownDelay = Just d})
              Nothing -> ts1
  in (t14, ts2)

updateK8sContext :: Maybe TargetState -> (K8sReleaseContext -> K8sReleaseContext) -> Maybe TargetState
updateK8sContext (Just (K8sState k8s)) f = Just $ K8sState $ k8s { context = f (context k8s) }
updateK8sContext other _ = other

listEventsH :: Text -> Flow [Value]
listEventsH rid = do
  db <- getDBEnv
  events <- liftIO $ listReleaseEvents db rid
  pure $ fmap (\e -> object
    [ "category" .= S.reCategory e
    , "label" .= S.reLabel e
    , "data" .= S.rePayload e
    , "timestamp" .= S.reCreatedAt e
    ]) events


listConfigMapsH :: Maybe Text -> Maybe Text -> Flow Value
listConfigMapsH mFrom mTo = do
  db <- getDBEnv
  now <- liftIO getCurrentTime
  let tryParse t = case parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" (T.unpack t) of
                     Just v -> Just v
                     Nothing -> parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Q%z" (T.unpack t)
      from = fromMaybe (addUTCTime (-2592000) now) (mFrom >>= tryParse)
      to   = fromMaybe now (mTo >>= tryParse)
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
      let cmMetadata = object $ concat
            [ maybe [] (\c -> ["config" .= c]) config'
            , maybe [] (\c -> ["file" .= c]) config'
            , maybe [] (\n -> ["name" .= n]) name'
            , maybe [] (\c -> ["cluster" .= c]) (if T.null cluster' then Nothing else Just cluster')
            ]
          tracker = ReleaseTracker
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
      -- Handle sync to secondary cluster
      let isSync = case body of
            Object o -> isTruthy "isSync" o
            _ -> False
      cfg <- getConfig
      when (isSync && not (null (syncClusterUrl cfg))) $ do
        let rawUrl = syncClusterUrl cfg
            normalised = let u = if "http" `T.isPrefixOf` T.pack rawUrl then rawUrl else "http://" <> rawUrl
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
            postCurlArgs = ["-s", "-X", "POST", postUrl
                           , "-H", "Content-Type: application/json"
                           , "-d", LBS.unpack (A.encode syncBody)
                           , "--max-time", "30"
                           ] <> authArgs
        liftIO $ insertReleaseEvent db rid "BUSINESS" "CONFIGMAP_SYNC_REQUEST"
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
    , "date_created" .= NT.startTime rt  -- Use startTime as proxy; will use DB createdAt
    , "last_updated" .= NT.endTime rt
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
extractCmFields (Object obj) = Right
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
              Just "CREATED" -> rt { NT.status = Created }
              Just "INPROGRESS" -> rt { NT.status = InProgress }
              Just "COMPLETED" -> rt { NT.status = Completed }
              Just "ABORTED" -> rt { NT.status = Aborted }
              _ -> rt
      rt2 = maybe rt1 (\s -> rt1 { NT.description = Just s }) (getStrM "description" obj)
      rt3 = maybe rt2 (\s -> rt2 { NT.changeLog = Just s }) (getStrM "change_log" obj)
      rt4 = if isTruthy "is_approved" obj then rt3 { NT.isApproved = True } else rt3
      rt5 = if isTruthy "is_infra_approved" obj then rt4 { NT.isInfraApproved = True } else rt4
      -- Update metadata fields (config/file/commit)
      oldMeta = case NT.metadata rt5 of
                  Just (Object o) -> o
                  _ -> KM.empty
      newMeta1 = case firstJust (getStrM "file" obj) (getStrM "config" obj) of
                   Just c -> KM.insert (K.fromText "config") (String c)
                           $ KM.insert (K.fromText "file") (String c) oldMeta
                   Nothing -> oldMeta
      newMeta2 = case getStrM "commit" obj of
                   Just c -> KM.insert (K.fromText "commit") (String c) newMeta1
                   Nothing -> newMeta1
      rt6 = rt5 { NT.metadata = Just (Object newMeta2) }
  in rt6
applyCmUpdates rt _ = rt

isTruthy :: Text -> KM.KeyMap Value -> Bool
isTruthy k obj = case KM.lookup (K.fromText k) obj of
  Just (String t) -> t `elem` ["true", "1", "True", "yes"]
  Just (Number n) -> n > 0
  Just (Bool b)   -> b
  _ -> False

getStr :: Text -> KM.KeyMap Value -> Text
getStr k obj = case KM.lookup (K.fromText k) obj of { Just (String t) -> t; _ -> "" }

getStrM :: Text -> KM.KeyMap Value -> Maybe Text
getStrM k obj = case KM.lookup (K.fromText k) obj of { Just (String t) | not (T.null t) -> Just t; _ -> Nothing }

safeReadInt :: Text -> Maybe Int
safeReadInt t = case reads (T.unpack t) of { ((n, _) : _) -> Just n; _ -> Nothing }

firstJust :: Maybe a -> Maybe a -> Maybe a
firstJust (Just x) _ = Just x
firstJust Nothing b = b


listServerConfigH :: Flow Value
listServerConfigH = do
  db <- getDBEnv
  rows <- liftIO $ listAllServerConfigs db
  let toObj (rowId, typ, name, val, enabled) = object
        [ "id" .= rowId
        , "type" .= typ
        , "name" .= name
        , "value" .= val
        , "enabled" .= enabled
        ]
  pure $ object ["configs" .= map toObj rows]

upsertServerConfigH :: Value -> Flow APIResponse
upsertServerConfigH (Object obj) = do
  db <- getDBEnv
  let name = getStr "name" obj
      typ = fromMaybe "" (getStrM "type" obj)
      value = fromMaybe "" (getStrM "value" obj)
      enabled = maybe True (\t -> t == "1" || T.toLower t == "true") (getStrM "enabled" obj)
  if T.null name
    then pure $ APIResponse "ERROR" "name is required"
    else do
      liftIO $ upsertServerConfig db name typ value enabled
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
      let normalised = let u = if "http" `T.isPrefixOf` T.pack rawUrl then rawUrl else "http://" <> rawUrl
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

-- | Proxy env fetch to sync cluster URL for secondary cloud.
-- Tries the namma-ap endpoint format (GET /envs) first, then falls back to
-- ny-autopilot format (POST /release/getenvs/).
fetchSecondaryEnvsH :: Maybe Text -> Maybe Text -> Maybe Text -> Flow Value
fetchSecondaryEnvsH mProduct mEnv mService = do
  cfg <- getConfig
  case (mProduct, mEnv, mService) of
    (Just product', Just env', Just service') -> do
      let rawUrl = syncClusterUrl cfg
      if null rawUrl
        then pure $ toJSON ([] :: [Value])
        else do
          let normalised = let u = if "http" `T.isPrefixOf` T.pack rawUrl then rawUrl else "http://" <> rawUrl
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
          bodyJson = A.encode $ object
            [ "product" .= product'
            , "env" .= env'
            , "service" .= service'
            , "secondary" .= True
            ]
          postCurlArgs = ["-s", "-X", "POST", postUrl
                         , "-H", "Content-Type: application/json"
                         , "-d", LBS.unpack bodyJson
                         , "--max-time", "15"
                         ] <> authArgs
      liftIO $ putStrLn $ "[SYNC-ENV] Trying ny-autopilot format: POST " <> postUrl
      postResult <- liftIO (try (readProcessWithExitCode "curl" postCurlArgs "") :: IO (Either SomeException (ExitCode, String, String)))
      case postResult of
        Right (ExitSuccess, out, _) ->
          case A.decodeStrict' (encodeUtf8 (T.pack out)) of
            Just v -> pure v
            Nothing -> pure $ toJSON ([] :: [Value])
        _ -> pure $ toJSON ([] :: [Value])
