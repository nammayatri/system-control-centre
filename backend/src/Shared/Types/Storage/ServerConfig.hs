{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}

{- | Cross-product @server_config@ table.

This table holds runtime feature flags and tunables that can be either
global (@product IS NULL@) or scoped to a specific product (@product = 'x'@).
It is consumed by Autopilot today and will be consumed by additional
products (Config Manager, future products) tomorrow, which is why the type
and its Beam binding live under @Shared.*@ rather than inside any product
module (task #30 — tightening the product-boundary refactor).

Beam's 'Database' constraint requires every 'TableEntity' to be owned by a
single 'DatabaseSettings' value, so @server_config@ gets its own
'ServerConfigDb' instead of being bolted onto 'AutopilotDb'. Both settings
values point at the same Postgres database — they are just separate Beam
/views/ of disjoint sets of tables, which is the idiomatic way to split
tables across modules.
-}
module Shared.Types.Storage.ServerConfig where

import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Database.Beam
import GHC.Int (Int32)

{- | Row in the @server_config@ table.

@scProduct@ is 'Nothing' for global flags and @'Just' "autopilot"@ (etc.)
for product-scoped flags. Lookups should prefer product-scoped rows and
fall back to global rows — see "Shared.Queries.ServerConfig".
-}
data ServerConfigT f = ServerConfigT
    { scId :: Columnar f Int32
    , scType :: Columnar f Text
    , scName :: Columnar f Text
    , scValue :: Columnar f Text
    , scLastUpdated :: Columnar f UTCTime
    , scEnabled :: Columnar f Int32
    , scProduct :: Columnar f (Maybe Text)
    }
    deriving (Generic, Beamable)

type ServerConfig = ServerConfigT Identity

deriving instance Show ServerConfig

instance Table ServerConfigT where
    data PrimaryKey ServerConfigT f = ServerConfigId (Columnar f Int32) deriving (Generic, Beamable)
    primaryKey = ServerConfigId . scId

{- | Beam database containing just the cross-product @server_config@ table.
Separate from 'Products.Autopilot.Types.Storage.Schema.AutopilotDb' because
a single 'DatabaseSettings' value owns its tables exclusively.
-}
newtype ServerConfigDb f = ServerConfigDb
    { serverConfigs :: f (TableEntity ServerConfigT)
    }
    deriving (Generic, Database be)

serverConfigDb :: DatabaseSettings be ServerConfigDb
serverConfigDb =
    defaultDbSettings
        `withDbModification` dbModification
            { serverConfigs =
                setEntityName "server_config"
                    <> modifyTableFields
                        tableModification
                            { scId = fieldNamed "id"
                            , scType = fieldNamed "type"
                            , scName = fieldNamed "name"
                            , scValue = fieldNamed "value"
                            , scLastUpdated = fieldNamed "last_updated"
                            , scEnabled = fieldNamed "enabled"
                            , scProduct = fieldNamed "product"
                            }
            }
