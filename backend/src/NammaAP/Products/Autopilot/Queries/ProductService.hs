{-# LANGUAGE OverloadedStrings #-}

module NammaAP.Products.Autopilot.Queries.ProductService where

import Data.List (find)
import Data.Text (Text)
import Database.Beam
import GHC.Int (Int32)
import NammaAP.Core.DB.Connection (runDB)
import NammaAP.Core.Environment (DBEnv)
import NammaAP.Products.Autopilot.Types.Target.Kubernetes (K8sProductConfig(..), K8sServiceConfig(..), defaultK8sProductConfig)
import NammaAP.Products.Autopilot.Queries.ReleaseTracker (encodeJsonText, parseJsonTextMaybe)
import NammaAP.Products.Autopilot.Types.Storage.Schema

-- | Extract K8s product config from a ProductConfig row
getK8sProductConfig :: ProductConfig -> K8sProductConfig
getK8sProductConfig pc =
  case parseJsonTextMaybe (productTargetConfig pc) :: Maybe K8sProductConfig of
    Just cfg -> cfg
    Nothing  -> defaultK8sProductConfig

-- Named extractors to avoid field-name ambiguity at call sites
getProductCluster :: ProductConfig -> Text
getProductCluster = cluster . getK8sProductConfig

getProductNamespace :: ProductConfig -> Text
getProductNamespace = namespace . getK8sProductConfig

getProductVsName :: ProductConfig -> Text
getProductVsName = vsName . getK8sProductConfig

getProductSyncCluster :: ProductConfig -> Maybe Text
getProductSyncCluster = syncCluster . getK8sProductConfig

getProductVsLockedBy :: ProductConfig -> Maybe Text
getProductVsLockedBy = vsLockedBy . getK8sProductConfig

-- | Extract service host from a ReleaseConfig row
getServiceHost :: ReleaseConfig -> Maybe Text
getServiceHost rc =
  case parseJsonTextMaybe (serviceTargetConfig rc) :: Maybe K8sServiceConfig of
    Just cfg -> serviceHost cfg
    Nothing  -> Nothing

upsertProduct ::
  DBEnv ->
  Int32 ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Maybe Text ->
  Maybe Bool ->
  IO ()
upsertProduct db rowId productName' cluster' namespace' vsName' repoName productType productAcronym releaseBranch syncCluster' needInfraApproval = do
  let k8sCfg = K8sProductConfig
        { cluster = cluster'
        , namespace = namespace'
        , vsName = vsName'
        , kubeContext = Just cluster'
        , syncCluster = syncCluster'
        , vsLockedBy = Nothing
        , vsLockTimestamp = Nothing
        }
      row :: ProductConfig
      row =
        ProductConfigT
          { productConfigId = rowId,
            productName = productName',
            productRepoName = repoName,
            productType = productType,
            productAcronym = productAcronym,
            productReleaseBranch = releaseBranch,
            productNeedInfraApproval = needInfraApproval,
            productTargetConfig = Just (encodeJsonText k8sCfg)
          }
  runDB db $ do
    runDelete $
      delete (productConfig nammaAPDb) (\p -> productName p ==. val_ productName')
    runInsert $
      insert (productConfig nammaAPDb) $
        insertValues [row]

upsertService ::
  DBEnv ->
  Int32 ->
  Maybe Text ->
  Maybe Text ->
  Maybe Text ->
  Text ->
  Text ->
  Text ->
  Maybe Text ->
  Maybe Text ->
  Maybe Text ->
  IO ()
upsertService db rowId emails rolloutStrategy decisionConfig serviceName' product' sType serviceHost' bitbucketPath revertStrategy = do
  let svcCfg = K8sServiceConfig { serviceHost = serviceHost' }
      row :: ReleaseConfig
      row =
        ReleaseConfigT
          { releaseConfigId = rowId,
            releaseConfigEmails = emails,
            releaseConfigRolloutStrategy = rolloutStrategy,
            releaseConfigDecisionConfig = decisionConfig,
            serviceName = serviceName',
            serviceProduct = product',
            releaseConfigFlags = Nothing,
            releaseConfigSlackWebhookUrls = Nothing,
            serviceAcronym = Nothing,
            serviceType = sType,
            releaseConfigBitbucketPath = bitbucketPath,
            releaseConfigMicroserviceType = Nothing,
            releaseConfigRevertStrategy = revertStrategy,
            releaseConfigJiraWebhookUrl = Nothing,
            serviceTargetConfig = Just (encodeJsonText svcCfg)
          }
  runDB db $ do
    runDelete $
      delete (releaseConfig nammaAPDb) (\s -> serviceProduct s ==. val_ product' &&. serviceName s ==. val_ serviceName')
    runInsert $
      insert (releaseConfig nammaAPDb) $
        insertValues [row]

findProductByName :: DBEnv -> Text -> IO (Maybe ProductConfig)
findProductByName db pName = do
  rows <-
    runDB db $
      runSelectReturningList $
        select $ do
          p <- all_ (productConfig nammaAPDb)
          guard_ (productName p ==. val_ pName)
          pure p
  pure $ case rows of
    [] -> Nothing
    (x : _) -> Just x

findProductByNameAndCluster :: DBEnv -> Text -> Text -> IO (Maybe ProductConfig)
findProductByNameAndCluster db pName clusterName = do
  rows <- listProductsByName db pName
  pure $ find (\p -> getProductCluster p == clusterName) rows

listProductsByName :: DBEnv -> Text -> IO [ProductConfig]
listProductsByName db pName =
  runDB db $
    runSelectReturningList $
      select $ do
        p <- all_ (productConfig nammaAPDb)
        guard_ (productName p ==. val_ pName)
        pure p

findServiceByProductAndName :: DBEnv -> Text -> Text -> IO (Maybe ReleaseConfig)
findServiceByProductAndName db pName sName = do
  rows <-
    runDB db $
      runSelectReturningList $
        select $ do
          s <- all_ (releaseConfig nammaAPDb)
          guard_ (serviceProduct s ==. val_ pName)
          guard_ (serviceName s ==. val_ sName)
          pure s
  pure $ case rows of
    [] -> Nothing
    (x : _) -> Just x

listProducts :: DBEnv -> IO [ProductConfig]
listProducts db =
  runDB db $
    runSelectReturningList $
      select $
        all_ (productConfig nammaAPDb)

listReleaseConfigByProduct :: DBEnv -> Text -> IO [ReleaseConfig]
listReleaseConfigByProduct db pName =
  runDB db $
    runSelectReturningList $
      select $ do
        s <- all_ (releaseConfig nammaAPDb)
        guard_ (serviceProduct s ==. val_ pName)
        pure s

listSchedulerServicesByProduct :: DBEnv -> Text -> IO [ReleaseConfig]
listSchedulerServicesByProduct db pName =
  runDB db $
    runSelectReturningList $
      select $ do
        s <- all_ (releaseConfig nammaAPDb)
        guard_ (serviceProduct s ==. val_ pName)
        guard_ (serviceType s ==. val_ "SCHEDULER")
        pure s
