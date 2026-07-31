{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Mobile (builds + OTA) permissions as a promoted ADT — the grant universe
of the @mobile@ product after the 2026-07-31 product split
(docs\/superpowers\/plans\/2026-07-31-mobile-product-split.md).

Wire name == constructor, exactly like the OTA family: the ADT constructor,
sc_role\/override strings and frontend permission names are the identical
@MB_@-prefixed spelling, self-disambiguating from autopilot's prefix-stripped
BE verbs (\"RELEASE_VIEW\" is BE; \"MB_RELEASE_VIEW\" is mobile). The split
migration rewrites pre-split strings on moved rows. The OTA family is NOT
declared here: @allPermissions Mobile@ folds
'Products.AirborneOta.Types.Permission.OtaPermission' in, the same way
autopilot used to.
-}
module Products.Mobile.Types.Permission (
    MobilePermission (..),
    mobilePermissionToText,
    textToMobilePermission,
    mobilePermissionDescription,
)
where

import Core.Auth.Permission (KnownPermission (..))
import Data.Text (Text)

data MobilePermission
    = MB_RELEASE_VIEW
    | MB_RELEASE_CREATE
    | MB_RELEASE_PROMOTE
    | MB_RELEASE_ROLLOUT
    | MB_RELEASE_REVERT
    | MB_RELEASE_ABORT
    | MB_MOBILE_DISPATCH
    | MB_MOBILE_APP_MANAGE
    | MB_AI_SUMMARIZE
    deriving (Show, Read, Eq, Ord, Enum, Bounded)

mobilePermissionToText :: MobilePermission -> Text
mobilePermissionToText MB_RELEASE_VIEW = "MB_RELEASE_VIEW"
mobilePermissionToText MB_RELEASE_CREATE = "MB_RELEASE_CREATE"
mobilePermissionToText MB_RELEASE_PROMOTE = "MB_RELEASE_PROMOTE"
mobilePermissionToText MB_RELEASE_ROLLOUT = "MB_RELEASE_ROLLOUT"
mobilePermissionToText MB_RELEASE_REVERT = "MB_RELEASE_REVERT"
mobilePermissionToText MB_RELEASE_ABORT = "MB_RELEASE_ABORT"
mobilePermissionToText MB_MOBILE_DISPATCH = "MB_MOBILE_DISPATCH"
mobilePermissionToText MB_MOBILE_APP_MANAGE = "MB_MOBILE_APP_MANAGE"
mobilePermissionToText MB_AI_SUMMARIZE = "MB_AI_SUMMARIZE"

textToMobilePermission :: Text -> Maybe MobilePermission
textToMobilePermission "MB_RELEASE_VIEW" = Just MB_RELEASE_VIEW
textToMobilePermission "MB_RELEASE_CREATE" = Just MB_RELEASE_CREATE
textToMobilePermission "MB_RELEASE_PROMOTE" = Just MB_RELEASE_PROMOTE
textToMobilePermission "MB_RELEASE_ROLLOUT" = Just MB_RELEASE_ROLLOUT
textToMobilePermission "MB_RELEASE_REVERT" = Just MB_RELEASE_REVERT
textToMobilePermission "MB_RELEASE_ABORT" = Just MB_RELEASE_ABORT
textToMobilePermission "MB_MOBILE_DISPATCH" = Just MB_MOBILE_DISPATCH
textToMobilePermission "MB_MOBILE_APP_MANAGE" = Just MB_MOBILE_APP_MANAGE
textToMobilePermission "MB_AI_SUMMARIZE" = Just MB_AI_SUMMARIZE
textToMobilePermission _ = Nothing

-- | Human-readable description (exhaustive, -Wall catches missing variants).
mobilePermissionDescription :: MobilePermission -> Text
mobilePermissionDescription MB_RELEASE_VIEW = "View mobile releases, groups and store state"
mobilePermissionDescription MB_RELEASE_CREATE = "Create mobile release builds"
mobilePermissionDescription MB_RELEASE_PROMOTE = "Promote a built release to store review"
mobilePermissionDescription MB_RELEASE_ROLLOUT = "Manage staged rollout (set %, halt, resume, release)"
mobilePermissionDescription MB_RELEASE_REVERT = "Create mobile rollback builds"
mobilePermissionDescription MB_RELEASE_ABORT = "Cancel a running mobile build (aborts the GitHub job)"
mobilePermissionDescription MB_MOBILE_DISPATCH = "Dispatch mobile builds and OTA bundle pushes to GitHub Actions"
mobilePermissionDescription MB_MOBILE_APP_MANAGE = "Manage mobile app catalog (admin)"
mobilePermissionDescription MB_AI_SUMMARIZE = "Generate AI changelog summaries for mobile releases"

-- 'permissionName' MUST match 'mobilePermissionToText' for the same
-- constructor; the RBAC check compares this string against the DB.

instance KnownPermission 'MB_RELEASE_VIEW where
    permissionProduct _ = "mobile"
    permissionName _ = "MB_RELEASE_VIEW"

instance KnownPermission 'MB_RELEASE_CREATE where
    permissionProduct _ = "mobile"
    permissionName _ = "MB_RELEASE_CREATE"

instance KnownPermission 'MB_RELEASE_PROMOTE where
    permissionProduct _ = "mobile"
    permissionName _ = "MB_RELEASE_PROMOTE"

instance KnownPermission 'MB_RELEASE_ROLLOUT where
    permissionProduct _ = "mobile"
    permissionName _ = "MB_RELEASE_ROLLOUT"

instance KnownPermission 'MB_RELEASE_REVERT where
    permissionProduct _ = "mobile"
    permissionName _ = "MB_RELEASE_REVERT"

instance KnownPermission 'MB_RELEASE_ABORT where
    permissionProduct _ = "mobile"
    permissionName _ = "MB_RELEASE_ABORT"

instance KnownPermission 'MB_MOBILE_DISPATCH where
    permissionProduct _ = "mobile"
    permissionName _ = "MB_MOBILE_DISPATCH"

instance KnownPermission 'MB_MOBILE_APP_MANAGE where
    permissionProduct _ = "mobile"
    permissionName _ = "MB_MOBILE_APP_MANAGE"

instance KnownPermission 'MB_AI_SUMMARIZE where
    permissionProduct _ = "mobile"
    permissionName _ = "MB_AI_SUMMARIZE"
