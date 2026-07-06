{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

{- | Mobile-release HTTP API. Mounted as a suffix of 'CoreAPI' by
'Products.Autopilot.Routes'. Do NOT mount this independently from
"Core.Server" — the unified-product principle keeps every Autopilot
route on the same Servant tree so RBAC, logging, and middleware stay
consistent.
-}
module Products.Autopilot.Mobile.Routes (
    MobileAPI,
    mobileServer,
) where

import Core.Auth.Protected (Protected)
import Core.Environment (Flow)
import Data.Int (Int32)
import Data.Text (Text)
import Products.Autopilot.Mobile.Handlers.AppCatalog
import Products.Autopilot.Mobile.Handlers.Live
import Products.Autopilot.Mobile.Handlers.Release
import Products.Autopilot.Mobile.Handlers.Revert (
    RevertDiffResp,
    RevertDraft,
    RevertReq,
    RevertResp,
    VerifyCommitResp,
    mobileRevertCreateH,
    mobileRevertDiffH,
    mobileRevertDraftH,
    verifyCommitH,
 )
import Products.Autopilot.Mobile.Handlers.Rollout (
    BulkActionResp,
    BulkPromoteReq,
    BulkRolloutReq,
    MarkRejectedReq,
    PromoteForm,
    PromoteReq,
    PromoteResp,
    RolloutDetail,
    RolloutSetReq,
    bulkPromoteH,
    bulkRolloutH,
    markApprovedH,
    markRejectedH,
    promoteFormH,
    promoteH,
    releaseH,
    rolloutDetailH,
    rolloutHaltH,
    rolloutReleaseAllH,
    rolloutResumeH,
    rolloutSetH,
    withdrawH,
 )
import Products.Autopilot.Mobile.Handlers.StoreMonitor (
    StoreMonitorAppResp,
    StoreMonitorResp,
    refreshStoreAppH,
    storeMonitorH,
 )
import Products.Autopilot.Mobile.Handlers.Versions
import Products.Autopilot.Types.Permission (AutopilotPermission (..))
import Servant
import Shared.API.Response (APISuccess)

type MobileAPI =
    "mobile"
        :> "apps"
        :> Protected 'AP_RELEASE_VIEW
        :> Get '[JSON] [AppCatalogEntryResp]
        :<|> "mobile"
            :> "apps"
            :> Protected 'AP_MOBILE_APP_MANAGE
            :> ReqBody '[JSON] NewAppReq
            :> Post '[JSON] AppCatalogEntryResp
        :<|> "mobile"
            :> "apps"
            :> Protected 'AP_MOBILE_APP_MANAGE
            :> Capture "id" Int32
            :> ReqBody '[JSON] PatchAppReq
            :> Patch '[JSON] AppCatalogEntryResp
        :<|> "mobile"
            :> "versions"
            :> "preview"
            :> Protected 'AP_RELEASE_CREATE
            :> ReqBody '[JSON] PreviewVersionsReq
            :> Post '[JSON] PreviewVersionsResp
        :<|> "releases"
            :> "mobile"
            :> "create"
            :> Protected 'AP_RELEASE_CREATE
            :> ReqBody '[JSON] CreateMobileReleasesReq
            :> Post '[JSON] CreateMobileReleasesResp
        :<|> "releases"
            :> "mobile"
            :> "dispatch"
            :> Protected 'AP_MOBILE_DISPATCH
            :> ReqBody '[JSON] DispatchMobileReleasesReq
            :> Post '[JSON] DispatchMobileReleasesResp
        :<|> "releases"
            :> "live"
            :> Protected 'AP_RELEASE_VIEW
            :> QueryParam "category" Text
            :> Get '[JSON] LiveReleasesResp
        :<|> "mobile"
            :> "branches"
            :> Protected 'AP_RELEASE_CREATE
            :> QueryParam "q" Text
            :> Get '[JSON] BranchesResp
        :<|> "mobile"
            :> "changelog-preview"
            :> Protected 'AP_RELEASE_CREATE
            :> QueryParam' '[Required, Strict] "app" Text
            :> QueryParam' '[Required, Strict] "surface" Text
            :> QueryParam' '[Required, Strict] "platform" Text
            :> QueryParam' '[Required, Strict] "branch" Text
            :> QueryParam "base" Text
            :> Get '[JSON] ChangelogPreviewResp
        :<|> "mobile"
            :> "changelog-ai-summary"
            :> Protected 'AP_AI_SUMMARIZE
            :> QueryParam' '[Required, Strict] "app" Text
            :> QueryParam' '[Required, Strict] "surface" Text
            :> QueryParam' '[Required, Strict] "platform" Text
            :> QueryParam' '[Required, Strict] "branch" Text
            :> QueryParam "base" Text
            :> QueryParam "versionName" Text
            :> QueryParam "versionCode" Text
            :> Get '[JSON] AiSummaryResp
        :<|> "releases"
            :> Capture "releaseId" Text
            :> "mobile-revert"
            :> "draft"
            :> Protected 'AP_RELEASE_REVERT
            :> Get '[JSON] RevertDraft
        :<|> "releases"
            :> Capture "releaseId" Text
            :> "mobile-revert"
            :> Protected 'AP_RELEASE_REVERT
            :> ReqBody '[JSON] RevertReq
            :> Post '[JSON] RevertResp
        :<|> "releases"
            :> Capture "releaseId" Text
            :> "mobile-revert"
            :> "verify-commit"
            :> Protected 'AP_RELEASE_REVERT
            :> QueryParam' '[Required, Strict] "sha" Text
            :> Get '[JSON] VerifyCommitResp
        :<|> "releases"
            :> Capture "releaseId" Text
            :> "mobile-revert"
            :> "diff"
            :> Protected 'AP_RELEASE_REVERT
            :> QueryParam' '[Required, Strict] "source" Text
            :> Get '[JSON] RevertDiffResp
        -- ── Promote-to-review + staged rollout (Phase 6) ──
        :<|> "releases"
            :> Capture "releaseId" Text
            :> "promote-form"
            :> Protected 'AP_RELEASE_VIEW
            :> Get '[JSON] PromoteForm
        :<|> "releases"
            :> Capture "releaseId" Text
            :> "promote"
            :> Protected 'AP_RELEASE_PROMOTE
            :> ReqBody '[JSON] PromoteReq
            :> Post '[JSON] PromoteResp
        :<|> "releases"
            :> Capture "releaseId" Text
            :> "rollout"
            :> Protected 'AP_RELEASE_VIEW
            :> Get '[JSON] RolloutDetail
        :<|> "releases"
            :> Capture "releaseId" Text
            :> "release"
            :> Protected 'AP_RELEASE_ROLLOUT
            :> Post '[JSON] APISuccess
        :<|> "releases"
            :> Capture "releaseId" Text
            :> "rollout"
            :> "set"
            :> Protected 'AP_RELEASE_ROLLOUT
            :> ReqBody '[JSON] RolloutSetReq
            :> Post '[JSON] APISuccess
        :<|> "releases"
            :> Capture "releaseId" Text
            :> "rollout"
            :> "halt"
            :> Protected 'AP_RELEASE_ROLLOUT
            :> Post '[JSON] APISuccess
        :<|> "releases"
            :> Capture "releaseId" Text
            :> "rollout"
            :> "resume"
            :> Protected 'AP_RELEASE_ROLLOUT
            :> Post '[JSON] APISuccess
        :<|> "releases"
            :> Capture "releaseId" Text
            :> "rollout"
            :> "release-all"
            :> Protected 'AP_RELEASE_ROLLOUT
            :> Post '[JSON] APISuccess
        :<|> "releases"
            :> Capture "releaseId" Text
            :> "review"
            :> "mark-approved"
            :> Protected 'AP_RELEASE_PROMOTE
            :> Post '[JSON] APISuccess
        :<|> "releases"
            :> Capture "releaseId" Text
            :> "review"
            :> "mark-rejected"
            :> Protected 'AP_RELEASE_PROMOTE
            :> ReqBody '[JSON] MarkRejectedReq
            :> Post '[JSON] APISuccess
        :<|> "releases"
            :> Capture "releaseId" Text
            :> "withdraw"
            :> Protected 'AP_RELEASE_PROMOTE
            :> Post '[JSON] APISuccess
        -- ── App Release Monitoring (store-monitor) ──
        :<|> "mobile"
            :> "store-monitor"
            :> Protected 'AP_RELEASE_VIEW
            :> Get '[JSON] StoreMonitorResp
        :<|> "mobile"
            :> "store-monitor"
            :> Capture "appCatalogId" Int32
            :> "refresh"
            :> Protected 'AP_RELEASE_VIEW
            :> Post '[JSON] StoreMonitorAppResp
        -- ── Bulk promote / rollout (one action over many apps) ──
        -- Under the `mobile/bulk/*` literal namespace so they never collide with
        -- the `releases/:releaseId/*` capture routes above.
        :<|> "mobile"
            :> "bulk"
            :> "promote"
            :> Protected 'AP_RELEASE_PROMOTE
            :> ReqBody '[JSON] BulkPromoteReq
            :> Post '[JSON] BulkActionResp
        :<|> "mobile"
            :> "bulk"
            :> "rollout"
            :> Protected 'AP_RELEASE_ROLLOUT
            :> ReqBody '[JSON] BulkRolloutReq
            :> Post '[JSON] BulkActionResp

mobileServer :: ServerT MobileAPI Flow
mobileServer =
    listAppsH
        :<|> createAppH
        :<|> patchAppH
        :<|> previewVersionsH
        :<|> createMobileReleasesH
        :<|> dispatchMobileReleasesH
        :<|> liveReleasesH
        :<|> (\ap mq -> listBranchesH ap mq)
        :<|> (\ap app surface platform branch base -> changelogPreviewH ap app surface platform branch base)
        :<|> (\ap app surface platform branch base vName vCode -> changelogAiSummaryH ap app surface platform branch base vName vCode)
        :<|> (\rid ap -> mobileRevertDraftH ap rid)
        :<|> (\rid ap req -> mobileRevertCreateH ap rid req)
        :<|> (\rid ap sha -> verifyCommitH ap rid sha)
        :<|> (\rid ap source -> mobileRevertDiffH ap rid source)
        -- ── Promote-to-review + staged rollout (Phase 6) ──
        :<|> (\rid ap -> promoteFormH ap rid)
        :<|> (\rid ap req -> promoteH ap rid req)
        :<|> (\rid ap -> rolloutDetailH ap rid)
        :<|> (\rid ap -> releaseH ap rid)
        :<|> (\rid ap req -> rolloutSetH ap rid req)
        :<|> (\rid ap -> rolloutHaltH ap rid)
        :<|> (\rid ap -> rolloutResumeH ap rid)
        :<|> (\rid ap -> rolloutReleaseAllH ap rid)
        :<|> (\rid ap -> markApprovedH ap rid)
        :<|> (\rid ap req -> markRejectedH ap rid req)
        :<|> (\rid ap -> withdrawH ap rid)
        -- ── App Release Monitoring (store-monitor) ──
        :<|> storeMonitorH
        :<|> (\aid ap -> refreshStoreAppH ap aid)
        -- ── Bulk promote / rollout ──
        :<|> (\ap req -> bulkPromoteH ap req)
        :<|> (\ap req -> bulkRolloutH ap req)
