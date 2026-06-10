{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

module Products.Autopilot.Routes (CoreAPI, coreServer) where

import Core.Auth.Protected (Protected)
import Core.Environment (Flow)
import Data.Aeson (Value)
import Data.Text (Text)
import GHC.Int (Int32)
import Products.Autopilot.Actions.ABValidation as ABValidation
import Products.Autopilot.Actions.Config as Config
import Products.Autopilot.Actions.ConfigMap as ConfigMap
import Products.Autopilot.Actions.K8sResource as K8sResource
import Products.Autopilot.Actions.Release as Release
import Products.Autopilot.Actions.VSEdit as VSEdit
import Products.Autopilot.Handlers.Ai as Ai
import Products.Autopilot.Mobile.Routes (MobileAPI, mobileServer)
import Products.Autopilot.Types (ReleaseTracker)
import Products.Autopilot.Types.API
import Products.Autopilot.Types.Permission (AutopilotPermission (..))
import Servant
import Shared.API.Response (APIResponse (..))

{- | 'Protected' sits immediately after the first path literal (before
QueryParam/ReqBody/Capture/Header) so 'AuthedPerson' is the first
argument to every handler.
-}
type CoreAPI =
    "products" :> Protected 'AP_PRODUCT_CONFIG_VIEW :> Get '[JSON] [ProductResponse]
        :<|> "products" :> Protected 'AP_PRODUCT_CONFIG_EDIT :> ReqBody '[JSON] UpsertProductReq :> Post '[JSON] APIResponse
        :<|> "products" :> Protected 'AP_PRODUCT_CONFIG_VIEW :> Capture "product" Text :> "services" :> Get '[JSON] [ServiceResponse]
        :<|> "services" :> Protected 'AP_PRODUCT_CONFIG_EDIT :> ReqBody '[JSON] UpsertServiceReq :> Post '[JSON] APIResponse
        :<|> "releases" :> Protected 'AP_RELEASE_VIEW :> QueryParam "from" Text :> QueryParam "to" Text :> QueryParam "category" Text :> Get '[JSON] [ReleaseTracker]
        :<|> "releases" :> Protected 'AP_RELEASE_CREATE :> "create" :> Header "X-Forwarded-Email" Text :> Header "x-pomerium-jwt-assertion" Text :> ReqBody '[JSON] K8sCreateReleaseReq :> Post '[JSON] APIResponse
        :<|> "releases" :> Protected 'AP_RELEASE_VIEW :> Capture "releaseId" Text :> Get '[JSON] (Maybe ReleaseTracker)
        :<|> "releases" :> Protected 'AP_RELEASE_APPROVE :> Capture "releaseId" Text :> "approve" :> ReqBody '[JSON] ApproveReleaseReq :> Post '[JSON] (Maybe ReleaseTracker)
        :<|> "releases" :> Protected 'AP_RELEASE_CREATE :> Capture "releaseId" Text :> "trigger" :> ReqBody '[JSON] TriggerReleaseReq :> Post '[JSON] APIResponse
        :<|> "releases" :> Protected 'AP_RELEASE_REVERT :> Capture "releaseId" Text :> "rollback" :> ReqBody '[JSON] TriggerReleaseReq :> Post '[JSON] APIResponse
        :<|> "releases" :> Protected 'AP_RELEASE_REVERT :> Capture "releaseId" Text :> "revert" :> ReqBody '[JSON] RevertReleaseReq :> Post '[JSON] APIResponse
        :<|> "release" :> Protected 'AP_RELEASE_REVERT :> "revert" :> "global" :> Capture "globalId" Text :> Put '[JSON] APIResponse
        :<|> "release" :> Protected 'AP_RELEASE_REVERT :> "revert" :> "immediate" :> "global" :> Capture "globalId" Text :> Put '[JSON] APIResponse
        :<|> "releases" :> Protected 'AP_RELEASE_DISCARD :> Capture "releaseId" Text :> "discard" :> ReqBody '[JSON] DiscardReleaseReq :> Post '[JSON] APIResponse
        :<|> "releases" :> Protected 'AP_RELEASE_UPDATE :> Capture "releaseId" Text :> "update" :> ReqBody '[JSON] K8sUpdateTrackerReq :> Post '[JSON] APIResponse
        :<|> "releases" :> Protected 'AP_RELEASE_VIEW :> Capture "releaseId" Text :> "events" :> Get '[JSON] [ReleaseEventResponse]
        :<|> "releases" :> Protected 'AP_RELEASE_DELETE :> Capture "releaseId" Text :> "delete" :> Post '[JSON] APIResponse
        :<|> "tracker" :> Protected 'AP_RELEASE_VIEW :> "configmap" :> "list" :> QueryParam "from" Text :> QueryParam "to" Text :> Get '[JSON] ConfigMapListResponse
        :<|> "tracker" :> Protected 'AP_RELEASE_VIEW :> "configmap" :> Capture "id" Text :> Get '[JSON] Value
        :<|> "tracker" :> Protected 'AP_RELEASE_CREATE :> "configmap" :> ReqBody '[JSON] Value :> Post '[JSON] APIResponse
        :<|> "tracker" :> Protected 'AP_RELEASE_UPDATE :> "configmap" :> Capture "id" Text :> ReqBody '[JSON] Value :> Put '[JSON] APIResponse
        :<|> "server-config" :> Protected 'AP_SERVICE_CONFIG_VIEW :> QueryParam "product" Text :> Get '[JSON] ServerConfigResponse
        :<|> "server-config" :> Protected 'AP_SERVICE_CONFIG_EDIT :> ReqBody '[JSON] UpsertServerConfigReq :> Post '[JSON] APIResponse
        :<|> "server-config" :> Protected 'AP_SERVICE_CONFIG_EDIT :> Capture "id" Int32 :> Delete '[JSON] APIResponse
        :<|> "envs" :> Protected 'AP_RELEASE_VIEW :> QueryParam "product" Text :> QueryParam "env" Text :> QueryParam "service" Text :> Get '[JSON] Value
        :<|> "envs" :> Protected 'AP_RELEASE_VIEW :> "secondary" :> QueryParam "product" Text :> QueryParam "env" Text :> QueryParam "service" Text :> Get '[JSON] Value
        -- New endpoints
        :<|> "releases" :> Protected 'AP_RELEASE_VIEW :> Capture "releaseId" Text :> "diff" :> QueryParam "type" Text :> Get '[JSON] DiffResponse
        :<|> "releases" :> Protected 'AP_RELEASE_VIEW :> Capture "releaseId" Text :> "pods" :> "health" :> Get '[JSON] PodHealthResponse
        :<|> "releases" :> Protected 'AP_RELEASE_REVERT :> Capture "releaseId" Text :> "revert" :> "immediate" :> ReqBody '[JSON] ImmediateRevertReq :> Post '[JSON] APIResponse
        :<|> "releases" :> Protected 'AP_RELEASE_CREATE :> Capture "releaseId" Text :> "restart" :> ReqBody '[JSON] RestartReleaseReq :> Post '[JSON] APIResponse
        :<|> "releases" :> Protected 'AP_RELEASE_UPDATE :> Capture "releaseId" Text :> "fast-forward" :> ReqBody '[JSON] FastForwardReq :> Post '[JSON] APIResponse
        :<|> "resources" :> Protected 'AP_PRODUCT_CONFIG_VIEW :> QueryParam "PRODUCT" Text :> QueryParam "SERVICE" Text :> Get '[JSON] ResourcesResponse
        :<|> "releases" :> Protected 'AP_RELEASE_VIEW :> Capture "releaseId" Text :> "rollout-history" :> Get '[JSON] Value
        :<|> "releases" :> Protected 'AP_RELEASE_VIEW :> Capture "releaseId" Text :> "logslink" :> Get '[JSON] Value
        -- Product Config CRUD
        :<|> "products" :> Protected 'AP_PRODUCT_CONFIG_VIEW :> "config" :> Get '[JSON] [ProductConfigResponse]
        :<|> "products" :> Protected 'AP_PRODUCT_CONFIG_EDIT :> "config" :> ReqBody '[JSON] UpsertProductReq :> Post '[JSON] APIResponse
        :<|> "products" :> Protected 'AP_PRODUCT_CONFIG_VIEW :> "config" :> Capture "id" Int32 :> Get '[JSON] Value
        :<|> "products" :> Protected 'AP_PRODUCT_CONFIG_EDIT :> "config" :> Capture "id" Int32 :> ReqBody '[JSON] UpsertProductReq :> Put '[JSON] APIResponse
        :<|> "products" :> Protected 'AP_PRODUCT_CONFIG_EDIT :> "config" :> Capture "id" Int32 :> Delete '[JSON] APIResponse
        -- Release Config CRUD
        :<|> "services" :> Protected 'AP_PRODUCT_CONFIG_VIEW :> "config" :> QueryParam "product" Text :> Get '[JSON] [ReleaseConfigResponse]
        :<|> "services" :> Protected 'AP_PRODUCT_CONFIG_EDIT :> "config" :> ReqBody '[JSON] UpsertServiceReq :> Post '[JSON] APIResponse
        :<|> "services" :> Protected 'AP_PRODUCT_CONFIG_VIEW :> "config" :> Capture "id" Int32 :> Get '[JSON] Value
        :<|> "services" :> Protected 'AP_PRODUCT_CONFIG_EDIT :> "config" :> Capture "id" Int32 :> ReqBody '[JSON] UpsertServiceReq :> Put '[JSON] APIResponse
        :<|> "services" :> Protected 'AP_PRODUCT_CONFIG_EDIT :> "config" :> Capture "id" Int32 :> Delete '[JSON] APIResponse
        -- VS Edit Tracker (static paths BEFORE captures to avoid ambiguity)
        :<|> "vs-edit-tracker" :> Protected 'AP_RELEASE_CREATE :> ReqBody '[JSON] CreateVsEditTrackerReq :> Post '[JSON] Value
        :<|> "vs-edit-tracker" :> Protected 'AP_RELEASE_VIEW :> "list" :> QueryParam "from" Text :> QueryParam "to" Text :> Get '[JSON] [VsEditTrackerResponse]
        :<|> "vs-edit-tracker" :> Protected 'AP_RELEASE_VIEW :> "current-vs" :> QueryParam "product" Text :> QueryParam "service" Text :> Get '[JSON] Value
        :<|> "vs-edit-tracker" :> Protected 'AP_RELEASE_CREATE :> "lock" :> ReqBody '[JSON] VsLockReq :> Post '[JSON] APIResponse
        :<|> "vs-edit-tracker" :> Protected 'AP_RELEASE_UPDATE :> "unlock" :> ReqBody '[JSON] VsUnlockReq :> Post '[JSON] APIResponse
        :<|> "vs-edit-tracker" :> Protected 'AP_FORCE_UNLOCK :> "force-unlock" :> ReqBody '[JSON] VsUnlockReq :> Post '[JSON] APIResponse
        :<|> "vs-edit-tracker" :> Protected 'AP_RELEASE_REVERT :> "revert" :> Capture "id" Text :> Put '[JSON] APIResponse
        :<|> "vs-edit-tracker" :> Protected 'AP_RELEASE_VIEW :> Capture "id" Text :> Get '[JSON] Value
        :<|> "vs-edit-tracker" :> Protected 'AP_RELEASE_UPDATE :> Capture "id" Text :> ReqBody '[JSON] UpdateVsEditTrackerReq :> Put '[JSON] APIResponse
        -- K8s ConfigMap lookup
        :<|> "configmap" :> Protected 'AP_CONFIG_EDIT :> QueryParam "PRODUCT" Text :> QueryParam "NAME" Text :> Get '[JSON] Value
        :<|> "configmap" :> Protected 'AP_CONFIG_EDIT :> "secondary" :> QueryParam "PRODUCT" Text :> QueryParam "NAME" Text :> Get '[JSON] Value
        -- Decision-engine post-monitoring webhook. UNAUTHENTICATED — trusts
        -- the run_id (releaseId-post) as the auth token; caller is the AB engine.
        :<|> "decision" :> "webhook" :> Capture "runId" Text :> ReqBody '[JSON] Value :> Post '[JSON] APIResponse
        -- Stagger info — called by AB engine to learn current traffic % on version B.
        -- UNAUTHENTICATED: the AB engine has no SCC credentials.
        :<|> "release" :> "staggerInfo" :> Capture "releaseId" Text :> Get '[JSON] Value
        -- AB validation (static path first so it doesn't conflict with release captures)
        :<|> "releases" :> Protected 'AP_RELEASE_VIEW :> "abstatus" :> QueryParam "from" Text :> QueryParam "to" Text :> QueryParam "product" Text :> Get '[JSON] Value
        :<|> "releases" :> Protected 'AP_RELEASE_VIEW :> Capture "releaseId" Text :> "ab" :> Get '[JSON] Value
        :<|> "releases" :> Protected 'AP_AB_VALIDATION_EDIT :> Capture "releaseId" Text :> "ab" :> ReqBody '[JSON] Value :> Put '[JSON] APIResponse
        -- AI (detail page): summary / risk / freeform Q&A over a release's context
        :<|> "releases" :> Protected 'AP_AI_SUMMARIZE :> Capture "releaseId" Text :> "ai" :> "summary" :> ReqBody '[JSON] AiActionReq :> Post '[JSON] AiResp
        :<|> "releases" :> Protected 'AP_AI_ASSESS :> Capture "releaseId" Text :> "ai" :> "risk" :> ReqBody '[JSON] AiActionReq :> Post '[JSON] AiResp
        :<|> "releases" :> Protected 'AP_AI_ASK :> Capture "releaseId" Text :> "ai" :> "ask" :> ReqBody '[JSON] AiAskReq :> Post '[JSON] AiResp
        -- AI (config): models available to the configured Grid key (model picker)
        :<|> "ai" :> Protected 'AP_AI_SUMMARIZE :> "models" :> Get '[JSON] AiModelsResp
        -- Mobile releases: app catalog CRUD (suffix mount per unified-product principle)
        :<|> MobileAPI

coreServer :: ServerT CoreAPI Flow
coreServer =
    -- Products
    Release.listProductsH
        :<|> Release.upsertProductH
        :<|> Release.listServicesH
        :<|> Release.upsertServiceH
        -- Releases
        :<|> Release.listReleasesH
        :<|> Release.createReleaseH
        :<|> Release.getReleaseH
        :<|> Release.approveReleaseH
        :<|> Release.triggerReleaseH
        :<|> Release.rollbackReleaseH
        :<|> Release.revertReleaseH
        :<|> Release.revertByGlobalIdH
        :<|> Release.immediateRevertByGlobalIdH
        :<|> Release.discardReleaseH
        :<|> Release.updateTrackerH
        :<|> Release.listEventsH
        :<|> Release.deleteReleaseH
        -- ConfigMap Tracker
        :<|> ConfigMap.listConfigMapsH
        :<|> ConfigMap.getConfigMapH
        :<|> ConfigMap.createConfigMapH
        :<|> ConfigMap.updateConfigMapH
        -- Server config
        :<|> Config.listServerConfigH
        :<|> Config.upsertServerConfigH
        :<|> Config.deleteServerConfigH
        -- Envs
        :<|> K8sResource.fetchEnvsH
        :<|> K8sResource.fetchSecondaryEnvsH
        -- New endpoints
        :<|> Release.releaseDiffH
        :<|> Release.podHealthH
        :<|> Release.immediateRevertH
        :<|> Release.restartReleaseH
        :<|> Release.fastForwardH
        :<|> K8sResource.fetchResourcesH
        :<|> Release.rolloutHistoryH
        :<|> Release.logsLinkH
        -- Product Config CRUD
        :<|> Config.listProductConfigsH
        :<|> Config.createProductConfigH
        :<|> Config.getProductConfigH
        :<|> Config.updateProductConfigH
        :<|> Config.deleteProductConfigH
        -- Release Config CRUD
        :<|> Config.listReleaseConfigsH
        :<|> Config.createReleaseConfigH
        :<|> Config.getReleaseConfigH
        :<|> Config.updateReleaseConfigH
        :<|> Config.deleteReleaseConfigH
        -- VS Edit Tracker (order must match API type: static paths before captures)
        :<|> VSEdit.createVsEditTrackerH
        :<|> VSEdit.listVsEditTrackersH
        :<|> VSEdit.fetchCurrentVsH
        :<|> VSEdit.lockVsEditTrackerH
        :<|> VSEdit.unlockVsEditTrackerH
        :<|> VSEdit.forceUnlockVsEditTrackerH
        :<|> VSEdit.revertVsEditTrackerH
        :<|> VSEdit.getVsEditTrackerH
        :<|> VSEdit.updateVsEditTrackerH
        -- K8s ConfigMap lookup
        :<|> ConfigMap.fetchConfigMapFromK8sH
        :<|> ConfigMap.fetchSecondaryConfigMapH
        -- Post-monitoring webhook receiver
        :<|> Release.decisionWebhookH
        -- Stagger info for AB engine
        :<|> Release.staggerInfoH
        -- AB validation
        :<|> ABValidation.getABMetricsH
        :<|> ABValidation.getValidABStatusesH
        :<|> ABValidation.updateABValidationH
        -- AI (detail page)
        :<|> Ai.summarizeReleaseH
        :<|> Ai.assessReleaseH
        :<|> Ai.askReleaseH
        -- AI (config): model picker
        :<|> Ai.listAiModelsH
        -- Mobile releases (suffix mount of MobileAPI)
        :<|> mobileServer
