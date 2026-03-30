{-# LANGUAGE OverloadedStrings #-}

-- | ConfigManager product permissions
--
-- All permissions for the ConfigManager product as a type-safe ADT.
module NammaAP.Products.ConfigManager.Types.Permission
  ( ConfigManagerPermission (..)
  , configManagerPermissionToText
  , textToConfigManagerPermission
  , cmPermissionDescription
  ) where

import Data.Text (Text)

data ConfigManagerPermission
  = CM_CONFIG_VIEW
  | CM_CONFIG_CREATE
  | CM_CONFIG_APPLY
  | CM_CONFIG_ROLLBACK
  | CM_CONFIG_UPDATE
  deriving (Show, Read, Eq, Ord, Enum, Bounded)

configManagerPermissionToText :: ConfigManagerPermission -> Text
configManagerPermissionToText CM_CONFIG_VIEW = "CONFIG_VIEW"
configManagerPermissionToText CM_CONFIG_CREATE = "CONFIG_CREATE"
configManagerPermissionToText CM_CONFIG_APPLY = "CONFIG_APPLY"
configManagerPermissionToText CM_CONFIG_ROLLBACK = "CONFIG_ROLLBACK"
configManagerPermissionToText CM_CONFIG_UPDATE = "CONFIG_UPDATE"

textToConfigManagerPermission :: Text -> Maybe ConfigManagerPermission
textToConfigManagerPermission "CONFIG_VIEW" = Just CM_CONFIG_VIEW
textToConfigManagerPermission "CONFIG_CREATE" = Just CM_CONFIG_CREATE
textToConfigManagerPermission "CONFIG_APPLY" = Just CM_CONFIG_APPLY
textToConfigManagerPermission "CONFIG_ROLLBACK" = Just CM_CONFIG_ROLLBACK
textToConfigManagerPermission "CONFIG_UPDATE" = Just CM_CONFIG_UPDATE
textToConfigManagerPermission _ = Nothing

-- | Human-readable description of each permission.
cmPermissionDescription :: ConfigManagerPermission -> Text
cmPermissionDescription CM_CONFIG_VIEW = "View configuration entries"
cmPermissionDescription CM_CONFIG_CREATE = "Create new configuration entries"
cmPermissionDescription CM_CONFIG_APPLY = "Apply configuration changes"
cmPermissionDescription CM_CONFIG_ROLLBACK = "Rollback configuration changes"
cmPermissionDescription CM_CONFIG_UPDATE = "Update existing configuration entries"
