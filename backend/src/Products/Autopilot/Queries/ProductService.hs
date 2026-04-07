{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Products.Autopilot.Queries.ProductService where

import qualified Control.Exception
import qualified Control.Monad.Catch
import Core.DB.Connection (runDB, withConn)
import Core.Environment (MonadFlow, withDb)
import Core.Logging (logInfoG)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text
import qualified Data.Text.Read as TR
import Database.Beam
import Database.Beam.Postgres (runBeamPostgres)
import Database.PostgreSQL.Simple (Only (..), execute, query, withTransaction)
import GHC.Int (Int32)
import Products.Autopilot.Types.Storage.Schema
import Shared.Queries.ServerConfig (getEnabledServerConfigValueForProduct_io)

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
    Int32 ->
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    Maybe Text ->
    Maybe Bool ->
    Maybe Text ->
    m ()
upsertProduct _rowId productName' cluster' namespace' vsName' productType' productAcronym' syncCluster' needInfraApproval slackChannel' = withDb $ \db -> do
    withConn db $ \conn ->
        withTransaction conn $ do
            runBeamPostgres conn $
                runDelete $
                    delete (deploymentConfig autopilotDb) (\p -> dcAppGroup p ==. val_ productName' &&. isNothing_ (dcService p))
            runBeamPostgres conn $
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
                                }
                            ]

upsertService ::
    (MonadFlow m) =>
    Int32 ->
    Maybe Text ->
    Maybe Text ->
    Text ->
    Text ->
    Text ->
    Maybe Text ->
    Maybe Text ->
    m ()
upsertService _rowId rolloutStrategy decisionConfig serviceName' product' sType serviceHost' revertStrategy = withDb $ \db -> do
    withConn db $ \conn ->
        withTransaction conn $ do
            runBeamPostgres conn $
                runDelete $
                    delete (deploymentConfig autopilotDb) (\s -> dcAppGroup s ==. val_ product' &&. dcService s ==. val_ (Just serviceName'))
            runBeamPostgres conn $
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

{- | Default stale-lock expiry (minutes). Used when server_config has no override.
Matches Julia production default VS_LOCK_EXPIRY_DELAY_MINUTES.
-}
defaultLockExpiryMinutes :: Int
defaultLockExpiryMinutes = 15

{- | Read lock_expiry_delay_minutes from server_config, with fallback to default.
Inlined here (rather than using RuntimeConfig) to keep Queries/ layering clean.
-}
getLockExpiryMins :: (MonadFlow m) => m Int
getLockExpiryMins = withDb $ \db -> do
    mVal <- getEnabledServerConfigValueForProduct_io db "lock_expiry_delay_minutes" (Just "autopilot")
    case mVal of
        Nothing -> pure defaultLockExpiryMinutes
        Just raw -> case TR.decimal (Data.Text.strip raw) of
            Right (n, _) -> pure n
            Left _ -> pure defaultLockExpiryMinutes

{- | Release the VS lock (or set a new owner). Clears vs_lock_timestamp when
unlocking so that stale-lock expiry checks behave correctly.
-}
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

{- | Atomically acquire the VS lock via a single UPDATE whose WHERE clause
enforces "currently unlocked OR lock has expired". Uses the affected-row
count from the UPDATE (via PostgreSQL.Simple 'execute') so there is no
TOCTOU between check and set — one statement, one transaction.

Expiry: a lock whose vs_lock_timestamp is NULL or older than
lock_expiry_delay_minutes (read from server_config) is treated as released.
This prevents orphaned locks (e.g. from a server crash mid-edit) from
blocking all VS edits until manual intervention.

Returns True iff this call installed the lock on behalf of 'lockOwner'.
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

{- | Atomically release the VS lock only if the current holder matches
'expectedOwner'. This is the ownership-checked path used by
'unlockVsEditTrackerH' so that one caller cannot steal-release another
caller's lock (soft auth hole flagged in task #10 audit as M6).

Implementation: single UPDATE with @WHERE vs_locked_by = ?@ guard — the
affected-row count from PostgreSQL.Simple 'execute' is the source of truth,
so there is no TOCTOU gap between "is caller the owner?" and "release it".

Returns True iff a row was updated (caller was the current owner).
Returns False if the lock is held by someone else, already released, or
the product row does not exist. Callers that need to bypass the ownership
check (operator recovery) must go through the superadmin-gated
force-unlock endpoint, which calls 'updateVsLockedBy db p Nothing' directly.
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

{- | Best-effort sweep that clears any VS lock older than the expiry window.
Intended for server startup after a crash, as a belt-and-braces companion
to the expiry check inside 'tryAcquireVsLock'. Returns the number of
deployment_config rows whose lock was cleared.
-}
releaseExpiredVsLocks :: (MonadFlow m) => m Int
releaseExpiredVsLocks = do
    expiryMins <- getLockExpiryMins
    withDb $ \db -> withConn db $ \conn -> do
        -- First, fetch the app_groups whose lock is being cleared — for logging.
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
        pure (fromIntegral n)

{- | Acquire VS lock, run an action, then release the lock.
Uses atomic UPDATE with expiry — no race condition.
If the lock is already held (and not expired), returns Left with error.
On success or failure of the action, the lock is always released (via finally).

NOTE (M8 — deferred, task #10 audit): the 'Control.Exception.try' below
catches 'SomeException', which also swallows async exceptions
(ThreadKilled, UserInterrupt, StackOverflow, …). The 'finally' still runs
the ownership-checked unlock so the lock is freed, but the caller sees the
async-kill as a plain Left Text and cannot distinguish "work failed" from
"thread was terminated". Team-lead's call (see race-hunter task #10
report): do NOT tighten this now — the unconditional finally-unlock is
more important than distinguishing exception kinds, and the only current
caller ('createVsEditTrackerH') does not need that distinction. Revisit if
a caller ever needs to retry on async-kill vs. give up on work-failure.

NOTE (HIGH #5 — task #34 race sweep): the finally clause uses
'releaseVsLockIfOwner' rather than an unconditional 'updateVsLockedBy _ Nothing'.
The ownership guard matters if 'action' ever runs longer than the lock
expiry (default 15 min from server_config): without the guard, the finally
would clear a lock that 'tryAcquireVsLock' had already handed to a
subsequent caller, effectively stealing the new holder's lock. Defense-in-
depth: the only current call site ('applyVirtualServiceRollout') is a fast
kubectl apply so the exposure is bounded in practice, but the invariant
"withVsLock only releases locks it owns" is worth maintaining as the set
of callers grows. Discards the 'Bool' result since finally expects 'IO ()';
a 'False' return here is expected (lock already expired + reacquired) and
not an error condition.
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
