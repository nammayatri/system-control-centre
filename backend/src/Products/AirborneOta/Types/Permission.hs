{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Airborne OTA permissions as a promoted ADT (same shape as
Products.Autopilot.Types.Permission). Unlike autopilot, the wire name
keeps the full @OTA_@ prefix so the ADT constructor, sc_role seeds and
frontend permission strings are the identical spelling.
-}
module Products.AirborneOta.Types.Permission (
    OtaPermission (..),
    otaPermissionToText,
    textToOtaPermission,
    otaPermissionDescription,
)
where

import Core.Auth.Permission (KnownPermission (..))
import Data.Text (Text)

data OtaPermission
    = OTA_VIEW
    | OTA_RELEASE_CREATE
    | OTA_RELEASE_RAMP
    | OTA_RELEASE_CONCLUDE
    | OTA_RELEASE_DISCARD
    | OTA_PACKAGE_MANAGE
    | OTA_FILE_MANAGE
    | OTA_CONFIG_MANAGE
    | OTA_APP_MANAGE
    deriving (Show, Read, Eq, Ord, Enum, Bounded)

otaPermissionToText :: OtaPermission -> Text
otaPermissionToText OTA_VIEW = "OTA_VIEW"
otaPermissionToText OTA_RELEASE_CREATE = "OTA_RELEASE_CREATE"
otaPermissionToText OTA_RELEASE_RAMP = "OTA_RELEASE_RAMP"
otaPermissionToText OTA_RELEASE_CONCLUDE = "OTA_RELEASE_CONCLUDE"
otaPermissionToText OTA_RELEASE_DISCARD = "OTA_RELEASE_DISCARD"
otaPermissionToText OTA_PACKAGE_MANAGE = "OTA_PACKAGE_MANAGE"
otaPermissionToText OTA_FILE_MANAGE = "OTA_FILE_MANAGE"
otaPermissionToText OTA_CONFIG_MANAGE = "OTA_CONFIG_MANAGE"
otaPermissionToText OTA_APP_MANAGE = "OTA_APP_MANAGE"

textToOtaPermission :: Text -> Maybe OtaPermission
textToOtaPermission "OTA_VIEW" = Just OTA_VIEW
textToOtaPermission "OTA_RELEASE_CREATE" = Just OTA_RELEASE_CREATE
textToOtaPermission "OTA_RELEASE_RAMP" = Just OTA_RELEASE_RAMP
textToOtaPermission "OTA_RELEASE_CONCLUDE" = Just OTA_RELEASE_CONCLUDE
textToOtaPermission "OTA_RELEASE_DISCARD" = Just OTA_RELEASE_DISCARD
textToOtaPermission "OTA_PACKAGE_MANAGE" = Just OTA_PACKAGE_MANAGE
textToOtaPermission "OTA_FILE_MANAGE" = Just OTA_FILE_MANAGE
textToOtaPermission "OTA_CONFIG_MANAGE" = Just OTA_CONFIG_MANAGE
textToOtaPermission "OTA_APP_MANAGE" = Just OTA_APP_MANAGE
textToOtaPermission _ = Nothing

otaPermissionDescription :: OtaPermission -> Text
otaPermissionDescription OTA_VIEW = "View OTA apps, releases, packages and files"
otaPermissionDescription OTA_RELEASE_CREATE = "Create/edit/clone OTA releases"
otaPermissionDescription OTA_RELEASE_RAMP = "Ramp OTA release traffic percentage"
otaPermissionDescription OTA_RELEASE_CONCLUDE = "Conclude (or revert via control) an OTA release"
otaPermissionDescription OTA_RELEASE_DISCARD = "Discard an ongoing OTA release"
otaPermissionDescription OTA_PACKAGE_MANAGE = "Create OTA packages"
otaPermissionDescription OTA_FILE_MANAGE = "Register OTA files and edit file tags"
otaPermissionDescription OTA_CONFIG_MANAGE = "Manage properties schema, dimensions, cohorts and release views"
otaPermissionDescription OTA_APP_MANAGE = "Manage the airborne app mapping (admin)"

-- 'permissionName' MUST match 'otaPermissionToText' for the same
-- constructor; the RBAC check compares this string against the DB.

instance KnownPermission 'OTA_VIEW where
    permissionProduct _ = "airborne-ota"
    permissionName _ = "OTA_VIEW"

instance KnownPermission 'OTA_RELEASE_CREATE where
    permissionProduct _ = "airborne-ota"
    permissionName _ = "OTA_RELEASE_CREATE"

instance KnownPermission 'OTA_RELEASE_RAMP where
    permissionProduct _ = "airborne-ota"
    permissionName _ = "OTA_RELEASE_RAMP"

instance KnownPermission 'OTA_RELEASE_CONCLUDE where
    permissionProduct _ = "airborne-ota"
    permissionName _ = "OTA_RELEASE_CONCLUDE"

instance KnownPermission 'OTA_RELEASE_DISCARD where
    permissionProduct _ = "airborne-ota"
    permissionName _ = "OTA_RELEASE_DISCARD"

instance KnownPermission 'OTA_PACKAGE_MANAGE where
    permissionProduct _ = "airborne-ota"
    permissionName _ = "OTA_PACKAGE_MANAGE"

instance KnownPermission 'OTA_FILE_MANAGE where
    permissionProduct _ = "airborne-ota"
    permissionName _ = "OTA_FILE_MANAGE"

instance KnownPermission 'OTA_CONFIG_MANAGE where
    permissionProduct _ = "airborne-ota"
    permissionName _ = "OTA_CONFIG_MANAGE"

instance KnownPermission 'OTA_APP_MANAGE where
    permissionProduct _ = "airborne-ota"
    permissionName _ = "OTA_APP_MANAGE"
