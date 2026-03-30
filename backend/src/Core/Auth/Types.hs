{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Core.Auth.Types
  ( AuthTokenInfo (..)
  , PersonAuth (..)
  , ProductAccess (..)
  , PermissionAction (..)
  , parsePermissionAction
  , PersonProductPerms (..)
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Data.UUID (UUID)
import GHC.Generics (Generic)

-- | All permission actions across products
data PermissionAction
  = RELEASE_VIEW
  | RELEASE_CREATE
  | RELEASE_APPROVE
  | RELEASE_REVERT
  | RELEASE_DISCARD
  | RELEASE_PAUSE
  | RELEASE_RESUME
  | RELEASE_ABORT
  | RELEASE_UPDATE
  | MANAGE_STAGGER
  | PRODUCT_CONFIG_VIEW
  | PRODUCT_CONFIG_EDIT
  | SERVICE_CONFIG_VIEW
  | SERVICE_CONFIG_EDIT
  | CONFIG_VIEW
  | CONFIG_CREATE
  | CONFIG_APPLY
  | CONFIG_ROLLBACK
  | CONFIG_UPDATE
  deriving (Show, Read, Eq, Ord, Enum, Bounded, Generic)

instance ToJSON PermissionAction
instance FromJSON PermissionAction

parsePermissionAction :: Text -> Maybe PermissionAction
parsePermissionAction "RELEASE_VIEW" = Just RELEASE_VIEW
parsePermissionAction "RELEASE_CREATE" = Just RELEASE_CREATE
parsePermissionAction "RELEASE_APPROVE" = Just RELEASE_APPROVE
parsePermissionAction "RELEASE_REVERT" = Just RELEASE_REVERT
parsePermissionAction "RELEASE_DISCARD" = Just RELEASE_DISCARD
parsePermissionAction "RELEASE_PAUSE" = Just RELEASE_PAUSE
parsePermissionAction "RELEASE_RESUME" = Just RELEASE_RESUME
parsePermissionAction "RELEASE_ABORT" = Just RELEASE_ABORT
parsePermissionAction "RELEASE_UPDATE" = Just RELEASE_UPDATE
parsePermissionAction "MANAGE_STAGGER" = Just MANAGE_STAGGER
parsePermissionAction "PRODUCT_CONFIG_VIEW" = Just PRODUCT_CONFIG_VIEW
parsePermissionAction "PRODUCT_CONFIG_EDIT" = Just PRODUCT_CONFIG_EDIT
parsePermissionAction "SERVICE_CONFIG_VIEW" = Just SERVICE_CONFIG_VIEW
parsePermissionAction "SERVICE_CONFIG_EDIT" = Just SERVICE_CONFIG_EDIT
parsePermissionAction "CONFIG_VIEW" = Just CONFIG_VIEW
parsePermissionAction "CONFIG_CREATE" = Just CONFIG_CREATE
parsePermissionAction "CONFIG_APPLY" = Just CONFIG_APPLY
parsePermissionAction "CONFIG_ROLLBACK" = Just CONFIG_ROLLBACK
parsePermissionAction "CONFIG_UPDATE" = Just CONFIG_UPDATE
parsePermissionAction _ = Nothing

-- | Person record from sc_person
data PersonAuth = PersonAuth
  { personId :: UUID
  , personEmail :: Text
  , personFirstName :: Text
  , personLastName :: Text
  , personPasswordHash :: Text
  , personIsActive :: Bool
  , personIsSuperadmin :: Bool
  , personCreatedAt :: UTCTime
  , personUpdatedAt :: UTCTime
  } deriving (Show, Generic)

instance ToJSON PersonAuth
instance FromJSON PersonAuth

-- | Product access for a person
data ProductAccess = ProductAccess
  { paProductSlug :: Text
  , paProductName :: Text
  , paRoleId :: UUID
  , paRoleName :: Text
  } deriving (Show, Generic)

instance ToJSON ProductAccess
instance FromJSON ProductAccess

-- | Token info passed to handlers after auth validation
data AuthTokenInfo = AuthTokenInfo
  { atiPersonId :: UUID
  , atiEmail :: Text
  , atiFirstName :: Text
  , atiLastName :: Text
  , atiIsSuperadmin :: Bool
  , atiProducts :: [PersonProductPerms]
  } deriving (Show, Generic)

instance ToJSON AuthTokenInfo
instance FromJSON AuthTokenInfo

-- | Per-product permissions for a person
data PersonProductPerms = PersonProductPerms
  { pppProductSlug :: Text
  , pppRoleName :: Text
  , pppPermissions :: [Text]
  } deriving (Show, Generic)

instance ToJSON PersonProductPerms
instance FromJSON PersonProductPerms
