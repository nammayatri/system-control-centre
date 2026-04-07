{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Products.Autopilot.Actions.Release (
    -- * Release Handlers
    createReleaseH,
    getReleaseH,
    listReleasesH,
    approveReleaseH,
    triggerReleaseH,
    rollbackReleaseH,
    revertReleaseH,
    revertByGlobalIdH,
    immediateRevertByGlobalIdH,
    discardReleaseH,
    deleteReleaseH,
    updateTrackerH,
    immediateRevertH,
    restartReleaseH,
    fastForwardH,
    releaseDiffH,
    podHealthH,
    rolloutHistoryH,
    listEventsH,
    logsLinkH,

    -- * Product/Service Handlers (used in Routes wiring)
    listProductsH,
    upsertProductH,
    listServicesH,
    upsertServiceH,

    -- * Helpers exported for other modules
    isValidK8sVersion,
) where

import Control.Applicative ((<|>))
import Control.Monad (void, when)
import Control.Monad.Catch (throwM, try)
import Database.PostgreSQL.Simple (SqlError (..))
import qualified Data.ByteString.Char8 as B
import Control.Monad.IO.Class (liftIO)
import Core.AppError (APIError (..))
import Core.Auth.Protected (AuthedPerson (..))
import Core.Config (Config (..))
import Core.DB.Connection (withConn)
import Core.Environment (Flow, forkFlow, getConfig, getDBEnv, logInfo)
import Data.Aeson (Value (..), object, toJSON, (.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.Char (isAlphaNum)
import Data.List (find)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime, parseTimeM)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import qualified Data.Yaml as Yaml
import Database.PostgreSQL.Simple (Only (..), execute, withTransaction)
import Products.Autopilot.Discovery (listServicesFromVirtualService)
import Products.Autopilot.EventLog (logStatusUpdated)
import Products.Autopilot.K8s.Deployment (deploymentExists)
import Products.Autopilot.Runner (dispatchWorkflow)
import Products.Autopilot.K8s.Execute (K8sError (..), K8sResult (..), executeWithRetry, runCmd, shellQuote)
import Products.Autopilot.K8s.Kubectl (getPrimarySubsetFromVirtualService)
import Products.Autopilot.Notifications
import Products.Autopilot.Queries.ProductService
import Products.Autopilot.Queries.ReleaseTracker
import Products.Autopilot.Queries.VsEditTracker ()
import Products.Autopilot.RuntimeConfig (isApproveAllReleases, isUnderMaintenance)
import Products.Autopilot.Sync (triggerImmediateRevertSync)
import Products.Autopilot.Types
import qualified Products.Autopilot.Types as NT
import Products.Autopilot.Types.API
import qualified Products.Autopilot.Types.Storage.Schema as S
import Products.Autopilot.Types.Target (TargetState (..))
import Products.Autopilot.Types.Target.Kubernetes
import qualified Products.Autopilot.Types.Target.Kubernetes as K8s
import Products.Autopilot.Workflow.Helpers (captureDeploymentPreview, captureDeploymentSnapshot)
import Shared.API.Response (APIResponse (..))

-- ============================================================================
-- Shared helpers
-- ============================================================================

{- | Standard error returned when a CAS update fails because another request
mutated the tracker between snapshot read and write.
-}
staleTrackerError :: APIResponse
staleTrackerError = APIResponse "ERROR" "Release was modified by another request. Please refresh and try again."

{- | Apply an update function to a value only when the optional input is 'Just'.
Used to collapse long sequential @case req.field of Just x -> ...; Nothing -> acc@
chains in 'applyUpdates' into a single combinator.
-}
applyMaybe :: Maybe a -> (a -> b -> b) -> b -> b
applyMaybe Nothing _ acc = acc
applyMaybe (Just x) f acc = f x acc

-- ============================================================================
-- Product/Service Handlers
-- ============================================================================

upsertProductH :: AuthedPerson -> UpsertProductReq -> Flow APIResponse
upsertProductH _ap req = do
    upsertProduct req.appGroup req.cluster req.namespace req.vsName req.productType req.productAcronym req.syncCluster req.needInfraApproval req.slackChannel
    pure $ APIResponse "SUCCESS" "product_config upserted"

listProductsH :: AuthedPerson -> Flow [ProductResponse]
listProductsH _ap = do
    rows <- listProducts
    pure $
        map
            ( \p ->
                ProductResponse
                    { appGroup = S.dcAppGroup p
                    , cluster = getProductCluster p
                    , namespace = getProductNamespace p
                    , vsName = getProductVsName p
                    , productType = fromMaybe "SERVICE" (S.dcAppGroupType p)
                    , productAcronym = fromMaybe "" (S.dcAppGroupAcronym p)
                    , syncCluster = getProductSyncCluster p
                    , slackChannel = S.dcSlackChannel p
                    }
            )
            rows

listServicesH :: AuthedPerson -> Text -> Flow [ServiceResponse]
listServicesH _ap productName' = do
    cfg <- getConfig
    products <- listProductsByName productName'
    case products of
        [] -> pure []
        _ ->
            if any (\p -> S.dcAppGroupType p == Just "SCHEDULER") products
                then do
                    services <- listSchedulerServicesByProduct productName'
                    pure $
                        map
                            (\s -> ServiceResponse (fromMaybe "" (S.dcService s)) (getServiceHost s) (fromMaybe "SERVICE" (S.dcServiceType s)) "DB")
                            services
                else do
                    cfgServices <- listReleaseConfigByProduct productName'
                    let configuredHosts = fmap getServiceHost cfgServices
                        normalizeHost h = T.takeWhile (/= '.') h
                        hostMatches configured vsHost =
                            let v = normalizeHost vsHost
                             in configured == v || vsHost == configured
                        toResponse h =
                            case find (\s -> maybe False (`hostMatches` h) (getServiceHost s)) cfgServices of
                                Just svc -> ServiceResponse (fromMaybe "" (S.dcService svc)) (getServiceHost svc) (fromMaybe "SERVICE" (S.dcServiceType svc)) "VIRTUAL_SERVICE"
                                Nothing -> ServiceResponse h (Just h) "SERVICE" "VIRTUAL_SERVICE"
                        pickServices :: [S.DeploymentConfig] -> IO (Either Text [Text])
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
                            -- return services directly from deployment_config
                            pure $
                                map
                                    (\s -> ServiceResponse (fromMaybe "" (S.dcService s)) (getServiceHost s) (fromMaybe "SERVICE" (S.dcServiceType s)) "DB")
                                    cfgServices
                        Right hosts
                            | null hosts ->
                                -- If K8s returned empty, also fallback to DB
                                pure $
                                    map
                                        (\s -> ServiceResponse (fromMaybe "" (S.dcService s)) (getServiceHost s) (fromMaybe "SERVICE" (S.dcServiceType s)) "DB")
                                        cfgServices
                            | otherwise -> pure $ map toResponse hosts

upsertServiceH :: AuthedPerson -> UpsertServiceReq -> Flow APIResponse
upsertServiceH _ap req = do
    upsertService req.rolloutStrategyText req.decisionConfigText req.service req.appGroup req.serviceType req.serviceHost req.revertStrategyText
    pure $ APIResponse "SUCCESS" "release_config upserted"

-- ============================================================================
-- Release CRUD Handlers
-- ============================================================================

listReleasesH :: AuthedPerson -> Maybe Text -> Maybe Text -> Flow [ReleaseTracker]
listReleasesH _ap mFrom mTo = do
    case (mFrom >>= parseISO, mTo >>= parseISO) of
        (Just fromTime, Just toTime) -> do
            pairs <- listReleaseTrackersByDateRange fromTime toTime
            pure (map fst pairs)
        _ -> do
            -- No valid date range -- default to last 30 days as safety limit
            now <- liftIO getCurrentTime
            let thirtyDaysAgo = addUTCTime (-30 * 86400) now
            pairs <- listReleaseTrackersByDateRange thirtyDaysAgo now
            pure (map fst pairs)
  where
    parseISO :: Text -> Maybe UTCTime
    parseISO t =
        parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" (T.unpack t)
            <|> parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (T.unpack t)
            <|> parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Q%Z" (T.unpack t)

createReleaseH :: AuthedPerson -> Maybe Text -> Maybe Text -> K8sCreateReleaseReq -> Flow APIResponse
createReleaseH _ap mXForwardedEmail mXPomeriumJwt req@K8sCreateReleaseReq{..} = do
    case globalId of
        Just gid | not (T.null gid) -> do
            existing <- findReleaseTrackerByGlobalId gid
            case existing of
                Just (existingTracker, _) -> do
                    logInfo $ "Idempotent receive: tracker already exists for global_id=" <> gid
                    pure $ APIResponse "SUCCESS" ("Tracker already exists: " <> NT.releaseId existingTracker)
                Nothing -> normalCreatePath
        _ -> normalCreatePath
  where
    normalCreatePath = createReleaseHBody mXForwardedEmail mXPomeriumJwt req

createReleaseHBody :: Maybe Text -> Maybe Text -> K8sCreateReleaseReq -> Flow APIResponse
createReleaseHBody mXForwardedEmail mXPomeriumJwt K8sCreateReleaseReq{..} = do
    -- Same-service concurrency guard. Different services in the same app
    -- group can run in parallel (serialised at kubectl-replace via VS lock
    -- retry — see runVsRolloutWithLock). Same (appGroup, service) with any
    -- in-flight tracker is rejected unconditionally.
    mConflict <- findInFlightSameService appGroup service
    case mConflict of
        Just existing ->
            pure $
                APIResponse
                    "ERROR"
                    ( "Service "
                        <> service
                        <> " in app group "
                        <> appGroup
                        <> " already has an in-flight release "
                        <> NT.releaseId existing
                        <> " (status="
                        <> T.pack (show (NT.status existing))
                        <> "). Wait for it to complete, abort, or discard."
                    )
        Nothing -> createReleaseHBodyAfterGuard mXForwardedEmail mXPomeriumJwt K8sCreateReleaseReq{..}

findInFlightSameService :: Text -> Text -> Flow (Maybe ReleaseTracker)
findInFlightSameService ag svc = do
    -- Single query that catches CREATED (approved or not), INPROGRESS, PAUSED,
    -- ABORTING, REVERTING, RESTARTING for the (ag, svc) pair. Avoids the
    -- prior bug where findRunnableReleaseTrackers filtered isApproved=true and
    -- missed un-approved CREATED rows.
    rows <- findActiveTrackersForService ag svc
    logInfo $ "[same-svc-guard] " <> ag <> "/" <> svc <> " active=" <> T.pack (show (length rows))
    pure $ case rows of
        ((rt, _) : _) -> Just rt
        [] -> Nothing

{- | Insert a release tracker, translating partial-unique-index violations
into the same friendly responses the application-level checks would have
returned. Two indexes can fire here:

1. uq_release_tracker_service_inflight (same-service in-flight guard) →
   HTTP 409 Conflict, same shape the in-Haskell `findInFlightSameService`
   path returns when it sees a duplicate.

2. uq_release_tracker_global_id (cross-cloud sync idempotency guard) →
   re-fetch the existing tracker by globalId and behave as if the original
   `findReleaseTrackerByGlobalId` short-circuit had won the race. This
   makes 10 parallel POSTs with the same global_id all succeed cleanly
   (1 inserts, 9 see "already exists") instead of 9 leaking raw SQL 23505.

Returns Just the existing tracker's id when the global_id idempotent path
fired (so the caller can return the same SUCCESS message). Returns Nothing
when a fresh insert succeeded.
-}
insertReleaseTrackerSafe :: ReleaseTracker -> TargetState -> Flow (Maybe Text)
insertReleaseTrackerSafe trk ts = do
    let go :: Flow (Either SqlError ())
        go = try $ insertReleaseTracker trk (Just ts)
    r <- go
    case r of
        Right () -> pure Nothing
        Left e
            | sqlState e == B.pack "23505"
                && B.isInfixOf (B.pack "uq_release_tracker_service_inflight") (sqlErrorMsg e <> sqlErrorDetail e) ->
                throwM $
                    Conflict
                        ( "Service "
                            <> NT.service trk
                            <> " in app group "
                            <> NT.appGroup trk
                            <> " already has an in-flight release. Wait for it to complete, abort, or discard."
                        )
            | sqlState e == B.pack "23505"
                && B.isInfixOf (B.pack "uq_release_tracker_global_id") (sqlErrorMsg e <> sqlErrorDetail e) ->
                case NT.globalId trk of
                    Just gid -> do
                        m <- findReleaseTrackerByGlobalId gid
                        case m of
                            Just (existing, _) -> pure (Just (NT.releaseId existing))
                            Nothing -> throwM e -- shouldn't happen, but safer than swallowing
                    Nothing -> throwM e
            | otherwise -> throwM e

createReleaseHBodyAfterGuard :: Maybe Text -> Maybe Text -> K8sCreateReleaseReq -> Flow APIResponse
createReleaseHBodyAfterGuard mXForwardedEmail mXPomeriumJwt K8sCreateReleaseReq{..} = do
    cfg <- getConfig
    p <- findProductByName appGroup
    s <- findServiceByProductAndName appGroup service
    case (p, s) of
        (Nothing, _) -> pure $ APIResponse "ERROR" "Product not configured"
        (_, Nothing) -> pure $ APIResponse "ERROR" "Service not configured for product"
        (Just pCfg, Just sCfg) -> do
            -- Safety check: old_version == new_version
            if oldVersion == newVersion
                then pure $ APIResponse "ERROR" "old_version and new_version cannot be the same"
                else -- Safety check: maintenance mode
                do
                    maintenance <- isUnderMaintenance
                    if maintenance
                        then pure $ APIResponse "ERROR" "System is under maintenance. Release creation is disabled."
                        else -- Safety check: version format (K8s label: [a-z0-9]([-a-z0-9]*[a-z0-9])?)

                            if not (isValidK8sVersion newVersion)
                                then pure $ APIResponse "ERROR" ("Invalid version format for K8s label: " <> newVersion <> ". Must match [a-z0-9]([-a-z0-9]*[a-z0-9])?")
                                else -- Existing cluster check

                                    if maybe False (/= getProductCluster pCfg) requestedCluster
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
                                                                logInfo "[createReleaseH] New service flag set, skipping old version discovery"
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
                                                                , syncClusterEnvOverrideData = syncClusterEnvOverrideData
                                                                , syncClusterRolloutStrategy = fmap (\v -> T.pack (LBS.unpack (A.encode v))) syncClusterRolloutStrategy
                                                                , syncXForwardedEmail = mXForwardedEmail
                                                                , syncXPomeriumJwt = mXPomeriumJwt
                                                                }
                                                        reqMode = case mode of
                                                            Just "MANUAL" -> MANUAL
                                                            Just "manual" -> MANUAL
                                                            _ -> AUTO
                                                    approveAll <- isApproveAllReleases
                                                    now <- liftIO getCurrentTime
                                                    let isFromSync = fromMaybe False isSystemTriggered
                                                        initialApproval = case isApproved of
                                                            Just True -> True
                                                            _ -> approveAll && isFromSync
                                                        -- Auto-generate release tag if not provided
                                                        autoTag = case releaseTag of
                                                            Just t | not (T.null t) -> Just t
                                                            _ ->
                                                                let datePart = T.pack (formatTime defaultTimeLocale "%Y%m%d" now)
                                                                    modeText = T.pack (show reqMode)
                                                                    priText = T.pack (show (fromMaybe 0 priority))
                                                                 in Just (T.intercalate "_" [appGroup, datePart, newVersion, service, modeText, env, priText])
                                                        tracker =
                                                            ReleaseTracker
                                                                { releaseId = rid
                                                                , appGroup = appGroup
                                                                , service = service
                                                                , env = env
                                                                , category = trackerType
                                                                , status = CREATED
                                                                , releaseWFStatus = INIT
                                                                , mode = reqMode
                                                                , createdBy = createdBy
                                                                , approvedBy = approvedBy
                                                                , isApproved = initialApproval
                                                                , isInfraApproved = fromMaybe (fromMaybe False (S.dcNeedInfraApproval pCfg >>= \need -> if need then Just False else Just True)) isInfraApproved
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
                                                                , syncEnabled =
                                                                    if isFromSync
                                                                        then Nothing
                                                                        else case isReleaseSync of
                                                                            Just True -> Just "true"
                                                                            _ -> syncEnabled
                                                                , envOverrideData = envOverrideData
                                                                , slackThreadTs = slackThreadTs
                                                                , -- Seed from 'derivedContext' below so the tracker's public view
                                                                  -- matches the 'K8sState' target state we're about to persist.
                                                                  -- Without this field the record is partial and any access to
                                                                  -- 'releaseContext' crashes at runtime with "Missing field in
                                                                  -- record construction" (caught by -Wmissing-fields).
                                                                  releaseContext = Just (toJSON derivedContext)
                                                                }
                                                        targetState =
                                                            K8sState $
                                                                emptyK8sState
                                                                    { context = derivedContext
                                                                    , newService = fromMaybe False newService
                                                                    , cronjobSuspend = fromMaybe False cronjobSuspend
                                                                    }
                                                    -- insertReleaseTrackerSafe returns Just <existing-id>
                                                    -- when the parallel global_id idempotency path fired
                                                    -- (another thread already inserted this global_id);
                                                    -- in that case, short-circuit with the same SUCCESS
                                                    -- shape the createReleaseH idempotent fast-path uses.
                                                    mIdem <- insertReleaseTrackerSafe tracker targetState
                                                    case mIdem of
                                                        Just existingRid -> do
                                                            logInfo $ "Idempotent receive (DB-level): tracker already exists for global_id, returning existing id=" <> existingRid
                                                            pure $ APIResponse "SUCCESS" ("Tracker already exists: " <> existingRid)
                                                        Nothing -> do
                                                            insertReleaseEvent rid "BUSINESS" "TRACKER_CREATED" (toJSON tracker)
                                                            -- Capture BEFORE snapshots at creation time (so diff is available immediately)
                                                            -- Also generate a preview AFTER by modifying version/image in the old deployment YAML
                                                            let ns = getProductNamespace pCfg
                                                                oldDepName = targetSvcHost <> "-" <> resolvedOldVersion
                                                            captureDeploymentSnapshot cfg rid ns oldDepName "DEPLOYMENT_BEFORE"
                                                            -- Generate preview AFTER: take old deployment, replace version + image
                                                            captureDeploymentPreview
                                                                cfg
                                                                rid
                                                                ns
                                                                oldDepName
                                                                newVersion
                                                                (fromMaybe "" metadataDockerImage)
                                                                "DEPLOYMENT_AFTER"
                                                            notifyReleaseCreated tracker
                                                            pure $ APIResponse "SUCCESS" ("Tracker created: " <> rid)

getReleaseH :: AuthedPerson -> Text -> Flow (Maybe ReleaseTracker)
getReleaseH _ap rid = do
    m <- findReleaseTracker rid
    pure (fmap fst m)

approveReleaseH :: AuthedPerson -> Text -> ApproveReleaseReq -> Flow (Maybe ReleaseTracker)
approveReleaseH _ap rid req = do
    m <- findReleaseTracker rid
    case m of
        Nothing -> throwM $ NotFound ("Release not found: " <> rid)
        Just (tracker, mTargetState) -> do
            -- Pre-check (cheap, friendly errors)
            if NT.status tracker /= CREATED
                then throwM $ BadRequest ("Cannot approve release in status " <> T.pack (show (NT.status tracker)) <> ". Only CREATED releases can be approved.")
                else if NT.isApproved tracker
                    then throwM $ BadRequest ("Release already approved by " <> fromMaybe "unknown" (NT.approvedBy tracker) <> ". Cannot approve again.")
                else do
                    let approver = req.approvedBy
                        infraApproval = req.isInfraApproved
                        updated =
                            (tracker :: ReleaseTracker)
                                { NT.approvedBy = Just approver
                                , NT.isApproved = True
                                , NT.isInfraApproved = fromMaybe (NT.isInfraApproved tracker) infraApproval
                                }
                    -- Atomic CAS: only update if status is still CREATED AND
                    -- not yet approved. Two concurrent approve calls both pass
                    -- the pre-check above; conditionalUpdateApprove uses an
                    -- UPDATE WHERE clause that lets exactly one win.
                    ok <- conditionalUpdateApprove updated mTargetState
                    if not ok
                        then throwM $ BadRequest "Release was approved or transitioned by a concurrent request."
                        else do
                            insertReleaseEvent rid "BUSINESS" "TRACKER_APPROVED" (toJSON approver)
                            notifyReleaseApproved updated
                            pure (Just updated)

triggerReleaseH :: AuthedPerson -> Text -> TriggerReleaseReq -> Flow APIResponse
triggerReleaseH _ap rid TriggerReleaseReq{..} = do
    m <- findReleaseTracker rid
    case m of
        Nothing -> pure $ APIResponse "ERROR" "Release not found"
        Just (tracker, mTargetState) -> do
            let oldStatus = NT.status tracker
            if isTerminalStatus oldStatus
                then pure $ APIResponse "ERROR" ("Cannot trigger from terminal status: " <> T.pack (show oldStatus))
                else do
                    now <- liftIO getCurrentTime
                    let updated = (tracker :: ReleaseTracker){NT.scheduleTime = Just now, NT.status = CREATED}
                    ok <- conditionalUpdateTracker updated mTargetState (releaseStatusToText oldStatus)
                    if ok
                        then do
                            insertReleaseEvent rid "BUSINESS" "TRACKER_TRIGGERED" (toJSON reason)
                            pure $ APIResponse "SUCCESS" "Release scheduled for execution"
                        else pure staleTrackerError

rollbackReleaseH :: AuthedPerson -> Text -> TriggerReleaseReq -> Flow APIResponse
rollbackReleaseH _ap rid TriggerReleaseReq{..} = do
    m <- findReleaseTracker rid
    case m of
        Nothing -> pure $ APIResponse "ERROR" "Release not found"
        Just (tracker, mTargetState) -> do
            let oldStatus = NT.status tracker
            if not (validateStatusTransition oldStatus ABORTING)
                then pure $ APIResponse "ERROR" ("Cannot rollback from status: " <> T.pack (show oldStatus))
                else do
                    let updated = (tracker :: ReleaseTracker){NT.status = ABORTING, NT.releaseWFStatus = ROLLING_BACK}
                    ok <- conditionalUpdateTracker updated mTargetState (releaseStatusToText oldStatus)
                    if ok
                        then do
                            insertReleaseEvent rid "BUSINESS" "ROLLBACK_REQUESTED" (toJSON reason)
                            pure $ APIResponse "SUCCESS" "Rollback marked"
                        else pure staleTrackerError

revertReleaseH :: AuthedPerson -> Text -> RevertReleaseReq -> Flow APIResponse
revertReleaseH _ap rid req = do
    cfg <- getConfig
    m <- findReleaseTracker rid
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
                        origSyncEnabled = maybe False (\t -> T.toLower t == "true") (NT.syncEnabled tracker)
                        shouldSyncRevert = fromMaybe False ((req :: RevertReleaseReq).isRevertSync) && origSyncEnabled
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
                                , NT.status = CREATED
                                , NT.releaseWFStatus = INIT
                                , NT.createdBy = fromMaybe trackerCreatedBy ((req :: RevertReleaseReq).requestedBy)
                                , NT.approvedBy = if isImmediate then Just (fromMaybe trackerCreatedBy ((req :: RevertReleaseReq).requestedBy)) else Nothing
                                , NT.isApproved = isImmediate
                                , NT.scheduleTime = Just now
                                , NT.startTime = Nothing
                                , NT.endTime = Nothing
                                , NT.rolloutHistory = []
                                , NT.releaseTag = fmap (<> "_REVERT") (NT.releaseTag tracker)
                                , NT.info = (req :: RevertReleaseReq).info
                                , NT.syncEnabled = if shouldSyncRevert then Just "true" else Nothing
                                , -- Bug fix: swap oldVersion/newVersion on the domain record so that
                                  -- Runner.validateRunningVersion (which compares NT.oldVersion against
                                  -- the live VS subset) will match. Without this swap the runner
                                  -- always sees the current VS at the original newVersion and
                                  -- discards the revert tracker with VERSION_MISMATCH.
                                  NT.oldVersion = NT.newVersion tracker
                                , NT.newVersion = NT.oldVersion tracker
                                , -- Bug fix (round 5): clear globalId on the revert tracker. The
                                  -- partial unique index uq_release_tracker_global_id forbids two
                                  -- rows with the same global_id; without this reset, every revert
                                  -- of a release that ever had a global_id (i.e. every cross-cloud
                                  -- replicated release) hit a raw SQL 23505 violation.
                                  NT.globalId = Nothing
                                }
                    insertReleaseTracker revertedTracker (Just revertedTargetState)
                    insertReleaseEvent
                        newRid
                        "BUSINESS"
                        "REVERT_TRACKER_CREATED"
                        ( object
                            [ "originalId" .= rid
                            , "shouldSyncRevert" .= shouldSyncRevert
                            , "isImmediate" .= isImmediate
                            , "origSyncEnabled" .= (origSyncEnabled :: Bool)
                            ]
                        )
                    -- Capture BEFORE snapshots for the revert release
                    let revertNs = (\(K8sReleaseContext{namespace = n}) -> n) oldCtx
                        revertNewDep = ctxServiceName <> "-" <> NT.newVersion tracker
                    captureDeploymentSnapshot cfg newRid revertNs revertNewDep "DEPLOYMENT_BEFORE"
                    captureDeploymentPreview
                        cfg
                        newRid
                        revertNs
                        revertNewDep
                        (NT.oldVersion tracker)
                        (fromMaybe "" (K8s.dockerImage oldCtx))
                        "DEPLOYMENT_AFTER"
                    notifyReleaseReverted revertedTracker
                    when (isImmediate && shouldSyncRevert) $
                        triggerImmediateRevertSync tracker mTargetState
                    pure $ APIResponse "SUCCESS" ("Revert tracker created: " <> newRid)

revertByGlobalIdH :: AuthedPerson -> Text -> Flow APIResponse
revertByGlobalIdH ap gid = do
    m <- findReleaseTrackerByGlobalId gid
    case m of
        Nothing -> pure $ APIResponse "ERROR" ("No release found with global_id=" <> gid)
        Just (tracker, _) -> revertReleaseH ap (releaseId tracker) (RevertReleaseReq Nothing Nothing Nothing Nothing)

immediateRevertByGlobalIdH :: AuthedPerson -> Text -> Flow APIResponse
immediateRevertByGlobalIdH ap gid = do
    m <- findReleaseTrackerByGlobalId gid
    case m of
        Nothing -> pure $ APIResponse "ERROR" ("No release found with global_id=" <> gid)
        Just (tracker, _) -> revertReleaseH ap (releaseId tracker) (RevertReleaseReq Nothing Nothing (Just True) Nothing)

discardReleaseH :: AuthedPerson -> Text -> DiscardReleaseReq -> Flow APIResponse
discardReleaseH _ap rid DiscardReleaseReq{..} = do
    m <- findReleaseTracker rid
    case m of
        Nothing -> pure $ APIResponse "ERROR" "Release not found"
        Just (tracker, mTargetState) -> do
            let oldStatus = NT.status tracker
            if not (validateStatusTransition oldStatus DISCARDED)
                then pure $ APIResponse "ERROR" ("Cannot discard from status: " <> T.pack (show oldStatus))
                else do
                    let updated = (tracker :: ReleaseTracker){NT.status = DISCARDED}
                    ok <- conditionalUpdateTracker updated mTargetState (releaseStatusToText oldStatus)
                    if ok
                        then do
                            -- Production parity: NOTIFICATION / STATUS_UPDATED
                            logStatusUpdated updated ("Tracker marked as DISCARDED" <> maybe "" (": " <>) reason)
                            notifyReleaseDiscarded updated
                            pure $ APIResponse "SUCCESS" "Release discarded"
                        else pure staleTrackerError

deleteReleaseH :: AuthedPerson -> Text -> Flow APIResponse
deleteReleaseH _ap rid = do
    db <- getDBEnv
    mTracker <- findReleaseTracker rid
    case mTracker of
        Nothing -> pure $ APIResponse "ERROR" "Release not found"
        Just (tracker, _) -> do
            -- Block deletion of active releases (INPROGRESS, ABORTING, REVERTING, PAUSED, RESTARTING)
            let activeStatuses = [INPROGRESS, ABORTING, REVERTING, PAUSED, RESTARTING]
            if NT.status tracker `elem` activeStatuses
                then pure $ APIResponse "ERROR" ("Cannot delete release in " <> T.pack (show (NT.status tracker)) <> " status. Abort or complete it first.")
                else do
                    _ <- liftIO $ withConn db $ \conn -> withTransaction conn $ do
                        _ <- execute conn "DELETE FROM release_events WHERE re_release_id = ?" (Only rid)
                        execute conn "DELETE FROM release_tracker WHERE id = ?" (Only rid)
                    pure $ APIResponse "SUCCESS" ("Release deleted: " <> rid)

updateTrackerH :: AuthedPerson -> Text -> K8sUpdateTrackerReq -> Flow APIResponse
updateTrackerH _ap rid req = do
    m <- findReleaseTracker rid
    case m of
        Nothing -> pure $ APIResponse "ERROR" "Release not found"
        Just (tracker, mTargetState) -> do
            let oldStatus = NT.status tracker
                oldStatusText = releaseStatusToText oldStatus
            -- Validate the update request against rollout-strategy invariants
            -- and mid-flight immutability rules. A broken strategy shape or a
            -- disallowed field modification is always rejected up-front, so
            -- the downstream apply/DB path never sees inconsistent data.
            case validateUpdateRequest tracker req of
                Left err -> pure $ APIResponse "ERROR" err
                Right () -> do
                    let (updatedTracker, updatedTargetState) = applyUpdates tracker mTargetState req
                    case (req :: K8sUpdateTrackerReq).status of
                        Just newStatusText -> do
                            let newStatus = parseReleaseStatus newStatusText
                            if newStatus == oldStatus
                                then do
                                    -- Same status: just update other fields, but guard against concurrent status change
                                    ok <- conditionalUpdateTracker updatedTracker updatedTargetState oldStatusText
                                    if ok
                                        then do
                                            insertReleaseEvent rid "BUSINESS" "TRACKER_UPDATED" (toJSON updatedTracker)
                                            notifyReleaseUpdated updatedTracker "fields updated"
                                            pure $ APIResponse "SUCCESS" "Tracker updated"
                                        else pure staleTrackerError
                                else
                                    if not (validateStatusTransition oldStatus newStatus)
                                        then pure $ APIResponse "ERROR" ("Invalid status transition: " <> T.pack (show oldStatus) <> " -> " <> newStatusText)
                                        else do
                                            ok <- conditionalUpdateTracker updatedTracker updatedTargetState oldStatusText
                                            if ok
                                                then do
                                                    -- Production parity: NOTIFICATION / STATUS_UPDATED
                                                    logStatusUpdated updatedTracker ("Tracker marked as " <> newStatusText)
                                                    -- Send status-specific Slack notifications
                                                    case newStatus of
                                                        PAUSED -> notifyReleasePaused updatedTracker
                                                        INPROGRESS -> notifyReleaseResumed updatedTracker
                                                        ABORTING -> notifyReleaseAborted updatedTracker
                                                        COMPLETED -> notifyReleaseCompleted updatedTracker updatedTargetState
                                                        _ -> notifyReleaseUpdated updatedTracker ("status changed to " <> newStatusText)
                                                    -- Bug fix #3 (round 4): re-attach the workflow on PAUSED→INPROGRESS.
                                                    -- Backend restart while paused leaves the in-memory worker dead.
                                                    -- The user-facing resume must re-fork dispatchWorkflow so the
                                                    -- rollout continues. Race-safety (round 7 audit B6 verified):
                                                    -- the conditionalUpdateTracker CAS above is the gate — only the
                                                    -- single caller that wins the atomic PAUSED→INPROGRESS UPDATE
                                                    -- reaches this fork. Rapid 5x resume calls all see PAUSED, all
                                                    -- attempt the CAS, exactly one transitions, the other 4 get
                                                    -- staleTrackerError. So no fork-storm is possible here.
                                                    when (oldStatus == PAUSED && newStatus == INPROGRESS) $
                                                        void $ forkFlow $ do
                                                            r <- dispatchWorkflow updatedTracker updatedTargetState
                                                            case r of
                                                                Right _ -> logInfo $ "[resume] workflow re-attached for " <> rid
                                                                Left e -> logInfo $ "[resume] workflow exited for " <> rid <> ": " <> T.pack (show e)
                                                    pure $ APIResponse "SUCCESS" "Tracker updated"
                                                else pure staleTrackerError
                        Nothing -> do
                            -- No status change requested, but guard against concurrent status change
                            ok <- conditionalUpdateTracker updatedTracker updatedTargetState oldStatusText
                            if ok
                                then do
                                    insertReleaseEvent rid "BUSINESS" "TRACKER_UPDATED" (toJSON updatedTracker)
                                    notifyReleaseUpdated updatedTracker "status/fields updated"
                                    pure $ APIResponse "SUCCESS" "Tracker updated"
                                else pure staleTrackerError

{- | Validate an incoming 'K8sUpdateTrackerReq' against two independent sets
of rules, returning @Left reason@ on the first failure.

1. __Rollout strategy invariants__ (apply at /every/ status): whenever the
request supplies a new @rolloutStrategy@, it must be non-empty, use only
valid cooloff/pod/percent values, have strictly-monotonic @rolloutPercent@
values, and end at 100. These are cheap shape checks that catch obviously
broken payloads before they hit the DB or the workflow loop.

2. __Mid-flight immutability__ (apply to @INPROGRESS@ / @PAUSED@ /
@RESTARTING@ / @REVERTING@): while a release is live the ONLY fields a
user may touch are @status@ (pause/resume/abort transitions),
@rolloutStrategy@ (limited to future-stage edits — stages that already
appear in @rolloutHistory@ must be byte-identical), and @changeLog@
(informational, safe to append during a rollout). Everything else is
rejected because it would race the running workflow.

The separation matters: #1 runs even at @CREATED@ (catches bad initial
strategies); #2 only runs once the rollout is live, so @CREATED@ releases
can still be edited freely.
-}
validateUpdateRequest :: ReleaseTracker -> K8sUpdateTrackerReq -> Either Text ()
validateUpdateRequest tracker req = do
    -- (1) Strategy shape invariants — always applied when a strategy is sent.
    case (req :: K8sUpdateTrackerReq).rolloutStrategy of
        Nothing -> pure ()
        Just newStrategy -> validateStrategyShape newStrategy
    -- (2) Mid-flight immutability.
    let oldStatus = NT.status tracker
    if oldStatus `elem` midFlightStatuses
        then do
            -- Only status / rolloutStrategy / changeLog may be non-Nothing.
            case forbiddenFieldDuringMidFlight req of
                Just fieldName ->
                    Left $
                        "Cannot modify '"
                            <> fieldName
                            <> "' while release is "
                            <> releaseStatusText oldStatus
                            <> ". Pause it first."
                Nothing -> pure ()
            -- Status transition, if requested, must be pause/abort-only.
            case (req :: K8sUpdateTrackerReq).status of
                Nothing -> pure ()
                Just newStatusText ->
                    let newStatus = parseReleaseStatus newStatusText
                     in if newStatus == oldStatus
                            || newStatus `elem` [PAUSED, ABORTING, INPROGRESS, RESTARTING]
                            then pure ()
                            else
                                Left $
                                    "During mid-flight, only status transitions to PAUSED / ABORTING / "
                                        <> "INPROGRESS / RESTARTING are allowed; got "
                                        <> newStatusText
            -- Strategy updates must preserve every stage already reached.
            case (req :: K8sUpdateTrackerReq).rolloutStrategy of
                Nothing -> pure ()
                Just newStrategy ->
                    let histLen = length (NT.rolloutHistory tracker)
                        oldStrategy = NT.rolloutStrategy tracker
                     in if histLen == 0 || take histLen newStrategy == take histLen oldStrategy
                            then pure ()
                            else
                                Left
                                    "Cannot modify a rollout stage that has already started. \
                                    \Future (not-yet-reached) stages may still be edited."
        else pure ()
  where
    midFlightStatuses :: [ReleaseStatus]
    midFlightStatuses = [INPROGRESS, PAUSED, RESTARTING, REVERTING]

{- | Shape-level invariants on a proposed rollout strategy: non-empty, valid
numeric ranges, strictly monotonic rolloutPercent, and a terminal 100 stage.
Runs before any state-dependent checks.
-}
validateStrategyShape :: [RolloutStep] -> Either Text ()
validateStrategyShape [] = Left "Rollout strategy must have at least one stage"
validateStrategyShape steps = do
    let percents = map rolloutPercent steps
        cooloffs = map cooloffMinutes steps
        pods = map podPercent steps
    when (any (\p -> p < 0 || p > 100) percents) $
        Left "Rollout percents must be in the range [0, 100]"
    when (any (\p -> p < 0 || p > 100) pods) $
        Left "Pod percents must be in the range [0, 100]"
    when (any (< 0) cooloffs) $
        Left "Cooloff minutes must be non-negative"
    when (percents /= sortedStrictlyIncreasing percents) $
        Left "Rollout percents must be strictly increasing across stages"
    when (Prelude.last percents /= 100) $
        Left "Final rollout stage must reach 100%"
  where
    sortedStrictlyIncreasing :: [Int] -> [Int]
    sortedStrictlyIncreasing xs =
        -- Strictly-increasing iff no adjacent pair (x, y) has x >= y.
        if all (uncurry (<)) (zip xs (drop 1 xs))
            then xs
            else [] -- sentinel that never equals a valid list of length >= 1

{- | Identify the first mid-flight-forbidden field set in the request, if any.
During INPROGRESS/PAUSED/etc only status, rolloutStrategy, and changeLog
are legal. Returns @Just fieldName@ for the first violation.
-}
forbiddenFieldDuringMidFlight :: K8sUpdateTrackerReq -> Maybe Text
forbiddenFieldDuringMidFlight req
    | isJust (req.mode) = Just "mode"
    | isJust (req.releaseManager) = Just "releaseManager"
    | isJust (req.priority) = Just "priority"
    | isJust (req.scheduleTime) = Just "scheduleTime"
    | isJust (req.description) = Just "description"
    | isJust (req.info) = Just "info"
    | isJust (req.isApproved) = Just "isApproved"
    | isJust (req.isInfraApproved) = Just "isInfraApproved"
    | isJust (req.syncEnabled) = Just "syncEnabled"
    | isJust (req.envOverrideData) = Just "envOverrideData"
    | isJust (req.slackThreadTs) = Just "slackThreadTs"
    | isJust (req.dockerImage) = Just "dockerImage"
    | isJust (req.podsScaleDownDelay) = Just "podsScaleDownDelay"
    | otherwise = Nothing

applyUpdates :: ReleaseTracker -> Maybe TargetState -> K8sUpdateTrackerReq -> (ReleaseTracker, Maybe TargetState)
applyUpdates tracker mts req =
    let setMode m t = case m of
            "MANUAL" -> t{NT.mode = MANUAL}
            "AUTO" -> t{NT.mode = AUTO}
            _ -> t
        updatedTracker =
            applyMaybe req.status (\s t -> (t :: ReleaseTracker){NT.status = parseReleaseStatus s}) $
                applyMaybe req.mode setMode $
                    applyMaybe req.releaseManager (\rm t -> t{NT.createdBy = rm}) $
                        applyMaybe req.priority (\p t -> t{NT.priority = p}) $
                            applyMaybe req.scheduleTime (\st t -> t{NT.scheduleTime = Just st}) $
                                applyMaybe req.description (\d t -> t{NT.description = Just d}) $
                                    applyMaybe req.info (\i t -> t{NT.info = Just i}) $
                                        applyMaybe req.rolloutStrategy (\rs t -> t{NT.rolloutStrategy = rs}) $
                                            applyMaybe req.changeLog (\cl t -> t{NT.changeLog = Just cl}) $
                                                applyMaybe req.isApproved (\a t -> t{NT.isApproved = a}) $
                                                    applyMaybe req.isInfraApproved (\a t -> t{NT.isInfraApproved = a}) $
                                                        applyMaybe req.syncEnabled (\u t -> t{NT.syncEnabled = Just u}) $
                                                            applyMaybe req.envOverrideData (\u t -> t{NT.envOverrideData = Just u}) $
                                                                applyMaybe req.slackThreadTs (\u t -> t{NT.slackThreadTs = Just u}) tracker
        updatedTargetState =
            applyMaybe req.dockerImage (\img s -> updateK8sContext s (\ctx -> ctx{K8s.dockerImage = Just img})) $
                applyMaybe req.podsScaleDownDelay (\d s -> updateK8sContext s (\ctx -> ctx{K8s.podsScaleDownDelay = Just d})) mts
     in (updatedTracker, updatedTargetState)

updateK8sContext :: Maybe TargetState -> (K8sReleaseContext -> K8sReleaseContext) -> Maybe TargetState
updateK8sContext (Just (K8sState k8s)) f = Just $ K8sState $ k8s{context = f (context k8s)}
updateK8sContext other _ = other

listEventsH :: AuthedPerson -> Text -> Flow [ReleaseEventResponse]
listEventsH _ap rid = do
    events <- listReleaseEvents rid
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

rolloutHistoryH :: AuthedPerson -> Text -> Flow Value
rolloutHistoryH _ap rid = do
    m <- findReleaseTracker rid
    case m of
        Nothing -> throwM $ NotFound "Release not found"
        Just (tracker, _) -> pure $ toJSON (NT.rolloutHistory tracker)

-- ============================================================================
-- Logs Link Endpoint (GET /releases/:id/logslink)
-- ============================================================================

logsLinkH :: AuthedPerson -> Text -> Flow Value
logsLinkH _ap rid = do
    m <- findReleaseTracker rid
    case m of
        Nothing -> throwM $ NotFound "Release not found"
        Just _ ->
            -- Stub: production generates Grafana/Kibana URLs from config; not yet
            -- wired up here. Surface explicitly instead of returning empty links
            -- so callers don't silently render broken UI.
            throwM $ InternalError "logsLinkH not yet implemented"

-- ============================================================================
-- Diff Endpoint (GET /releases/:id/diff)
-- ============================================================================

releaseDiffH :: AuthedPerson -> Text -> Maybe Text -> Flow DiffResponse
releaseDiffH _ap rid _mType = do
    cfg <- getConfig
    m <- findReleaseTracker rid
    case m of
        Nothing -> pure $ DiffResponse "" "" "Release not found"
        Just (tracker, mTargetState) -> do
            -- Check for stored SNAPSHOT events first
            snapshotEvents <- listReleaseEventsByCategory rid "SNAPSHOT"
            let trackerCat = NT.category tracker
                (beforeLabel, afterLabel, diffLabel) = case trackerCat of
                    BackendConfig -> ("CONFIGMAP_BEFORE", "CONFIGMAP_AFTER", "ConfigMap diff")
                    VSEdit -> ("VS_OLD", "VS_NEW", "VS diff")
                    _ -> ("DEPLOYMENT_BEFORE", "DEPLOYMENT_AFTER", "Deployment diff")
                findSnapshot label = find (\e -> S.reLabel e == label) snapshotEvents
                mBefore = findSnapshot beforeLabel
                mAfter = findSnapshot afterLabel
            let payloadToText :: Value -> Text
                payloadToText (String s) = s -- Already YAML text from snapshot capture, return as-is
                payloadToText other = TE.decodeUtf8 (LBS.toStrict (A.encode other))
            case (mBefore, mAfter) of
                (Just beforeEvt, Just afterEvt) ->
                    let b = payloadToText (S.rePayload beforeEvt)
                        a = payloadToText (S.rePayload afterEvt)
                     in pure $ case trackerCat of
                            BackendConfig -> DiffResponse (extractConfigMapDataSection b) (extractConfigMapDataSection a) diffLabel
                            _ -> DiffResponse b a diffLabel
                (Just beforeEvt, Nothing) -> do
                    -- For configmaps, extract data section from both sides so they're comparable
                    case trackerCat of
                        BackendConfig -> do
                            let beforeData = extractConfigMapDataSection (payloadToText (S.rePayload beforeEvt))
                                rawProposed =
                                    case NT.metadata tracker of
                                        Just (Object o) ->
                                            case KM.lookup (K.fromText "file") o of
                                                Just (String f) -> f
                                                _ -> case KM.lookup (K.fromText "config") o of
                                                    Just (String c) -> c
                                                    _ -> ""
                                        _ -> ""
                                -- Normalize: if proposed is a K8s YAML manifest, extract data section
                                proposedData = extractConfigMapDataSection rawProposed
                            pure $ DiffResponse beforeData proposedData diffLabel
                        _ ->
                            pure $
                                DiffResponse
                                    (payloadToText (S.rePayload beforeEvt))
                                    ""
                                    (diffLabel <> " (after snapshot pending)")
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
                            -- Get new deployment envs (or envOverrideData env switch data)
                            let newEnvSource = NT.envOverrideData tracker
                            case newEnvSource of
                                Just envOverrideEnvs | not (T.null envOverrideEnvs) -> do
                                    -- envOverrideData contains the new env switch data
                                    let oldEnvText = case oldEnvResult of
                                            Right (K8sResult out) -> cleanJsonpath out
                                            Left _ -> ""
                                    pure $ DiffResponse oldEnvText envOverrideEnvs "Diff from env switch (envOverrideData)"
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

podHealthH :: AuthedPerson -> Text -> Flow PodHealthResponse
podHealthH _ap rid = do
    cfg <- getConfig
    m <- findReleaseTracker rid
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

immediateRevertH :: AuthedPerson -> Text -> ImmediateRevertReq -> Flow APIResponse
immediateRevertH _ap rid req@ImmediateRevertReq{isRevertSync = mIsRevertSync} = do
    cfg <- getConfig
    m <- findReleaseTracker rid
    case m of
        Nothing -> pure $ APIResponse "ERROR" "Release not found"
        Just (tracker, mTargetState) -> do
            let currentStatus = NT.status tracker
            if currentStatus /= COMPLETED && currentStatus /= INPROGRESS
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
                                    restartResult <- liftIO $ executeWithRetry cfg restartCmd
                                    let mRestartErr = case restartResult of
                                            Left (K8sError e) -> Just e
                                            Right _ -> Nothing
                                    -- Step 3: CAS update tracker status against snapshot
                                    let updated = (tracker :: ReleaseTracker){NT.status = REVERTED}
                                    ok <- conditionalUpdateTracker updated mTargetState (releaseStatusToText currentStatus)
                                    if not ok
                                        then pure staleTrackerError
                                        else do
                                            insertReleaseEvent rid "BUSINESS" "IMMEDIATE_REVERT" (object ["requestedBy" .= (req :: ImmediateRevertReq).requestedBy, "info" .= (req :: ImmediateRevertReq).info])
                                            notifyImmediateReverted updated
                                            -- Step 4: Optionally trigger sync revert
                                            let shouldSync = fromMaybe False mIsRevertSync
                                            when shouldSync $
                                                triggerImmediateRevertSync tracker mTargetState
                                            -- Step 5: surface restart failure as WARNING (image swap already succeeded;
                                            -- caller decides whether to roll back manually).
                                            case mRestartErr of
                                                Just err -> do
                                                    logInfo $ "[immediateRevertH] rollout restart failed for " <> rid <> ": " <> err
                                                    insertReleaseEvent
                                                        rid
                                                        "BUSINESS"
                                                        "REVERT_RESTART_FAILED"
                                                        (object ["error" .= err])
                                                    pure $
                                                        APIResponse
                                                            "WARNING"
                                                            ( "Immediate revert: image swapped, but rollout restart failed: "
                                                                <> err
                                                                <> ". Pods may still be running the new image; manual intervention may be required."
                                                            )
                                                Nothing ->
                                                    pure $ APIResponse "SUCCESS" "Immediate revert: image swapped + pods restarting"

-- ============================================================================
-- Restart Release (POST /releases/:id/restart)
-- ============================================================================

restartReleaseH :: AuthedPerson -> Text -> RestartReleaseReq -> Flow APIResponse
restartReleaseH _ap rid req = do
    m <- findReleaseTracker rid
    case m of
        Nothing -> pure $ APIResponse "ERROR" "Release not found"
        Just (tracker, mTargetState) -> do
            let currentStatus = NT.status tracker
            if currentStatus /= ABORTED && currentStatus /= USER_ABORTED && currentStatus /= REVERTED
                then pure $ APIResponse "ERROR" ("Cannot restart from status: " <> T.pack (show currentStatus) <> ". Valid: ABORTED, USER_ABORTED, REVERTED")
                else do
                    now <- liftIO getCurrentTime
                    let updated =
                            (tracker :: ReleaseTracker)
                                { NT.status = CREATED
                                , NT.releaseWFStatus = INIT
                                , NT.startTime = Nothing
                                , NT.endTime = Nothing
                                , NT.scheduleTime = Just now
                                , NT.rolloutHistory = []
                                }
                    ok <- conditionalUpdateTracker updated mTargetState (releaseStatusToText currentStatus)
                    if not ok
                        then pure staleTrackerError
                        else do
                            insertReleaseEvent
                                rid
                                "BUSINESS"
                                "RELEASE_RESTARTED"
                                ( object
                                    [ "requestedBy" .= (req :: RestartReleaseReq).requestedBy
                                    , "reason" .= (req :: RestartReleaseReq).reason
                                    , "previousStatus" .= T.pack (show currentStatus)
                                    ]
                                )
                            notifyReleaseRestarted updated
                            pure $ APIResponse "SUCCESS" "Release restarted"

-- ============================================================================
-- Fast Forward (POST /releases/:id/fast-forward)
-- ============================================================================

fastForwardH :: AuthedPerson -> Text -> FastForwardReq -> Flow APIResponse
fastForwardH ap rid req = do
    m <- findReleaseTracker rid
    case m of
        Nothing -> pure $ APIResponse "ERROR" "Release not found"
        Just (tracker, mTargetState) -> do
            let currentStatus = NT.status tracker
            if currentStatus /= INPROGRESS
                then pure $ APIResponse "ERROR" ("Cannot fast-forward from status: " <> T.pack (show currentStatus) <> ". Must be INPROGRESS")
                else do
                    -- Debounce: if the current stage is ALREADY marked manualOverride=true,
                    -- a previous fast-forward already fired and the workflow just hasn't
                    -- advanced yet (it polls every release_watch_delay seconds). Return a
                    -- friendly no-op so we don't pollute the event log with duplicate
                    -- FAST_FORWARD entries when the user clicks twice quickly.
                    -- BUT (round 7 audit B5): if the previous fast-forward never landed
                    -- (workflow stuck for >5 minutes since the manualOverride was set),
                    -- ALLOW a fresh fast-forward attempt so the user can recover from a
                    -- wedged workflow without aborting + restarting the whole release.
                    nowFF <- liftIO getCurrentTime
                    let history = NT.rolloutHistory tracker
                        (currentStepAlreadyForwarded, stuckTooLong) = case history of
                            [] -> (False, False)
                            xs ->
                                let lastH = last xs
                                    forwarded = historyManualOverride lastH
                                    elapsedMin =
                                        round
                                            ( realToFrac (diffUTCTime nowFF (historyStartedAt lastH)) / 60.0
                                                :: Double
                                            ) ::
                                            Int
                                 in (forwarded, elapsedMin >= 5)
                    if currentStepAlreadyForwarded && not stuckTooLong
                        then pure $ APIResponse "SUCCESS" "Fast forward already in progress for current stage; runner will advance on next poll."
                        else do
                            -- Fast-forward: match production Julia logic exactly.
                            -- Sets rollout strategy cooloff to elapsed minutes (time since step started),
                            -- so isCoolOffExceeded(cooloff, startedAt) returns true immediately:
                            --   coolOffLimit = startedAt + Minute(elapsedMinutes) <= now  →  true
                            -- Also marks historyManualOverride = True.
                            now <- liftIO getCurrentTime
                            let currentStepIdx = length history - 1
                                -- Calculate elapsed minutes from step start
                                elapsedMins = case history of
                                    [] -> 0
                                    steps ->
                                        let lastStep = last steps
                                         in round (realToFrac (diffUTCTime now (historyStartedAt lastStep)) / 60 :: Double) :: Int
                                strategy = NT.rolloutStrategy tracker
                                updatedStrategy = case strategy of
                                    [] -> []
                                    steps ->
                                        zipWith (\i s -> if i == currentStepIdx then s{cooloffMinutes = elapsedMins} else s) [0 ..] steps
                                -- History keeps original cooloff for display; manualOverride=True shows it was fast-forwarded
                                -- Strategy gets elapsedMins so workflow's isCoolOffExceeded passes immediately
                                updatedHistory = case history of
                                    [] -> []
                                    steps ->
                                        let lastIdx = length steps - 1
                                            updateStep i step =
                                                if i == lastIdx
                                                    then step{historyManualOverride = True}
                                                    else step
                                         in zipWith updateStep [0 ..] steps
                                updated = (tracker :: ReleaseTracker){NT.rolloutHistory = updatedHistory, NT.rolloutStrategy = updatedStrategy}
                            ok <- conditionalUpdateTracker updated mTargetState (releaseStatusToText currentStatus)
                            if not ok
                                then pure staleTrackerError
                                else do
                                    -- Default requestedBy to the authenticated person if frontend
                                    -- omitted the field, so the audit log isn't full of nulls.
                                    let actor = case (req :: FastForwardReq).requestedBy of
                                            Just t | not (T.null t) -> t
                                            _ -> apEmail ap
                                        reasonText = case (req :: FastForwardReq).reason of
                                            Just t | not (T.null t) -> Just t
                                            _ -> Just "User-initiated fast-forward"
                                    insertReleaseEvent
                                        rid
                                        "BUSINESS"
                                        "FAST_FORWARD"
                                        ( object
                                            [ "requestedBy" .= actor
                                            , "reason" .= reasonText
                                            , "stage" .= (currentStepIdx + 1)
                                            ]
                                        )
                                    notifyReleaseFastForwarded updated
                                    pure $ APIResponse "SUCCESS" "Fast forward: cooloff period skipped, runner will advance on next poll"

-- ============================================================================
-- Validation Helpers
-- ============================================================================

{- | Validate that a version string matches the K8s label format: [a-z0-9]([-a-z0-9]*[a-z0-9])?
Empty strings are rejected. The check is case-insensitive (lowered before validation).
-}
isValidK8sVersion :: Text -> Bool
isValidK8sVersion ver
    | T.null ver = False
    | otherwise =
        -- K8s deployment names are case-sensitive and must be all-lowercase
        -- (RFC 1123 label). Don't pre-lowercase the input — that masks bugs
        -- like an UPPERCASE caller passing "V102BAD" which would fail later
        -- at kubectl apply. Reject anything containing uppercase or chars
        -- outside [a-z0-9-], with start/end alphanumeric.
        let chars = T.unpack ver
            isValidChar c = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-'
            isAlnumLower c = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
            startsOk = case chars of (c : _) -> isAlnumLower c; [] -> False
            endsOk = case chars of [] -> False; _ -> isAlnumLower (Prelude.last chars)
         in all isValidChar chars && startsOk && endsOk

{- | Extract just the data section from a K8s ConfigMap YAML as JSON.
Input: full K8s YAML like "apiVersion: v1\ndata:\n  app.conf: |-\n    ...\nkind: ..."
Output: JSON like "{\"app.conf\":\"...\"}" so it matches the tracker's file format.
-}
extractConfigMapDataSection :: Text -> Text
extractConfigMapDataSection yamlText =
    case Yaml.decodeEither' (TE.encodeUtf8 yamlText) :: Either Yaml.ParseException Value of
        Right (Object obj) ->
            case KM.lookup (K.fromText "data") obj of
                Just dataVal -> TE.decodeUtf8 (LBS.toStrict (A.encode dataVal))
                Nothing -> yamlText
        _ -> yamlText
