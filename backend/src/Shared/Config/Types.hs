{-# LANGUAGE OverloadedStrings #-}

module Shared.Config.Types
  ( ConfigType (..)
  , ConfigGroup (..)
  , ConfigEntry (..)
  , configGroupToText
  , configTypeDefault
  , configTypeTag
  ) where

import Data.Text (Text)
import qualified Data.Text as T

data ConfigType
  = BoolConfig Bool        -- toggle
  | IntConfig Int          -- number
  | DoubleConfig Double    -- decimal
  | TextConfig Text        -- free text
  | JsonConfig Text        -- JSON string
  deriving (Show)

data ConfigGroup
  = GeneralGroup
  | DeploymentGroup
  | SyncGroup
  | MonitoringGroup
  | ScalingGroup
  | NotificationGroup
  | ABTestingGroup
  deriving (Show, Eq, Ord, Enum, Bounded)

configGroupToText :: ConfigGroup -> Text
configGroupToText GeneralGroup      = "General"
configGroupToText DeploymentGroup   = "Deployment"
configGroupToText SyncGroup         = "Sync"
configGroupToText MonitoringGroup   = "Monitoring"
configGroupToText ScalingGroup      = "Scaling"
configGroupToText NotificationGroup = "Notification"
configGroupToText ABTestingGroup    = "A/B Testing"

data ConfigEntry = ConfigEntry
  { ceKey         :: Text
  , ceType        :: ConfigType
  , ceGroup       :: ConfigGroup
  , ceDescription :: Text
  , ceProduct     :: Maybe Text  -- Nothing = global
  }

configTypeDefault :: ConfigType -> Text
configTypeDefault (BoolConfig b)   = if b then "true" else "false"
configTypeDefault (IntConfig i)    = T.pack (show i)
configTypeDefault (DoubleConfig d) = T.pack (show d)
configTypeDefault (TextConfig t)   = t
configTypeDefault (JsonConfig j)   = j

configTypeTag :: ConfigType -> Text
configTypeTag (BoolConfig _)   = "bool"
configTypeTag (IntConfig _)    = "int"
configTypeTag (DoubleConfig _) = "double"
configTypeTag (TextConfig _)   = "text"
configTypeTag (JsonConfig _)   = "json"
