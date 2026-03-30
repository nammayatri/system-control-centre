{-# LANGUAGE OverloadedStrings #-}

-- | Kubernetes DestinationRule operations: ensure subsets exist for traffic routing.
module Products.Autopilot.K8s.DestinationRule
  ( ensureDestinationRuleSubset
  , ensureDestinationRule
  ) where

import Data.Aeson (Value (..))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Core.Config (Config (..))
import Products.Autopilot.Types.Target.Kubernetes (K8sReleaseContext (..))
import Products.Autopilot.K8s.Execute
import Products.Autopilot.K8s.VirtualService (getVirtualServiceJson)

ensureDestinationRuleSubset :: Config -> K8sReleaseContext -> IO (Either K8sError K8sResult)
ensureDestinationRuleSubset cfg ctx = do
  resolved <- resolveDestinationRuleName cfg ctx
  case resolved of
    Left err -> pure (Left err)
    Right drName -> do
      drRes <- getDestinationRuleJson cfg (namespace ctx) drName
      case drRes of
        Left err -> pure (Left err)
        Right body -> do
          vsRes <- getVirtualServiceJson cfg (namespace ctx) (virtualServiceName ctx)
          case (A.decodeStrict' (encodeUtf8 body) :: Maybe Value, vsRes) of
            (Nothing, _) -> pure (Left (K8sError "Failed to decode destinationrule JSON"))
            (_, Left err) -> pure (Left err)
            (Just drValue, Right vsBody) ->
              case A.decodeStrict' (encodeUtf8 vsBody) :: Maybe Value of
                Nothing -> pure (Left (K8sError "Failed to decode virtualservice JSON"))
                Just vsValue ->
                  case buildSubsetPatch drValue vsValue of
                    Nothing -> pure (Left (K8sError "DestinationRule missing spec.subsets"))
                    Just patchJson ->
                      runCmd (unwords ["echo", shellQuote patchJson, "|", kubectlBin cfg, "-n", T.unpack (namespace ctx), "patch destinationrule", T.unpack drName, "--type merge -p \"$(cat)\""])
  where
    buildSubsetPatch (Object root) vsValue = do
      spec <- getObj "spec" root
      subsets <- getArr "subsets" spec
      let activeFromVs = extractActiveSubsetsFromVS vsValue
          keepNames = uniq (newVersion ctx : oldVersion ctx : activeFromVs)
          filtered = filter (subsetIn keepNames) subsets
          alreadyHasNew = any isTargetSubset filtered
          newSubset = Object (KM.fromList [(K.fromText "name", String (newVersion ctx)), (K.fromText "labels", Object (KM.fromList [(K.fromText "version", String (newVersion ctx))]))])
          finalSubsets = if alreadyHasNew then filtered else filtered <> [newSubset]
          patchVal = Object (KM.fromList [(K.fromText "spec", Object (KM.fromList [(K.fromText "subsets", A.toJSON finalSubsets)]))])
      pure (jsonToText patchVal)
    buildSubsetPatch _ _ = Nothing

    isTargetSubset (Object o) = getTxt "name" o == Just (newVersion ctx)
    isTargetSubset _ = False
    subsetIn names (Object o) = case getTxt "name" o of { Just n -> n `elem` names; Nothing -> False }
    subsetIn _ _ = False
    extractActiveSubsetsFromVS (Object root) = case getObj "spec" root >>= getArr "http" of { Nothing -> []; Just httpRules -> uniq (concatMap fromHttp httpRules) }
    extractActiveSubsetsFromVS _ = []
    fromHttp (Object httpObj) = case getArr "route" httpObj of { Nothing -> []; Just routes -> foldr collect [] routes }
    fromHttp _ = []
    collect (Object routeObj) acc = case getObj "destination" routeObj of
      Just dest -> case (getTxt "host" dest, getTxt "subset" dest) of
        (Just h, Just subset) | hostEq h (serviceName ctx) -> subset : acc
        _ -> acc
      Nothing -> acc
    collect _ acc = acc

resolveDestinationRuleName :: Config -> K8sReleaseContext -> IO (Either K8sError Text)
resolveDestinationRuleName cfg ctx = do
  drs <- listDestinationRuleNames cfg (namespace ctx)
  pure $ case drs of
    Left err -> Left err
    Right names ->
      case findFirst (`elem` names) [destinationRuleName ctx, serviceName ctx <> "-destinations", serviceName ctx <> "-dr"] of
        Just nm -> Right nm
        Nothing -> Left (K8sError ("destinationrule not found for service: " <> serviceName ctx))
  where
    findFirst _ [] = Nothing
    findFirst p (x : xs) = if p x then Just x else findFirst p xs

getDestinationRuleJson :: Config -> Text -> Text -> IO (Either K8sError Text)
getDestinationRuleJson cfg ns drName = do
  res <- runCmd (unwords [kubectlBin cfg, "-n", T.unpack ns, "get destinationrule", T.unpack drName, "-o json"])
  pure $ case res of { Left err -> Left err; Right (K8sResult out) -> Right out }

listDestinationRuleNames :: Config -> Text -> IO (Either K8sError [Text])
listDestinationRuleNames cfg ns = do
  res <- runCmd (unwords [kubectlBin cfg, "-n", T.unpack ns, "get destinationrule -o name"])
  pure $ case res of
    Left err -> Left err
    Right (K8sResult out) -> Right (map stripPrefix (filter (not . T.null) (T.lines out)))
  where
    stripPrefix n = case T.splitOn "/" n of { [_, nm] -> nm; _ -> n }

-- Shared helpers
hostEq :: Text -> Text -> Bool
hostEq a b = a == b || T.takeWhile (/= '.') a == T.takeWhile (/= '.') b

uniq :: Eq a => [a] -> [a]
uniq = foldr (\x acc -> if x `elem` acc then acc else x : acc) []

getObj :: Text -> KM.KeyMap Value -> Maybe (KM.KeyMap Value)
getObj key obj = case KM.lookup (K.fromText key) obj of { Just (Object o) -> Just o; _ -> Nothing }

getArr :: Text -> KM.KeyMap Value -> Maybe [Value]
getArr key obj = case KM.lookup (K.fromText key) obj of { Just (Array a) -> Just (foldr (:) [] a); _ -> Nothing }

getTxt :: Text -> KM.KeyMap Value -> Maybe Text
getTxt key obj = case KM.lookup (K.fromText key) obj of { Just (String t) -> Just t; _ -> Nothing }

-- | Ensure a DestinationRule exists with the required subsets.
-- If a DR already exists, delegates to ensureDestinationRuleSubset.
-- If no DR exists, creates a minimal one with old+new version subsets.
ensureDestinationRule :: Config -> K8sReleaseContext -> IO (Either K8sError K8sResult)
ensureDestinationRule cfg ctx = do
  resolved <- resolveDestinationRuleName cfg ctx
  case resolved of
    Right _ -> ensureDestinationRuleSubset cfg ctx
    Left _  -> createMinimalDestinationRule cfg ctx

createMinimalDestinationRule :: Config -> K8sReleaseContext -> IO (Either K8sError K8sResult)
createMinimalDestinationRule cfg ctx = do
  let ns = T.unpack (namespace ctx)
      svc = T.unpack (serviceName ctx)
      drName = svc <> "-destinations"
      oldV = T.unpack (oldVersion ctx)
      newV = T.unpack (newVersion ctx)
      yaml = T.pack $ unlines
        [ "apiVersion: networking.istio.io/v1beta1"
        , "kind: DestinationRule"
        , "metadata:"
        , "  name: " <> drName
        , "  namespace: " <> ns
        , "spec:"
        , "  host: " <> svc
        , "  subsets:"
        , "  - name: " <> oldV
        , "    labels:"
        , "      version: \"" <> oldV <> "\""
        , "  - name: " <> newV
        , "    labels:"
        , "      version: \"" <> newV <> "\""
        ]
  runCmd (unwords ["echo", shellQuote yaml, "|", kubectlBin cfg, "-n", ns, "apply -f -"])
