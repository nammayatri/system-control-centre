{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Core.Auth.Types
  ( AuthTokenInfo (..),
    PersonAuth (..),
    ProductAccess (..),
    DeploymentAccess (..),
    PersonProductPerms (..),
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Data.UUID (UUID)
import GHC.Generics (Generic)

-- | Person record from sc_person
data PersonAuth = PersonAuth
  { personId :: UUID,
    personEmail :: Text,
    personFirstName :: Text,
    personLastName :: Text,
    personPasswordHash :: Text,
    personIsActive :: Bool,
    personIsSuperadmin :: Bool,
    personCreatedAt :: UTCTime,
    personUpdatedAt :: UTCTime
  }
  deriving (Show, Generic)

instance ToJSON PersonAuth

instance FromJSON PersonAuth

-- | Product access for a person
data ProductAccess = ProductAccess
  { paProductSlug :: Text,
    paProductName :: Text,
    paRoleId :: UUID,
    paRoleName :: Text
  }
  deriving (Show, Generic)

instance ToJSON ProductAccess

instance FromJSON ProductAccess

data DeploymentAccess = DeploymentAccess
  { daProductSlug :: Text,
    daAppGroup :: Text,
    daRoleId :: UUID,
    daRoleName :: Text
  }
  deriving (Show, Generic)

instance ToJSON DeploymentAccess

instance FromJSON DeploymentAccess

-- | Token info passed to handlers after auth validation
data AuthTokenInfo = AuthTokenInfo
  { atiPersonId :: UUID,
    atiEmail :: Text,
    atiFirstName :: Text,
    atiLastName :: Text,
    atiIsSuperadmin :: Bool,
    atiProducts :: [PersonProductPerms]
  }
  deriving (Show, Generic)

instance ToJSON AuthTokenInfo

instance FromJSON AuthTokenInfo

-- | Per-product permissions for a person
data PersonProductPerms = PersonProductPerms
  { pppProductSlug :: Text,
    pppRoleName :: Text,
    pppPermissions :: [Text]
  }
  deriving (Show, Generic)

instance ToJSON PersonProductPerms

instance FromJSON PersonProductPerms
