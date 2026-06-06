{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Autopilot permissions as a promoted ADT. Each constructor is also a
-- type (DataKinds) consumed by the 'Protected' Servant combinator; the
-- 'KnownPermission' instances bridge each type back to its runtime
-- @(product, action)@ pair used by the RBAC check.
module Products.Autopilot.Types.Permission
  ( AutopilotPermission (..),
    autopilotPermissionToText,
    textToAutopilotPermission,
    permissionDescription,
  )
where

import Core.Auth.Permission (KnownPermission (..))
import Data.Text (Text)

data AutopilotPermission
  = AP_RELEASE_VIEW
  | AP_RELEASE_CREATE
  | AP_RELEASE_APPROVE
  | AP_RELEASE_REVERT
  | AP_RELEASE_DISCARD
  | AP_RELEASE_PAUSE
  | AP_RELEASE_RESUME
  | AP_RELEASE_ABORT
  | AP_RELEASE_UPDATE
  | AP_RELEASE_DELETE
  | AP_MANAGE_STAGGER
  | AP_PRODUCT_CONFIG_VIEW
  | AP_PRODUCT_CONFIG_EDIT
  | AP_SERVICE_CONFIG_VIEW
  | AP_SERVICE_CONFIG_EDIT
  | AP_CONFIG_EDIT
  | AP_CONFIG_DISCARD
  | AP_CONFIG_REVERT
  | AP_FORCE_UNLOCK
  | AP_MOBILE_DISPATCH
  | AP_MOBILE_APP_MANAGE
  | AP_AB_VALIDATION_EDIT
  deriving (Show, Read, Eq, Ord, Enum, Bounded)

autopilotPermissionToText :: AutopilotPermission -> Text
autopilotPermissionToText AP_RELEASE_VIEW = "RELEASE_VIEW"
autopilotPermissionToText AP_RELEASE_CREATE = "RELEASE_CREATE"
autopilotPermissionToText AP_RELEASE_APPROVE = "RELEASE_APPROVE"
autopilotPermissionToText AP_RELEASE_REVERT = "RELEASE_REVERT"
autopilotPermissionToText AP_RELEASE_DISCARD = "RELEASE_DISCARD"
autopilotPermissionToText AP_RELEASE_PAUSE = "RELEASE_PAUSE"
autopilotPermissionToText AP_RELEASE_RESUME = "RELEASE_RESUME"
autopilotPermissionToText AP_RELEASE_ABORT = "RELEASE_ABORT"
autopilotPermissionToText AP_RELEASE_UPDATE = "RELEASE_UPDATE"
autopilotPermissionToText AP_RELEASE_DELETE = "RELEASE_DELETE"
autopilotPermissionToText AP_MANAGE_STAGGER = "MANAGE_STAGGER"
autopilotPermissionToText AP_PRODUCT_CONFIG_VIEW = "PRODUCT_CONFIG_VIEW"
autopilotPermissionToText AP_PRODUCT_CONFIG_EDIT = "PRODUCT_CONFIG_EDIT"
autopilotPermissionToText AP_SERVICE_CONFIG_VIEW = "SERVICE_CONFIG_VIEW"
autopilotPermissionToText AP_SERVICE_CONFIG_EDIT = "SERVICE_CONFIG_EDIT"
autopilotPermissionToText AP_CONFIG_EDIT = "CONFIG_EDIT"
autopilotPermissionToText AP_CONFIG_DISCARD = "CONFIG_DISCARD"
autopilotPermissionToText AP_CONFIG_REVERT = "CONFIG_REVERT"
autopilotPermissionToText AP_FORCE_UNLOCK = "FORCE_UNLOCK"
autopilotPermissionToText AP_MOBILE_DISPATCH = "MOBILE_DISPATCH"
autopilotPermissionToText AP_MOBILE_APP_MANAGE = "MOBILE_APP_MANAGE"
autopilotPermissionToText AP_AB_VALIDATION_EDIT = "AB_VALIDATION_EDIT"

textToAutopilotPermission :: Text -> Maybe AutopilotPermission
textToAutopilotPermission "RELEASE_VIEW" = Just AP_RELEASE_VIEW
textToAutopilotPermission "RELEASE_CREATE" = Just AP_RELEASE_CREATE
textToAutopilotPermission "RELEASE_APPROVE" = Just AP_RELEASE_APPROVE
textToAutopilotPermission "RELEASE_REVERT" = Just AP_RELEASE_REVERT
textToAutopilotPermission "RELEASE_DISCARD" = Just AP_RELEASE_DISCARD
textToAutopilotPermission "RELEASE_PAUSE" = Just AP_RELEASE_PAUSE
textToAutopilotPermission "RELEASE_RESUME" = Just AP_RELEASE_RESUME
textToAutopilotPermission "RELEASE_ABORT" = Just AP_RELEASE_ABORT
textToAutopilotPermission "RELEASE_UPDATE" = Just AP_RELEASE_UPDATE
textToAutopilotPermission "RELEASE_DELETE" = Just AP_RELEASE_DELETE
textToAutopilotPermission "MANAGE_STAGGER" = Just AP_MANAGE_STAGGER
textToAutopilotPermission "PRODUCT_CONFIG_VIEW" = Just AP_PRODUCT_CONFIG_VIEW
textToAutopilotPermission "PRODUCT_CONFIG_EDIT" = Just AP_PRODUCT_CONFIG_EDIT
textToAutopilotPermission "SERVICE_CONFIG_VIEW" = Just AP_SERVICE_CONFIG_VIEW
textToAutopilotPermission "SERVICE_CONFIG_EDIT" = Just AP_SERVICE_CONFIG_EDIT
textToAutopilotPermission "CONFIG_EDIT" = Just AP_CONFIG_EDIT
textToAutopilotPermission "CONFIG_DISCARD" = Just AP_CONFIG_DISCARD
textToAutopilotPermission "CONFIG_REVERT" = Just AP_CONFIG_REVERT
textToAutopilotPermission "FORCE_UNLOCK" = Just AP_FORCE_UNLOCK
textToAutopilotPermission "MOBILE_DISPATCH" = Just AP_MOBILE_DISPATCH
textToAutopilotPermission "MOBILE_APP_MANAGE" = Just AP_MOBILE_APP_MANAGE
textToAutopilotPermission "AB_VALIDATION_EDIT" = Just AP_AB_VALIDATION_EDIT
textToAutopilotPermission _ = Nothing

-- | Human-readable description (exhaustive, -Wall catches missing variants).
permissionDescription :: AutopilotPermission -> Text
permissionDescription AP_RELEASE_VIEW = "View releases and events"
permissionDescription AP_RELEASE_CREATE = "Create new releases"
permissionDescription AP_RELEASE_APPROVE = "Approve releases for deployment"
permissionDescription AP_RELEASE_REVERT = "Revert completed releases"
permissionDescription AP_RELEASE_DISCARD = "Discard created releases"
permissionDescription AP_RELEASE_PAUSE = "Pause in-progress releases"
permissionDescription AP_RELEASE_RESUME = "Resume paused releases"
permissionDescription AP_RELEASE_ABORT = "Abort in-progress releases"
permissionDescription AP_RELEASE_UPDATE = "Update release metadata"
permissionDescription AP_RELEASE_DELETE = "Delete releases"
permissionDescription AP_MANAGE_STAGGER = "Manage rollout stagger configuration"
permissionDescription AP_PRODUCT_CONFIG_VIEW = "View product configurations"
permissionDescription AP_PRODUCT_CONFIG_EDIT = "Edit product configurations"
permissionDescription AP_SERVICE_CONFIG_VIEW = "View server configurations"
permissionDescription AP_SERVICE_CONFIG_EDIT = "Edit server configurations"
permissionDescription AP_CONFIG_EDIT = "Edit ConfigMap and VS edit releases"
permissionDescription AP_CONFIG_DISCARD = "Discard ConfigMap and VS edit releases"
permissionDescription AP_CONFIG_REVERT = "Revert ConfigMap releases"
permissionDescription AP_FORCE_UNLOCK = "Force-release a VS edit lock held by another user (operator recovery; superadmin only)"
permissionDescription AP_MOBILE_DISPATCH = "Dispatch mobile release to GitHub Actions"
permissionDescription AP_MOBILE_APP_MANAGE = "Manage mobile app catalog (admin)"
permissionDescription AP_AB_VALIDATION_EDIT = "Set AB validation status on completed releases"

-- 'permissionName' MUST match 'autopilotPermissionToText' for the same
-- constructor; the RBAC check compares this string against the DB.

instance KnownPermission 'AP_RELEASE_VIEW where
  permissionProduct _ = "autopilot"
  permissionName _ = "RELEASE_VIEW"

instance KnownPermission 'AP_RELEASE_CREATE where
  permissionProduct _ = "autopilot"
  permissionName _ = "RELEASE_CREATE"

instance KnownPermission 'AP_RELEASE_APPROVE where
  permissionProduct _ = "autopilot"
  permissionName _ = "RELEASE_APPROVE"

instance KnownPermission 'AP_RELEASE_REVERT where
  permissionProduct _ = "autopilot"
  permissionName _ = "RELEASE_REVERT"

instance KnownPermission 'AP_RELEASE_DISCARD where
  permissionProduct _ = "autopilot"
  permissionName _ = "RELEASE_DISCARD"

instance KnownPermission 'AP_RELEASE_PAUSE where
  permissionProduct _ = "autopilot"
  permissionName _ = "RELEASE_PAUSE"

instance KnownPermission 'AP_RELEASE_RESUME where
  permissionProduct _ = "autopilot"
  permissionName _ = "RELEASE_RESUME"

instance KnownPermission 'AP_RELEASE_ABORT where
  permissionProduct _ = "autopilot"
  permissionName _ = "RELEASE_ABORT"

instance KnownPermission 'AP_RELEASE_UPDATE where
  permissionProduct _ = "autopilot"
  permissionName _ = "RELEASE_UPDATE"

instance KnownPermission 'AP_RELEASE_DELETE where
  permissionProduct _ = "autopilot"
  permissionName _ = "RELEASE_DELETE"

instance KnownPermission 'AP_MANAGE_STAGGER where
  permissionProduct _ = "autopilot"
  permissionName _ = "MANAGE_STAGGER"

instance KnownPermission 'AP_PRODUCT_CONFIG_VIEW where
  permissionProduct _ = "autopilot"
  permissionName _ = "PRODUCT_CONFIG_VIEW"

instance KnownPermission 'AP_PRODUCT_CONFIG_EDIT where
  permissionProduct _ = "autopilot"
  permissionName _ = "PRODUCT_CONFIG_EDIT"

instance KnownPermission 'AP_SERVICE_CONFIG_VIEW where
  permissionProduct _ = "autopilot"
  permissionName _ = "SERVICE_CONFIG_VIEW"

instance KnownPermission 'AP_SERVICE_CONFIG_EDIT where
  permissionProduct _ = "autopilot"
  permissionName _ = "SERVICE_CONFIG_EDIT"

instance KnownPermission 'AP_CONFIG_EDIT where
  permissionProduct _ = "autopilot"
  permissionName _ = "CONFIG_EDIT"

instance KnownPermission 'AP_CONFIG_DISCARD where
  permissionProduct _ = "autopilot"
  permissionName _ = "CONFIG_DISCARD"

instance KnownPermission 'AP_CONFIG_REVERT where
  permissionProduct _ = "autopilot"
  permissionName _ = "CONFIG_REVERT"

instance KnownPermission 'AP_FORCE_UNLOCK where
  permissionProduct _ = "autopilot"
  permissionName _ = "FORCE_UNLOCK"

instance KnownPermission 'AP_MOBILE_DISPATCH where
  permissionProduct _ = "autopilot"
  permissionName _ = "MOBILE_DISPATCH"

instance KnownPermission 'AP_MOBILE_APP_MANAGE where
  permissionProduct _ = "autopilot"
  permissionName _ = "MOBILE_APP_MANAGE"

instance KnownPermission 'AP_AB_VALIDATION_EDIT where
  permissionProduct _ = "autopilot"
  permissionName _ = "AB_VALIDATION_EDIT"
