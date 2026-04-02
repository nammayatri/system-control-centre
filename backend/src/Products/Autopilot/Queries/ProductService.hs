{-# LANGUAGE OverloadedStrings #-}

module Products.Autopilot.Queries.ProductService where

import Core.DB.Connection (runDB)
import Core.Environment (DBEnv)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Database.Beam
import GHC.Int (Int32)
import Shared.Types.Storage.Schema

-- ============================================================================
-- Product-level queries (service IS NULL)
-- ============================================================================

-- | Named extractors for product-level fields (flat columns, no JSON parsing)
getProductCluster :: DeploymentConfig -> Text
getProductCluster = fromMaybe "" . dcCluster

getProductNamespace :: DeploymentConfig -> Text
getProductNamespace = fromMaybe "" . dcNamespace

getProductVsName :: DeploymentConfig -> Text
getProductVsName = fromMaybe "" . dcVsName

getProductSyncCluster :: DeploymentConfig -> Maybe Text
getProductSyncCluster = dcSyncCluster

getProductVsLockedBy :: DeploymentConfig -> Maybe Text
getProductVsLockedBy = dcVsLockedBy

-- | Extract service host from a service-level deployment config (flat column)
getServiceHost :: DeploymentConfig -> Maybe Text
getServiceHost = dcServiceHost

-- | Get slack channel for a service
getSlackChannelDirect :: DeploymentConfig -> Maybe Text
getSlackChannelDirect = dcSlackChannel

findProductByName :: DBEnv -> Text -> IO (Maybe DeploymentConfig)
findProductByName db pName = do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    p <- all_ (deploymentConfig nammaAPDb)
                    guard_ (dcProduct p ==. val_ pName)
                    guard_ (isNothing_ (dcService p))
                    pure p
    pure $ case rows of
        [] -> Nothing
        (x : _) -> Just x

findProductByNameAndCluster :: DBEnv -> Text -> Text -> IO (Maybe DeploymentConfig)
findProductByNameAndCluster db pName clusterName = do
    rows <- listProductsByName db pName
    pure $ case clusterName of
        "" -> safeHead rows
        _  -> case filter (\p -> getProductCluster p == clusterName) rows of
            (p:_) -> Just p
            []    -> safeHead rows
  where
    safeHead []    = Nothing
    safeHead (x:_) = Just x

listProductsByName :: DBEnv -> Text -> IO [DeploymentConfig]
listProductsByName db pName =
    runDB db $
        runSelectReturningList $
            select $ do
                p <- all_ (deploymentConfig nammaAPDb)
                guard_ (dcProduct p ==. val_ pName)
                guard_ (isNothing_ (dcService p))
                pure p

listProducts :: DBEnv -> IO [DeploymentConfig]
listProducts db =
    runDB db $
        runSelectReturningList $
            select $ do
                p <- all_ (deploymentConfig nammaAPDb)
                guard_ (isNothing_ (dcService p))
                pure p

-- ============================================================================
-- Service-level queries (service IS NOT NULL)
-- ============================================================================

findServiceByProductAndName :: DBEnv -> Text -> Text -> IO (Maybe DeploymentConfig)
findServiceByProductAndName db pName sName = do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    s <- all_ (deploymentConfig nammaAPDb)
                    guard_ (dcProduct s ==. val_ pName)
                    guard_ (dcService s ==. val_ (Just sName))
                    pure s
    pure $ case rows of
        [] -> Nothing
        (x : _) -> Just x

listReleaseConfigByProduct :: DBEnv -> Text -> IO [DeploymentConfig]
listReleaseConfigByProduct db pName =
    runDB db $
        runSelectReturningList $
            select $ do
                s <- all_ (deploymentConfig nammaAPDb)
                guard_ (dcProduct s ==. val_ pName)
                guard_ (isNothing_ (dcService s) ==. val_ False)
                pure s

listSchedulerServicesByProduct :: DBEnv -> Text -> IO [DeploymentConfig]
listSchedulerServicesByProduct db pName =
    runDB db $
        runSelectReturningList $
            select $ do
                s <- all_ (deploymentConfig nammaAPDb)
                guard_ (dcProduct s ==. val_ pName)
                guard_ (isNothing_ (dcService s) ==. val_ False)
                guard_ (dcServiceType s ==. val_ (Just "SCHEDULER"))
                pure s

-- ============================================================================
-- Upsert operations (delete + insert pattern)
-- ============================================================================

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
upsertProduct db rowId productName' cluster' namespace' vsName' repoName productType' productAcronym' releaseBranch syncCluster' needInfraApproval = do
    let row :: DeploymentConfig
        row =
            DeploymentConfigT
                { dcId = rowId
                , dcProduct = productName'
                , dcService = Nothing
                , dcCluster = Just cluster'
                , dcNamespace = Just namespace'
                , dcVsName = Just vsName'
                , dcProductAcronym = Just productAcronym'
                , dcProductType = Just productType'
                , dcRepoName = Just repoName
                , dcReleaseBranch = Just releaseBranch
                , dcSyncCluster = syncCluster'
                , dcNeedInfraApproval = needInfraApproval
                , dcVsLockedBy = Nothing
                , dcVsLockTimestamp = Nothing
                , dcServiceHost = Nothing
                , dcServiceType = Nothing
                , dcServiceAcronym = Nothing
                , dcRolloutStrategy = Nothing
                , dcRevertStrategy = Nothing
                , dcDecisionConfig = Nothing
                , dcBitbucketPath = Nothing
                , dcSlackChannel = Nothing
                , dcEmails = Nothing
                }
    runDB db $ do
        runDelete $
            delete (deploymentConfig nammaAPDb) (\p -> dcProduct p ==. val_ productName' &&. isNothing_ (dcService p))
        runInsert $
            insert (deploymentConfig nammaAPDb) $
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
    let row :: DeploymentConfig
        row =
            DeploymentConfigT
                { dcId = rowId
                , dcProduct = product'
                , dcService = Just serviceName'
                , dcCluster = Nothing
                , dcNamespace = Nothing
                , dcVsName = Nothing
                , dcProductAcronym = Nothing
                , dcProductType = Nothing
                , dcRepoName = Nothing
                , dcReleaseBranch = Nothing
                , dcSyncCluster = Nothing
                , dcNeedInfraApproval = Nothing
                , dcVsLockedBy = Nothing
                , dcVsLockTimestamp = Nothing
                , dcServiceHost = serviceHost'
                , dcServiceType = Just sType
                , dcServiceAcronym = Nothing
                , dcRolloutStrategy = rolloutStrategy
                , dcRevertStrategy = revertStrategy
                , dcDecisionConfig = decisionConfig
                , dcBitbucketPath = bitbucketPath
                , dcSlackChannel = Nothing
                , dcEmails = emails
                }
    runDB db $ do
        runDelete $
            delete (deploymentConfig nammaAPDb) (\s -> dcProduct s ==. val_ product' &&. dcService s ==. val_ (Just serviceName'))
        runInsert $
            insert (deploymentConfig nammaAPDb) $
                insertValues [row]

-- ============================================================================
-- CRUD by ID (used by Config actions)
-- ============================================================================

findProductConfigById :: DBEnv -> Int32 -> IO (Maybe DeploymentConfig)
findProductConfigById db pid = do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    p <- all_ (deploymentConfig nammaAPDb)
                    guard_ (dcId p ==. val_ pid)
                    guard_ (isNothing_ (dcService p))
                    pure p
    pure $ case rows of
        [] -> Nothing
        (x : _) -> Just x

deleteProductConfig :: DBEnv -> Int32 -> IO ()
deleteProductConfig db pid =
    runDB db $
        runDelete $
            delete (deploymentConfig nammaAPDb) (\p -> dcId p ==. val_ pid)

listAllReleaseConfigs :: DBEnv -> IO [DeploymentConfig]
listAllReleaseConfigs db =
    runDB db $
        runSelectReturningList $
            select $ do
                s <- all_ (deploymentConfig nammaAPDb)
                guard_ (isNothing_ (dcService s) ==. val_ False)
                pure s

findReleaseConfigById :: DBEnv -> Int32 -> IO (Maybe DeploymentConfig)
findReleaseConfigById db rid = do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    r <- all_ (deploymentConfig nammaAPDb)
                    guard_ (dcId r ==. val_ rid)
                    guard_ (isNothing_ (dcService r) ==. val_ False)
                    pure r
    pure $ case rows of
        [] -> Nothing
        (x : _) -> Just x

deleteReleaseConfig :: DBEnv -> Int32 -> IO ()
deleteReleaseConfig db rid =
    runDB db $
        runDelete $
            delete (deploymentConfig nammaAPDb) (\r -> dcId r ==. val_ rid)

-- ============================================================================
-- VS lock helpers (update deployment_config.vs_locked_by)
-- ============================================================================

updateVsLockedBy :: DBEnv -> Text -> Maybe Text -> IO ()
updateVsLockedBy db productName' mLockedBy =
    runDB db $
        runUpdate $
            update (deploymentConfig nammaAPDb)
                (\p -> mconcat
                    [ dcVsLockedBy p <-. val_ mLockedBy
                    ])
                (\p -> dcProduct p ==. val_ productName' &&. isNothing_ (dcService p))
