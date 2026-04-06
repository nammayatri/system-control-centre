{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

module Products.Autopilot.Routes (CoreAPI, coreServer) where

import Core.Utils.FlowMonad (Flow)
import Data.Aeson (Value)
import Data.Text (Text)
import GHC.Int (Int32)
import Products.Autopilot.Actions.Config as Config
import Products.Autopilot.Actions.ConfigMap as ConfigMap
import Products.Autopilot.Actions.K8sResource as K8sResource
import Products.Autopilot.Actions.Release as Release
import Products.Autopilot.Actions.VSEdit as VSEdit
import Products.Autopilot.Types (ReleaseTracker)
import Products.Autopilot.Types.API
import Servant
import Shared.API.Response (APIResponse (..))

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
    :<|> "releases" :> Capture "releaseId" Text :> "events" :> Get '[JSON] [ReleaseEventResponse]
    :<|> "releases" :> Capture "releaseId" Text :> "delete" :> Post '[JSON] APIResponse
    :<|> "tracker" :> "configmap" :> "list" :> QueryParam "from" Text :> QueryParam "to" Text :> Get '[JSON] ConfigMapListResponse
    :<|> "tracker" :> "configmap" :> Capture "id" Text :> Get '[JSON] Value
    :<|> "tracker" :> "configmap" :> ReqBody '[JSON] Value :> Post '[JSON] APIResponse
    :<|> "tracker" :> "configmap" :> Capture "id" Text :> ReqBody '[JSON] Value :> Put '[JSON] APIResponse
    :<|> "server-config" :> QueryParam "product" Text :> Get '[JSON] ServerConfigResponse
    :<|> "server-config" :> ReqBody '[JSON] UpsertServerConfigReq :> Post '[JSON] APIResponse
    :<|> "server-config" :> Capture "id" Int32 :> Delete '[JSON] APIResponse
    :<|> "envs" :> QueryParam "product" Text :> QueryParam "env" Text :> QueryParam "service" Text :> Get '[JSON] Value
    :<|> "envs" :> "secondary" :> QueryParam "product" Text :> QueryParam "env" Text :> QueryParam "service" Text :> Get '[JSON] Value
    -- New endpoints
    :<|> "releases" :> Capture "releaseId" Text :> "diff" :> QueryParam "type" Text :> Get '[JSON] DiffResponse
    :<|> "releases" :> Capture "releaseId" Text :> "pods" :> "health" :> Get '[JSON] PodHealthResponse
    :<|> "releases" :> Capture "releaseId" Text :> "revert" :> "immediate" :> ReqBody '[JSON] ImmediateRevertReq :> Post '[JSON] APIResponse
    :<|> "releases" :> Capture "releaseId" Text :> "restart" :> ReqBody '[JSON] RestartReleaseReq :> Post '[JSON] APIResponse
    :<|> "releases" :> Capture "releaseId" Text :> "fast-forward" :> ReqBody '[JSON] FastForwardReq :> Post '[JSON] APIResponse
    :<|> "resources" :> QueryParam "PRODUCT" Text :> QueryParam "SERVICE" Text :> Get '[JSON] ResourcesResponse
    :<|> "releases" :> Capture "releaseId" Text :> "rollout-history" :> Get '[JSON] Value
    :<|> "releases" :> Capture "releaseId" Text :> "logslink" :> Get '[JSON] Value
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
    :<|> "vs-edit-tracker" :> "list" :> QueryParam "from" Text :> QueryParam "to" Text :> Get '[JSON] [VsEditTrackerResponse]
    :<|> "vs-edit-tracker" :> "current-vs" :> QueryParam "product" Text :> QueryParam "service" Text :> Get '[JSON] Value
    :<|> "vs-edit-tracker" :> "lock" :> ReqBody '[JSON] VsLockReq :> Post '[JSON] APIResponse
    :<|> "vs-edit-tracker" :> "unlock" :> ReqBody '[JSON] VsUnlockReq :> Post '[JSON] APIResponse
    :<|> "vs-edit-tracker" :> "force-unlock" :> ReqBody '[JSON] VsUnlockReq :> Post '[JSON] APIResponse
    :<|> "vs-edit-tracker" :> "revert" :> Capture "id" Text :> Put '[JSON] APIResponse
    :<|> "vs-edit-tracker" :> Capture "id" Text :> Get '[JSON] Value
    :<|> "vs-edit-tracker" :> Capture "id" Text :> ReqBody '[JSON] UpdateVsEditTrackerReq :> Put '[JSON] APIResponse

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
