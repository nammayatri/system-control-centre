{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Products.Autopilot.Queries.ProductService where

import qualified Control.Exception
import Core.DB.Connection (runDB, withConn)
import Core.Environment (DBEnv)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text
import Database.Beam
import Database.Beam.Postgres (runBeamPostgres)
import Database.PostgreSQL.Simple (withTransaction)
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
          guard_ (dcAppGroup p ==. val_ pName)
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
    _ -> case filter (\p -> getProductCluster p == clusterName) rows of
      (p : _) -> Just p
      [] -> safeHead rows
  where
    safeHead [] = Nothing
    safeHead (x : _) = Just x

listProductsByName :: DBEnv -> Text -> IO [DeploymentConfig]
listProductsByName db pName =
  runDB db $
    runSelectReturningList $
      select $ do
        p <- all_ (deploymentConfig nammaAPDb)
        guard_ (dcAppGroup p ==. val_ pName)
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
          guard_ (dcAppGroup s ==. val_ pName)
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
        guard_ (dcAppGroup s ==. val_ pName)
        guard_ (isNothing_ (dcService s) ==. val_ False)
        pure s

listSchedulerServicesByProduct :: DBEnv -> Text -> IO [DeploymentConfig]
listSchedulerServicesByProduct db pName =
  runDB db $
    runSelectReturningList $
      select $ do
        s <- all_ (deploymentConfig nammaAPDb)
        guard_ (dcAppGroup s ==. val_ pName)
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
  Maybe Text ->
  Maybe Bool ->
  IO ()
upsertProduct db rowId productName' cluster' namespace' vsName' productType' productAcronym' syncCluster' needInfraApproval = do
  let row :: DeploymentConfig
      row =
        DeploymentConfigT
          { dcId = rowId,
            dcAppGroup = productName',
            dcService = Nothing,
            dcCluster = Just cluster',
            dcNamespace = Just namespace',
            dcVsName = Just vsName',
            dcAppGroupAcronym = Just productAcronym',
            dcAppGroupType = Just productType',
            dcSyncCluster = syncCluster',
            dcNeedInfraApproval = needInfraApproval,
            dcVsLockedBy = Nothing,
            dcVsLockTimestamp = Nothing,
            dcServiceHost = Nothing,
            dcServiceType = Nothing,
            dcRolloutStrategy = Nothing,
            dcRevertStrategy = Nothing,
            dcDecisionConfig = Nothing,
            dcSlackChannel = Nothing
          }
  withConn db $ \conn ->
    withTransaction conn $ do
      runBeamPostgres conn $
        runDelete $
          delete (deploymentConfig nammaAPDb) (\p -> dcAppGroup p ==. val_ productName' &&. isNothing_ (dcService p))
      runBeamPostgres conn $
        runInsert $
          insert (deploymentConfig nammaAPDb) $
            insertValues [row]

upsertService ::
  DBEnv ->
  Int32 ->
  Maybe Text ->
  Maybe Text ->
  Text ->
  Text ->
  Text ->
  Maybe Text ->
  Maybe Text ->
  IO ()
upsertService db rowId rolloutStrategy decisionConfig serviceName' product' sType serviceHost' revertStrategy = do
  let row :: DeploymentConfig
      row =
        DeploymentConfigT
          { dcId = rowId,
            dcAppGroup = product',
            dcService = Just serviceName',
            dcCluster = Nothing,
            dcNamespace = Nothing,
            dcVsName = Nothing,
            dcAppGroupAcronym = Nothing,
            dcAppGroupType = Nothing,
            dcSyncCluster = Nothing,
            dcNeedInfraApproval = Nothing,
            dcVsLockedBy = Nothing,
            dcVsLockTimestamp = Nothing,
            dcServiceHost = serviceHost',
            dcServiceType = Just sType,
            dcRolloutStrategy = rolloutStrategy,
            dcRevertStrategy = revertStrategy,
            dcDecisionConfig = decisionConfig,
            dcSlackChannel = Nothing
          }
  withConn db $ \conn ->
    withTransaction conn $ do
      runBeamPostgres conn $
        runDelete $
          delete (deploymentConfig nammaAPDb) (\s -> dcAppGroup s ==. val_ product' &&. dcService s ==. val_ (Just serviceName'))
      runBeamPostgres conn $
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
      update
        (deploymentConfig nammaAPDb)
        ( \p ->
            mconcat
              [ dcVsLockedBy p <-. val_ mLockedBy
              ]
        )
        (\p -> dcAppGroup p ==. val_ productName' &&. isNothing_ (dcService p))

-- | Atomically acquire VS lock using PostgreSQL UPDATE ... WHERE vs_locked_by IS NULL.
-- This is a single atomic SQL statement — no race condition possible.
-- Returns the number of rows updated (1 = lock acquired, 0 = already locked).
tryAcquireVsLock :: DBEnv -> Text -> Text -> IO Bool
tryAcquireVsLock db productName' lockOwner = do
  -- Atomic: UPDATE SET vs_locked_by = owner WHERE app_group = X AND service IS NULL AND vs_locked_by IS NULL
  -- If already locked, 0 rows updated. If not locked, 1 row updated. No race condition.
  runDB db $
    runUpdate $
      update
        (deploymentConfig nammaAPDb)
        (\p -> dcVsLockedBy p <-. val_ (Just lockOwner))
        ( \p ->
            dcAppGroup p ==. val_ productName'
              &&. isNothing_ (dcService p)
              &&. isNothing_ (dcVsLockedBy p)
        )
  -- Check if we actually got the lock
  rows <- runDB db $
    runSelectReturningList $
      select $ do
        p <- all_ (deploymentConfig nammaAPDb)
        guard_ (dcAppGroup p ==. val_ productName')
        guard_ (isNothing_ (dcService p))
        guard_ (dcVsLockedBy p ==. val_ (Just lockOwner))
        pure p
  pure (not (null rows))

-- | Acquire VS lock, run an action, then release the lock.
-- Uses atomic UPDATE WHERE vs_locked_by IS NULL — no race condition.
-- If the lock is already held, returns Left with error.
-- On success or failure of the action, the lock is always released (via finally).
withVsLock :: forall a. DBEnv -> Text -> Text -> IO a -> IO (Either Text a)
withVsLock db productName' lockOwner action = do
  acquired <- tryAcquireVsLock db productName' lockOwner
  if not acquired
    then pure (Left "VS is locked by another release/editor")
    else -- Use finally to guarantee lock release even on async exceptions

      Control.Exception.finally
        ( do
            result <- Control.Exception.try action :: IO (Either Control.Exception.SomeException a)
            case result of
              Right v -> pure (Right v)
              Left ex -> pure (Left (Data.Text.pack (show ex)))
        )
        (updateVsLockedBy db productName' Nothing)
