{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Lock / unlock new releases for an app group or one service. Driven from the
Deployment Config page, so it uses the same permission as editing that config.
-}
module Products.Autopilot.Actions.ReleaseLock (
    SetReleaseLockReq (..),
    ClearReleaseLockReq (..),
    listReleaseLocksH,
    setReleaseLockH,
    clearReleaseLockH,
)
where

import Control.Monad.Catch (throwM)
import Core.AppError (APIError (..))
import Core.Auth.Protected (AuthedPerson (..), requireDeploymentPermission)
import Core.Environment (Flow)
import Data.Aeson (FromJSON)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Products.Autopilot.Notifications (notifyReleaseLockChanged)
import Products.Autopilot.Queries.ReleaseLock (ReleaseLock, clearReleaseLock, listReleaseLocks, setReleaseLock)
import Products.Autopilot.Types.Permission (AutopilotPermission (..))
import Shared.API.Response (APIResponse (..))

-- | @service@ absent or empty locks the whole app group.
data SetReleaseLockReq = SetReleaseLockReq
    { appGroup :: Text
    , service :: Maybe Text
    , reason :: Maybe Text
    }
    deriving (Generic)

instance FromJSON SetReleaseLockReq

data ClearReleaseLockReq = ClearReleaseLockReq
    { appGroup :: Text
    , service :: Maybe Text
    }
    deriving (Generic)

instance FromJSON ClearReleaseLockReq

editPerm :: Proxy 'AP_PRODUCT_CONFIG_EDIT
editPerm = Proxy

scopeName :: Text -> Text -> Text
scopeName g s = if T.null s then g else g <> "/" <> s

listReleaseLocksH :: AuthedPerson -> Maybe Text -> Flow [ReleaseLock]
listReleaseLocksH _ap = listReleaseLocks

setReleaseLockH :: AuthedPerson -> SetReleaseLockReq -> Flow APIResponse
setReleaseLockH ap req = do
    let g = T.strip req.appGroup
        s = maybe "" T.strip req.service
    if T.null g then throwM (BadRequest "appGroup is required") else pure ()
    requireDeploymentPermission editPerm ap g
    let why = maybe "" T.strip req.reason
    setReleaseLock g s why (apEmail ap)
    notifyReleaseLockChanged True g s (apEmail ap) why
    pure $ APIResponse "SUCCESS" ("Releases locked for " <> scopeName g s)

clearReleaseLockH :: AuthedPerson -> ClearReleaseLockReq -> Flow APIResponse
clearReleaseLockH ap req = do
    let g = T.strip req.appGroup
        s = maybe "" T.strip req.service
    requireDeploymentPermission editPerm ap g
    clearReleaseLock g s
    notifyReleaseLockChanged False g s (apEmail ap) ""
    pure $ APIResponse "SUCCESS" ("Releases unlocked for " <> scopeName g s)
