{-# LANGUAGE OverloadedStrings #-}

{- | Pure planning for HPA changes: turn an 'HpaChange' into a new spec, a
ready-to-@replace@ object, a restore plan, and a verification. No IO.

Design rules this module enforces:

* The new object is the /live object/ with only the touched fields edited, so
  every field we do not model (selectors, unknown metric types, future K8s
  fields) survives the round trip untouched.
* @spec.metrics@ is an array that a merge patch would replace wholesale, so
  we never address it by position or send a partial list: we edit entries in
  place by their 'metricKey' and send the whole object back (guarded by its
  @resourceVersion@).
* Restoring puts back only the fields that still hold the value we wrote.
  A field someone else changed in the meantime is left alone and reported.
-}
module Products.Autopilot.Hpa.Change (
    Field (..),
    FieldVal (..),
    fieldLabel,
    touchedFields,
    fieldValue,
    fieldMatches,
    applyChangeTyped,
    changeIsNoop,
    buildChangedObject,
    RestorePlan (..),
    planRestore,
    verifyApplied,
    ApplyAction (..),
    decideApplyAction,
    checkGuardrail,
    DiffEntry (..),
    jsonDiff,
    baseSpecJson,
    specHash,
    stripManagedAnnotations,
    managedAnnotationKeys,
)
where

import Control.Applicative ((<|>))
import Crypto.Hash (SHA256 (..), hashWith)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text.Encoding qualified as TE
import Data.Aeson (ToJSON (..), Value (..), (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Foldable (foldlM)
import Data.List (nub, sort)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Scientific (Scientific)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Products.Autopilot.Hpa.Quantity (qRaw)
import Products.Autopilot.Hpa.Spec
import Products.Autopilot.Hpa.Types

-- ---------------------------------------------------------------------------
-- Fields a change can touch

data Field
    = FMin
    | FMax
    | FMetric Text
    | FScaleUp
    | FScaleDown
    deriving (Eq, Show)

data FieldVal
    = VInt Int
    | VTarget (Maybe MetricTarget)
    | VRules (Maybe ScalingRules)
    deriving (Eq, Show)

fieldLabel :: Field -> Text
fieldLabel FMin = "minReplicas"
fieldLabel FMax = "maxReplicas"
fieldLabel (FMetric k) = "metric " <> k
fieldLabel FScaleUp = "behavior.scaleUp"
fieldLabel FScaleDown = "behavior.scaleDown"

touchedFields :: HpaChange -> [Field]
touchedFields c =
    [FMin | Just _ <- [chMinReplicas c]]
        <> [FMax | Just _ <- [chMaxReplicas c]]
        <> map (FMetric . mtcKey) (chMetricTargets c)
        <> [FScaleUp | Just _ <- [chScaleUp c]]
        <> [FScaleDown | Just _ <- [chScaleDown c]]

fieldValue :: Field -> HpaSpec -> FieldVal
fieldValue FMin s = VInt (hsMinReplicas s)
fieldValue FMax s = VInt (hsMaxReplicas s)
fieldValue (FMetric k) s = VTarget (metricTargetByKey k (hsMetrics s))
fieldValue FScaleUp s = VRules (hsBehavior s >>= bScaleUp)
fieldValue FScaleDown s = VRules (hsBehavior s >>= bScaleDown)

metricTarget :: MetricSpec -> Maybe MetricTarget
metricTarget m = case m of
    ResourceMetric _ t -> Just t
    ContainerResourceMetric _ _ t -> Just t
    PodsMetric _ t -> Just t
    ObjectMetric _ _ t -> Just t
    ExternalMetric _ t -> Just t
    UnknownMetric _ -> Nothing

withTarget :: MetricTarget -> MetricSpec -> MetricSpec
withTarget t m = case m of
    ResourceMetric r _ -> ResourceMetric r t
    ContainerResourceMetric c r _ -> ContainerResourceMetric c r t
    PodsMetric i _ -> PodsMetric i t
    ObjectMetric o i _ -> ObjectMetric o i t
    ExternalMetric i _ -> ExternalMetric i t
    UnknownMetric v -> UnknownMetric v

metricTargetByKey :: Text -> [MetricSpec] -> Maybe MetricTarget
metricTargetByKey k ms = case filter ((== k) . metricKey) ms of
    (m : _) -> metricTarget m
    [] -> Nothing

{- | Does the cluster's value satisfy the wanted one? Equal for numbers and targets. For
scaling rules the API server fills in defaults (selectPolicy, policies, stabilisation
windows), so a wanted rule is satisfied when every field WE specified matches; fields we
left out are the server's to default. Wanting no rules means the cluster has none.
-}
fieldMatches :: FieldVal -> FieldVal -> Bool
fieldMatches (VRules Nothing) (VRules Nothing) = True
fieldMatches (VRules (Just w)) (VRules (Just l)) =
    maybe True (\x -> Just x == srStabilizationWindowSeconds l) (srStabilizationWindowSeconds w)
        && maybe True (\x -> Just x == srSelectPolicy l) (srSelectPolicy w)
        && (null (srPolicies w) || srPolicies w == srPolicies l)
fieldMatches (VRules _) (VRules _) = False
fieldMatches want have = want == have

-- ---------------------------------------------------------------------------
-- Typed application

{- | The spec after the change, or every reason it cannot be applied. Fails on
an empty change, an unknown or duplicated metric key, or a result that
'validateSpec' rejects.
-}
applyChangeTyped :: HpaSpec -> HpaChange -> Either [Text] HpaSpec
applyChangeTyped spec ch
    | changeIsEmpty ch = Left ["the change is empty"]
    | length keys /= length (nub keys) = Left ["metricTargets lists the same metric key twice"]
    | otherwise = do
        metrics' <- foldlM setTarget (hsMetrics spec) (chMetricTargets ch)
        let spec' =
                spec
                    { hsMinReplicas = fromMaybe (hsMinReplicas spec) (chMinReplicas ch)
                    , hsMaxReplicas = fromMaybe (hsMaxReplicas spec) (chMaxReplicas ch)
                    , hsMetrics = metrics'
                    , hsBehavior = behavior'
                    }
        case validateSpec spec' of
            [] -> Right spec'
            es -> Left es
  where
    keys = map mtcKey (chMetricTargets ch)
    behavior' = case (chScaleUp ch, chScaleDown ch) of
        (Nothing, Nothing) -> hsBehavior spec
        (u, d) ->
            let Behavior ou od = fromMaybe (Behavior Nothing Nothing) (hsBehavior spec)
             in Just (Behavior (u <|> ou) (d <|> od))
    setTarget ms (MetricTargetChange k t) =
        case break ((== k) . metricKey) ms of
            (_, []) ->
                Left
                    [ "metric '"
                        <> k
                        <> "' not found on this HPA (it has: "
                        <> T.intercalate ", " (map metricKey ms)
                        <> ")"
                    ]
            (_, UnknownMetric _ : _) -> Left ["metric '" <> k <> "' has a type this tool cannot edit"]
            (pre, m : post) -> Right (pre <> [withTarget t m] <> post)

-- | True when applying the change would leave the spec unchanged.
changeIsNoop :: HpaSpec -> HpaChange -> Bool
changeIsNoop spec ch = applyChangeTyped spec ch == Right spec

-- ---------------------------------------------------------------------------
-- Raw object editing

alterObj :: Text -> (Maybe Value -> Maybe Value) -> Value -> Value
alterObj k f (Object o) =
    let key = K.fromText k
     in Object (maybe (KM.delete key o) (\v -> KM.insert key v o) (f (KM.lookup key o)))
alterObj _ _ v = v

setIn :: [Text] -> Value -> Value -> Value
setIn [] new _ = new
setIn (k : ks) new v = alterObj k (\m -> Just (setIn ks new (fromMaybe (Object KM.empty) m))) v

deleteIn :: [Text] -> Value -> Value
deleteIn [] v = v
deleteIn [k] v = alterObj k (const Nothing) v
deleteIn (k : ks) v = alterObj k (fmap (deleteIn ks)) v

getIn :: [Text] -> Value -> Maybe Value
getIn [] v = Just v
getIn (k : ks) (Object o) = KM.lookup (K.fromText k) o >>= getIn ks
getIn _ _ = Nothing

rawMetricKey :: Value -> Maybe Text
rawMetricKey v = case A.fromJSON v of
    A.Success m -> Just (metricKey m)
    A.Error _ -> Nothing

setRawTarget :: MetricTarget -> Value -> Value
setRawTarget t v = case getIn ["type"] v of
    Just (String ty) | Just k <- lookup ty typeKeys -> setIn [k, "target"] (toJSON t) v
    _ -> v
  where
    typeKeys =
        [ ("Resource", "resource")
        , ("ContainerResource", "containerResource")
        , ("Pods", "pods")
        , ("Object", "object")
        , ("External", "external")
        ]

-- | Write one field's value into the raw object. Metric fields that are absent are a no-op.
setFieldRaw :: Field -> FieldVal -> Value -> Value
setFieldRaw f val obj = case (f, val) of
    (FMin, VInt n) -> setIn ["spec", "minReplicas"] (toJSON n) obj
    (FMax, VInt n) -> setIn ["spec", "maxReplicas"] (toJSON n) obj
    (FMetric k, VTarget (Just t)) ->
        alterObj "spec" (fmap (alterObj "metrics" (fmap (mapMetrics k t)))) obj
    (FScaleUp, VRules r) -> setBehavior "scaleUp" r obj
    (FScaleDown, VRules r) -> setBehavior "scaleDown" r obj
    _ -> obj
  where
    mapMetrics k t (Array a) = Array (V.map (\m -> if rawMetricKey m == Just k then setRawTarget t m else m) a)
    mapMetrics _ _ other = other

{- | Set or clear one direction of @spec.behavior@. Clearing the last key also
removes an empty @behavior@ object so a restore leaves no trace.
-}
setBehavior :: Text -> Maybe ScalingRules -> Value -> Value
setBehavior dir (Just r) obj = setIn ["spec", "behavior", dir] (toJSON r) obj
setBehavior dir Nothing obj =
    let cleared = deleteIn ["spec", "behavior", dir] obj
     in case getIn ["spec", "behavior"] cleared of
            Just (Object o) | KM.null o -> deleteIn ["spec", "behavior"] cleared
            _ -> cleared

managedAnnotationKeys :: [Text]
managedAnnotationKeys = [annScheduleId, annApplyId, annBaseSpec]

stripManagedAnnotations :: Value -> Value
stripManagedAnnotations obj =
    let cleaned = foldr (\k -> deleteIn ["metadata", "annotations", k]) obj managedAnnotationKeys
     in case getIn ["metadata", "annotations"] cleaned of
            Just (Object o) | KM.null o -> deleteIn ["metadata", "annotations"] cleaned
            _ -> cleaned

-- | Server-owned noise that must not be sent back on a replace.
stripServerFields :: Value -> Value
stripServerFields = deleteIn ["status"] . deleteIn ["metadata", "managedFields"]

{- | The live object with the change applied and the given annotations set,
ready for @kubectl replace@. Keeps @metadata.resourceVersion@, so a concurrent
edit makes the replace fail with a conflict instead of being overwritten.
-}
buildChangedObject :: HpaObject -> HpaChange -> [(Text, Text)] -> Either [Text] Value
buildChangedObject h ch anns = do
    after <- applyChangeTyped (hoSpec h) ch
    let edited = foldl (\o f -> setFieldRaw f (fieldValue f after) o) (hoRaw h) (touchedFields ch)
        annotated = foldl (\o (k, v) -> setIn ["metadata", "annotations", k] (String v) o) edited anns
    pure (stripServerFields annotated)

-- ---------------------------------------------------------------------------
-- Restore

data Verdict = AlreadyOriginal | Restore | Drift

data RestorePlan = RestorePlan
    { rpObject :: Value
    -- ^ Live object with restorable fields put back and our annotations removed.
    , rpRestored :: [Text]
    , rpDrifted :: [Text]
    -- ^ Fields left alone because live no longer holds what we wrote.
    , rpAlreadyOriginal :: [Text]
    }
    deriving (Eq, Show)

{- | @planRestore before after change live@. Per touched field: live already
equals the original -> nothing to do; live equals what we wrote -> restore;
anything else was edited by someone else -> leave it and report drift.
-}
planRestore :: HpaSpec -> HpaSpec -> HpaChange -> HpaObject -> RestorePlan
planRestore before after ch live = RestorePlan obj restored drifted already
  where
    liveSpec = hoSpec live
    classify f =
        let lv = fieldValue f liveSpec
            bv = fieldValue f before
            av = fieldValue f after
         in if fieldMatches bv lv
                then (f, AlreadyOriginal)
                else
                    if fieldMatches av lv
                        then (f, Restore)
                        else (f, Drift)
    classified = map classify (touchedFields ch)
    toRestore = [f | (f, Restore) <- classified]
    restored = map fieldLabel toRestore
    drifted = [fieldLabel f | (f, Drift) <- classified]
    already = [fieldLabel f | (f, AlreadyOriginal) <- classified]
    edited = foldl (\o f -> setFieldRaw f (fieldValue f before) o) (hoRaw live) toRestore
    -- The server adds defaults for BOTH directions once any behavior exists. If the HPA had no
    -- behavior at all originally, put it back that way rather than leaving a defaulted block.
    behaviorTouched = any (`elem` toRestore) [FScaleUp, FScaleDown]
    cleaned = if behaviorTouched && hsBehavior before == Nothing then deleteIn ["spec", "behavior"] edited else edited
    obj = stripServerFields (stripManagedAnnotations cleaned)

-- | Mismatches between the intended spec and what the cluster now holds, on touched fields only.
verifyApplied :: HpaSpec -> HpaChange -> HpaSpec -> [Text]
verifyApplied intended ch live =
    [ fieldLabel f <> ": expected " <> render (fieldValue f intended) <> ", cluster has " <> render (fieldValue f live)
    | f <- touchedFields ch
    , not (fieldMatches (fieldValue f intended) (fieldValue f live))
    ]
  where
    render (VInt n) = T.pack (show n)
    render (VTarget Nothing) = "<absent>"
    render (VTarget (Just t)) = renderTarget t
    render (VRules Nothing) = "<none>"
    render (VRules (Just r)) = T.pack (take 160 (show r))
    renderTarget (Utilization n) = T.pack (show n) <> "%"
    renderTarget (AverageValue q) = "avg " <> qRaw q
    renderTarget (TargetValue q) = "value " <> qRaw q

data ApplyAction
    = -- | Every touched field already holds the intended value (a previous attempt got this far).
      AlreadyApplied
    | -- | Touched fields still hold their original values: send the change.
      NeedsPatch
    | -- | Some touched fields hold neither the original nor the intended value: someone else edited them.
      Diverged [Text]
    deriving (Eq, Show)

{- | What to do with an apply that may have been interrupted, decided from the
live spec and not from where the dead worker thought it was.
-}
decideApplyAction :: HpaSpec -> HpaSpec -> HpaChange -> HpaSpec -> ApplyAction
decideApplyAction before after ch live
    | not (null diverged) = Diverged (map fieldLabel diverged)
    | all (\f -> fieldMatches (fieldValue f after) (fieldValue f live)) fields = AlreadyApplied
    | otherwise = NeedsPatch
  where
    fields = touchedFields ch
    diverged = [f | f <- fields, not (fieldMatches (fieldValue f before) (fieldValue f live)), not (fieldMatches (fieldValue f after) (fieldValue f live))]

-- ---------------------------------------------------------------------------
-- Guardrails

{- | Reasons a change is refused for this service: frozen, above the replica
cap, below the floor, or a step larger than allowed relative to the current spec.
-}
checkGuardrail :: Guardrail -> HpaSpec -> HpaSpec -> [Text]
checkGuardrail g current after =
    concat
        [ ["service is frozen" <> maybe "" (": " <>) (grFrozenReason g) | grFrozen g, current /= after]
        , [ "maxReplicas " <> tshow (hsMaxReplicas after) <> " exceeds the cap of " <> tshow cap
          | Just cap <- [grMaxReplicasCap g]
          , hsMaxReplicas after > cap
          ]
        , [ "minReplicas " <> tshow (hsMinReplicas after) <> " is below the floor of " <> tshow fl
          | Just fl <- [grMinReplicasFloor g]
          , hsMinReplicas after < fl
          ]
        , stepIssues "minReplicas" (hsMinReplicas current) (hsMinReplicas after)
        , stepIssues "maxReplicas" (hsMaxReplicas current) (hsMaxReplicas after)
        ]
  where
    tshow :: Int -> Text
    tshow = T.pack . show
    stepIssues label cur new = case grMaxStepPct g of
        Just pct
            | cur > 0
            , abs (new - cur) * 100 > pct * cur ->
                [label <> " changes by " <> tshow (abs (new - cur) * 100 `div` cur) <> "% (limit " <> tshow pct <> "%)"]
        _ -> []

-- ---------------------------------------------------------------------------
-- Diff

data DiffEntry = DiffEntry
    { dePath :: Text
    , deOld :: Maybe Value
    , deNew :: Maybe Value
    }
    deriving (Eq, Show)

instance ToJSON DiffEntry where
    toJSON d = A.object ["path" .= dePath d, "old" .= deOld d, "new" .= deNew d]

-- | Structural diff. Arrays compare by index; objects by key (sorted).
jsonDiff :: Value -> Value -> [DiffEntry]
jsonDiff = go ""
  where
    go path (Object a) (Object b) =
        concat
            [ case (KM.lookup k a, KM.lookup k b) of
                (Just x, Just y) -> go (join' path (K.toText k)) x y
                (Just x, Nothing) -> [DiffEntry (join' path (K.toText k)) (Just x) Nothing]
                (Nothing, Just y) -> [DiffEntry (join' path (K.toText k)) Nothing (Just y)]
                (Nothing, Nothing) -> []
            | k <- sort (nub (KM.keys a <> KM.keys b))
            ]
    go path (Array a) (Array b) =
        let xs = V.toList a
            ys = V.toList b
            n = max (length xs) (length ys)
         in concat
                [ case (nth i xs, nth i ys) of
                    (Just x, Just y) -> go (path <> "[" <> T.pack (show i) <> "]") x y
                    (Just x, Nothing) -> [DiffEntry (path <> "[" <> T.pack (show i) <> "]") (Just x) Nothing]
                    (Nothing, Just y) -> [DiffEntry (path <> "[" <> T.pack (show i) <> "]") Nothing (Just y)]
                    (Nothing, Nothing) -> []
                | i <- [0 .. n - 1]
                ]
    go path x y
        | numEq x y || x == y = []
        | otherwise = [DiffEntry path (Just x) (Just y)]
    join' "" k = k
    join' p k = p <> "." <> k
    nth i xs = case drop i xs of (x : _) -> Just x; [] -> Nothing
    numEq (Number a) (Number b) = (a :: Scientific) == b
    numEq _ _ = False

-- ---------------------------------------------------------------------------
-- Base spec (for release cloning)

{- | The parts of @spec@ a schedule can change, as they were before the change.
Stored in an annotation so a release that clones this HPA copies the
baseline, not a temporary override.
-}
baseSpecJson :: HpaObject -> Value
baseSpecJson h =
    A.object $
        mapMaybe
            (\k -> (,) (K.fromText k) <$> getIn ["spec", k] (hoRaw h))
            ["minReplicas", "maxReplicas", "metrics", "behavior"]

{- | Stable fingerprint of a spec, to tell whether it changed between observations.
Computed from the canonical typed JSON, so a quantity written another way
(@0.5@ vs @500m@) still hashes by its spelling: that is a real edit to the object.
-}
specHash :: HpaSpec -> Text
specHash spec =
    let digest = hashWith SHA256 (LBS.toStrict (A.encode spec))
     in TE.decodeUtf8 (convertToBase Base16 digest :: BS.ByteString)
