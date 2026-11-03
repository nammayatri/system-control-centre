{-# LANGUAGE OverloadedStrings #-}

{- | Domain types for the capacity scaler. A 'Target' is something registered in the console
(@redis_config@ or @db_config@): a Memorystore for Valkey instance or an AlloyDB read pool. A
'ScaleChange' is what a schedule asks of it, 'InstanceState' is what it looks like now, and
'ScaleSnapshot' / 'ScaleAfter' are what the apply ledger remembers.

Three modes exist, and each scales by one thing:

* 'ModeCluster' (Valkey @CLUSTER@): shard count, optionally replicas too.
* 'ModeStandalone' (Valkey @CLUSTER_DISABLED@): always one shard, so replica count.
* 'ModeReadPool' (AlloyDB read pool): node count.
-}
module Products.Autopilot.Scaler.Types (
    TargetKind (..),
    targetKindText,
    parseTargetKind,
    Target (..),
    jobLocationOf,
    InstanceMode (..),
    instanceModeText,
    parseInstanceMode,
    modeKind,
    InstanceState (..),
    ScaleChange (..),
    validateChange,
    unitsHardCap,
    maxReplicasHardCap,
    Guardrail (..),
    defaultGuardrail,
    ScaleSnapshot (..),
    ScaleAfter (..),
    emptyAfter,
    AutoscalerKeys (..),
    autoscalerKeys,
)
where

import Data.Aeson (FromJSON (..), ToJSON (..), (.!=), (.:), (.:?), (.=))
import Data.Aeson qualified as A
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime)

-- ---------------------------------------------------------------------------
-- Targets

data TargetKind = KindRedis | KindDb
    deriving (Eq, Show)

targetKindText :: TargetKind -> Text
targetKindText KindRedis = "REDIS"
targetKindText KindDb = "DB"

parseTargetKind :: Text -> Maybe TargetKind
parseTargetKind "REDIS" = Just KindRedis
parseTargetKind "DB" = Just KindDb
parseTargetKind _ = Nothing

instance ToJSON TargetKind where
    toJSON = A.String . targetKindText

instance FromJSON TargetKind where
    parseJSON = A.withText "TargetKind" $ \t -> maybe (fail ("unknown target kind: " <> T.unpack t)) pure (parseTargetKind t)

{- | A registered target. @tgParent@ is the AlloyDB cluster (Valkey has none); @tgResource@ is the
Memorystore instance id or the AlloyDB read-pool instance id. The autoscaler job is optional: a target
without one can still be scheduled, it just cannot have its scale-in blocked or its autoscaler edited.
-}
data Target = Target
    { tgId :: Text
    , tgKind :: TargetKind
    , tgName :: Text
    , tgProject :: Text
    , tgLocation :: Text
    , tgParent :: Maybe Text
    , tgResource :: Text
    , tgJob :: Maybe Text
    , tgJobLocation :: Maybe Text
    }
    deriving (Eq, Show)

-- | Cloud Scheduler jobs live in their own region; default to the target's.
jobLocationOf :: Target -> Text
jobLocationOf t = maybe (tgLocation t) id (tgJobLocation t)

instance ToJSON Target where
    toJSON t =
        A.object
            [ "id" .= tgId t
            , "kind" .= tgKind t
            , "name" .= tgName t
            , "project" .= tgProject t
            , "location" .= tgLocation t
            , "parent" .= tgParent t
            , "resource" .= tgResource t
            , "autoscalerJob" .= tgJob t
            , "autoscalerLocation" .= tgJobLocation t
            ]

-- ---------------------------------------------------------------------------
-- Instance

data InstanceMode = ModeCluster | ModeStandalone | ModeReadPool
    deriving (Eq, Show)

instanceModeText :: InstanceMode -> Text
instanceModeText ModeCluster = "CLUSTER"
instanceModeText ModeStandalone = "CLUSTER_DISABLED"
instanceModeText ModeReadPool = "READ_POOL"

parseInstanceMode :: Text -> Maybe InstanceMode
parseInstanceMode "CLUSTER" = Just ModeCluster
parseInstanceMode "CLUSTER_DISABLED" = Just ModeStandalone
parseInstanceMode "READ_POOL" = Just ModeReadPool
parseInstanceMode _ = Nothing

-- | Which kind of target a mode belongs to.
modeKind :: InstanceMode -> TargetKind
modeKind ModeReadPool = KindDb
modeKind _ = KindRedis

instance ToJSON InstanceMode where
    toJSON = A.String . instanceModeText

{- | What the instance reports right now. @isUnits@ is the shard count (cluster), 1 (standalone) or
the node count (read pool). @isState@ is the API's state text; only @ACTIVE@ (Memorystore) or
@READY@ (AlloyDB) accepts a resize.
-}
data InstanceState = InstanceState
    { isMode :: InstanceMode
    , isState :: Text
    , isUnits :: Int
    , isReplicas :: Int
    }
    deriving (Eq, Show)

instance ToJSON InstanceState where
    toJSON s =
        A.object
            [ "mode" .= isMode s
            , "state" .= isState s
            , "units" .= isUnits s
            , "replicas" .= isReplicas s
            ]

-- ---------------------------------------------------------------------------
-- Change

{- | What a schedule (or a manual apply) asks for. Capacity only ever goes UP at the start of a window:
a target at or below the current value changes nothing. Whether capacity is shrunk back at the end is
opt-in ('scShrinkOnEnd'); by default the target keeps what it has and the autoscaler decides later.

'scBlockScaleIn' pins the autoscaler's minimum at the target for the window so it cannot scale in; the
original minimum is put back at the end, but only if nobody changed it since. It needs the target to have
an autoscaler job, and is not available for a standalone instance (no autoscaler manages replicas).
-}
data ScaleChange = ScaleChange
    { scUnits :: Maybe Int
    , scReplicas :: Maybe Int
    , scBlockScaleIn :: Bool
    , scShrinkOnEnd :: Bool
    }
    deriving (Eq, Show)

instance ToJSON ScaleChange where
    toJSON c =
        A.object $
            maybe [] (\x -> ["units" .= x]) (scUnits c)
                <> maybe [] (\x -> ["replicas" .= x]) (scReplicas c)
                <> ["blockScaleIn" .= scBlockScaleIn c, "shrinkOnEnd" .= scShrinkOnEnd c]

instance FromJSON ScaleChange where
    parseJSON = A.withObject "ScaleChange" $ \o ->
        ScaleChange
            <$> o .:? "units"
            <*> o .:? "replicas"
            <*> o .:? "blockScaleIn" .!= False
            <*> o .:? "shrinkOnEnd" .!= False

-- | Largest unit / replica counts the scaler will ever request, whatever a guardrail says.
unitsHardCap :: InstanceMode -> Int
unitsHardCap ModeReadPool = 20
unitsHardCap _ = 250

maxReplicasHardCap :: Int
maxReplicasHardCap = 5

-- | Structural checks against the instance mode; does not look at the live instance.
validateChange :: InstanceMode -> ScaleChange -> [Text]
validateChange mode c = case mode of
    ModeCluster ->
        [ "shards is required for a cluster-mode instance" | scUnits c == Nothing ]
            <> unitIssues "shards"
            <> replicaIssues
    ModeStandalone ->
        [ "a standalone instance has exactly one shard; scale it with replicas" | maybe False (/= 1) (scUnits c) ]
            <> [ "replicas is required for a standalone instance" | scReplicas c == Nothing ]
            <> [ "blockScaleIn does not apply to a standalone instance (no autoscaler manages its replicas)" | scBlockScaleIn c ]
            <> replicaIssues
    ModeReadPool ->
        [ "nodes is required for a read pool" | scUnits c == Nothing ]
            <> unitIssues "nodes"
            <> [ "a read pool has no replicas setting; scale it with nodes" | scReplicas c /= Nothing ]
  where
    unitIssues label =
        [ label <> " must be 1.." <> T.pack (show (unitsHardCap mode)) | Just n <- [scUnits c], n < 1 || n > unitsHardCap mode ]
    replicaIssues =
        [ "replicas must be 0.." <> T.pack (show maxReplicasHardCap) | Just n <- [scReplicas c], n < 0 || n > maxReplicasHardCap ]

-- ---------------------------------------------------------------------------
-- Guardrail

data Guardrail = Guardrail
    { grMaxUnits :: Maybe Int
    , grMaxReplicas :: Maybe Int
    , grMaxStep :: Maybe Int
    -- ^ Largest increase in units one apply may request.
    , grFrozen :: Bool
    , grFrozenReason :: Maybe Text
    }
    deriving (Eq, Show)

defaultGuardrail :: Guardrail
defaultGuardrail = Guardrail Nothing Nothing Nothing False Nothing

instance ToJSON Guardrail where
    toJSON g =
        A.object
            [ "maxUnits" .= grMaxUnits g
            , "maxReplicas" .= grMaxReplicas g
            , "maxStep" .= grMaxStep g
            , "frozen" .= grFrozen g
            , "frozenReason" .= grFrozenReason g
            ]

instance FromJSON Guardrail where
    parseJSON = A.withObject "Guardrail" $ \o ->
        Guardrail
            <$> o .:? "maxUnits"
            <*> o .:? "maxReplicas"
            <*> o .:? "maxStep"
            <*> o .:? "frozen" .!= False
            <*> o .:? "frozenReason"

-- ---------------------------------------------------------------------------
-- What the ledger remembers

{- | The values to put back, captured once before the first change. @ssMinimum@ is the autoscaler's
minimum (@minSize@ / @minNodeCount@) at that moment; @Nothing@ when we never looked at it.
-}
data ScaleSnapshot = ScaleSnapshot
    { ssUnits :: Int
    , ssReplicas :: Int
    , ssMinimum :: Maybe Int
    }
    deriving (Eq, Show)

instance ToJSON ScaleSnapshot where
    toJSON s = A.object ["units" .= ssUnits s, "replicas" .= ssReplicas s, "minimum" .= ssMinimum s]

instance FromJSON ScaleSnapshot where
    parseJSON = A.withObject "ScaleSnapshot" $ \o ->
        ScaleSnapshot <$> o .: "units" <*> o .: "replicas" <*> o .:? "minimum"

{- | What we have done so far, rewritten whole after each side effect. Every step decides from the live
target first, so a lost write here only costs a repeat check, never a repeat change.

@saPinIntent@ is recorded BEFORE the autoscaler job is written, so a crash between the write and
'saPinned' still leaves a record that the value there is ours to put back.
-}
data ScaleAfter = ScaleAfter
    { saTargetUnits :: Maybe Int
    , saTargetReplicas :: Maybe Int
    , saPinIntent :: Maybe Int
    , saPinned :: Maybe Int
    , saOperation :: Maybe Text
    , saShrinkDeadline :: Maybe UTCTime
    }
    deriving (Eq, Show)

emptyAfter :: ScaleAfter
emptyAfter = ScaleAfter Nothing Nothing Nothing Nothing Nothing Nothing

instance ToJSON ScaleAfter where
    toJSON a =
        A.object
            [ "targetUnits" .= saTargetUnits a
            , "targetReplicas" .= saTargetReplicas a
            , "pinIntent" .= saPinIntent a
            , "pinned" .= saPinned a
            , "operation" .= saOperation a
            , "shrinkDeadline" .= saShrinkDeadline a
            ]

instance FromJSON ScaleAfter where
    parseJSON = A.withObject "ScaleAfter" $ \o ->
        ScaleAfter
            <$> o .:? "targetUnits"
            <*> o .:? "targetReplicas"
            <*> o .:? "pinIntent"
            <*> o .:? "pinned"
            <*> o .:? "operation"
            <*> o .:? "shrinkDeadline"

-- ---------------------------------------------------------------------------
-- The autoscaler's config entry

{- | How to find a target's entry in its autoscaler job's payload, and which keys hold its limits. The
payload is one JSON object or an array of them (one per managed target); an entry is ours when every
@akRequired@ pair matches, and any @akOptional@ pair that is present matches too (so an entry for the
same cluster name in another project or region is never mistaken for it).
-}
data AutoscalerKeys = AutoscalerKeys
    { akMinKey :: Text
    , akMaxKey :: Text
    , akRequired :: [(Text, Text)]
    , akOptional :: [(Text, Text)]
    }
    deriving (Eq, Show)

autoscalerKeys :: Target -> AutoscalerKeys
autoscalerKeys t = case tgKind t of
    KindRedis ->
        AutoscalerKeys "minSize" "maxSize" [("clusterId", tgResource t)] [("projectId", tgProject t), ("regionId", tgLocation t)]
    KindDb ->
        AutoscalerKeys
            "minNodeCount"
            "maxNodeCount"
            [("clusterId", maybe "" id (tgParent t)), ("readPoolId", tgResource t)]
            [("projectId", tgProject t), ("regionId", tgLocation t)]
