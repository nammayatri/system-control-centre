{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}

{- | Beam ORM mapping for the @app_catalog@ table — the catalog of mobile apps
releasable through SCC.
-}
module Products.Autopilot.Mobile.Types.Storage (
    AppCatalogT (..),
    AppCatalog,
    AppCatalogId,
    appCatalog,
) where

import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Database.Beam
import GHC.Int (Int32)

data AppCatalogT f = AppCatalog
    { acId :: Columnar f Int32
    , acName :: Columnar f Text
    , acSurface :: Columnar f Text
    , acPlatform :: Columnar f Text
    , acGithubRepo :: Columnar f Text
    , acWorkflowPath :: Columnar f Text
    , acPackageName :: Columnar f (Maybe Text)
    , acDisplayLabel :: Columnar f (Maybe Text)
    , acEnabled :: Columnar f Bool
    , acCreatedAt :: Columnar f UTCTime
    }
    deriving (Generic, Beamable)

instance Table AppCatalogT where
    data PrimaryKey AppCatalogT f = AppCatalogId (Columnar f Int32)
        deriving (Generic, Beamable)
    primaryKey = AppCatalogId . acId

type AppCatalog = AppCatalogT Identity
type AppCatalogId = PrimaryKey AppCatalogT Identity

deriving instance Show AppCatalog
deriving instance Eq AppCatalog

appCatalog :: EntityModification (DatabaseEntity be db) be (TableEntity AppCatalogT)
appCatalog =
    setEntityName "app_catalog"
        <> modifyTableFields
            tableModification
                { acId = fieldNamed "id"
                , acName = fieldNamed "name"
                , acSurface = fieldNamed "surface"
                , acPlatform = fieldNamed "platform"
                , acGithubRepo = fieldNamed "github_repo"
                , acWorkflowPath = fieldNamed "workflow_path"
                , acPackageName = fieldNamed "package_name"
                , acDisplayLabel = fieldNamed "display_label"
                , acEnabled = fieldNamed "enabled"
                , acCreatedAt = fieldNamed "created_at"
                }
