{-# LANGUAGE OverloadedStrings #-}

{- | Which HPA is actually serving a service right now?

Autopilot creates one HPA per deployed version (@<serviceHost>-<version>-hpa@
targeting the @<serviceHost>-<version>@ Deployment), so during and after a
rollout a service can have several. The serving one is the HPA whose
version the VirtualService is sending traffic to. This is resolved at the
moment of use, never stored: a schedule names a service, not an HPA, so a
release that swaps versions does not strand it.

'classifyHpas' and 'subsetWeightsFromVs' are pure so the rules can be tested
without a cluster; 'resolveServiceHpas' is the thin kubectl wrapper.
-}
module Products.Autopilot.Hpa.Resolver (
    HpaRole (..),
    ResolvedHpa (..),
    Resolution (..),
    classifyHpas,
    editableReason,
    servingTargets,
    subsetWeightsFromVs,
    resolveServiceHpas,
    resolveServiceHpasWith,
)
where

import Core.Config (Config)
import Data.Aeson (ToJSON (..), Value (..), (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseMaybe)
import Data.List (foldl')
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Products.Autopilot.Hpa.Spec
import Products.Autopilot.Hpa.Kube (Kube, getVirtualService, kubeErrText, listHpas, mkKube)

data HpaRole
    = -- | Its version receives VirtualService traffic.
      RoleServing
    | -- | Its version is in the VirtualService with weight 0 (kept warm / draining).
      RoleDraining
    | -- | Its version is not in the VirtualService at all (orphan, or another service sharing the prefix).
      RoleUnrouted
    | -- | Traffic weights could not be read (no VS configured, e.g. a scheduler, or lookup failed).
      RoleUnknown
    deriving (Eq, Show)

instance ToJSON HpaRole where
    toJSON RoleServing = "SERVING"
    toJSON RoleDraining = "DRAINING"
    toJSON RoleUnrouted = "UNROUTED"
    toJSON RoleUnknown = "UNKNOWN"

data ResolvedHpa = ResolvedHpa
    { rhHpa :: HpaObject
    , rhVersion :: Text
    , rhTrafficWeight :: Maybe Int
    , rhRole :: HpaRole
    , rhEditableReason :: Maybe Text
    -- ^ @Nothing@ = safe for the scheduler to edit; otherwise why not.
    }
    deriving (Eq, Show)

instance ToJSON ResolvedHpa where
    toJSON r =
        A.object
            [ "name" .= hoName (rhHpa r)
            , "namespace" .= hoNamespace (rhHpa r)
            , "scaleTarget" .= hsTarget (hoSpec (rhHpa r))
            , "version" .= rhVersion r
            , "trafficWeight" .= rhTrafficWeight r
            , "role" .= rhRole r
            , "editable" .= (rhEditableReason r == Nothing)
            , "notEditableReason" .= rhEditableReason r
            , "spec" .= hoSpec (rhHpa r)
            , "status" .= hoStatus (rhHpa r)
            , "metricSummary" .= map describeMetric (hsMetrics (hoSpec (rhHpa r)))
            , "validationIssues" .= validateSpec (hoSpec (rhHpa r))
            , "annotations" .= A.object [K.fromText k .= v | (k, v) <- hoAnnotations (rhHpa r)]
            , "resourceVersion" .= hoResourceVersion (rhHpa r)
            ]

data Resolution = Resolution
    { resHpas :: [ResolvedHpa]
    , resServing :: [Text]
    -- ^ Names of the HPAs currently serving traffic (more than one when traffic is split).
    , resReason :: Text
    , resWarnings :: [Text]
    }
    deriving (Eq, Show)

instance ToJSON Resolution where
    toJSON r =
        A.object
            [ "hpas" .= resHpas r
            , "serving" .= resServing r
            , "reason" .= resReason r
            , "multipleHpas" .= (length (resHpas r) > 1)
            , "warnings" .= resWarnings r
            ]

{- | Pure core of resolution.

@otherHosts@ are the other configured service hosts in the same namespace: a
Deployment @foo-bar-v1@ has prefix @foo-@ but belongs to service @foo-bar@, so
HPAs claimed by a longer matching host are not ours.

@mWeights@ is @Nothing@ when the VirtualService could not be read.
-}
classifyHpas :: Text -> [Text] -> Maybe [(Text, Int)] -> [HpaObject] -> Resolution
classifyHpas svcHost otherHosts mWeights hpas =
    Resolution
        { resHpas = resolved
        , resServing = [hoName (rhHpa r) | r <- resolved, rhRole r == RoleServing]
        , resReason = reason
        , resWarnings = warnings
        }
  where
    prefix = svcHost <> "-"
    longerHosts = [h | h <- otherHosts, T.length h > T.length svcHost, prefix `T.isPrefixOf` h]
    -- An HPA targeting "<svcHost>-<rest>" is ours unless a longer host owns that prefix.
    ours h =
        let ScaleTargetRef kind tname = hsTarget (hoSpec h)
         in kind == "Deployment"
                && prefix `T.isPrefixOf` tname
                && not (any (\o -> (o <> "-") `T.isPrefixOf` tname) longerHosts)
    mine = filter ours hpas
    versionOf h = T.drop (T.length prefix) (strName (hsTarget (hoSpec h)))
    weightMap = fmap Map.fromList mWeights

    resolved = [mk h | h <- mine]
    mk h =
        let ver = versionOf h
            (weight, role) = case weightMap of
                Nothing -> (Nothing, RoleUnknown)
                Just wm -> case Map.lookup ver wm of
                    Just w | w > 0 -> (Just w, RoleServing)
                    Just w -> (Just w, RoleDraining)
                    Nothing -> (Nothing, RoleUnrouted)
         in ResolvedHpa
                { rhHpa = h
                , rhVersion = ver
                , rhTrafficWeight = weight
                , rhRole = role
                , rhEditableReason = editableReason h
                }

    servingVersions = [rhVersion r | r <- resolved, rhRole r == RoleServing]
    reason = case (mWeights, resolved) of
        (_, []) -> "No HPA targets a " <> svcHost <> "-<version> Deployment"
        (Nothing, _) -> "Traffic weights unavailable; cannot tell which HPA is serving"
        (Just _, _) -> case servingVersions of
            [] -> "No HPA matches a version that is receiving traffic"
            [v] -> "Serving version " <> v <> " (VirtualService weight)"
            vs -> "Traffic split across versions " <> T.intercalate ", " vs
    warnings =
        [ "Serving version(s) " <> T.intercalate ", " missing <> " have no HPA"
        | Just ws <- [mWeights]
        , let missing = [v | (v, w) <- ws, w > 0, v `notElem` map rhVersion resolved]
        , not (null missing)
        ]
            <> [ "Multiple HPAs serve traffic (" <> T.intercalate ", " (map (hoName . rhHpa) srv) <> "); a change would apply to all of them"
               | let srv = filter ((== RoleServing) . rhRole) resolved
               , length srv > 1
               ]

-- | @Nothing@ when the scheduler may edit this HPA; otherwise why it must not.
editableReason :: HpaObject -> Maybe Text
editableReason h
    | hoKedaManaged h = Just "Managed by KEDA; edits would be reverted by the ScaledObject"
    | hoLegacyV1 h = Just "Returned in autoscaling/v1 shape (no spec.metrics); refusing partial edits"
    | otherwise = Nothing

{- | The HPAs a schedule applies to: those serving traffic. When traffic weights are
unavailable (a scheduler without a VirtualService) and there is exactly one HPA, it
is the target; with several and no way to tell, none is, rather than guessing.
-}
servingTargets :: Resolution -> [ResolvedHpa]
servingTargets r = case filter ((== RoleServing) . rhRole) (resHpas r) of
    [] -> case resHpas r of
        [only] | rhRole only == RoleUnknown -> [only]
        _ -> []
    serving -> serving

{- | Per-subset traffic weight for @svcHost@ from a VirtualService document.
A subset appearing in several http rules takes its highest weight. A route
with a single destination and no weight is 100, per Istio semantics.
-}
subsetWeightsFromVs :: Text -> Value -> [(Text, Int)]
subsetWeightsFromVs svcHost (Object root) =
    Map.toList (foldl' (\m (s, w) -> Map.insertWith max s w m) Map.empty (concatMap rule rules))
  where
    rules = case KM.lookup "spec" root of
        Just (Object spec) -> case KM.lookup "http" spec of
            Just (Array a) -> V.toList a
            _ -> []
        _ -> []
    rule (Object r) = case KM.lookup "route" r of
        Just (Array routes) ->
            let rs = V.toList routes
                single = length rs == 1
             in mapMaybe (route single) rs
        _ -> []
    rule _ = []
    route single (Object ro) = do
        Object dest <- KM.lookup "destination" ro
        String host <- KM.lookup "host" dest
        String subset <- KM.lookup "subset" dest
        if hostEq host svcHost
            then
                let w = case KM.lookup "weight" ro >>= parseMaybe A.parseJSON of
                        Just n -> n
                        Nothing -> if single then 100 else 0
                 in Just (subset, w)
            else Nothing
    route _ _ = Nothing
    hostEq a b = a == b || T.takeWhile (/= '.') a == T.takeWhile (/= '.') b
subsetWeightsFromVs _ _ = []

{- | Fetch HPAs (always as @autoscaling/v2@) and the VirtualService, then classify.
A VirtualService failure degrades to 'RoleUnknown' with a warning rather than
failing the whole read; failing to list HPAs is an error.
-}
resolveServiceHpas :: Config -> Text -> Text -> Text -> [Text] -> IO (Either Text Resolution)
resolveServiceHpas cfg = resolveServiceHpasWith (mkKube cfg)

resolveServiceHpasWith :: Kube -> Text -> Text -> Text -> [Text] -> IO (Either Text Resolution)
resolveServiceHpasWith kube ns vsName svcHost otherHosts = do
    hpaRes <- listHpas kube ns
    case hpaRes of
        Left e -> pure (Left ("kubectl get hpa failed: " <> kubeErrText e))
        Right (hpas, parseErrs) -> do
            (mWeights, vsWarn) <-
                if T.null vsName
                    then pure (Nothing, ["No VirtualService configured for this product (scheduler?)"])
                    else do
                        vsRes <- getVirtualService kube ns vsName
                        pure $ case vsRes of
                            Left e -> (Nothing, ["VirtualService read failed: " <> kubeErrText e])
                            Right vs -> (Just (subsetWeightsFromVs svcHost vs), [])
            let base = classifyHpas svcHost otherHosts mWeights hpas
            pure . Right $
                base
                    { resWarnings =
                        vsWarn
                            <> map ("Skipped an unparseable HPA: " <>) parseErrs
                            <> resWarnings base
                    }
