{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Core.Admin.Types
  ( CreatePersonReq (..),
    UpdatePersonReq (..),
    AssignRoleReq (..),
    PermissionOverrideReq (..),
    CreateRoleReq (..),
    UpdateRoleReq (..),
    CreateProductReq (..),
    PersonDetail (..),
    RoleDetail (..),
    PermissionDetail (..),
    ProductDetail (..),
    OverrideDetail (..),
    DeploymentAccessDetail (..),
    DeploymentRosterEntry (..),
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Data.UUID (UUID)
import GHC.Generics (Generic)

data CreatePersonReq = CreatePersonReq
  { cprEmail :: Text,
    cprFirstName :: Text,
    cprLastName :: Text,
    cprPassword :: Text,
    cprIsSuperadmin :: Maybe Bool
  }
  deriving (Show, Generic)

instance FromJSON CreatePersonReq

instance ToJSON CreatePersonReq

data UpdatePersonReq = UpdatePersonReq
  { uprFirstName :: Maybe Text,
    uprLastName :: Maybe Text,
    uprIsActive :: Maybe Bool,
    uprIsSuperadmin :: Maybe Bool
  }
  deriving (Show, Generic)

instance FromJSON UpdatePersonReq

instance ToJSON UpdatePersonReq

data AssignRoleReq = AssignRoleReq
  { arProductSlug :: Text,
    arRoleId :: UUID
  }
  deriving (Show, Generic)

instance FromJSON AssignRoleReq

instance ToJSON AssignRoleReq

data PermissionOverrideReq = PermissionOverrideReq
  { porProductSlug :: Text,
    porPermissionAction :: Text,
    porOverrideType :: Text -- "GRANT" or "DENY"
  }
  deriving (Show, Generic)

instance FromJSON PermissionOverrideReq

instance ToJSON PermissionOverrideReq

data CreateRoleReq = CreateRoleReq
  { crrName :: Text,
    crrDescription :: Maybe Text,
    crrPermissionIds :: [UUID]
  }
  deriving (Show, Generic)

instance FromJSON CreateRoleReq

instance ToJSON CreateRoleReq

data UpdateRoleReq = UpdateRoleReq
  { urrDescription :: Maybe Text,
    urrPermissionIds :: [UUID]
  }
  deriving (Show, Generic)

instance FromJSON UpdateRoleReq

instance ToJSON UpdateRoleReq

data CreateProductReq = CreateProductReq
  { cpSlug :: Text,
    cpName :: Text,
    cpDescription :: Maybe Text
  }
  deriving (Show, Generic)

instance FromJSON CreateProductReq

instance ToJSON CreateProductReq

-- Response types

data PersonDetail = PersonDetail
  { pdId :: UUID,
    pdEmail :: Text,
    pdFirstName :: Text,
    pdLastName :: Text,
    pdIsActive :: Bool,
    pdIsSuperadmin :: Bool,
    pdCreatedAt :: UTCTime
  }
  deriving (Show, Generic)

instance ToJSON PersonDetail

data RoleDetail = RoleDetail
  { rdId :: UUID,
    rdName :: Text,
    rdDescription :: Maybe Text,
    rdIsSystemRole :: Bool,
    rdPermissions :: [Text]
  }
  deriving (Show, Generic)

instance ToJSON RoleDetail

data PermissionDetail = PermissionDetail
  { permId :: UUID,
    permAction :: Text,
    permDescription :: Maybe Text
  }
  deriving (Show, Generic)

instance ToJSON PermissionDetail

data ProductDetail = ProductDetail
  { prodId :: UUID,
    prodSlug :: Text,
    prodName :: Text,
    prodDescription :: Maybe Text,
    prodIsActive :: Bool
  }
  deriving (Show, Generic)

instance ToJSON ProductDetail

data OverrideDetail = OverrideDetail
  { odId :: UUID,
    odPermissionAction :: Text,
    odOverrideType :: Text,
    odProductSlug :: Text
  }
  deriving (Show, Generic)

instance ToJSON OverrideDetail

data DeploymentAccessDetail = DeploymentAccessDetail
  { ddId :: UUID,
    ddProductSlug :: Text,
    ddAppGroup :: Text,
    ddRoleId :: UUID,
    ddRoleName :: Text
  }
  deriving (Show, Generic)

instance ToJSON DeploymentAccessDetail

-- | One deployment-level grant, joined with the person and role it points at.
-- Powers the Access Control board's reverse lookup ("who has access to
-- deployment X"), which the per-user endpoints can't answer directly.
data DeploymentRosterEntry = DeploymentRosterEntry
  { drProductSlug :: Text,
    drAppGroup :: Text,
    drPersonId :: UUID,
    drFirstName :: Text,
    drLastName :: Text,
    drEmail :: Text,
    drRoleId :: UUID,
    drRoleName :: Text
  }
  deriving (Show, Generic)

instance ToJSON DeploymentRosterEntry
