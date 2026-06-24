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
    StoreStatusT (..),
    StoreStatus,
    storeStatus,
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
    , acFirebaseProjectId :: Columnar f (Maybe Text)
    , acEnabled :: Columnar f Bool
    , acStoreAccount :: Columnar f (Maybe Text)
    -- ^ Which App Store Connect account/team this app lives in. NULL = the default
    -- (unsuffixed) ASC key; a value (e.g. "cumta") selects @SC_ASC_*_<ACCOUNT>@. Lets
    -- one SCC instance read apps that span multiple Apple accounts.
    , acManagedPublishing :: Columnar f Bool
    -- ^ Whether this app uses Play Managed Publishing (Console-only setting, no API to
    -- detect — recorded explicitly, migration 0037). True ⇒ a promoted build stays
    -- STAGED on production until the operator clicks Publish, so the release summary
    -- shows the "Publish in Play Console" gate. False (provider/driver apps) ⇒ a rollout
    -- % applies immediately, so the rollout controls are shown directly.
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
                , acFirebaseProjectId = fieldNamed "firebase_project_id"
                , acEnabled = fieldNamed "enabled"
                , acStoreAccount = fieldNamed "store_account"
                , acManagedPublishing = fieldNamed "managed_publishing"
                , acCreatedAt = fieldNamed "created_at"
                }

{- | Per-track live store-state cache (migration 0030) behind the App Release
Monitoring dashboard. One row per (app_catalog_id, platform, track); written by
the StoreSync poller / on-demand refresh, read in a single query by the monitor.
-}
data StoreStatusT f = StoreStatus
    { ssAppCatalogId :: Columnar f Int32
    , ssPlatform :: Columnar f Text
    , ssTrack :: Columnar f Text
    , ssVersionName :: Columnar f (Maybe Text)
    , ssVersionCode :: Columnar f (Maybe Int32)
    , ssStatus :: Columnar f (Maybe Text)
    , ssRolloutPercent :: Columnar f (Maybe Double)
    , ssReviewStatus :: Columnar f (Maybe Text)
    , ssReleaseNotes :: Columnar f (Maybe Text)
    , ssExpectedVersion :: Columnar f (Maybe Text)
    , ssSyncedAt :: Columnar f UTCTime
    }
    deriving (Generic, Beamable)

instance Table StoreStatusT where
    -- Composite PK: (app_catalog_id, platform, track). app_catalog_id already
    -- determines platform, but the column mirrors the migration verbatim.
    data PrimaryKey StoreStatusT f
        = StoreStatusId (Columnar f Int32) (Columnar f Text) (Columnar f Text)
        deriving (Generic, Beamable)
    primaryKey s = StoreStatusId (ssAppCatalogId s) (ssPlatform s) (ssTrack s)

type StoreStatus = StoreStatusT Identity

deriving instance Show StoreStatus
deriving instance Eq StoreStatus

storeStatus :: EntityModification (DatabaseEntity be db) be (TableEntity StoreStatusT)
storeStatus =
    setEntityName "store_status"
        <> modifyTableFields
            tableModification
                { ssAppCatalogId = fieldNamed "app_catalog_id"
                , ssPlatform = fieldNamed "platform"
                , ssTrack = fieldNamed "track"
                , ssVersionName = fieldNamed "version_name"
                , ssVersionCode = fieldNamed "version_code"
                , ssStatus = fieldNamed "status"
                , ssRolloutPercent = fieldNamed "rollout_percent"
                , ssReviewStatus = fieldNamed "review_status"
                , ssReleaseNotes = fieldNamed "release_notes"
                , ssExpectedVersion = fieldNamed "expected_version"
                , ssSyncedAt = fieldNamed "synced_at"
                }
