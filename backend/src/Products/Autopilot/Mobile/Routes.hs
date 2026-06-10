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
import Products.Autopilot.Mobile.Handlers.Versions
import Products.Autopilot.Types.Permission (AutopilotPermission (..))
import Servant

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
            :> Get '[JSON] ChangelogPreviewResp
        :<|> "mobile"
            :> "changelog-ai-summary"
            :> Protected 'AP_AI_SUMMARIZE
            :> QueryParam' '[Required, Strict] "app" Text
            :> QueryParam' '[Required, Strict] "surface" Text
            :> QueryParam' '[Required, Strict] "platform" Text
            :> QueryParam' '[Required, Strict] "branch" Text
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
        :<|> (\ap app surface platform branch -> changelogPreviewH ap app surface platform branch)
        :<|> (\ap app surface platform branch vName vCode -> changelogAiSummaryH ap app surface platform branch vName vCode)
        :<|> (\rid ap -> mobileRevertDraftH ap rid)
        :<|> (\rid ap req -> mobileRevertCreateH ap rid req)
        :<|> (\rid ap sha -> verifyCommitH ap rid sha)
        :<|> (\rid ap source -> mobileRevertDiffH ap rid source)
