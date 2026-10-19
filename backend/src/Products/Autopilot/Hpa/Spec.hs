{-# LANGUAGE OverloadedStrings #-}

{- | Typed model of an @autoscaling/v2@ HorizontalPodAutoscaler.

The typed view exists so we can validate and diff by meaning (a
@Utilization 70@ percentage vs an @AverageValue 500m@ quantity vs a
scale-rate @Percent@ policy are different types, not three integers). The
full live object is kept verbatim in 'hoRaw' so that fields we do not model
survive a read-modify-write untouched.
-}
module Products.Autopilot.Hpa.Spec (
    ResourceName (..),
    MetricTarget (..),
    MetricIdentifier (..),
    ObjectRef (..),
    MetricSpec (..),
    PolicyType (..),
    SelectPolicy (..),
    ScalingPolicy (..),
    ScalingRules (..),
    Behavior (..),
    ScaleTargetRef (..),
    HpaSpec (..),
    HpaCondition (..),
    HpaStatus (..),
    HpaObject (..),
    parseHpaObject,
    parseHpaList,
    metricKey,
    describeMetric,
    validateSpec,
    currentUtilization,
)
where

import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), (.:), (.:?), (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Products.Autopilot.Hpa.Quantity

-- ---------------------------------------------------------------------------
-- Metrics

data ResourceName = Cpu | Memory | OtherResource Text
    deriving (Eq, Show)

instance ToJSON ResourceName where
    toJSON Cpu = "cpu"
    toJSON Memory = "memory"
    toJSON (OtherResource t) = String t

instance FromJSON ResourceName where
    parseJSON = A.withText "ResourceName" $ \t -> pure $ case t of
        "cpu" -> Cpu
        "memory" -> Memory
        other -> OtherResource other

{- | What the metric is compared against. 'Utilization' is a percentage of the
pod's /request/ and is only meaningful for cpu/memory; 'AverageValue' is a
per-pod quantity; 'TargetValue' is a total quantity (Object/External only).
-}
data MetricTarget
    = Utilization Int
    | AverageValue Quantity
    | TargetValue Quantity
    deriving (Eq, Show)

instance ToJSON MetricTarget where
    toJSON (Utilization n) = A.object ["type" .= ("Utilization" :: Text), "averageUtilization" .= n]
    toJSON (AverageValue q) = A.object ["type" .= ("AverageValue" :: Text), "averageValue" .= q]
    toJSON (TargetValue q) = A.object ["type" .= ("Value" :: Text), "value" .= q]

instance FromJSON MetricTarget where
    parseJSON = A.withObject "MetricTarget" $ \o -> do
        ty <- o .: "type"
        case (ty :: Text) of
            "Utilization" -> Utilization <$> o .: "averageUtilization"
            "AverageValue" -> AverageValue <$> o .: "averageValue"
            "Value" -> TargetValue <$> o .: "value"
            other -> fail ("unknown metric target type: " <> T.unpack other)

data MetricIdentifier = MetricIdentifier
    { miName :: Text
    , miSelector :: Maybe Value
    }
    deriving (Eq, Show)

instance ToJSON MetricIdentifier where
    toJSON (MetricIdentifier n s) = A.object (["name" .= n] <> maybe [] (\v -> ["selector" .= v]) s)

instance FromJSON MetricIdentifier where
    parseJSON = A.withObject "MetricIdentifier" $ \o ->
        MetricIdentifier <$> o .: "name" <*> o .:? "selector"

data ObjectRef = ObjectRef
    { orKind :: Text
    , orName :: Text
    }
    deriving (Eq, Show)

instance ToJSON ObjectRef where
    toJSON (ObjectRef k n) = A.object ["kind" .= k, "name" .= n]

instance FromJSON ObjectRef where
    parseJSON = A.withObject "ObjectRef" $ \o -> ObjectRef <$> o .: "kind" <*> o .: "name"

{- | One entry of @spec.metrics@. The HPA computes a desired replica count per
entry and takes the max, so this is always a list, never "the" metric.
'UnknownMetric' keeps any type we do not model verbatim.
-}
data MetricSpec
    = ResourceMetric ResourceName MetricTarget
    | ContainerResourceMetric Text ResourceName MetricTarget
    | PodsMetric MetricIdentifier MetricTarget
    | ObjectMetric ObjectRef MetricIdentifier MetricTarget
    | ExternalMetric MetricIdentifier MetricTarget
    | UnknownMetric Value
    deriving (Eq, Show)

instance ToJSON MetricSpec where
    toJSON (ResourceMetric r t) =
        A.object ["type" .= ("Resource" :: Text), "resource" .= A.object ["name" .= r, "target" .= t]]
    toJSON (ContainerResourceMetric c r t) =
        A.object ["type" .= ("ContainerResource" :: Text), "containerResource" .= A.object ["container" .= c, "name" .= r, "target" .= t]]
    toJSON (PodsMetric m t) =
        A.object ["type" .= ("Pods" :: Text), "pods" .= A.object ["metric" .= m, "target" .= t]]
    toJSON (ObjectMetric o m t) =
        A.object ["type" .= ("Object" :: Text), "object" .= A.object ["describedObject" .= o, "metric" .= m, "target" .= t]]
    toJSON (ExternalMetric m t) =
        A.object ["type" .= ("External" :: Text), "external" .= A.object ["metric" .= m, "target" .= t]]
    toJSON (UnknownMetric v) = v

instance FromJSON MetricSpec where
    parseJSON v = flip (A.withObject "MetricSpec") v $ \o -> do
        ty <- o .: "type"
        case (ty :: Text) of
            "Resource" -> do
                r <- o .: "resource"
                ResourceMetric <$> r .: "name" <*> r .: "target"
            "ContainerResource" -> do
                r <- o .: "containerResource"
                ContainerResourceMetric <$> r .: "container" <*> r .: "name" <*> r .: "target"
            "Pods" -> do
                p <- o .: "pods"
                PodsMetric <$> p .: "metric" <*> p .: "target"
            "Object" -> do
                ob <- o .: "object"
                ObjectMetric <$> ob .: "describedObject" <*> ob .: "metric" <*> ob .: "target"
            "External" -> do
                e <- o .: "external"
                ExternalMetric <$> e .: "metric" <*> e .: "target"
            _ -> pure (UnknownMetric v)

-- | Stable identity of a metric entry, used to address it in a patch.
metricKey :: MetricSpec -> Text
metricKey (ResourceMetric r _) = "resource/" <> resName r
metricKey (ContainerResourceMetric c r _) = "containerResource/" <> c <> "/" <> resName r
metricKey (PodsMetric m _) = "pods/" <> miName m
metricKey (ObjectMetric o m _) = "object/" <> orKind o <> "/" <> orName o <> "/" <> miName m
metricKey (ExternalMetric m _) = "external/" <> miName m
metricKey (UnknownMetric v) = "unknown/" <> T.pack (take 64 (show v))

resName :: ResourceName -> Text
resName Cpu = "cpu"
resName Memory = "memory"
resName (OtherResource t) = t

-- | Short human string for the UI, e.g. @cpu 70%@ or @memory avg 256Mi@.
describeMetric :: MetricSpec -> Text
describeMetric m = case m of
    ResourceMetric r t -> resName r <> " " <> tgt t
    ContainerResourceMetric c r t -> c <> "/" <> resName r <> " " <> tgt t
    PodsMetric mi t -> miName mi <> " " <> tgt t
    ObjectMetric o mi t -> orKind o <> "/" <> orName o <> " " <> miName mi <> " " <> tgt t
    ExternalMetric mi t -> miName mi <> " " <> tgt t
    UnknownMetric _ -> "unrecognised metric"
  where
    tgt (Utilization n) = T.pack (show n) <> "%"
    tgt (AverageValue q) = "avg " <> qRaw q
    tgt (TargetValue q) = "value " <> qRaw q

-- ---------------------------------------------------------------------------
-- Behavior

{- | Scale-rate policy unit. Deliberately NOT the same type as 'Utilization':
@Percent@ here means "change replica count by N% per period".
-}
data PolicyType = PolicyPods | PolicyPercent
    deriving (Eq, Show)

instance ToJSON PolicyType where
    toJSON PolicyPods = "Pods"
    toJSON PolicyPercent = "Percent"

instance FromJSON PolicyType where
    parseJSON = A.withText "PolicyType" $ \t -> case t of
        "Pods" -> pure PolicyPods
        "Percent" -> pure PolicyPercent
        other -> fail ("unknown scaling policy type: " <> T.unpack other)

data SelectPolicy = SelMax | SelMin | SelDisabled
    deriving (Eq, Show)

instance ToJSON SelectPolicy where
    toJSON SelMax = "Max"
    toJSON SelMin = "Min"
    toJSON SelDisabled = "Disabled"

instance FromJSON SelectPolicy where
    parseJSON = A.withText "SelectPolicy" $ \t -> case t of
        "Max" -> pure SelMax
        "Min" -> pure SelMin
        "Disabled" -> pure SelDisabled
        other -> fail ("unknown selectPolicy: " <> T.unpack other)

data ScalingPolicy = ScalingPolicy
    { spType :: PolicyType
    , spValue :: Int
    , spPeriodSeconds :: Int
    }
    deriving (Eq, Show)

instance ToJSON ScalingPolicy where
    toJSON (ScalingPolicy t v p) = A.object ["type" .= t, "value" .= v, "periodSeconds" .= p]

instance FromJSON ScalingPolicy where
    parseJSON = A.withObject "ScalingPolicy" $ \o ->
        ScalingPolicy <$> o .: "type" <*> o .: "value" <*> o .: "periodSeconds"

data ScalingRules = ScalingRules
    { srStabilizationWindowSeconds :: Maybe Int
    , srSelectPolicy :: Maybe SelectPolicy
    , srPolicies :: [ScalingPolicy]
    }
    deriving (Eq, Show)

instance ToJSON ScalingRules where
    toJSON (ScalingRules w s ps) =
        A.object $
            maybe [] (\x -> ["stabilizationWindowSeconds" .= x]) w
                <> maybe [] (\x -> ["selectPolicy" .= x]) s
                <> ["policies" .= ps | not (null ps)]

instance FromJSON ScalingRules where
    parseJSON = A.withObject "ScalingRules" $ \o ->
        ScalingRules
            <$> o .:? "stabilizationWindowSeconds"
            <*> o .:? "selectPolicy"
            <*> (fromMaybe [] <$> o .:? "policies")

data Behavior = Behavior
    { bScaleUp :: Maybe ScalingRules
    , bScaleDown :: Maybe ScalingRules
    }
    deriving (Eq, Show)

instance ToJSON Behavior where
    toJSON (Behavior u d) =
        A.object (maybe [] (\x -> ["scaleUp" .= x]) u <> maybe [] (\x -> ["scaleDown" .= x]) d)

instance FromJSON Behavior where
    parseJSON = A.withObject "Behavior" $ \o -> Behavior <$> o .:? "scaleUp" <*> o .:? "scaleDown"

-- ---------------------------------------------------------------------------
-- Spec / status / object

data ScaleTargetRef = ScaleTargetRef
    { strKind :: Text
    , strName :: Text
    }
    deriving (Eq, Show)

instance ToJSON ScaleTargetRef where
    toJSON (ScaleTargetRef k n) = A.object ["kind" .= k, "name" .= n]

instance FromJSON ScaleTargetRef where
    parseJSON = A.withObject "ScaleTargetRef" $ \o -> ScaleTargetRef <$> o .: "kind" <*> o .: "name"

data HpaSpec = HpaSpec
    { hsTarget :: ScaleTargetRef
    , hsMinReplicas :: Int
    , hsMaxReplicas :: Int
    , hsMetrics :: [MetricSpec]
    , hsBehavior :: Maybe Behavior
    }
    deriving (Eq, Show)

instance ToJSON HpaSpec where
    toJSON s =
        A.object $
            [ "scaleTargetRef" .= hsTarget s
            , "minReplicas" .= hsMinReplicas s
            , "maxReplicas" .= hsMaxReplicas s
            , "metrics" .= hsMetrics s
            ]
                <> maybe [] (\b -> ["behavior" .= b]) (hsBehavior s)

instance FromJSON HpaSpec where
    parseJSON = A.withObject "HpaSpec" $ \o ->
        HpaSpec
            <$> o .: "scaleTargetRef"
            -- K8s defaults an absent minReplicas to 1.
            <*> (fromMaybe 1 <$> o .:? "minReplicas")
            <*> o .: "maxReplicas"
            <*> (fromMaybe [] <$> o .:? "metrics")
            <*> o .:? "behavior"

data HpaCondition = HpaCondition
    { hcType :: Text
    , hcStatus :: Text
    , hcReason :: Maybe Text
    , hcMessage :: Maybe Text
    }
    deriving (Eq, Show)

instance ToJSON HpaCondition where
    toJSON c = A.object ["type" .= hcType c, "status" .= hcStatus c, "reason" .= hcReason c, "message" .= hcMessage c]

instance FromJSON HpaCondition where
    parseJSON = A.withObject "HpaCondition" $ \o ->
        HpaCondition <$> o .: "type" <*> o .: "status" <*> o .:? "reason" <*> o .:? "message"

data HpaStatus = HpaStatus
    { hstCurrentReplicas :: Int
    , hstDesiredReplicas :: Int
    , hstLastScaleTime :: Maybe Text
    , hstConditions :: [HpaCondition]
    , hstCurrentMetrics :: Value
    }
    deriving (Eq, Show)

instance ToJSON HpaStatus where
    toJSON s =
        A.object
            [ "currentReplicas" .= hstCurrentReplicas s
            , "desiredReplicas" .= hstDesiredReplicas s
            , "lastScaleTime" .= hstLastScaleTime s
            , "conditions" .= hstConditions s
            , "currentMetrics" .= hstCurrentMetrics s
            ]

instance FromJSON HpaStatus where
    parseJSON = A.withObject "HpaStatus" $ \o ->
        HpaStatus
            <$> (fromMaybe 0 <$> o .:? "currentReplicas")
            <*> (fromMaybe 0 <$> o .:? "desiredReplicas")
            <*> o .:? "lastScaleTime"
            <*> (fromMaybe [] <$> o .:? "conditions")
            <*> (fromMaybe Null <$> o .:? "currentMetrics")

data HpaObject = HpaObject
    { hoName :: Text
    , hoNamespace :: Text
    , hoResourceVersion :: Text
    , hoAnnotations :: [(Text, Text)]
    , hoSpec :: HpaSpec
    , hoStatus :: HpaStatus
    , hoKedaManaged :: Bool
    -- ^ KEDA owns and reconciles this HPA; editing it would be reverted.
    , hoLegacyV1 :: Bool
    -- ^ Came back in @autoscaling/v1@ shape (no @spec.metrics@). We refuse to edit these.
    , hoRaw :: Value
    -- ^ Complete live object, for lossless read-modify-write.
    }
    deriving (Eq, Show)

-- | Parse one HPA item. A malformed HPA yields @Left@ so it never poisons a whole listing.
parseHpaObject :: Value -> Either Text HpaObject
parseHpaObject raw = either (Left . T.pack) Right (parseEither go raw)
  where
    go :: Value -> Parser HpaObject
    go = A.withObject "HPA" $ \o -> do
        meta <- o .: "metadata"
        name <- meta .: "name"
        ns <- fromMaybe "" <$> meta .:? "namespace"
        rv <- fromMaybe "" <$> meta .:? "resourceVersion"
        anns <- fromMaybe KM.empty <$> meta .:? "annotations" :: Parser (KM.KeyMap Value)
        labels <- fromMaybe KM.empty <$> meta .:? "labels" :: Parser (KM.KeyMap Value)
        owners <- fromMaybe [] <$> meta .:? "ownerReferences" :: Parser [Value]
        specV <- o .: "spec"
        spec <- parseJSON specV
        status <- maybe (pure (HpaStatus 0 0 Nothing [] Null)) parseJSON =<< o .:? "status"
        let annPairs = [(k', v') | (k, String v') <- KM.toList anns, let k' = keyText k]
            hasKedaLabel = any (T.isInfixOf "keda.sh" . keyText) (KM.keys labels)
            ownedByKeda = any isScaledObject owners
            legacy = case specV of
                Object so -> not (KM.member "metrics" so) && KM.member "targetCPUUtilizationPercentage" so
                _ -> False
        pure
            HpaObject
                { hoName = name
                , hoNamespace = ns
                , hoResourceVersion = rv
                , hoAnnotations = annPairs
                , hoSpec = spec
                , hoStatus = status
                , hoKedaManaged = hasKedaLabel || ownedByKeda || "keda-hpa-" `T.isPrefixOf` name
                , hoLegacyV1 = legacy
                , hoRaw = raw
                }
    keyText = K.toText
    isScaledObject (Object ow) = KM.lookup "kind" ow == Just (String "ScaledObject")
    isScaledObject _ = False

{- | Parse the output of @kubectl get hpa -o json@ (a @List@). Returns the
parsed objects and a message per item that could not be parsed.
-}
parseHpaList :: Value -> ([HpaObject], [Text])
parseHpaList (Object o) = case KM.lookup "items" o of
    Just (Array items) -> foldr step ([], []) (V.toList items)
    _ -> ([], ["response had no items array"])
  where
    step item (oks, errs) = case parseHpaObject item of
        Right h -> (h : oks, errs)
        Left e -> (oks, e : errs)
parseHpaList _ = ([], ["response was not a JSON object"])

-- ---------------------------------------------------------------------------
-- Validation

{- | Rules the API server would reject anyway, plus a few it would accept but we
refuse to write. Returned as messages so the UI can show all of them at once.
-}
validateSpec :: HpaSpec -> [Text]
validateSpec s =
    concat
        [ [ "minReplicas must be >= 1 (scale-to-zero is not supported)" | hsMinReplicas s < 1 ]
        , [ "maxReplicas must be >= minReplicas" | hsMaxReplicas s < hsMinReplicas s ]
        , concatMap validateMetric (hsMetrics s)
        , maybe [] validateBehavior (hsBehavior s)
        ]

validateMetric :: MetricSpec -> [Text]
validateMetric m = case m of
    ResourceMetric r t -> resourceRules (resName r) t
    ContainerResourceMetric c r t -> resourceRules (c <> "/" <> resName r) t
    PodsMetric mi t -> case t of
        AverageValue q -> positive (miName mi) q
        Utilization _ -> [miName mi <> ": Utilization is only valid for cpu/memory"]
        TargetValue _ -> [miName mi <> ": Pods metrics take AverageValue, not Value"]
    ObjectMetric _ mi t -> notUtilization (miName mi) t
    ExternalMetric mi t -> notUtilization (miName mi) t
    UnknownMetric _ -> []
  where
    resourceRules label t = case t of
        Utilization n -> [label <> ": averageUtilization must be > 0" | n <= 0]
        AverageValue q -> positive label q
        TargetValue _ -> [label <> ": resource metrics take Utilization or AverageValue, not Value"]
    notUtilization label t = case t of
        Utilization _ -> [label <> ": Utilization is only valid for cpu/memory"]
        AverageValue q -> positive label q
        TargetValue q -> positive label q
    positive label q = [label <> ": target quantity must be > 0" | qMilli q <= 0]

validateBehavior :: Behavior -> [Text]
validateBehavior b = concatMap (maybe [] (validateRules "scaleUp")) [bScaleUp b] <> concatMap (maybe [] (validateRules "scaleDown")) [bScaleDown b]

validateRules :: Text -> ScalingRules -> [Text]
validateRules dir r =
    [ dir <> ": stabilizationWindowSeconds must be 0..3600" | Just w <- [srStabilizationWindowSeconds r], w < 0 || w > 3600 ]
        <> concatMap policy (srPolicies r)
  where
    policy p =
        [dir <> ": policy value must be > 0" | spValue p <= 0]
            <> [dir <> ": policy periodSeconds must be 1..1800" | spPeriodSeconds p < 1 || spPeriodSeconds p > 1800]

{- | The measured average utilisation (percent of request) of a resource from
@status.currentMetrics@; @Nothing@ when the HPA reports an absolute value instead.
-}
currentUtilization :: Text -> Value -> Maybe Double
currentUtilization name (Array ms) = case mapMaybe pick (V.toList ms) of
    (x : _) -> Just x
    [] -> Nothing
  where
    pick (Object m)
        | Just (String "Resource") <- KM.lookup "type" m
        , Just (Object r) <- KM.lookup "resource" m
        , Just (String n) <- KM.lookup "name" r
        , n == name
        , Just (Object cur) <- KM.lookup "current" r
        , Just (Number u) <- KM.lookup "averageUtilization" cur =
            Just (realToFrac u)
    pick _ = Nothing
currentUtilization _ _ = Nothing
