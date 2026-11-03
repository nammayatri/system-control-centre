{-# LANGUAGE OverloadedStrings #-}

{- | The decisions of the capacity scaler as pure functions: what capacity change a schedule needs given the
live target, whether a guardrail allows it, how to find, pin and put back the autoscaler's minimum, and how
to validate an edit of the autoscaler's own settings. The worker and the API only carry these decisions
out, so everything that can go wrong in the logic can be tested without a cloud.
-}
module Products.Autopilot.Scaler.Logic (
    -- * Capacity
    CapacityPlan (..),
    planIsNoop,
    planCapacity,
    describePlan,
    capacityReached,
    instanceBusy,
    shrinkPlan,

    -- * The autoscaler's entry
    entryFor,
    readMinimum,
    PinResult (..),
    pinMinimum,
    RestoreMin (..),
    restoreMinimum,

    -- * Editing it
    EditReq (..),
    editableKeys,
    KeyKind (..),
    applyEdit,
    validateRules,

    -- * Job payload encoding
    decodeJobData,
    encodeJobData,
)
where

import Data.Aeson (Value (..))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Base64 qualified as B64
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (toList)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Products.Autopilot.Scaler.Types

-- ---------------------------------------------------------------------------
-- Capacity

-- | What still has to be changed on the target. @Nothing@ = already enough.
data CapacityPlan = CapacityPlan
    { cpUnits :: Maybe Int
    , cpReplicas :: Maybe Int
    }
    deriving (Eq, Show)

planIsNoop :: CapacityPlan -> Bool
planIsNoop p = cpUnits p == Nothing && cpReplicas p == Nothing

describePlan :: InstanceMode -> CapacityPlan -> Text
describePlan mode p
    | planIsNoop p = "no capacity change needed"
    | otherwise =
        T.intercalate ", " $
            [ unitWord mode <> " -> " <> T.pack (show n) | Just n <- [cpUnits p] ]
                <> [ "replicas -> " <> T.pack (show n) | Just n <- [cpReplicas p] ]

unitWord :: InstanceMode -> Text
unitWord ModeReadPool = "nodes"
unitWord _ = "shards"

{- | Work out the capacity change from the LIVE instance and apply the guardrail. Capacity only goes up;
a target at or below the current value is a no-op rather than a shrink. A refused plan is a list of
reasons, each of which can be shown to the user as is.
-}
planCapacity :: Guardrail -> InstanceState -> ScaleChange -> Either [Text] CapacityPlan
planCapacity g st c
    | grFrozen g = Left ["changes are frozen" <> maybe "" (": " <>) (grFrozenReason g)]
    | not (null issues) = Left issues
    | otherwise = Right (CapacityPlan unitsPlan replicasPlan)
  where
    mode = isMode st
    unitCap = maybe (unitsHardCap mode) (min (unitsHardCap mode)) (grMaxUnits g)
    replicaCap = maybe maxReplicasHardCap (min maxReplicasHardCap) (grMaxReplicas g)
    wantUnits = case mode of
        ModeStandalone -> Nothing
        _ -> scUnits c
    wantReplicas = case mode of
        ModeReadPool -> Nothing
        _ -> scReplicas c
    unitsPlan = case wantUnits of
        Just t | t > isUnits st -> Just t
        _ -> Nothing
    replicasPlan = case wantReplicas of
        Just t | t > isReplicas st -> Just t
        _ -> Nothing
    word = unitWord mode
    issues =
        [ "target of " <> tshow t <> " " <> word <> " is above the limit of " <> tshow unitCap | Just t <- [wantUnits], t > unitCap ]
            <> [ "adding " <> tshow (t - isUnits st) <> " " <> word <> " at once is above the step limit of " <> tshow s
               | Just t <- [wantUnits]
               , Just s <- [grMaxStep g]
               , t > isUnits st
               , t - isUnits st > s
               ]
            <> [ "target of " <> tshow t <> " replicas is above the limit of " <> tshow replicaCap | Just t <- [wantReplicas], t > replicaCap ]
    tshow = T.pack . show

{- | Is the target idle and at or above the requested capacity? Only then is the change complete; while a
resize runs the state is not idle.
-}
capacityReached :: InstanceState -> ScaleChange -> Bool
capacityReached st c =
    not (instanceBusy st)
        && maybe True (<= isUnits st) wantUnits
        && maybe True (<= isReplicas st) wantReplicas
  where
    wantUnits = case isMode st of
        ModeStandalone -> Nothing
        _ -> scUnits c
    wantReplicas = case isMode st of
        ModeReadPool -> Nothing
        _ -> scReplicas c

-- | Memorystore accepts a resize only when @ACTIVE@, AlloyDB only when @READY@.
instanceBusy :: InstanceState -> Bool
instanceBusy st = isState st `notElem` ["ACTIVE", "READY"]

{- | The change that undoes a capacity increase at the end of a window (opt-in). It only returns something
while the target still holds what WE set, so a resize made by someone or something else in the meantime is
never undone.
-}
shrinkPlan :: InstanceState -> ScaleSnapshot -> ScaleAfter -> CapacityPlan
shrinkPlan st before after = CapacityPlan unitsBack replicasBack
  where
    unitsBack = case (isMode st, saTargetUnits after) of
        (ModeStandalone, _) -> Nothing
        (_, Just t) | isUnits st == t, ssUnits before < t -> Just (ssUnits before)
        _ -> Nothing
    replicasBack = case (isMode st, saTargetReplicas after) of
        (ModeReadPool, _) -> Nothing
        (_, Just t) | isReplicas st == t, ssReplicas before < t -> Just (ssReplicas before)
        _ -> Nothing

-- ---------------------------------------------------------------------------
-- The autoscaler's entry

field :: A.Object -> Text -> Maybe Text
field o k = case KM.lookup (K.fromText k) o of
    Just (String t) -> Just t
    _ -> Nothing

matches :: AutoscalerKeys -> A.Object -> Bool
matches keys o =
    all (\(k, v) -> field o k == Just v) (akRequired keys)
        && all (\(k, v) -> maybe True (== v) (field o k)) (akOptional keys)

describeRequired :: AutoscalerKeys -> Text
describeRequired keys = T.intercalate ", " [k <> "=" <> v | (k, v) <- akRequired keys]

{- | The autoscaler reads its settings from the payload of a Cloud Scheduler job: one JSON object, or an array
of them. Find the entry for this target, and refuse to touch one that is for another.
-}
findEntry :: AutoscalerKeys -> Value -> Either Text A.Object
findEntry keys (Object o)
    | matches keys o = Right o
    | otherwise = Left ("the autoscaler config is not for this target (expected " <> describeRequired keys <> ")")
findEntry keys (Array a) = case [o | Object o <- toList a, matches keys o] of
    [o] -> Right o
    [] -> Left ("the autoscaler config has no entry for " <> describeRequired keys)
    _ -> Left ("the autoscaler config has more than one entry for " <> describeRequired keys)
findEntry _ _ = Left "the autoscaler config is not a JSON object"

-- | The target's config entry as a JSON value.
entryFor :: AutoscalerKeys -> Value -> Either Text Value
entryFor keys v = Object <$> findEntry keys v

readInt :: Value -> Maybe Int
readInt v = case A.fromJSON v of
    A.Success n -> Just n
    A.Error _ -> Nothing

readMinimum :: AutoscalerKeys -> Value -> Either Text Int
readMinimum keys v = do
    o <- findEntry keys v
    maybe (Left ("the autoscaler config has no whole-number " <> akMinKey keys)) Right (KM.lookup (K.fromText (akMinKey keys)) o >>= readInt)

-- | Replace the target's entry, wherever it sits in the payload.
replaceEntry :: AutoscalerKeys -> A.Object -> Value -> Either Text Value
replaceEntry keys new v = do
    _ <- findEntry keys v
    pure (go v)
  where
    go (Object _) = Object new
    go (Array a) = Array (fmap fixOne a)
    go other = other
    fixOne (Object o) | matches keys o = Object new
    fixOne other = other

setKey :: AutoscalerKeys -> Text -> Value -> Value -> Either Text Value
setKey keys k val v = do
    o <- findEntry keys v
    replaceEntry keys (KM.insert (K.fromText k) val o) v

data PinResult
    = -- | The minimum is already at or above the target; nothing to write.
      AlreadyHeld Int
    | -- | The previous minimum and the payload to write.
      Pin Int Value
    deriving (Eq, Show)

-- | Raise the minimum to @target@ (never lower it).
pinMinimum :: AutoscalerKeys -> Int -> Value -> Either Text PinResult
pinMinimum keys target v = do
    cur <- readMinimum keys v
    if cur >= target
        then Right (AlreadyHeld cur)
        else Pin cur <$> setKey keys (akMinKey keys) (A.toJSON target) v

data RestoreMin
    = -- | Write this payload: it puts the original minimum back.
      RestoreWrite Value
    | -- | The minimum already is the original value.
      RestoreAlready
    | -- | Someone changed the minimum after we pinned it; leave it alone (the value found).
      RestoreDrifted Int
    deriving (Eq, Show)

{- | Put the original minimum back, but only if it still holds the value we pinned. A value anyone else has
set since is theirs.
-}
restoreMinimum :: AutoscalerKeys -> Int -> Int -> Value -> Either Text RestoreMin
restoreMinimum keys pinned original v = do
    cur <- readMinimum keys v
    if cur == original
        then Right RestoreAlready
        else
            if cur == pinned
                then RestoreWrite <$> setKey keys (akMinKey keys) (A.toJSON original) v
                else Right (RestoreDrifted cur)

-- ---------------------------------------------------------------------------
-- Editing the autoscaler's settings

data KeyKind
    = -- | A whole number in this inclusive range.
      KInt Int Int
    | -- | One of these strings.
      KEnum [Text]
    deriving (Eq, Show)

{- | The settings of an entry that can be changed from the console, per kind of target. Anything else (the
topics, the state database, the identity of the cluster) is deliberately not editable here.
-}
editableKeys :: TargetKind -> [(Text, KeyKind)]
editableKeys KindRedis =
    [ ("minSize", KInt 1 250)
    , ("maxSize", KInt 1 250)
    , ("scaleOutLimit", KInt 1 250)
    , ("scaleInLimit", KInt 1 250)
    , ("scaleOutCoolingMinutes", KInt 0 1440)
    , ("scaleInCoolingMinutes", KInt 0 1440)
    , ("minFreeMemoryPercent", KInt 0 100)
    , ("scalingMethod", KEnum ["LINEAR", "STEPWISE", "DIRECT"])
    ]
editableKeys KindDb =
    [ ("minNodeCount", KInt 1 20)
    , ("maxNodeCount", KInt 1 20)
    , ("stepSize", KInt 1 20)
    , ("scaleOutCoolingMinutes", KInt 0 1440)
    , ("scaleInCoolingMinutes", KInt 0 1440)
    ]

-- | The settings to change and, optionally, the whole list of scaling rules to put in place.
data EditReq = EditReq
    { erSet :: [(Text, Value)]
    , erRules :: Maybe Value
    }
    deriving (Eq, Show)

operators :: [Text]
operators = ["equal", "notEqual", "lessThan", "lessThanInclusive", "greaterThan", "greaterThanInclusive"]

{- | A scaling rule is @{name, conditions: {any|all: [{fact, operator, value}]}, event: {type: OUT|IN, params}}@.
Checked structurally so a typo cannot silently disable scaling.
-}
validateRules :: Value -> [Text]
validateRules (Array rs)
    | V.null rs = ["there must be at least one scaling rule"]
    | otherwise = concat (zipWith ruleIssues [1 :: Int ..] (toList rs))
validateRules _ = ["scalingRules must be a list"]

ruleIssues :: Int -> Value -> [Text]
ruleIssues n (Object r) =
    [ lbl <> "has no name" | maybe True T.null (field r "name") ]
        <> condIssues
        <> eventIssues
  where
    lbl = "rule " <> T.pack (show n) <> " "
    condIssues = case KM.lookup "conditions" r of
        Just (Object c) -> case (KM.lookup "any" c, KM.lookup "all" c) of
            (Just (Array xs), Nothing) -> conds xs
            (Nothing, Just (Array xs)) -> conds xs
            _ -> [lbl <> "conditions must have exactly one of any / all, as a list"]
        _ -> [lbl <> "has no conditions"]
    conds xs
        | V.null xs = [lbl <> "has an empty condition list"]
        | otherwise = concatMap cond (toList xs)
    cond (Object c) =
        [ lbl <> "has a condition with no fact" | maybe True T.null (field c "fact") ]
            <> [ lbl <> "has an unknown operator" | maybe True (`notElem` operators) (field c "operator") ]
            <> [ lbl <> "has a condition whose value is not a number" | not (isNum (KM.lookup "value" c)) ]
    cond _ = [lbl <> "has a condition that is not an object"]
    isNum (Just (Number _)) = True
    isNum _ = False
    eventIssues = case KM.lookup "event" r of
        Just (Object e) ->
            [ lbl <> "event type must be OUT or IN" | maybe True (`notElem` ["OUT", "IN"]) (field e "type") ]
        _ -> [lbl <> "has no event"]
ruleIssues n _ = ["rule " <> T.pack (show n) <> " is not an object"]

{- | Apply an edit to the payload. Returns the new payload and the target's entry before and after, or every
problem found. Only whitelisted settings that already exist in the entry can be set; the entry's identity
is never touched.
-}
applyEdit :: AutoscalerKeys -> TargetKind -> EditReq -> Value -> Either [Text] (Value, Value, Value)
applyEdit keys kind req payload = do
    entry <- either (Left . pure) Right (findEntry keys payload)
    let allowed = editableKeys kind
        setIssues = concatMap (checkSet allowed entry) (erSet req)
        rulesIssues = maybe [] validateRules (erRules req)
        merged = foldl (\o (k, v) -> KM.insert (K.fromText k) v o) entry (erSet req)
        merged' = maybe merged (\r -> KM.insert "scalingRules" r merged) (erRules req)
        orderIssues = case (intAt merged' (akMinKey keys), intAt merged' (akMaxKey keys)) of
            (Just lo, Just hi) | lo > hi -> [akMinKey keys <> " must not exceed " <> akMaxKey keys]
            _ -> []
        problems = setIssues <> rulesIssues <> orderIssues
    if not (null problems)
        then Left problems
        else do
            new <- either (Left . pure) Right (replaceEntry keys merged' payload)
            pure (new, Object entry, Object merged')
  where
    intAt o k = KM.lookup (K.fromText k) o >>= readInt
    checkSet allowed entry (k, v) = case lookup k allowed of
        Nothing -> ["'" <> k <> "' cannot be changed here"]
        Just kk
            | not (KM.member (K.fromText k) entry) -> ["'" <> k <> "' is not part of this autoscaler's config"]
            | otherwise -> checkValue k kk v
    checkValue k (KInt lo hi) v = case readInt v of
        Just n | n >= lo && n <= hi -> []
        _ -> ["'" <> k <> "' must be a whole number from " <> T.pack (show lo) <> " to " <> T.pack (show hi)]
    checkValue k (KEnum opts) (String s)
        | s `elem` opts = []
        | otherwise = ["'" <> k <> "' must be one of " <> T.intercalate ", " opts]
    checkValue k (KEnum opts) _ = ["'" <> k <> "' must be one of " <> T.intercalate ", " opts]

-- ---------------------------------------------------------------------------
-- Job payload encoding

-- | The scheduler stores the payload as base64 text.
decodeJobData :: Text -> Either Text Value
decodeJobData t = do
    raw <- either (const (Left "the autoscaler job data is not valid base64")) Right (B64.decode (TE.encodeUtf8 (T.filter (not . (`elem` ("\n\r " :: String))) t)))
    either (\e -> Left ("the autoscaler job data is not valid JSON: " <> T.pack e)) Right (A.eitherDecodeStrict raw)

encodeJobData :: Value -> Text
encodeJobData = TE.decodeUtf8 . B64.encode . BL.toStrict . A.encode
