{-# LANGUAGE OverloadedStrings #-}

-- | Autopilot product permissions
--
-- All permissions for the Autopilot product as a type-safe ADT.
-- Adding a new permission here without handling in permissionDescription
-- will cause a compiler warning with -Wall.
module NammaAP.Products.Autopilot.Types.Permission
  ( AutopilotPermission (..)
  , autopilotPermissionToText
  , textToAutopilotPermission
  , permissionDescription
  ) where

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
  | AP_MANAGE_STAGGER
  | AP_PRODUCT_CONFIG_VIEW
  | AP_PRODUCT_CONFIG_EDIT
  | AP_SERVICE_CONFIG_VIEW
  | AP_SERVICE_CONFIG_EDIT
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
autopilotPermissionToText AP_MANAGE_STAGGER = "MANAGE_STAGGER"
autopilotPermissionToText AP_PRODUCT_CONFIG_VIEW = "PRODUCT_CONFIG_VIEW"
autopilotPermissionToText AP_PRODUCT_CONFIG_EDIT = "PRODUCT_CONFIG_EDIT"
autopilotPermissionToText AP_SERVICE_CONFIG_VIEW = "SERVICE_CONFIG_VIEW"
autopilotPermissionToText AP_SERVICE_CONFIG_EDIT = "SERVICE_CONFIG_EDIT"

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
textToAutopilotPermission "MANAGE_STAGGER" = Just AP_MANAGE_STAGGER
textToAutopilotPermission "PRODUCT_CONFIG_VIEW" = Just AP_PRODUCT_CONFIG_VIEW
textToAutopilotPermission "PRODUCT_CONFIG_EDIT" = Just AP_PRODUCT_CONFIG_EDIT
textToAutopilotPermission "SERVICE_CONFIG_VIEW" = Just AP_SERVICE_CONFIG_VIEW
textToAutopilotPermission "SERVICE_CONFIG_EDIT" = Just AP_SERVICE_CONFIG_EDIT
textToAutopilotPermission _ = Nothing

-- | Human-readable description of each permission.
-- Exhaustive pattern match ensures compiler warns if a new permission is added.
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
permissionDescription AP_MANAGE_STAGGER = "Manage rollout stagger configuration"
permissionDescription AP_PRODUCT_CONFIG_VIEW = "View product configurations"
permissionDescription AP_PRODUCT_CONFIG_EDIT = "Edit product configurations"
permissionDescription AP_SERVICE_CONFIG_VIEW = "View server configurations"
permissionDescription AP_SERVICE_CONFIG_EDIT = "Edit server configurations"
