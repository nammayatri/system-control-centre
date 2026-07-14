{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Products.Autopilot.Actions.Release
  ( -- * Release Handlers
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
    decisionWebhookH,
    staggerInfoH,
    rolloutRestartDeploymentH,

    -- * Product/Service Handlers (used in Routes wiring)
    listProductsH,
    upsertProductH,
    listServicesH,
    upsertServiceH,

    -- * Helpers exported for other modules
    isValidK8sVersion,
    injectPromotable,
    injectStoreState,
  )
where

import Control.Applicative ((<|>))
import Control.Monad (void, when)
import Control.Monad.Catch (throwM, try)
import Control.Monad.IO.Class (liftIO)
import Core.AppError (APIError (..))
import Core.Auth.Protected (AuthedPerson (..), requireDeploymentPermission)
import Core.Config (Config (..))
import Core.DB.Connection (withConn)
import Core.Environment (Flow, forkFlow, getConfig, getDBEnv, logInfo)
import Core.Logging (logErrorG)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Char8 qualified as B
import Data.ByteString.Lazy.Char8 qualified as LBS
import Data.Foldable qualified as F
import Data.Int (Int32)
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import Data.Proxy (Proxy (..))
import Data.Scientific (toBoundedInteger)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime, parseTimeM)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Data.Yaml qualified as Yaml
import Database.PostgreSQL.Simple (Only (..), SqlError (..), execute, withTransaction)
import Products.Autopilot.DiffLink (buildDiffLink)
import Products.Autopilot.Discovery (listServicesFromVirtualService)
import Products.Autopilot.EventLog (logStatusUpdated)
import Products.Autopilot.K8s.Deployment (buildPatchDeploymentEnvsCommand, deploymentExists, getRunningSchedulerVersion)
import Products.Autopilot.K8s.Execute (K8sError (..), K8sResult (..), executeWithRetry, runCmd, shellQuote)
import Products.Autopilot.K8s.Kubectl (getPrimarySubsetFromVirtualService)
import Products.Autopilot.Mobile.Lifecycle.BuildKind (buildKind)
import Products.Autopilot.Mobile.Lifecycle.Phase (Display (..), displayStatusInferred, phaseFromFields, phaseSlug, variantSlug)
import Products.Autopilot.Mobile.Queries.StoreStatus (StoreCell, productionVersionsByApp, resolveStoreState, storeCellsByApp)
import Products.Autopilot.Mobile.StoreSync (versionOlderThan)
import Products.Autopilot.Mobile.Types (mbContext, mbWfStatus)
import Products.Autopilot.Notifications
import Products.Autopilot.Queries.ProductService
import Products.Autopilot.Queries.ReleaseTracker
import Products.Autopilot.Queries.VsEditTracker ()
import Products.Autopilot.Runner (dispatchWorkflow)
import Products.Autopilot.RuntimeConfig (isApproveAllReleases, isUnderMaintenance)
import Products.Autopilot.Sync (triggerImmediateRevertSync)
import Products.Autopilot.Types
import Products.Autopilot.Types qualified as NT
import Products.Autopilot.Types.API
import Products.Autopilot.Types.Permission (AutopilotPermission (..))
import Products.Autopilot.Types.Storage.Schema qualified as S
import Products.Autopilot.Types.Target (TargetState (..))
import Products.Autopilot.Types.Target.Kubernetes
import Products.Autopilot.Types.Target.Kubernetes qualified as K8s
import Products.Autopilot.Workflow.Helpers (captureDeploymentPreview, captureDeploymentSnapshot)
import Shared.API.Response (APIResponse (..))

-- ============================================================================
-- Shared helpers
-- ============================================================================

-- | Standard error returned when a CAS update fails because another request
-- mutated the tracker between snapshot read and write.
staleTrackerError :: APIResponse
staleTrackerError = APIResponse "ERROR" "Release was modified by another request. Please refresh and try again."

-- | Apply an update function to a value only when the optional input is 'Just'.
-- Used to collapse long sequential @case req.field of Just x -> ...; Nothing -> acc@
-- chains in 'applyUpdates' into a single combinator.
applyMaybe :: Maybe a -> (a -> b -> b) -> b -> b
applyMaybe Nothing _ acc = acc
applyMaybe (Just x) f acc = f x acc

-- ============================================================================
-- Product/Service Handlers
-- ============================================================================

upsertProductH :: AuthedPerson -> UpsertProductReq -> Flow APIResponse
upsertProductH ap req = do
  requireDeploymentPermission (Proxy :: Proxy 'AP_PRODUCT_CONFIG_EDIT) ap req.appGroup
  case normalizeProductType req.productType of
    Left err -> pure $ APIResponse "ERROR" err
    Right canonical -> do
      upsertProduct req.appGroup req.cluster req.namespace req.vsName canonical req.productAcronym req.syncCluster req.needInfraApproval req.slackChannel req.repoName
      pure $ APIResponse "SUCCESS" "product_config upserted"

-- | Map any incoming productType string to the canonical 'ReleaseCategory'
-- ADT name. Tolerates legacy aliases ('SERVICE', 'SCHEDULER') so old admin
-- clients keep working, but rejects unknown values so we don't silently
-- store garbage that breaks the workflow factory downstream. Empty input
-- defaults to BackendService (preserves prior implicit behavior).
normalizeProductType :: Text -> Either Text Text
normalizeProductType raw = case T.toLower (T.strip raw) of
  "" -> Right "BackendService"
  "backendservice" -> Right "BackendService"
  "service" -> Right "BackendService"
  "backendscheduler" -> Right "BackendScheduler"
  "scheduler" -> Right "BackendScheduler"
  "backendconfig" -> Right "BackendConfig"
  "config" -> Right "BackendConfig"
  "vsedit" -> Right "VSEdit"
  other -> Left ("Invalid productType: " <> other <> ". Expected one of BackendService, BackendScheduler, BackendConfig, VSEdit.")

listProductsH :: AuthedPerson -> Flow [ProductResponse]
listProductsH _ap = do
  rows <- listProducts
  pure $
    map
      ( \p ->
          ProductResponse
            { appGroup = S.dcAppGroup p,
              cluster = getProductCluster p,
              namespace = getProductNamespace p,
              vsName = getProductVsName p,
              productType = fromMaybe "SERVICE" (S.dcAppGroupType p),
              productAcronym = fromMaybe "" (S.dcAppGroupAcronym p),
              syncCluster = getProductSyncCluster p,
              slackChannel = S.dcSlackChannel p
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
upsertServiceH ap req = do
  requireDeploymentPermission (Proxy :: Proxy 'AP_PRODUCT_CONFIG_EDIT) ap req.appGroup
  upsertService req.rolloutStrategyText req.decisionConfigText req.service req.appGroup req.serviceType req.serviceHost req.revertStrategyText
  pure $ APIResponse "SUCCESS" "release_config upserted"

-- ============================================================================
-- Release CRUD Handlers
-- ============================================================================

listReleasesH :: AuthedPerson -> Maybe Text -> Maybe Text -> Maybe Text -> Flow [ReleaseTracker]
listReleasesH _ap mFrom mTo mCategory = do
  let mWhitelist = categoryWhitelist mCategory
  prodCodes <- productionVersionsByApp
  cells <- storeCellsByApp
  let enrich = fst . injectStoreState cells . injectPromotable prodCodes
  case (mFrom >>= parseISO, mTo >>= parseISO) of
    (Just fromTime, Just toTime) -> do
      pairs <- listReleaseTrackersByDateRangeAndCategory fromTime toTime mWhitelist
      pure (map enrich pairs)
    _ -> do
      -- No valid date range -- default to last 30 days as safety limit
      now <- liftIO getCurrentTime
      let thirtyDaysAgo = addUTCTime (-30 * 86400) now
      pairs <- listReleaseTrackersByDateRangeAndCategory thirtyDaysAgo now mWhitelist
      pure (map enrich pairs)
  where
    parseISO :: Text -> Maybe UTCTime
    parseISO t =
      parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" (T.unpack t)
        <|> parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (T.unpack t)
        <|> parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Q%Z" (T.unpack t)
    -- 'Nothing' / unknown values fall through to the default UI exclusions
    -- (VSEdit + BackendConfig hidden). 'Just "mobile"' restricts to
    -- MobileBuild; 'Just "backend"' to the three backend categories,
    -- including BackendConfig (overriding the default exclusion since the
    -- caller is asking for it explicitly).
    categoryWhitelist :: Maybe Text -> Maybe [Text]
    categoryWhitelist (Just "mobile") = Just ["MobileBuild"]
    categoryWhitelist (Just "backend") =
      Just ["BackendService", "BackendScheduler", "BackendConfig"]
    categoryWhitelist _ = Nothing

-- | Inject a per-row @promotable@ flag (BE truth) into a mobile release's release_context:
-- True when the build is ahead of production — a NEWER marketing version, or the same version
-- with a HIGHER build number. Mirrors the promote handler's gate (and is version-first so iOS,
-- whose build number resets per marketing version, isn't wrongly marked superseded). Non-mobile
-- rows are left untouched (no flag → the FE keeps its own stage logic); an app with no synced
-- production is promotable by default.
injectPromotable :: Map.Map (Text, Text, Text) (Text, Maybe Int32) -> TrackerWithTarget -> TrackerWithTarget
injectPromotable prods pair@(tracker, mts) =
  case mts of
    Just (MobileBuildState _) ->
      let key = (NT.appGroup tracker, NT.service tracker, NT.env tracker)
          buildVer = NT.newVersion tracker
          bCode = NT.versionCode tracker
          promotable = case Map.lookup key prods of
            Just (pVer, mpCode) ->
              not (buildVer `versionOlderThan` pVer || (buildVer == pVer && codeAtOrBelow bCode mpCode))
            Nothing -> True -- no synced production → ahead by default
          rc' = case NT.releaseContext tracker of
            Just (Object o) -> Just (Object (KM.insert (K.fromText "promotable") (Bool promotable) o))
            other -> other
       in (tracker {releaseContext = rc'}, mts)
    _ -> pair
  where
    codeAtOrBelow (Just b) (Just p) = b <= p
    codeAtOrBelow _ _ = False

-- | §16 read model for the list: REVIEW comes from the ROW (the setPhase-owned
-- decision, immediate); rollout / % / track presence come from store_status (the
-- per-track live truth), matched by (version, code) with production-precedence.
-- A build not currently on any track is left as serialized — 'fromRow' already
-- derived its baseline from the row's own columns (terminal / SCC state).
-- Non-mobile rows are untouched.
injectStoreState :: Map.Map (Text, Text, Text) [StoreCell] -> TrackerWithTarget -> TrackerWithTarget
injectStoreState cellsByApp pair@(tracker, mts) =
  case mts of
    Just (MobileBuildState s) ->
      let key = (NT.appGroup tracker, NT.service tracker, NT.env tracker)
          cells = Map.findWithDefault [] key cellsByApp
       in case resolveStoreState cells (NT.newVersion tracker) (NT.versionCode tracker) of
            Nothing -> pair
            Just (rollout, pct, track) ->
              let ph = phaseFromFields (buildKind (mbContext s)) (mbWfStatus s) (NT.reviewStatus tracker) rollout pct track
                  disp = displayStatusInferred (reviewInferredOf (NT.metadata tracker)) ph
                  rc' =
                    fmap
                      (addMobileLifecycle (T.pack (show (mbWfStatus s))) rollout pct track (dLabel disp) (variantSlug (dVariant disp)) (phaseSlug ph) Nothing)
                      (NT.releaseContext tracker)
               in (tracker {releaseContext = rc'}, mts)
    _ -> pair

createReleaseH :: AuthedPerson -> Maybe Text -> Maybe Text -> K8sCreateReleaseReq -> Flow APIResponse
createReleaseH ap mXForwardedEmail mXPomeriumJwt req@K8sCreateReleaseReq {..} = do
  requireDeploymentPermission (Proxy :: Proxy 'AP_RELEASE_CREATE) ap appGroup
  -- System-triggered (cross-cluster sync) requests already carry the real
  -- release manager's email in the payload; only stamp the authenticated
  -- caller's email for direct, user-initiated creates.
  let stampedReq = req {createdBy = apEmail ap} :: K8sCreateReleaseReq
      req' = if fromMaybe False isSystemTriggered then req else stampedReq
  case globalId of
    Just gid | not (T.null gid) -> do
      existing <- findReleaseTrackerByGlobalId gid
      case existing of
        Just (existingTracker, _) -> do
          logInfo $ "Idempotent receive: tracker already exists for global_id=" <> gid
          pure $ APIResponse "SUCCESS" ("Tracker already exists: " <> NT.releaseId existingTracker)
        Nothing -> normalCreatePath req'
    _ -> normalCreatePath req'
  where
    normalCreatePath r = createReleaseHBody mXForwardedEmail mXPomeriumJwt r

createReleaseHBody :: Maybe Text -> Maybe Text -> K8sCreateReleaseReq -> Flow APIResponse
createReleaseHBody mXForwardedEmail mXPomeriumJwt K8sCreateReleaseReq {..} = do
  -- Julia parity (api/release/create.jl:95,237-255 validateUdf2):
  -- when envOverrideData (legacy `udf2`) carries a YAML/JSON env list,
  -- reject duplicate keys at create time so the workflow doesn't crash
  -- mid-flight with a kubectl error. Empty / Nothing is fine.
  case validateEnvOverrideData envOverrideData of
    Left err -> pure $ APIResponse "ERROR" ("envOverrideData validation failed: " <> err)
    Right () -> do
      -- Julia parity (api/release/create.jl:77,285-298 validateInfo):
      -- when info is provided AND the service has a custom service type
      -- (CUSTOM/CUSTOM_SERVICE), require the YAML/JSON to contain a
      -- `headers` block — otherwise the deployment template won't have
      -- the routing data it needs and will fail at apply time. For
      -- non-custom services, info is free-form.
      mServiceCfg <- findServiceByProductAndName appGroup service
      let svcType = mServiceCfg >>= S.dcServiceType
      case validateCustomServiceInfo svcType info of
        Left err -> pure $ APIResponse "ERROR" ("info validation failed: " <> err)
        Right () -> createReleaseHBodyContinue mXForwardedEmail mXPomeriumJwt K8sCreateReleaseReq {..}

-- | Refactored continuation so the validation guards above can short-circuit
-- without forcing the entire body into nested case-blocks.
createReleaseHBodyContinue :: Maybe Text -> Maybe Text -> K8sCreateReleaseReq -> Flow APIResponse
createReleaseHBodyContinue mXForwardedEmail mXPomeriumJwt K8sCreateReleaseReq {..} = do
  -- Same-service concurrency guard. Different services in the same app
  -- group can run in parallel (serialised at kubectl-replace via VS lock
  -- retry — see runVsRolloutWithLock). Same (appGroup, service) with any
  -- in-flight tracker is rejected unconditionally.
  mConflict <- findInFlightSameService appGroup service
  case mConflict of
    Just existing ->
      -- Distinguish VS edits from regular release trackers — both can
      -- block a new release on the same service, but the resolution is
      -- different (apply/discard the edit vs wait for the release).
      let cat = NT.category existing
          msg = case cat of
            VSEdit ->
              "Service "
                <> service
                <> " in app group "
                <> appGroup
                <> " has a pending VS edit "
                <> NT.releaseId existing
                <> " (status="
                <> T.pack (show (NT.status existing))
                <> "). Apply, force-unlock, or discard the VS edit before creating a release."
            _ ->
              "Service "
                <> service
                <> " in app group "
                <> appGroup
                <> " already has an in-flight release "
                <> NT.releaseId existing
                <> " (status="
                <> T.pack (show (NT.status existing))
                <> "). Wait for it to complete, abort, or discard."
       in pure $ APIResponse "ERROR" msg
    Nothing -> do
      -- Julia parity (api/release/create.jl:103,195-221
      -- validateGCLTAbortInPreviousTracker): block a new release if
      -- the previous release on the same (appGroup, service, env)
      -- ended in GCLT_ABORTED. The global changelog aborter has
      -- vetoed this service — operator must explicitly resolve the
      -- root cause and (manually or via tooling) clear the
      -- GCLT_ABORTED tracker before retrying. Without this guard
      -- a CI/CD loop can keep retrying a release that's been
      -- killed by an unrelated upstream incident, masking the
      -- GCLT signal.
      mGcltBlock <- findLastGcltAbortedTracker appGroup service env
      case mGcltBlock of
        Just blocker ->
          pure $
            APIResponse
              "ERROR"
              ( "Previous release "
                  <> NT.releaseId blocker
                  <> " for "
                  <> appGroup
                  <> "/"
                  <> service
                  <> " was GCLT_ABORTED. Resolve the root cause and "
                  <> "discard / restart the blocker tracker before creating a new release."
              )
        Nothing -> createReleaseHBodyAfterGuard mXForwardedEmail mXPomeriumJwt K8sCreateReleaseReq {..}

-- | Julia parity (api/release/create.jl:237-255 validateUdf2). The
-- @envOverrideData@ field (legacy name @udf2@) is a YAML/JSON list of
-- @{name, value}@ env-var entries that get patched into the deployment.
-- Reject duplicate env names at create time so the workflow doesn't crash
-- mid-flight with a kubectl error like "duplicate env name".
--
-- Accepts both YAML-list and JSON-array formats. Empty / Nothing is fine
-- (many releases don't override envs at all). Permissive on parse failure
-- — if the payload doesn't look like a structured env list, we let it
-- through and trust the workflow to handle it (Julia is the same).
validateEnvOverrideData :: Maybe Text -> Either Text ()
validateEnvOverrideData Nothing = Right ()
validateEnvOverrideData (Just t) | T.null (T.strip t) = Right ()
validateEnvOverrideData (Just t) =
  case A.eitherDecodeStrict (B.pack (T.unpack t)) :: Either String Value of
    Right (Array arr) ->
      let names = [n | Object o <- F.toList arr, Just (String n) <- [KM.lookup (K.fromText "name") o]]
          dups = findDuplicates names
       in if null dups
            then Right ()
            else Left ("Duplicate env name(s): " <> T.intercalate ", " dups)
    Right _ -> Right () -- Not a JSON array — let workflow decide
    Left _ -> Right () -- Not JSON at all — could be YAML; permissive
  where
    findDuplicates :: [Text] -> [Text]
    findDuplicates xs = go [] [] xs
      where
        go _ dups [] = reverse dups
        go seen dups (x : rest)
          | x `elem` seen && x `notElem` dups = go seen (x : dups) rest
          | otherwise = go (x : seen) dups rest

-- | Julia parity (api/release/create.jl:285-298 validateInfo). When the
-- service has a custom service type and the operator passed an @info@
-- payload, require the YAML/JSON to declare a @headers@ block — otherwise
-- the custom-service deployment template can't build the routing config
-- and will fail at apply time. Non-custom service types skip this check.
--
-- Accepts JSON-only for now (Haskell doesn't carry a YAML decoder in this
-- module — production cutover doesn't use YAML for info per CONTEXT.md).
validateCustomServiceInfo :: Maybe Text -> Maybe Text -> Either Text ()
validateCustomServiceInfo svcType mInfo
  | not (isCustomServiceType svcType) = Right ()
  | otherwise = case mInfo of
      Nothing -> Left "Custom service type requires `info` with a `headers` block"
      Just t | T.null (T.strip t) -> Left "Custom service type requires `info` with a `headers` block"
      Just t ->
        case A.eitherDecodeStrict (B.pack (T.unpack t)) :: Either String Value of
          Right (Object o) ->
            case KM.lookup (K.fromText "headers") o of
              Just (Object _) -> Right ()
              Just (Array _) -> Right ()
              _ -> Left "Custom service type `info` must declare a non-empty `headers` block"
          Right (Array arr) ->
            -- Julia tolerates a list of dicts; succeed if any element has headers.
            let elemHasHeaders v = case v of
                  Object o -> case KM.lookup (K.fromText "headers") o of
                    Just _ -> True
                    Nothing -> False
                  _ -> False
                hasHeaders = any elemHasHeaders (F.toList arr)
             in if hasHeaders then Right () else Left "Custom service type `info` list must contain a `headers` block"
          _ -> Left "Custom service type `info` must be valid JSON with a `headers` block"
  where
    isCustomServiceType :: Maybe Text -> Bool
    isCustomServiceType (Just s) = T.toUpper s `elem` ["CUSTOM", "CUSTOM_SERVICE"]
    isCustomServiceType Nothing = False

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

-- | Insert a release tracker, translating partial-unique-index violations
-- into the same friendly responses the application-level checks would have
-- returned. Two indexes can fire here:
--
-- 1. uq_release_tracker_service_inflight (same-service in-flight guard) →
--   HTTP 409 Conflict, same shape the in-Haskell `findInFlightSameService`
--   path returns when it sees a duplicate.
--
-- 2. uq_release_tracker_global_id (cross-cloud sync idempotency guard) →
--   re-fetch the existing tracker by globalId and behave as if the original
--   `findReleaseTrackerByGlobalId` short-circuit had won the race. This
--   makes 10 parallel POSTs with the same global_id all succeed cleanly
--   (1 inserts, 9 see "already exists") instead of 9 leaking raw SQL 23505.
--
-- Returns Just the existing tracker's id when the global_id idempotent path
-- fired (so the caller can return the same SUCCESS message). Returns Nothing
-- when a fresh insert succeeded.
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
createReleaseHBodyAfterGuard mXForwardedEmail mXPomeriumJwt K8sCreateReleaseReq {..} = do
  -- G2 (Julia parity): reject malformed rollout strategies at create time
  -- so operators get a friendly 4xx instead of a workflow that explodes
  -- mid-rollout. validateStrategyShape enforces non-empty, monotonic
  -- percents in [0,100], non-negative cooloffs, and a terminal 100% stage.
  case validateStrategyShape rolloutStrategy of
    Left errMsg -> pure $ APIResponse "ERROR" ("Invalid rollout strategy: " <> errMsg)
    Right () -> createReleaseHBodyAfterStrategyCheck mXForwardedEmail mXPomeriumJwt K8sCreateReleaseReq {..}

createReleaseHBodyAfterStrategyCheck :: Maybe Text -> Maybe Text -> K8sCreateReleaseReq -> Flow APIResponse
createReleaseHBodyAfterStrategyCheck mXForwardedEmail mXPomeriumJwt K8sCreateReleaseReq {..} = do
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
                            claimed <- claimServiceForModification appGroup service
                            if not claimed
                              then pure $ APIResponse "ERROR" ("Service " <> service <> " in app group " <> appGroup <> " is already being modified (service_state guard). Try again shortly.")
                              else createReleaseHBodyAfterClaim mXForwardedEmail mXPomeriumJwt K8sCreateReleaseReq {..} pCfg sCfg

createReleaseHBodyAfterClaim ::
  Maybe Text ->
  Maybe Text ->
  K8sCreateReleaseReq ->
  S.DeploymentConfig ->
  S.DeploymentConfig ->
  Flow APIResponse
createReleaseHBodyAfterClaim mXForwardedEmail mXPomeriumJwt K8sCreateReleaseReq {..} pCfg sCfg = do
  cfg <- getConfig
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
          then case trackerType of
            BackendScheduler -> do
              -- Schedulers have no VS — discover from deployment labels
              -- (pick the version with the most ready replicas).
              discovered <- liftIO $ getRunningSchedulerVersion cfg (getProductNamespace pCfg) targetSvcHost
              pure $ case discovered of
                Right (Just ver) -> ver
                _ -> oldVersion
            _ -> do
              discovered <- liftIO $ getPrimarySubsetFromVirtualService cfg (getProductNamespace pCfg) (getProductVsName pCfg) targetSvcHost
              pure $ case discovered of
                Right (Just subset) -> subset
                _ -> oldVersion
          else pure oldVersion
  -- Changelog is always a generated GitHub diff link. Single-service creates
  -- build the link on the frontend and send it; multi-service creates (and any
  -- client that sends nothing) get it built here from the just-resolved old
  -- version. The keep-if-present guard only avoids rebuilding a link the
  -- frontend or a cross-cluster sync already produced — no case carries a
  -- handwritten changelog. Degrades to a /commits/<new> link when the old
  -- version couldn't be resolved, and to no link when the app group has no
  -- repo_name configured.
  let requestChangeLog = case changeLog of
        Just cl | not (T.null (T.strip cl)) -> Just cl
        _ -> Nothing
      resolvedChangeLog = requestChangeLog <|> buildDiffLink (S.dcRepoName pCfg) resolvedOldVersion newVersion
  case (requestChangeLog, resolvedChangeLog) of
    (Nothing, Just link) -> logInfo $ "[createReleaseH] generated changelog diff link: " <> link
    _ -> pure ()
  let derivedContext =
        K8sReleaseContext
          { cluster = getProductCluster pCfg,
            namespace = getProductNamespace pCfg,
            deploymentName = targetSvcHost <> "-" <> newVersion,
            serviceName = targetSvcHost,
            destinationRuleName = targetSvcHost <> "-destinations",
            virtualServiceName = getProductVsName pCfg,
            internalVirtualServiceName = metadataInternalVsName,
            containerName = targetSvcHost,
            oldVersion = resolvedOldVersion,
            newVersion = newVersion,
            dockerImage = metadataDockerImage,
            matches = [],
            podsScaleDownDelay = Nothing,
            podsScaleDownTimestamp = Nothing,
            podsScaleDownStatus = Nothing,
            oldVersionPodCount = Nothing,
            revert = Nothing,
            abRunId = Nothing,
            abStatus = Nothing,
            cleanupAt = Nothing,
            cleanupTargetDeployment = Nothing,
            cleanupStatus = Nothing,
            cleanupAttempts = 0,
            deployFilePath = deployFilePath,
            serviceFilePath = serviceFilePath,
            drFilePath = drFilePath,
            vsFilePath = vsFilePath,
            prevAbHsDecision = Nothing,
            postMonitoringDecisionMap = Nothing,
            syncClusterEnvOverrideData = syncClusterEnvOverrideData,
            syncClusterRolloutStrategy = fmap (\v -> T.pack (LBS.unpack (A.encode v))) syncClusterRolloutStrategy,
            syncXForwardedEmail = mXForwardedEmail,
            syncXPomeriumJwt = mXPomeriumJwt,
            changelogSlackOptIn = postChangelogSlack
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
          { releaseId = rid,
            appGroup = appGroup,
            service = service,
            env = env,
            category = trackerType,
            status = CREATED,
            releaseWFStatus = INIT,
            mode = reqMode,
            createdBy = createdBy,
            approvedBy = approvedBy,
            isApproved = initialApproval,
            isInfraApproved = fromMaybe (fromMaybe False (S.dcNeedInfraApproval pCfg >>= \need -> if need then Just False else Just True)) isInfraApproved,
            releaseTag = autoTag,
            dateCreated = Nothing, -- DB sets via DEFAULT now()
            lastUpdated = Nothing, -- DB sets via DEFAULT now()
            scheduleTime = scheduleTime,
            startTime = Nothing,
            endTime = Nothing,
            rolloutStrategy = rolloutStrategy,
            rolloutHistory = [],
            oldVersion = resolvedOldVersion,
            newVersion = newVersion,
            versionCode = Nothing,
            reviewStatus = Nothing,
            info = info,
            description = description,
            changeLog = resolvedChangeLog,
            metadata = metadata,
            priority = fromMaybe 0 priority,
            globalId = globalId,
            syncEnabled =
              if isFromSync
                then Nothing
                else case isReleaseSync of
                  Just True -> Just "true"
                  _ -> syncEnabled,
            envOverrideData = envOverrideData,
            slackThreadTs = slackThreadTs,
            -- Seed from 'derivedContext' below so the tracker's public view
            -- matches the 'K8sState' target state we're about to persist.
            -- Without this field the record is partial and any access to
            -- 'releaseContext' crashes at runtime with "Missing field in
            -- record construction" (caught by -Wmissing-fields).
            releaseContext = Just (toJSON derivedContext),
            -- Mobile/revert-only fields — not applicable to a freshly
            -- created backend (k8s) release. Must be set explicitly or the
            -- record is partial and crashes at runtime when forced.
            sourceRef = Nothing,
            commitSha = Nothing,
            revertsReleaseId = Nothing,
            abValidationStatus = Nothing,
            abValidation = Nothing
          }
      targetState =
        K8sState $
          emptyK8sState
            { context = derivedContext,
              newService = fromMaybe False newService,
              cronjobSuspend = fromMaybe False cronjobSuspend
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
      -- Capture PREVIEW snapshots at creation time so the diff
      -- is available immediately (before the workflow runs).
      -- Labels use the @_PREVIEW@ suffix to distinguish them
      -- from the workflow-time ground-truth snapshots, which
      -- use the plain @DEPLOYMENT_BEFORE/AFTER@ labels. Without
      -- this split, the event log showed TWO pairs of
      -- identically-labeled snapshots per release (create-time
      -- preview + workflow ground-truth). The diff endpoint
      -- prefers the workflow labels and falls back to
      -- @_PREVIEW@ if they haven't been written yet.
      let ns = getProductNamespace pCfg
          oldDepName = targetSvcHost <> "-" <> resolvedOldVersion
      captureDeploymentSnapshot cfg rid ns oldDepName "DEPLOYMENT_BEFORE_PREVIEW"
      captureDeploymentPreview
        cfg
        rid
        ns
        oldDepName
        newVersion
        (fromMaybe "" metadataDockerImage)
        envOverrideData
        "DEPLOYMENT_AFTER_PREVIEW"
      notifyReleaseCreated tracker
      pure $ APIResponse "SUCCESS" ("Tracker created: " <> rid)

getReleaseH :: AuthedPerson -> Text -> Flow (Maybe ReleaseTracker)
getReleaseH _ap rid = do
  m <- findReleaseTracker rid
  pure (fmap fst m)

approveReleaseH :: AuthedPerson -> Text -> ApproveReleaseReq -> Flow (Maybe ReleaseTracker)
approveReleaseH ap rid req = do
  m <- findReleaseTracker rid
  case m of
    Nothing -> throwM $ NotFound ("Release not found: " <> rid)
    Just (tracker, mTargetState) -> do
      requireDeploymentPermission (Proxy :: Proxy 'AP_RELEASE_APPROVE) ap (NT.appGroup tracker)
      -- Pre-check (cheap, friendly errors)
      if NT.status tracker /= CREATED
        then throwM $ BadRequest ("Cannot approve release in status " <> T.pack (show (NT.status tracker)) <> ". Only CREATED releases can be approved.")
        else
          if NT.isApproved tracker
            then throwM $ BadRequest ("Release already approved by " <> fromMaybe "unknown" (NT.approvedBy tracker) <> ". Cannot approve again.")
            else do
              let approver = req.approvedBy
                  infraApproval = req.isInfraApproved
                  updated =
                    (tracker :: ReleaseTracker)
                      { NT.approvedBy = Just approver,
                        NT.isApproved = True,
                        NT.isInfraApproved = fromMaybe (NT.isInfraApproved tracker) infraApproval
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
triggerReleaseH ap rid TriggerReleaseReq {..} = do
  m <- findReleaseTracker rid
  case m of
    Nothing -> pure $ APIResponse "ERROR" "Release not found"
    Just (tracker, mTargetState) -> do
      requireDeploymentPermission (Proxy :: Proxy 'AP_RELEASE_CREATE) ap (NT.appGroup tracker)
      let oldStatus = NT.status tracker
      if isTerminalStatus oldStatus
        then pure $ APIResponse "ERROR" ("Cannot trigger from terminal status: " <> T.pack (show oldStatus))
        else do
          now <- liftIO getCurrentTime
          let updated = (tracker :: ReleaseTracker) {NT.scheduleTime = Just now, NT.status = CREATED}
          ok <- conditionalUpdateTracker updated mTargetState (releaseStatusToText oldStatus)
          if ok
            then do
              insertReleaseEvent rid "BUSINESS" "TRACKER_TRIGGERED" (toJSON reason)
              pure $ APIResponse "SUCCESS" "Release scheduled for execution"
            else pure staleTrackerError

rollbackReleaseH :: AuthedPerson -> Text -> TriggerReleaseReq -> Flow APIResponse
rollbackReleaseH ap rid TriggerReleaseReq {..} = do
  m <- findReleaseTracker rid
  case m of
    Nothing -> pure $ APIResponse "ERROR" "Release not found"
    Just (tracker, mTargetState) -> do
      requireDeploymentPermission (Proxy :: Proxy 'AP_RELEASE_REVERT) ap (NT.appGroup tracker)
      let oldStatus = NT.status tracker
      if not (validateStatusTransition oldStatus ABORTING)
        then pure $ APIResponse "ERROR" ("Cannot rollback from status: " <> T.pack (show oldStatus))
        else do
          let updated = (tracker :: ReleaseTracker) {NT.status = ABORTING, NT.releaseWFStatus = ROLLING_BACK}
          ok <- conditionalUpdateTracker updated mTargetState (releaseStatusToText oldStatus)
          if ok
            then do
              insertReleaseEvent rid "BUSINESS" "ROLLBACK_REQUESTED" (toJSON reason)
              pure $ APIResponse "SUCCESS" "Rollback marked"
            else pure staleTrackerError

revertReleaseH :: AuthedPerson -> Text -> RevertReleaseReq -> Flow APIResponse
revertReleaseH ap rid req = do
  cfg <- getConfig
  m <- findReleaseTracker rid
  case m of
    Nothing -> pure $ APIResponse "ERROR" "Release not found"
    Just (tracker, mTargetState) -> do
      requireDeploymentPermission (Proxy :: Proxy 'AP_RELEASE_REVERT) ap (NT.appGroup tracker)
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
                  { deploymentName = ctxServiceName <> "-" <> ctxOldVersion,
                    oldVersion = ctxNewVersion,
                    newVersion = ctxOldVersion,
                    abRunId = Nothing,
                    abStatus = Nothing,
                    cleanupAt = Nothing,
                    cleanupTargetDeployment = Nothing,
                    cleanupStatus = Nothing,
                    podsScaleDownDelay = Nothing,
                    podsScaleDownTimestamp = Nothing,
                    podsScaleDownStatus = Nothing,
                    revert = Just 1,
                    prevAbHsDecision = Nothing,
                    postMonitoringDecisionMap = Nothing,
                    -- A revert restores the deployment to whatever it
                    -- already looks like in k8s. Carrying forward the
                    -- original release's dockerImage would re-apply
                    -- that image to the old deployment and produce a
                    -- misleading diff (showing a fake image change).
                    -- Clear it so the workflow leaves the existing
                    -- deployment's image alone.
                    K8s.dockerImage = Nothing
                  }
              revertedTargetState = K8sState $ emptyK8sState {context = revertedContext}
              revertedTracker =
                (tracker :: ReleaseTracker)
                  { NT.releaseId = newRid,
                    NT.status = CREATED,
                    NT.releaseWFStatus = INIT,
                    NT.createdBy = fromMaybe trackerCreatedBy ((req :: RevertReleaseReq).requestedBy),
                    NT.approvedBy = if isImmediate then Just (fromMaybe trackerCreatedBy ((req :: RevertReleaseReq).requestedBy)) else Nothing,
                    NT.isApproved = isImmediate,
                    -- Bug fix: refresh dateCreated/lastUpdated. The revert
                    -- tracker is a record copy of the original, so without
                    -- this override every revert inherits the ORIGINAL
                    -- release's dateCreated, making the audit log lie
                    -- about when the revert was actually issued.
                    NT.dateCreated = Just now,
                    NT.lastUpdated = Just now,
                    -- Bug fix: clear envOverrideData on revert. A revert
                    -- semantically means "undo the change", and the env
                    -- switch is part of the change. If we kept the
                    -- original's envOverrideData here, the revert workflow
                    -- would re-apply those overridden envs to the clone,
                    -- defeating the point of reverting. Clearing it lets
                    -- the clone preserve the source deployment's envs.
                    NT.envOverrideData = Nothing,
                    NT.scheduleTime = Just now,
                    NT.startTime = Nothing,
                    NT.endTime = Nothing,
                    NT.rolloutHistory = [],
                    NT.releaseTag = fmap (<> "_REVERT") (NT.releaseTag tracker),
                    NT.info = (req :: RevertReleaseReq).info,
                    NT.syncEnabled = if shouldSyncRevert then Just "true" else Nothing,
                    -- Bug fix: swap oldVersion/newVersion on the domain record so that
                    -- Runner.validateRunningVersion (which compares NT.oldVersion against
                    -- the live VS subset) will match. Without this swap the runner
                    -- always sees the current VS at the original newVersion and
                    -- discards the revert tracker with VERSION_MISMATCH.
                    NT.oldVersion = NT.newVersion tracker,
                    NT.newVersion = NT.oldVersion tracker,
                    -- Bug fix (round 5): clear globalId on the revert tracker. The
                    -- partial unique index uq_release_tracker_global_id forbids two
                    -- rows with the same global_id; without this reset, every revert
                    -- of a release that ever had a global_id (i.e. every cross-cloud
                    -- replicated release) hit a raw SQL 23505 violation.
                    NT.globalId = Nothing
                  }
          -- Round 8 audit C5: use insertReleaseTrackerSafe so the
          -- partial unique index uq_release_tracker_service_inflight
          -- catches a parallel revert call (or any other in-flight
          -- writer) and translates the SQL 23505 to a friendly
          -- Conflict, instead of leaving two revert trackers for the
          -- same (app_group, service) pair.
          _idem <- insertReleaseTrackerSafe revertedTracker revertedTargetState
          insertReleaseEvent
            newRid
            "BUSINESS"
            "REVERT_TRACKER_CREATED"
            ( object
                [ "originalId" .= rid,
                  "shouldSyncRevert" .= shouldSyncRevert,
                  "isImmediate" .= isImmediate,
                  "origSyncEnabled" .= (origSyncEnabled :: Bool)
                ]
            )
          -- Capture BEFORE/AFTER snapshots for the revert release.
          -- BEFORE = the CURRENT live state (the new deployment from
          -- the original release, which we're reverting away from).
          -- AFTER  = the TARGET deployment the revert will restore
          -- (the original's oldVersion, which typically still exists
          -- on the cluster at 0 replicas). Sourcing the preview from
          -- the target gives the user a correct diff showing what
          -- will happen — including any env removal, because the
          -- target deployment's env spec is what the user is
          -- reverting TO.
          let revertNs = (\(K8sReleaseContext {namespace = n}) -> n) oldCtx
              revertNewDep = ctxServiceName <> "-" <> NT.newVersion tracker
              revertTargetDep = ctxServiceName <> "-" <> NT.oldVersion tracker
          -- Create-time preview snapshots (see createReleaseH for
          -- the rationale behind the @_PREVIEW@ suffix).
          captureDeploymentSnapshot cfg newRid revertNs revertNewDep "DEPLOYMENT_BEFORE_PREVIEW"
          captureDeploymentPreview
            cfg
            newRid
            revertNs
            revertTargetDep
            (NT.oldVersion tracker)
            -- Revert never patches the image; the workflow just clones
            -- the target deployment as-is. Passing the original
            -- release's image here would synthesise a fake image
            -- change in the preview diff (matches the runtime fix to
            -- 'revertedContext.dockerImage = Nothing').
            ""
            Nothing -- revert tracker clears envOverrideData (see buildRevertedTracker)
            "DEPLOYMENT_AFTER_PREVIEW"
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
discardReleaseH ap rid DiscardReleaseReq {..} = do
  m <- findReleaseTracker rid
  case m of
    Nothing -> pure $ APIResponse "ERROR" "Release not found"
    Just (tracker, mTargetState) -> do
      requireDeploymentPermission (Proxy :: Proxy 'AP_RELEASE_DISCARD) ap (NT.appGroup tracker)
      let oldStatus = NT.status tracker
      if not (validateStatusTransition oldStatus DISCARDED)
        then pure $ APIResponse "ERROR" ("Cannot discard from status: " <> T.pack (show oldStatus))
        else do
          let updated = (tracker :: ReleaseTracker) {NT.status = DISCARDED}
          ok <- conditionalUpdateTracker updated mTargetState (releaseStatusToText oldStatus)
          if ok
            then do
              -- Production parity: NOTIFICATION / STATUS_UPDATED
              logStatusUpdated updated ("Tracker marked as DISCARDED" <> maybe "" (": " <>) reason)
              notifyReleaseDiscarded updated
              releaseService (NT.appGroup updated) (NT.service updated)
              pure $ APIResponse "SUCCESS" "Release discarded"
            else pure staleTrackerError

deleteReleaseH :: AuthedPerson -> Text -> Flow APIResponse
deleteReleaseH ap rid = do
  db <- getDBEnv
  mTracker <- findReleaseTracker rid
  case mTracker of
    Nothing -> pure $ APIResponse "ERROR" "Release not found"
    Just (tracker, _) -> do
      requireDeploymentPermission (Proxy :: Proxy 'AP_RELEASE_DELETE) ap (NT.appGroup tracker)
      -- Block deletion of active releases (INPROGRESS, ABORTING, REVERTING, PAUSED, RESTARTING)
      let activeStatuses = [INPROGRESS, ABORTING, REVERTING, PAUSED, RESTARTING]
      if NT.status tracker `elem` activeStatuses
        then pure $ APIResponse "ERROR" ("Cannot delete release in " <> T.pack (show (NT.status tracker)) <> " status. Abort or complete it first.")
        else do
          _ <- liftIO $ withConn db $ \conn -> withTransaction conn $ do
            _ <- execute conn "DELETE FROM release_events WHERE re_release_id = ?" (Only rid)
            execute conn "DELETE FROM release_tracker WHERE id = ?" (Only rid)
          releaseService (NT.appGroup tracker) (NT.service tracker)
          pure $ APIResponse "SUCCESS" ("Release deleted: " <> rid)

updateTrackerH :: AuthedPerson -> Text -> K8sUpdateTrackerReq -> Flow APIResponse
updateTrackerH ap rid req = do
  m <- findReleaseTracker rid
  case m of
    Nothing -> pure $ APIResponse "ERROR" "Release not found"
    Just (tracker, mTargetState) -> do
      requireDeploymentPermission (Proxy :: Proxy 'AP_RELEASE_UPDATE) ap (NT.appGroup tracker)
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
                            void $
                              forkFlow $ do
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

-- | Validate an incoming 'K8sUpdateTrackerReq' against two independent sets
-- of rules, returning @Left reason@ on the first failure.
--
-- 1. __Rollout strategy invariants__ (apply at /every/ status): whenever the
-- request supplies a new @rolloutStrategy@, it must be non-empty, use only
-- valid cooloff/pod/percent values, have strictly-monotonic @rolloutPercent@
-- values, and end at 100. These are cheap shape checks that catch obviously
-- broken payloads before they hit the DB or the workflow loop.
--
-- 2. __Mid-flight immutability__ (apply to @INPROGRESS@ / @PAUSED@ /
-- @RESTARTING@ / @REVERTING@): while a release is live the fields a user
-- may touch are @status@ (pause/resume/abort transitions),
-- @rolloutStrategy@ (limited to future-stage edits — stages that already
-- appear in @rolloutHistory@ must be byte-identical), @mode@ (AUTO ↔
-- MANUAL flip for pausing/resuming auto-advance), and @changeLog@
-- (informational append). Everything else — including @envOverrideData@,
-- @dockerImage@, approvals, priority, description — is rejected because
-- it would race the running workflow, change release identity, or mutate
-- pods that have already rolled out. Recommended UX: pause the release,
-- edit mode or remaining stages, then resume.
--
-- The separation matters: #1 runs even at @CREATED@ (catches bad initial
-- strategies); #2 only runs once the rollout is live, so @CREATED@ releases
-- can still be edited freely.
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
              <> ". Abort and create a new release to change this field."
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

-- | Shape-level invariants on a proposed rollout strategy: non-empty, valid
-- numeric ranges, strictly monotonic rolloutPercent, and a terminal 100 stage.
-- Runs before any state-dependent checks.
validateStrategyShape :: [RolloutStep] -> Either Text ()
validateStrategyShape [] = Left "Rollout strategy must have at least one stage"
validateStrategyShape steps = do
  let percents = map rolloutPercent steps
      cooloffs = map cooloffMinutes steps
      pods = map podCount steps
  when (any (\p -> p < 0 || p > 100) percents) $
    Left "Rollout percents must be in the range [0, 100]"
  -- podCount is a raw pod count (NOT a percentage). Bug fix from the
  -- 0011 rename: previous code clamped to [0, 100] under the mistaken
  -- belief it was a percentage, which silently rejected valid pod
  -- counts > 100. The HPA cap (live max) protects against overscaling
  -- at runtime, so we only enforce non-negative here.
  when (any (< 0) pods) $
    Left "Pod count must be non-negative"
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

-- | Identify the first mid-flight-forbidden field set in the request, if any.
-- During INPROGRESS/PAUSED/etc only @status@, @rolloutStrategy@, @mode@, and
-- @changeLog@ are legal. Everything else (including @envOverrideData@ and
-- @dockerImage@) is rejected — changing those mid-rollout would race the
-- running pods or change release identity. Returns @Just fieldName@ for the
-- first violation.
forbiddenFieldDuringMidFlight :: K8sUpdateTrackerReq -> Maybe Text
forbiddenFieldDuringMidFlight req
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
        "MANUAL" -> t {NT.mode = MANUAL}
        "AUTO" -> t {NT.mode = AUTO}
        _ -> t
      updatedTracker =
        applyMaybe req.status (\s t -> (t :: ReleaseTracker) {NT.status = parseReleaseStatus s}) $
          applyMaybe req.mode setMode $
            applyMaybe req.releaseManager (\rm t -> t {NT.createdBy = rm}) $
              applyMaybe req.priority (\p t -> t {NT.priority = p}) $
                applyMaybe req.scheduleTime (\st t -> t {NT.scheduleTime = Just st}) $
                  applyMaybe req.description (\d t -> t {NT.description = Just d}) $
                    applyMaybe req.info (\i t -> t {NT.info = Just i}) $
                      applyMaybe req.rolloutStrategy (\rs t -> t {NT.rolloutStrategy = rs}) $
                        applyMaybe req.changeLog (\cl t -> t {NT.changeLog = Just cl}) $
                          applyMaybe req.isApproved (\a t -> t {NT.isApproved = a}) $
                            applyMaybe req.isInfraApproved (\a t -> t {NT.isInfraApproved = a}) $
                              applyMaybe req.syncEnabled (\u t -> t {NT.syncEnabled = Just u}) $
                                applyMaybe req.envOverrideData (\u t -> t {NT.envOverrideData = Just u}) $
                                  applyMaybe req.slackThreadTs (\u t -> t {NT.slackThreadTs = Just u}) tracker
      updatedTargetState =
        applyMaybe req.dockerImage (\img s -> updateK8sContext s (\ctx -> ctx {K8s.dockerImage = Just img})) $
          applyMaybe req.podsScaleDownDelay (\d s -> updateK8sContext s (\ctx -> ctx {K8s.podsScaleDownDelay = Just d})) mts
   in (updatedTracker, updatedTargetState)

updateK8sContext :: Maybe TargetState -> (K8sReleaseContext -> K8sReleaseContext) -> Maybe TargetState
updateK8sContext (Just (K8sState k8s)) f = Just $ K8sState $ k8s {context = f (context k8s)}
updateK8sContext other _ = other

listEventsH :: AuthedPerson -> Text -> Flow [ReleaseEventResponse]
listEventsH _ap rid = do
  events <- listReleaseEvents rid
  pure $
    fmap
      ( \e ->
          ReleaseEventResponse
            { reCategory = S.reCategory e,
              reLabel = S.reLabel e,
              reData = S.rePayload e,
              reTimestamp = S.reCreatedAt e
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

-- | Post-monitoring webhook receiver. Julia parity
-- (release/workflow/webhook.jl + api/decision/webhook.jl).
--
-- The external AB engine POSTs the post-100% verdict here using the
-- @runId@ as the auth token (no separate header — we trust whoever knows
-- the run_id). Run id is @<releaseId>-post@ for post-monitoring runs.
--
-- On Abort: emit a POST_MONITORING_RESULT event with action=alert_only,
-- fire a Slack alert, but do NOT auto-rollback (intentional divergence
-- from Julia, see notifyComplete in BackendServiceWorkflow.hs:1495-1521).
--
-- UNAUTHENTICATED endpoint by design — the webhook caller is the AB
-- engine, not a user. The run_id format is the auth token.
decisionWebhookH :: Text -> Value -> Flow APIResponse
decisionWebhookH runId body = do
  -- Strip the "-post" suffix to recover the original release id.
  let releaseRid =
        if "-post" `T.isSuffixOf` runId
          then T.dropEnd 5 runId
          else runId
  m <- findReleaseTracker releaseRid
  case m of
    Nothing -> do
      logErrorG $ "[WEBHOOK] Unknown run_id: " <> runId
      pure $ APIResponse "ERROR" ("Unknown run_id: " <> runId)
    Just (tracker, _) -> do
      let decisionStr = case body of
            Object o -> case KM.lookup (K.fromText "decision") o of
              Just (String s) -> T.toUpper s
              Just (Number n) -> case toBoundedInteger n :: Maybe Int of
                Just 0 -> "CONTINUE"
                Just 1 -> "ABORT"
                Just 2 -> "WAIT"
                _ -> "UNKNOWN"
              _ -> "UNKNOWN"
            _ -> "UNKNOWN"
          reasonText = case body of
            Object o -> case KM.lookup (K.fromText "reason") o of
              Just (String r) -> r
              _ -> ""
            _ -> ""
      insertReleaseEvent
        releaseRid
        "DECISION_ENGINE"
        "POST_MONITORING_WEBHOOK"
        ( object
            [ "runId" .= runId,
              "decision" .= decisionStr,
              "reason" .= reasonText,
              "action" .= ("alert_only_no_rollback" :: Text)
            ]
        )
      when (decisionStr == "ABORT") $ do
        logErrorG $
          "[WEBHOOK] POST-MONITORING ABORT received for "
            <> releaseRid
            <> " — alerting (NOT auto-rolling back, traffic stays at 100%)"
        _ <-
          notifyDecisionThreadMessage
            tracker
            "POSTMONITORING_WEBHOOK"
            decisionStr
            (if T.null reasonText then Nothing else Just reasonText)
            ( "🚨 POST-MONITORING ABORT (webhook, NOT auto-reverted — traffic at 100%): "
                <> (if T.null reasonText then "no reason" else reasonText)
                <> " — operator must decide whether to revert manually."
            )
        pure ()
      pure $ APIResponse "SUCCESS" ("Webhook received for " <> runId)

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
      -- Check for stored SNAPSHOT events first. For K8s deployments we
      -- look for workflow-time labels first (DEPLOYMENT_BEFORE / AFTER,
      -- written during prepare + finalize stages) and fall back to
      -- create-time preview labels (DEPLOYMENT_BEFORE_PREVIEW /
      -- AFTER_PREVIEW, written by createReleaseH/revertReleaseH/
      -- restartReleaseH). This gives the user an immediate diff when
      -- the release is first created, and automatically upgrades to
      -- the ground-truth workflow diff once the workflow runs.
      snapshotEvents <- listReleaseEventsByCategory rid "SNAPSHOT"
      let trackerCat = NT.category tracker
          diffLabel = case trackerCat of
            BackendConfig -> "ConfigMap diff"
            VSEdit -> "VS diff"
            _ -> "Deployment diff"
          -- Ordered candidate labels: first = preferred (ground-truth
          -- workflow snapshot), fall-through = preview (create-time).
          (beforeLabels, afterLabels) = case trackerCat of
            BackendConfig -> (["CONFIGMAP_BEFORE"], ["CONFIGMAP_AFTER"])
            VSEdit -> (["VS_OLD"], ["VS_NEW"])
            _ -> (["DEPLOYMENT_BEFORE", "DEPLOYMENT_BEFORE_PREVIEW"], ["DEPLOYMENT_AFTER", "DEPLOYMENT_AFTER_PREVIEW"])
          findSnapshot labels = listToMaybe [e | lbl <- labels, e <- snapshotEvents, S.reLabel e == lbl]
          mBefore = findSnapshot beforeLabels
          mAfter = findSnapshot afterLabels
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

-- | Immediate revert — exact Julia parity (api/revert/immediate_revert.jl).
--
-- Validation:
--  * status MUST be COMPLETED (Julia rejects everything else, including INPROGRESS)
--  * old-version deployment MUST exist in k8s
--  * its image MUST be readable
--
-- Action (4 kubectl calls, NO tracker DB writes):
--  1. kubectl get deployment <old> -o jsonpath=...image    — read live image
--  2. kubectl set image deployment/<new> <container>=<image> — patch in place
--  3. kubectl rollout restart deployment/<new>             — bounce pods
--  4. (optional) trigger sync to secondary cluster if isRevertSync && udf1=true
--
-- What this deliberately does NOT do (matching Julia):
--  * No VirtualService changes — VS already points at <new>; old may be at 0 pods.
--  * No new tracker created.
--  * No mutation of the original tracker's status — it stays COMPLETED. Julia's
--    rationale: immediate revert is a k8s-level patch, not a release flow, so
--    the tracker history should not be rewritten. Operators see the in-place
--    image swap via the IMMEDIATE_REVERT audit event on the same tracker.
immediateRevertH :: AuthedPerson -> Text -> ImmediateRevertReq -> Flow APIResponse
immediateRevertH ap rid req@ImmediateRevertReq {isRevertSync = mIsRevertSync} = do
  cfg <- getConfig
  m <- findReleaseTracker rid
  case m of
    Nothing -> pure $ APIResponse "ERROR" "Release not found"
    Just (tracker, mTargetState) -> do
      requireDeploymentPermission (Proxy :: Proxy 'AP_RELEASE_REVERT) ap (NT.appGroup tracker)
      let hasEnvChange = maybe False (not . T.null) (NT.envOverrideData tracker)
          currentStatus = NT.status tracker
      -- Block immediate revert when the release carried env changes.
      -- Immediate revert is an in-place image swap on the NEW deployment; it
      -- cannot reliably reconstruct the OLD deployment's env vars once the
      -- old deployment has been scaled down or deleted. Normal revert
      -- (POST /releases/{id}/revert) creates a fresh revert release that
      -- restores env + image together through the full workflow.
      if hasEnvChange
        then
          pure $
            APIResponse
              "ERROR"
              "Immediate revert is not allowed on releases with env changes. Use normal revert (POST /releases/{id}/revert) — it restores env and image together via the full revert workflow."
        else -- Julia parity: COMPLETED only. INPROGRESS is rejected because
        -- in-place image-swapping a release that's still rolling out
        -- would race the workflow's stage progression.
          if currentStatus /= COMPLETED
            then pure $ APIResponse "ERROR" ("Immediate revert requires status=COMPLETED (current: " <> T.pack (show currentStatus) <> ")")
            else case mTargetState of
              Just (K8sState k8s) -> do
                let ctx = context k8s
                    K8s.K8sReleaseContext {K8s.namespace = ns} = ctx
                    nsQ = shellQuote ns
                    newDepName = deploymentName ctx
                    depQ = shellQuote newDepName
                    cName = (K8s.containerName :: K8sReleaseContext -> Text) ctx
                    cNameQ = shellQuote cName
                    oldDepName = (K8s.serviceName :: K8sReleaseContext -> Text) ctx <> "-" <> NT.oldVersion tracker
                    oldDepQ = shellQuote oldDepName
                -- Step 1 (Julia parity): read the OLD deployment's container image LIVE
                -- via kubectl get. Don't trust the tracker's stored dockerImage field;
                -- the tracker may be stale and the fallback to oldVersion (a label) is
                -- not a valid image string.
                let getImageCmd =
                      unwords
                        [ kubectlBin cfg,
                          "-n",
                          nsQ,
                          "get deployment",
                          oldDepQ,
                          "-o",
                          "jsonpath='{.spec.template.spec.containers[?(@.name==\"" <> T.unpack cName <> "\")].image}'"
                        ]
                getResult <- liftIO $ runCmd getImageCmd
                case getResult of
                  Left (K8sError err) ->
                    pure $
                      APIResponse
                        "ERROR"
                        ( "Cannot read image from old deployment "
                            <> oldDepName
                            <> " (does it still exist?): "
                            <> err
                        )
                  Right (K8sResult rawImage) -> do
                    let oldImage = T.strip (T.dropAround (== '\'') (T.strip rawImage))
                    if T.null oldImage
                      then
                        pure $
                          APIResponse
                            "ERROR"
                            ( "Old deployment "
                                <> oldDepName
                                <> " exists but container '"
                                <> cName
                                <> "' has no image. Cannot immediate-revert."
                            )
                      else do
                        let oldImageQ = shellQuote oldImage
                        -- Step 2: Set image on the NEW deployment to OLD image
                        let setImageCmd =
                              unwords
                                [ kubectlBin cfg,
                                  "set",
                                  "image",
                                  "deployment/" <> depQ,
                                  cNameQ <> "=" <> oldImageQ,
                                  "-n",
                                  nsQ
                                ]
                        imgResult <- liftIO $ executeWithRetry cfg setImageCmd
                        case imgResult of
                          Left (K8sError err) ->
                            pure $ APIResponse "ERROR" ("Failed to set image: " <> err)
                          Right _ -> do
                            -- Step 2b (bug fix): if the release had an env-switch
                            -- override (envOverrideData), also restore the envs
                            -- from the OLD deployment. Without this, immediate
                            -- revert would leave the new deployment with the
                            -- overridden envs, which contradicts "undo the
                            -- release". Read the old deployment's env array
                            -- live and patch it onto the new deployment.
                            let hadEnvOverride = case NT.envOverrideData tracker of
                                  Just t -> not (T.null t)
                                  Nothing -> False
                            when hadEnvOverride $ do
                              let getEnvCmd =
                                    unwords
                                      [ kubectlBin cfg,
                                        "-n",
                                        nsQ,
                                        "get deployment",
                                        oldDepQ,
                                        "-o",
                                        "jsonpath='{.spec.template.spec.containers[?(@.name==\"" <> T.unpack cName <> "\")].env}'"
                                      ]
                              envResult <- liftIO $ runCmd getEnvCmd
                              case envResult of
                                Left (K8sError e) ->
                                  logInfo $ "[immediateRevertH] env restore: could not read old envs: " <> e
                                Right (K8sResult rawEnv) -> do
                                  let oldEnv = T.strip (T.dropAround (== '\'') (T.strip rawEnv))
                                      oldEnvNonEmpty = not (T.null oldEnv) && oldEnv /= "[]"
                                  if oldEnvNonEmpty
                                    then do
                                      patchEnvRes <- liftIO $ executeWithRetry cfg (buildPatchDeploymentEnvsCommand cfg ctx oldEnv)
                                      case patchEnvRes of
                                        Left (K8sError pe) ->
                                          logInfo $ "[immediateRevertH] env restore: patch failed: " <> pe
                                        Right _ ->
                                          logInfo "[immediateRevertH] env restore: patched envs from old deployment"
                                    else -- Old had no envs — clear the override by patching empty env
                                      do
                                        patchEnvRes <- liftIO $ executeWithRetry cfg (buildPatchDeploymentEnvsCommand cfg ctx "[]")
                                        case patchEnvRes of
                                          Left (K8sError pe) ->
                                            logInfo $ "[immediateRevertH] env clear: failed: " <> pe
                                          Right _ ->
                                            logInfo "[immediateRevertH] env restore: cleared envs (old had none)"

                            -- Step 3: rollout restart to bounce pods onto the old image
                            let restartCmd =
                                  unwords
                                    [ kubectlBin cfg,
                                      "rollout",
                                      "restart",
                                      "deployment/" <> depQ,
                                      "-n",
                                      nsQ
                                    ]
                            restartResult <- liftIO $ executeWithRetry cfg restartCmd
                            let mRestartErr = case restartResult of
                                  Left (K8sError e) -> Just e
                                  Right _ -> Nothing
                            -- Audit event on the ORIGINAL tracker — Julia parity, no
                            -- status mutation. The tracker stays COMPLETED.
                            insertReleaseEvent
                              rid
                              "BUSINESS"
                              "IMMEDIATE_REVERT"
                              ( object
                                  [ "requestedBy" .= (req :: ImmediateRevertReq).requestedBy,
                                    "info" .= (req :: ImmediateRevertReq).info,
                                    "fromImage" .= (NT.newVersion tracker :: Text),
                                    "toImage" .= (oldImage :: Text),
                                    "patchedDeployment" .= (newDepName :: Text),
                                    "imageReadFrom" .= (oldDepName :: Text)
                                  ]
                              )
                            notifyImmediateReverted tracker
                            let shouldSync = fromMaybe False mIsRevertSync
                            when shouldSync $
                              triggerImmediateRevertSync tracker mTargetState
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
                                    ( "Immediate revert: image swapped to "
                                        <> oldImage
                                        <> ", but rollout restart failed: "
                                        <> err
                                        <> ". Pods may still be running the new image; manual intervention may be required."
                                    )
                              Nothing ->
                                pure $
                                  APIResponse
                                    "SUCCESS"
                                    ( "Immediate revert: "
                                        <> newDepName
                                        <> " patched to image "
                                        <> oldImage
                                        <> " (read live from "
                                        <> oldDepName
                                        <> "); pods restarting"
                                    )
              _ -> pure $ APIResponse "ERROR" "No K8s context available for revert"

-- ============================================================================
-- Restart Release (POST /releases/:id/restart)
-- ============================================================================

-- | Julia parity (api/revert/restart.jl + rollback.jl reCreateRelease):
-- restart creates a brand-new tracker row that re-runs the same release.
-- The original (terminal) tracker is left untouched as an audit record.
--
-- Why a new tracker (and not in-place ABORTED → CREATED):
--  * Audit chain — every retry attempt is a separate row with its own
--    rollout_history, events, start_time. The release list shows the
--    full chain of (failed → restarted → completed).
--  * Clean state — the new tracker starts with empty release_context,
--    no leaked-cleanup markers, no stale rolloutHistory, no
--    podsScaleDownStatus carry-over from the previous attempt.
--  * Concurrency safety — the partial unique index
--    uq_release_tracker_service_inflight catches the case where another
--    in-flight tracker for the same (appGroup, service) already exists
--    via insertReleaseTrackerSafe, returning a friendly Conflict instead
--    of two competing workflows on the same service.
--  * Workflow simplicity — the runner has one mental model: "pick up
--    a CREATED tracker and run it from INIT to DONE". No "is this a
--    fresh start or a resume?" branching.
--
-- Validation mirrors Julia's @validateRestartTracker@ (restart.jl:43-46):
-- status must be in @{ABORTED, USER_ABORTED, DISCARDED, REVERTED}@ AND the
-- new-version deployment must still exist in k8s (otherwise the workflow
-- has nothing to scale up).
restartReleaseH :: AuthedPerson -> Text -> RestartReleaseReq -> Flow APIResponse
restartReleaseH ap rid req = do
  cfg <- getConfig
  m <- findReleaseTracker rid
  case m of
    Nothing -> pure $ APIResponse "ERROR" "Release not found"
    Just (tracker, mTargetState) -> do
      requireDeploymentPermission (Proxy :: Proxy 'AP_RELEASE_CREATE) ap (NT.appGroup tracker)
      let currentStatus = NT.status tracker
      if currentStatus /= ABORTED && currentStatus /= USER_ABORTED && currentStatus /= REVERTED && currentStatus /= DISCARDED
        then pure $ APIResponse "ERROR" ("Cannot restart from status: " <> T.pack (show currentStatus) <> ". Valid: ABORTED, USER_ABORTED, REVERTED, DISCARDED")
        else do
          -- Validate the new-version deployment still exists in k8s.
          -- Julia: validateRestartTracker (restart.jl:45-46).
          let oldCtx = case mTargetState of
                Just (K8sState k8s) -> context k8s
                _ -> defaultK8sReleaseContext
              ns = oldCtx.namespace
              svcName = oldCtx.serviceName
              newDepName = svcName <> "-" <> NT.newVersion tracker
          newDepExists <- liftIO $ deploymentExists cfg ns newDepName
          if not (T.null newDepName) && not newDepExists
            then
              pure $
                APIResponse
                  "ERROR"
                  ( "Cannot restart: new-version deployment "
                      <> newDepName
                      <> " no longer exists in k8s. Please create a new release."
                  )
            else do
              -- Defensive in-flight check: don't spawn a restart if another
              -- tracker for this (appGroup, service) is already running.
              -- The DB partial unique index will also catch this via
              -- insertReleaseTrackerSafe → Conflict, but a friendly
              -- pre-check gives a better error message.
              inFlight <- findInFlightSameService (NT.appGroup tracker) (NT.service tracker)
              case inFlight of
                Just existingTracker
                  | NT.releaseId existingTracker /= rid ->
                      pure $
                        APIResponse
                          "ERROR"
                          ( "Cannot restart: another in-flight release "
                              <> NT.releaseId existingTracker
                              <> " already exists for this service. Wait for it to finish or abort it first."
                          )
                _ -> do
                  claimed <- claimServiceForModification (NT.appGroup tracker) (NT.service tracker)
                  if not claimed
                    then
                      pure $
                        APIResponse
                          "ERROR"
                          ( "Service "
                              <> NT.service tracker
                              <> " in app group "
                              <> NT.appGroup tracker
                              <> " is already being modified (service_state guard). Try again shortly."
                          )
                    else do
                      now <- liftIO getCurrentTime
                      newRid <- liftIO (UUID.toText <$> UUID.nextRandom)
                      -- Build a fresh K8s release context: keep the static
                      -- deployment-identity fields (cluster/ns/service host/
                      -- VS/DR/version pair/match-config), but reset all
                      -- per-attempt state — no leaked-cleanup markers, no
                      -- AB run id, no scale-down status, no rollout flags.
                      let restartedContext =
                            oldCtx
                              { abRunId = Nothing,
                                abStatus = Nothing,
                                cleanupAt = Nothing,
                                cleanupTargetDeployment = Nothing,
                                cleanupStatus = Nothing,
                                podsScaleDownDelay = Nothing,
                                podsScaleDownTimestamp = Nothing,
                                podsScaleDownStatus = Nothing,
                                prevAbHsDecision = Nothing,
                                postMonitoringDecisionMap = Nothing,
                                oldVersionPodCount = Nothing
                              }
                          wasNewService = case mTargetState of
                            Just (K8sState K8sDeploymentState {newService = isNewService}) -> isNewService
                            _ -> False
                          restartedTargetState =
                            K8sState $
                              emptyK8sState
                                { context = restartedContext,
                                  newService = wasNewService
                                }
                          restartedTracker =
                            (tracker :: ReleaseTracker)
                              { NT.releaseId = newRid,
                                NT.status = CREATED,
                                NT.releaseWFStatus = INIT,
                                NT.scheduleTime = Just now,
                                NT.startTime = Nothing,
                                NT.endTime = Nothing,
                                NT.dateCreated = Nothing, -- DB sets via DEFAULT now()
                                NT.lastUpdated = Nothing,
                                NT.rolloutHistory = [],
                                -- Julia parity (create.jl:312 getInitialApprovalStatus):
                                -- restart-created trackers are NOT auto-approved.
                                -- The user must hit Approve again on the new tracker
                                -- to confirm intent. This matches Julia's reCreateRelease
                                -- which doesn't pass isSystemTriggered, so the new row
                                -- lands with is_approved=0.
                                NT.isApproved = False,
                                NT.isInfraApproved = False,
                                -- Round 8 audit C3: clear globalId so cross-cloud sync
                                -- on the secondary creates a fresh row, not idempotent-
                                -- skips because the global_id matches the original.
                                NT.globalId = Nothing,
                                -- Persist the restart's requestedBy as createdBy on the
                                -- new tracker so audit shows who triggered the retry.
                                NT.createdBy = fromMaybe (NT.createdBy tracker) ((req :: RestartReleaseReq).requestedBy),
                                NT.releaseContext = Just (toJSON restartedContext)
                              }
                      mIdem <- insertReleaseTrackerSafe restartedTracker restartedTargetState
                      case mIdem of
                        Just existingId ->
                          -- Idempotent: another identical restart already created
                          -- a tracker for this (appGroup, service). Return that id.
                          pure $ APIResponse "SUCCESS" ("Restart already in flight: " <> existingId)
                        Nothing -> do
                          -- Audit event on the ORIGINAL tracker so the chain is
                          -- discoverable from either side.
                          insertReleaseEvent
                            rid
                            "BUSINESS"
                            "RELEASE_RESTARTED"
                            ( object
                                [ "newTrackerId" .= newRid,
                                  "requestedBy" .= (req :: RestartReleaseReq).requestedBy,
                                  "reason" .= (req :: RestartReleaseReq).reason,
                                  "previousStatus" .= T.pack (show currentStatus)
                                ]
                            )
                          -- TRACKER_CREATED event on the NEW tracker with a back-pointer.
                          insertReleaseEvent
                            newRid
                            "BUSINESS"
                            "TRACKER_CREATED"
                            ( object
                                [ "restartedFrom" .= rid,
                                  "previousStatus" .= T.pack (show currentStatus),
                                  "appGroup" .= NT.appGroup restartedTracker,
                                  "service" .= NT.service restartedTracker,
                                  "oldVersion" .= NT.oldVersion restartedTracker,
                                  "newVersion" .= NT.newVersion restartedTracker
                                ]
                            )
                          -- Capture BEFORE/AFTER deployment snapshots so the
                          -- env-diff view on the new tracker has data to render.
                          -- createReleaseHBody and revertReleaseH do the same.
                          -- BEFORE = current state of the OLD deployment;
                          -- AFTER = preview of the NEW deployment built from the
                          -- OLD deployment YAML with image/version swapped in.
                          let restartNs = ns
                              restartOldDep = svcName <> "-" <> NT.oldVersion restartedTracker
                              restartNewVer = NT.newVersion restartedTracker
                              restartImage = fromMaybe "" (K8s.dockerImage oldCtx)
                          -- Create-time preview snapshots (see createReleaseH for
                          -- the rationale behind the @_PREVIEW@ suffix).
                          captureDeploymentSnapshot cfg newRid restartNs restartOldDep "DEPLOYMENT_BEFORE_PREVIEW"
                          captureDeploymentPreview
                            cfg
                            newRid
                            restartNs
                            restartOldDep
                            restartNewVer
                            restartImage
                            (NT.envOverrideData restartedTracker)
                            "DEPLOYMENT_AFTER_PREVIEW"
                          notifyReleaseRestarted restartedTracker
                          pure $ APIResponse "SUCCESS" ("Restart created: " <> newRid)

rolloutRestartDeploymentH :: AuthedPerson -> Text -> RestartReleaseReq -> Flow APIResponse
rolloutRestartDeploymentH ap rid req = do
  cfg <- getConfig
  m <- findReleaseTracker rid
  case m of
    Nothing -> pure $ APIResponse "ERROR" "Release not found"
    Just (tracker, mTargetState) -> do
      requireDeploymentPermission (Proxy :: Proxy 'AP_RELEASE_UPDATE) ap (NT.appGroup tracker)
      let currentStatus = NT.status tracker
      if currentStatus /= COMPLETED
        then
          pure $
            APIResponse
              "ERROR"
              ( "Rollout restart requires status=COMPLETED (current: "
                  <> T.pack (show currentStatus)
                  <> ")"
              )
        else case mTargetState of
          Just (K8sState k8s) -> do
            let ctx = context k8s
                K8s.K8sReleaseContext {K8s.namespace = ns} = ctx
                nsQ = shellQuote ns
                depName = deploymentName ctx
                depQ = shellQuote depName
                restartCmd =
                  unwords
                    [ kubectlBin cfg,
                      "rollout",
                      "restart",
                      "deployment/" <> depQ,
                      "-n",
                      nsQ
                    ]
            restartResult <- liftIO $ executeWithRetry cfg restartCmd
            case restartResult of
              Left (K8sError err) -> do
                logInfo $ "[rolloutRestartDeploymentH] rollout restart failed for " <> rid <> ": " <> err
                insertReleaseEvent
                  rid
                  "BUSINESS"
                  "DEPLOYMENT_RESTART_FAILED"
                  ( object
                      [ "requestedBy" .= (req :: RestartReleaseReq).requestedBy,
                        "deployment" .= depName,
                        "error" .= err
                      ]
                  )
                pure $ APIResponse "ERROR" ("Rollout restart failed: " <> err)
              Right _ -> do
                insertReleaseEvent
                  rid
                  "BUSINESS"
                  "DEPLOYMENT_RESTARTED"
                  ( object
                      [ "requestedBy" .= (req :: RestartReleaseReq).requestedBy,
                        "deployment" .= depName
                      ]
                  )
                pure $ APIResponse "SUCCESS" ("Rollout restart initiated for deployment/" <> depName)
          _ ->
            pure $ APIResponse "ERROR" "No K8s context available for this release"

-- ============================================================================
-- Fast Forward (POST /releases/:id/fast-forward)
-- ============================================================================

fastForwardH :: AuthedPerson -> Text -> FastForwardReq -> Flow APIResponse
fastForwardH ap rid req = do
  m <- findReleaseTracker rid
  case m of
    Nothing -> pure $ APIResponse "ERROR" "Release not found"
    Just (tracker, mTargetState) -> do
      requireDeploymentPermission (Proxy :: Proxy 'AP_RELEASE_UPDATE) ap (NT.appGroup tracker)
      let currentStatus = NT.status tracker
      if currentStatus /= INPROGRESS
        then pure $ APIResponse "ERROR" ("Cannot fast-forward from status: " <> T.pack (show currentStatus) <> ". Must be INPROGRESS")
        else do
          let ag = NT.appGroup tracker
          mProduct <- findProductByName ag
          let editorLocked = case mProduct of
                Nothing -> False
                Just p -> case getProductVsLockedBy p of
                  Nothing -> False
                  Just _ -> True
          if editorLocked
            then pure $ APIResponse "ERROR" ("Cannot fast-forward: VS is locked for " <> ag <> ". Unlock the VS first.")
            else do
              nowFF <- liftIO getCurrentTime
              let history = NT.rolloutHistory tracker
                  (currentStepAlreadyForwarded, stuckTooLong) = case history of
                    [] -> (False, False)
                    xs ->
                      let lastH = last xs
                          forwarded = historyManualOverride lastH
                          elapsedMin =
                            round
                              ( realToFrac (diffUTCTime nowFF (historyStartedAt lastH)) / 60.0 ::
                                  Double
                              ) ::
                              Int
                       in (forwarded, elapsedMin >= 5)
              if currentStepAlreadyForwarded && not stuckTooLong
                then pure $ APIResponse "SUCCESS" "Fast forward already in progress for current stage; runner will advance on next poll."
                else do
                  now <- liftIO getCurrentTime
                  let currentStepIdx = length history - 1
                      elapsedMins = case history of
                        [] -> 0
                        steps ->
                          let lastStep = last steps
                           in round (realToFrac (diffUTCTime now (historyStartedAt lastStep)) / 60 :: Double) :: Int
                      strategy = NT.rolloutStrategy tracker
                      updatedStrategy = case strategy of
                        [] -> []
                        steps ->
                          zipWith (\i s -> if i == currentStepIdx then s {cooloffMinutes = elapsedMins} else s) [0 ..] steps
                      updatedHistory = case history of
                        [] -> []
                        steps ->
                          let lastIdx = length steps - 1
                              updateStep i step =
                                if i == lastIdx
                                  then step {historyManualOverride = True}
                                  else step
                           in zipWith updateStep [0 ..] steps
                      updated = (tracker :: ReleaseTracker) {NT.rolloutHistory = updatedHistory, NT.rolloutStrategy = updatedStrategy}
                  ok <- conditionalUpdateTracker updated mTargetState (releaseStatusToText currentStatus)
                  if not ok
                    then pure staleTrackerError
                    else do
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
                            [ "requestedBy" .= actor,
                              "reason" .= reasonText,
                              "stage" .= (currentStepIdx + 1)
                            ]
                        )
                      notifyReleaseFastForwarded updated
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

-- | GET /release/staggerInfo/{releaseId}
-- Called by the external AB engine (ab-system-v2) during a live rollout to
-- determine the current traffic percentage on version B.  Returns the
-- ab-core StaggerInfo wire format: {"percentage": <double>, "time": "<ISO>"}
-- where percentage is 0-100 (current Istio weight on the new version) and
-- time is the release start time.  Falls back to 0 / epoch on missing data.
staggerInfoH :: Text -> Flow Value
staggerInfoH rid = do
  m <- findReleaseTracker rid
  case m of
    Nothing -> pure $ object ["percentage" .= (0.0 :: Double), "time" .= ("1970-01-01T00:00:00Z" :: Text)]
    Just (rt, mts) -> do
      let pct :: Double
          pct = case mts of
            Just ts -> case A.fromJSON (toJSON ts) of
              A.Success (Object o) ->
                case KM.lookup (K.fromText "trafficPercentage") o of
                  Just (Number n) -> realToFrac n
                  _ -> 0
              _ -> 0
            Nothing -> 0
          startIso = maybe "1970-01-01T00:00:00Z" (T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ") (NT.startTime rt)
      pure $ object ["percentage" .= pct, "time" .= startIso]

-- | Extract just the data section from a K8s ConfigMap YAML as JSON.
-- Input: full K8s YAML like "apiVersion: v1\ndata:\n  app.conf: |-\n    ...\nkind: ..."
-- Output: JSON like "{\"app.conf\":\"...\"}" so it matches the tracker's file format.
extractConfigMapDataSection :: Text -> Text
extractConfigMapDataSection yamlText =
  case Yaml.decodeEither' (TE.encodeUtf8 yamlText) :: Either Yaml.ParseException Value of
    Right (Object obj) ->
      case KM.lookup (K.fromText "data") obj of
        Just dataVal -> TE.decodeUtf8 (LBS.toStrict (A.encode dataVal))
        Nothing -> yamlText
    _ -> yamlText
