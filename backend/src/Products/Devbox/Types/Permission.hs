{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Devbox Releases permissions as a promoted ADT (same shape as
Products.AirborneOta.Types.Permission). The wire name keeps the full
@DEVBOX_@ prefix so the ADT constructor, sc_role seeds and frontend
permission strings are the identical spelling.

A devbox release is a feature branch (backend + control-center + app)
built and run on a fleet dev-box for testing. STOP is the creator's own
release; STOP_ANY is anyone's (Manager and Admin).
-}
module Products.Devbox.Types.Permission (
    DevboxPermission (..),
    devboxPermissionToText,
    textToDevboxPermission,
    devboxPermissionDescription,
)
where

import Core.Auth.Permission (KnownPermission (..))
import Data.Text (Text)

data DevboxPermission
    = DEVBOX_VIEW
    | DEVBOX_RELEASE_CREATE
    | DEVBOX_RELEASE_STOP
    | DEVBOX_RELEASE_STOP_ANY
    deriving (Show, Read, Eq, Ord, Enum, Bounded)

devboxPermissionToText :: DevboxPermission -> Text
devboxPermissionToText DEVBOX_VIEW = "DEVBOX_VIEW"
devboxPermissionToText DEVBOX_RELEASE_CREATE = "DEVBOX_RELEASE_CREATE"
devboxPermissionToText DEVBOX_RELEASE_STOP = "DEVBOX_RELEASE_STOP"
devboxPermissionToText DEVBOX_RELEASE_STOP_ANY = "DEVBOX_RELEASE_STOP_ANY"

textToDevboxPermission :: Text -> Maybe DevboxPermission
textToDevboxPermission "DEVBOX_VIEW" = Just DEVBOX_VIEW
textToDevboxPermission "DEVBOX_RELEASE_CREATE" = Just DEVBOX_RELEASE_CREATE
textToDevboxPermission "DEVBOX_RELEASE_STOP" = Just DEVBOX_RELEASE_STOP
textToDevboxPermission "DEVBOX_RELEASE_STOP_ANY" = Just DEVBOX_RELEASE_STOP_ANY
textToDevboxPermission _ = Nothing

devboxPermissionDescription :: DevboxPermission -> Text
devboxPermissionDescription DEVBOX_VIEW = "View devbox releases, their stages and URLs"
devboxPermissionDescription DEVBOX_RELEASE_CREATE = "Create a devbox release (feature branches on a dev-box)"
devboxPermissionDescription DEVBOX_RELEASE_STOP = "Stop your own devbox release"
devboxPermissionDescription DEVBOX_RELEASE_STOP_ANY = "Stop anyone's devbox release"

-- 'permissionName' MUST match 'devboxPermissionToText' for the same
-- constructor; the RBAC check compares this string against the DB.

instance KnownPermission 'DEVBOX_VIEW where
    permissionProduct _ = "devbox"
    permissionName _ = "DEVBOX_VIEW"

instance KnownPermission 'DEVBOX_RELEASE_CREATE where
    permissionProduct _ = "devbox"
    permissionName _ = "DEVBOX_RELEASE_CREATE"

instance KnownPermission 'DEVBOX_RELEASE_STOP where
    permissionProduct _ = "devbox"
    permissionName _ = "DEVBOX_RELEASE_STOP"

instance KnownPermission 'DEVBOX_RELEASE_STOP_ANY where
    permissionProduct _ = "devbox"
    permissionName _ = "DEVBOX_RELEASE_STOP_ANY"
