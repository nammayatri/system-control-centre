{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Products.Autopilot.Queries.ProductService where

import Control.Exception qualified
import Control.Monad (void)
import Control.Monad.Catch qualified
import Core.DB.Connection (runBeamLogged, runDB, withConn)
import Core.Config (Config (..))
import Core.Environment (MonadFlow, getConfig, withDb)
import Core.Logging (logInfoG)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified
import Data.Text.Read qualified as TR
import Database.Beam
import Database.PostgreSQL.Simple (In (..), Only (..), execute, query, withTransaction)
import Database.PostgreSQL.Simple.Types (PGArray (..))
import GHC.Int (Int32)
import Products.Autopilot.Types.Release (ServiceState (..), parseServiceStateText, serviceStateText)
import Products.Autopilot.Types.Storage.Schema
import Shared.Queries.ServerConfig (getEnabledServerConfigValueForProduct_io)

isVsLockedByEditor :: (MonadFlow m) => Text -> Text -> m Bool
isVsLockedByEditor productName' releaseOwner = do
    mProduct <- findProductByName productName'
    case mProduct of
        Nothing -> pure False
        Just p -> case getProductVsLockedBy p of
            Nothing -> pure False
            Just lockedBy
                | lockedBy == releaseOwner -> pure False
                | otherwise -> pure True

-- Product-level queries (service IS NULL)

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

getServiceHost :: DeploymentConfig -> Maybe Text
getServiceHost = dcServiceHost

getSlackChannelDirect :: DeploymentConfig -> Maybe Text
getSlackChannelDirect = dcSlackChannel

-- | Service's configured HPA floor/ceiling, defaulting to 2/100 when unset.
getHpaMinReplicas :: DeploymentConfig -> Int32
getHpaMinReplicas = fromMaybe 2 . dcHpaMinReplicas

getHpaMaxReplicas :: DeploymentConfig -> Int32
getHpaMaxReplicas = fromMaybe 100 . dcHpaMaxReplicas

{- | The app group's configured GitHub repo (@repo_name@ column), used to build
changelog diff links and fetch commits. 'Nothing' when unset.
-}
getRepoNameDirect :: DeploymentConfig -> Maybe Text
getRepoNameDirect = dcRepoName

findProductByName :: (MonadFlow m) => Text -> m (Maybe DeploymentConfig)
findProductByName pName = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    p <- all_ (deploymentConfig autopilotDb)
                    guard_ (dcAppGroup p ==. val_ pName)
                    guard_ (isNothing_ (dcService p))
                    pure p
    pure $ case rows of
        [] -> Nothing
        (x : _) -> Just x

findProductByNameAndCluster :: (MonadFlow m) => Text -> Text -> m (Maybe DeploymentConfig)
findProductByNameAndCluster pName clusterName = do
    rows <- listProductsByName pName
    pure $ case clusterName of
        "" -> safeHead rows
        _ -> case filter (\p -> getProductCluster p == clusterName) rows of
            (p : _) -> Just p
            [] -> safeHead rows
  where
    safeHead [] = Nothing
    safeHead (x : _) = Just x

listProductsByName :: (MonadFlow m) => Text -> m [DeploymentConfig]
listProductsByName pName = withDb $ \db ->
    runDB db $
        runSelectReturningList $
            select $ do
                p <- all_ (deploymentConfig autopilotDb)
                guard_ (dcAppGroup p ==. val_ pName)
                guard_ (isNothing_ (dcService p))
                pure p

{- | Batch lookup for (appGroup, cluster) pairs. Single SELECT on app_group
IN (...), cluster predicate filtered in Haskell (row-value IN is awkward
through Beam). Collapses an N+1 to 1 query.
-}
getProductsByNamesAndClusters ::
    (MonadFlow m) =>
    [(Text, Text)] ->
    m [DeploymentConfig]
getProductsByNamesAndClusters [] = pure []
getProductsByNamesAndClusters pairs = withDb $ \db -> do
    let names = map fst pairs
        wanted = map (\(n, c) -> (n, c)) pairs
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    p <- all_ (deploymentConfig autopilotDb)
                    guard_ (dcAppGroup p `in_` map val_ names)
                    guard_ (isNothing_ (dcService p))
                    pure p
    -- Empty cluster in the wanted-set matches any cluster.
    let matches p =
            let pName = dcAppGroup p
                pCluster = getProductCluster p
             in any (\(n, c) -> n == pName && (c == "" || c == pCluster)) wanted
    pure (filter matches rows)

listProducts :: (MonadFlow m) => m [DeploymentConfig]
listProducts = withDb $ \db ->
    runDB db $
        runSelectReturningList $
            select $ do
                p <- all_ (deploymentConfig autopilotDb)
                guard_ (isNothing_ (dcService p))
                pure p

findServiceByProductAndName :: (MonadFlow m) => Text -> Text -> m (Maybe DeploymentConfig)
findServiceByProductAndName pName sName = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    s <- all_ (deploymentConfig autopilotDb)
                    guard_ (dcAppGroup s ==. val_ pName)
                    guard_ (dcService s ==. val_ (Just sName))
                    pure s
    pure $ case rows of
        [] -> Nothing
        (x : _) -> Just x

listReleaseConfigByProduct :: (MonadFlow m) => Text -> m [DeploymentConfig]
listReleaseConfigByProduct pName = withDb $ \db ->
    runDB db $
        runSelectReturningList $
            select $ do
                s <- all_ (deploymentConfig autopilotDb)
                guard_ (dcAppGroup s ==. val_ pName)
                guard_ (isNothing_ (dcService s) ==. val_ False)
                pure s

listSchedulerServicesByProduct :: (MonadFlow m) => Text -> m [DeploymentConfig]
listSchedulerServicesByProduct pName = withDb $ \db ->
    runDB db $
        runSelectReturningList $
            select $ do
                s <- all_ (deploymentConfig autopilotDb)
                guard_ (dcAppGroup s ==. val_ pName)
                guard_ (isNothing_ (dcService s) ==. val_ False)
                guard_ (dcServiceType s ==. val_ (Just "SCHEDULER"))
                pure s

upsertProduct ::
    (MonadFlow m) =>
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    Maybe Text ->
    Maybe Bool ->
    Maybe Text ->
    Maybe Text ->
    m ()
upsertProduct productName' cluster' namespace' vsName' productType' productAcronym' syncCluster' needInfraApproval slackChannel' repoName' = withDb $ \db -> do
    withConn db $ \conn ->
        withTransaction conn $ do
            runBeamLogged conn $
                runDelete $
                    delete (deploymentConfig autopilotDb) (\p -> dcAppGroup p ==. val_ productName' &&. isNothing_ (dcService p))
            runBeamLogged conn $
                runInsert $
                    insert (deploymentConfig autopilotDb) $
                        insertExpressions
                            [ DeploymentConfigT
                                { dcId = default_
                                , dcAppGroup = val_ productName'
                                , dcService = val_ Nothing
                                , dcCluster = val_ (Just cluster')
                                , dcNamespace = val_ (Just namespace')
                                , dcVsName = val_ (Just vsName')
                                , dcAppGroupAcronym = val_ (Just productAcronym')
                                , dcRepoName = val_ repoName'
                                , dcAppGroupType = val_ (Just productType')
                                , dcSyncCluster = val_ syncCluster'
                                , dcNeedInfraApproval = val_ needInfraApproval
                                , dcVsLockedBy = val_ Nothing
                                , dcVsLockTimestamp = val_ Nothing
                                , dcServiceHost = val_ Nothing
                                , dcServiceType = val_ Nothing
                                , dcRolloutStrategy = val_ Nothing
                                , dcRevertStrategy = val_ Nothing
                                , dcDecisionConfig = val_ Nothing
                                , dcSlackChannel = val_ slackChannel'
                                , dcServiceState = val_ Nothing
                                , dcHpaMinReplicas = val_ Nothing
                                , dcHpaMaxReplicas = val_ Nothing
                                }
                            ]

upsertService ::
    (MonadFlow m) =>
    Maybe Text ->
    Maybe Text ->
    Text ->
    Text ->
    Text ->
    Maybe Text ->
    Maybe Text ->
    Maybe Int32 ->
    Maybe Int32 ->
    m ()
upsertService rolloutStrategy decisionConfig serviceName' product' sType serviceHost' revertStrategy hpaMinReplicas' hpaMaxReplicas' = withDb $ \db -> do
    withConn db $ \conn ->
        withTransaction conn $ do
            runBeamLogged conn $
                runDelete $
                    delete (deploymentConfig autopilotDb) (\s -> dcAppGroup s ==. val_ product' &&. dcService s ==. val_ (Just serviceName'))
            runBeamLogged conn $
                runInsert $
                    insert (deploymentConfig autopilotDb) $
                        insertExpressions
                            [ DeploymentConfigT
                                { dcId = default_
                                , dcAppGroup = val_ product'
                                , dcService = val_ (Just serviceName')
                                , dcCluster = val_ Nothing
                                , dcNamespace = val_ Nothing
                                , dcVsName = val_ Nothing
                                , dcAppGroupAcronym = val_ Nothing
                                , dcRepoName = val_ Nothing
                                , dcAppGroupType = val_ Nothing
                                , dcSyncCluster = val_ Nothing
                                , dcNeedInfraApproval = val_ Nothing
                                , dcVsLockedBy = val_ Nothing
                                , dcVsLockTimestamp = val_ Nothing
                                , dcServiceHost = val_ serviceHost'
                                , dcServiceType = val_ (Just sType)
                                , dcRolloutStrategy = val_ rolloutStrategy
                                , dcRevertStrategy = val_ revertStrategy
                                , dcDecisionConfig = val_ decisionConfig
                                , dcSlackChannel = val_ Nothing
                                , dcServiceState = val_ (Just (serviceStateText AVAILABLE))
                                , dcHpaMinReplicas = val_ hpaMinReplicas'
                                , dcHpaMaxReplicas = val_ hpaMaxReplicas'
                                }
                            ]

findProductConfigById :: (MonadFlow m) => Int32 -> m (Maybe DeploymentConfig)
findProductConfigById pid = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    p <- all_ (deploymentConfig autopilotDb)
                    guard_ (dcId p ==. val_ pid)
                    guard_ (isNothing_ (dcService p))
                    pure p
    pure $ case rows of
        [] -> Nothing
        (x : _) -> Just x

deleteProductConfig :: (MonadFlow m) => Int32 -> m ()
deleteProductConfig pid = withDb $ \db ->
    runDB db $
        runDelete $
            delete (deploymentConfig autopilotDb) (\p -> dcId p ==. val_ pid)

listAllReleaseConfigs :: (MonadFlow m) => m [DeploymentConfig]
listAllReleaseConfigs = withDb $ \db ->
    runDB db $
        runSelectReturningList $
            select $ do
                s <- all_ (deploymentConfig autopilotDb)
                guard_ (isNothing_ (dcService s) ==. val_ False)
                pure s

findReleaseConfigById :: (MonadFlow m) => Int32 -> m (Maybe DeploymentConfig)
findReleaseConfigById rid = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    r <- all_ (deploymentConfig autopilotDb)
                    guard_ (dcId r ==. val_ rid)
                    guard_ (isNothing_ (dcService r) ==. val_ False)
                    pure r
    pure $ case rows of
        [] -> Nothing
        (x : _) -> Just x

deleteReleaseConfig :: (MonadFlow m) => Int32 -> m ()
deleteReleaseConfig rid = withDb $ \db ->
    runDB db $
        runDelete $
            delete (deploymentConfig autopilotDb) (\r -> dcId r ==. val_ rid)

-- | Default stale-lock expiry (minutes) when server_config has no override.
defaultLockExpiryMinutes :: Int
defaultLockExpiryMinutes = 15

-- | Read @lock_expiry_delay_minutes@ from server_config with default fallback.
getLockExpiryMins :: (MonadFlow m) => m Int
getLockExpiryMins = withDb $ \db -> do
    mVal <- getEnabledServerConfigValueForProduct_io db "lock_expiry_delay_minutes" (Just "autopilot")
    case mVal of
        Nothing -> pure defaultLockExpiryMinutes
        Just raw -> case TR.decimal (Data.Text.strip raw) of
            Right (n, _) -> pure n
            Left _ -> pure defaultLockExpiryMinutes

-- | Release VS lock (or set a new owner). Clears timestamp on unlock.
updateVsLockedBy :: (MonadFlow m) => Text -> Maybe Text -> m ()
updateVsLockedBy productName' mLockedBy = withDb $ \db -> withConn db $ \conn ->
    case mLockedBy of
        Just owner -> do
            _ <-
                execute
                    conn
                    "UPDATE deployment_config \
                    \SET vs_locked_by = ?, vs_lock_timestamp = NOW() \
                    \WHERE app_group = ? AND service IS NULL"
                    (owner, productName')
            pure ()
        Nothing -> do
            _ <-
                execute
                    conn
                    "UPDATE deployment_config \
                    \SET vs_locked_by = NULL, vs_lock_timestamp = NULL \
                    \WHERE app_group = ? AND service IS NULL"
                    (Only productName')
            pure ()

{- | Atomically acquire the VS lock: single UPDATE with WHERE
"unlocked OR expired", no TOCTOU. Expiry prevents orphaned locks from a
crashed edit blocking all VS edits. Returns True iff lock installed.
-}
tryAcquireVsLock :: (MonadFlow m) => Text -> Text -> m Bool
tryAcquireVsLock productName' lockOwner = do
    expiryMins <- getLockExpiryMins
    withDb $ \db -> withConn db $ \conn -> do
        rows <-
            execute
                conn
                "UPDATE deployment_config \
                \SET vs_locked_by = ?, vs_lock_timestamp = NOW() \
                \WHERE app_group = ? \
                \  AND service IS NULL \
                \  AND ( vs_locked_by IS NULL \
                \     OR vs_lock_timestamp IS NULL \
                \     OR vs_lock_timestamp < NOW() - (? || ' minutes')::interval )"
                (lockOwner, productName', show expiryMins)
        pure (rows > 0)

{- | Release the VS lock only if the current holder matches @expectedOwner@
(single UPDATE with ownership guard, no TOCTOU). Returns True iff a row
was updated. Operator force-unlock bypasses this via 'updateVsLockedBy'.
-}
releaseVsLockIfOwner :: (MonadFlow m) => Text -> Text -> m Bool
releaseVsLockIfOwner productName' expectedOwner = withDb $ \db ->
    withConn db $ \conn -> do
        rows <-
            execute
                conn
                "UPDATE deployment_config \
                \SET vs_locked_by = NULL, vs_lock_timestamp = NULL \
                \WHERE app_group = ? \
                \  AND service IS NULL \
                \  AND vs_locked_by = ?"
                (productName', expectedOwner)
        pure (rows > 0)

{- | Startup sweep that clears VS locks older than the expiry window.
Complements the expiry check inside 'tryAcquireVsLock'. Returns count cleared.
-}
releaseExpiredVsLocks :: (MonadFlow m) => m Int
releaseExpiredVsLocks = do
    expiryMins <- getLockExpiryMins
    cloud <- cloudProvider <$> getConfig
    withDb $ \db -> withConn db $ \conn -> do
        -- Fetch app_groups about to be cleared, for logging.
        (owners :: [(Text, Text)]) <-
            query
                conn
                "SELECT app_group, COALESCE(vs_locked_by, '') \
                \FROM deployment_config \
                \WHERE service IS NULL \
                \  AND vs_locked_by IS NOT NULL \
                \  AND ( vs_lock_timestamp IS NULL \
                \     OR vs_lock_timestamp < NOW() - (? || ' minutes')::interval )"
                (Only (show expiryMins))
        mapM_
            ( \(ag, o) ->
                logInfoG $
                    "[STARTUP] Releasing expired VS lock: app_group="
                        <> ag
                        <> " (was held by "
                        <> o
                        <> ")"
            )
            owners
        n <-
            execute
                conn
                "UPDATE deployment_config \
                \SET vs_locked_by = NULL, vs_lock_timestamp = NULL \
                \WHERE service IS NULL \
                \  AND vs_locked_by IS NOT NULL \
                \  AND ( vs_lock_timestamp IS NULL \
                \     OR vs_lock_timestamp < NOW() - (? || ' minutes')::interval )"
                (Only (show expiryMins))
        -- Also UNLOCK orphan LOCKED tracker rows: deployment_config is the
        -- source of truth for the lock, tracker rows are bookkeeping.
        -- (1) app_groups just freed above; (2) pre-existing orphans whose
        -- end_time has passed (accumulate from force-unlock / crashes).
        _ <-
            case map fst owners of
                [] -> pure 0
                ags ->
                    execute
                        conn
                        "UPDATE release_tracker \
                        \SET status = 'UNLOCKED', last_updated = NOW(), end_time = NOW() \
                        \WHERE category = 'VSEdit' AND status = 'LOCKED' \
                        \  AND app_group IN ? \
                        \  AND (cloud_type = ? OR cloud_type IS NULL)"
                        (In ags, cloud)
        _ <-
            execute
                conn
                "UPDATE release_tracker \
                \SET status = 'UNLOCKED', last_updated = NOW(), end_time = COALESCE(end_time, NOW()) \
                \WHERE category = 'VSEdit' AND status = 'LOCKED' \
                \  AND ( end_time IS NULL OR end_time < NOW() ) \
                \  AND (cloud_type = ? OR cloud_type IS NULL)"
                (Only cloud)
        pure (fromIntegral n)

{- | Acquire VS lock, run action, release via finally. Returns Left if
another holder has the lock. The finally uses 'releaseVsLockIfOwner'
(not unconditional unlock) so that if @action@ ever runs past the lock
expiry, we don't steal a lock a subsequent caller has since acquired.

Note: 'try' catches SomeException, which also swallows async exceptions;
the unconditional finally-unlock matters more than distinguishing kinds.
-}
withVsLock ::
    forall m a.
    (MonadFlow m, Control.Monad.Catch.MonadCatch m, Control.Monad.Catch.MonadMask m) =>
    Text ->
    Text ->
    m a ->
    m (Either Text a)
withVsLock productName' lockOwner action = do
    acquired <- tryAcquireVsLock productName' lockOwner
    if not acquired
        then pure (Left "VS is locked by another release/editor")
        else
            Control.Monad.Catch.finally
                ( do
                    result <- Control.Monad.Catch.try action :: m (Either Control.Exception.SomeException a)
                    case result of
                        Right v -> pure (Right v)
                        Left ex -> pure (Left (Data.Text.pack (show ex)))
                )
                (releaseVsLockIfOwner productName' lockOwner >> pure ())

-- ============================================================================
-- Service State Guards (per-service lifecycle state management)
-- ============================================================================

{- | Get the current service state for a (product, service) pair.
Returns AVAILABLE if no row exists or service_state column is NULL.
-}
getServiceState :: (MonadFlow m) => Text -> Text -> m ServiceState
getServiceState appGroup serviceName = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    s <- all_ (deploymentConfig autopilotDb)
                    guard_ (dcAppGroup s ==. val_ appGroup)
                    guard_ (dcService s ==. val_ (Just serviceName))
                    pure s
    pure $ case rows of
        [] -> AVAILABLE
        (s : _) -> fromMaybe AVAILABLE (parseServiceStateText =<< dcServiceState s)

{- | Atomically check service state and transition to MODIFYING.
Returns True if transition succeeded (state was AVAILABLE or TERMINATED).
Returns False if transition blocked (state is CREATING, MODIFYING, or TERMINATING).

This is the core guard preventing concurrent modifications.
-}
tryTransitionServiceState ::
    (MonadFlow m) =>
    -- | appGroup
    Text ->
    -- | serviceName
    Text ->
    -- | expected current state(s) that allow transition
    [ServiceState] ->
    -- | new state to transition to
    ServiceState ->
    m Bool
tryTransitionServiceState appGroup serviceName fromStates toState = withDb $ \db -> withConn db $ \conn -> do
    let stateTexts = map serviceStateText fromStates
    rows <-
        execute
            conn
            "UPDATE deployment_config \
            \SET service_state = ? \
            \WHERE app_group = ? \
            \  AND service = ? \
            \  AND ( service_state IS NULL \
            \     OR service_state = ANY(?) )"
            (serviceStateText toState, appGroup, serviceName, PGArray stateTexts)
    pure (rows > 0)

{- | Convenience: attempt to claim service for modification.
Sets state to MODIFYING if current state is AVAILABLE or TERMINATED.
Returns True on success.
-}
claimServiceForModification :: (MonadFlow m) => Text -> Text -> m Bool
claimServiceForModification appGroup serviceName =
    tryTransitionServiceState
        appGroup
        serviceName
        [AVAILABLE, TERMINATED]
        MODIFYING

{- | Release service after modification (transition to AVAILABLE).
Always succeeds regardless of current state.
-}
releaseService :: (MonadFlow m) => Text -> Text -> m ()
releaseService appGroup serviceName = withDb $ \db -> withConn db $ \conn ->
    void $
        execute
            conn
            "UPDATE deployment_config \
            \SET service_state = 'AVAILABLE' \
            \WHERE app_group = ? \
            \  AND service = ?"
            (appGroup, serviceName)

{- | Mark service as terminating (prevents new modifications during cleanup).
Only succeeds if current state is AVAILABLE or MODIFYING.
-}
markServiceTerminating :: (MonadFlow m) => Text -> Text -> m Bool
markServiceTerminating appGroup serviceName =
    tryTransitionServiceState
        appGroup
        serviceName
        [AVAILABLE, MODIFYING]
        TERMINATING

{- | Mark service as terminated (final state).
Called after successful cleanup.
-}
markServiceTerminated :: (MonadFlow m) => Text -> Text -> m ()
markServiceTerminated appGroup serviceName = withDb $ \db -> withConn db $ \conn ->
    void $
        execute
            conn
            "UPDATE deployment_config \
            \SET service_state = 'TERMINATED' \
            \WHERE app_group = ? \
            \  AND service = ?"
            (appGroup, serviceName)

{- | Mark service as creating (initial deployment).
Usually only succeeds if no state exists or state is TERMINATED.
-}
markServiceCreating :: (MonadFlow m) => Text -> Text -> m Bool
markServiceCreating appGroup serviceName =
    tryTransitionServiceState
        appGroup
        serviceName
        [TERMINATED]
        CREATING

{- | Initialize service state for a new service configuration.
Ensures service_state is set to AVAILABLE when upserting a service.
-}
initializeServiceState :: (MonadFlow m) => Text -> Text -> m ()
initializeServiceState appGroup serviceName = withDb $ \db -> withConn db $ \conn ->
    void $
        execute
            conn
            "UPDATE deployment_config \
            \SET service_state = COALESCE(service_state, 'AVAILABLE') \
            \WHERE app_group = ? \
            \  AND service = ?"
            (appGroup, serviceName)
