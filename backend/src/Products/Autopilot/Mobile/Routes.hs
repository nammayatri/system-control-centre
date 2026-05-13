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

mobileServer :: ServerT MobileAPI Flow
mobileServer =
    listAppsH
        :<|> createAppH
        :<|> patchAppH
        :<|> previewVersionsH
        :<|> createMobileReleasesH
        :<|> dispatchMobileReleasesH
        :<|> liveReleasesH
