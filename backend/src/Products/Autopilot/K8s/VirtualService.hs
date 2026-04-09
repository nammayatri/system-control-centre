{-# LANGUAGE OverloadedStrings #-}

-- | Kubernetes VirtualService operations: get, patch rollout weights, check traffic.
module Products.Autopilot.K8s.VirtualService (
    getVirtualServiceJson,
    getVirtualServiceJsonInContext,
    applyVirtualServiceRollout,
    applyVirtualServiceRolloutWithRetries,
    isSubsetReceivingTraffic,
    getPrimarySubsetFromVirtualService,
)
where

import Control.Applicative ((<|>))
import Core.Config (Config (..))
import Core.Logging (logWarningG)
import Data.Aeson (Value (..))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Products.Autopilot.K8s.Execute
import Products.Autopilot.Types.Target.Kubernetes (K8sReleaseContext (..))
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

getVirtualServiceJson :: Config -> Text -> Text -> IO (Either K8sError Text)
getVirtualServiceJson cfg ns vsName = do
    res <- runCmd (unwords [kubectlBin cfg, "-n", shellQuote ns, "get virtualservice", shellQuote vsName, "-o json"])
    pure $ case res of Left err -> Left err; Right (K8sResult out) -> Right out

getVirtualServiceJsonInContext :: Config -> Text -> Text -> Text -> IO (Either K8sError Text)
getVirtualServiceJsonInContext cfg kubeContext ns vsName = do
    let cmd = withKubectx kubeContext (unwords [kubectlBin cfg, "-n", shellQuote ns, "get virtualservice", shellQuote vsName, "-o json"])
    res <- runCmd cmd
    case res of
        Right (K8sResult out) -> pure (Right out)
        Left _ -> do
            fallback <- runCmd (unwords [kubectlBin cfg, "-n", shellQuote ns, "get virtualservice", shellQuote vsName, "-o json"])
            pure $ case fallback of Left err -> Left err; Right (K8sResult out) -> Right out

applyVirtualServiceRollout :: Config -> K8sReleaseContext -> Int -> Int -> IO (Either K8sError K8sResult)
applyVirtualServiceRollout = applyVirtualServiceRolloutWithRetries 3

applyVirtualServiceRolloutWithRetries :: Int -> Config -> K8sReleaseContext -> Int -> Int -> IO (Either K8sError K8sResult)
applyVirtualServiceRolloutWithRetries maxRetries cfg ctx oldW newW = do
    externalRes <- applyVirtualServiceRolloutSingle cfg ctx maxRetries (virtualServiceName ctx) oldW newW
    case externalRes of
        Left err -> pure (Left err)
        Right _ ->
            case internalVirtualServiceName ctx of
                Nothing -> pure (Right (K8sResult "external-vs-updated"))
                Just internalVs -> applyVirtualServiceRolloutSingle cfg ctx maxRetries internalVs oldW newW

{- | Apply VS rollout with optimistic concurrency: read full VS, patch the
target service's routes, kubectl replace; re-reads and retries on 409.
-}
applyVirtualServiceRolloutSingle :: Config -> K8sReleaseContext -> Int -> Text -> Int -> Int -> IO (Either K8sError K8sResult)
applyVirtualServiceRolloutSingle cfg ctx maxRetries vsName oldW newW = go 1
  where
    go attempt = do
        vsRes <- getVirtualServiceJson cfg (namespace ctx) vsName
        case vsRes of
            Left err -> pure (Left err)
            Right body ->
                case A.decodeStrict' (encodeUtf8 body) :: Maybe Value of
                    Nothing -> pure (Left (K8sError "Failed to decode virtualservice JSON"))
                    Just v ->
                        case buildUpdatedVS v of
                            Nothing -> pure (Left (K8sError "VirtualService missing spec.http"))
                            Just updatedJson -> do
                                (exitCode, _out, errStr) <- readProcessWithExitCode (kubectlBin cfg) ["-n", T.unpack (namespace ctx), "replace", "-f", "-"] (T.unpack updatedJson)
                                case exitCode of
                                    ExitSuccess -> pure (Right (K8sResult "vs-updated"))
                                    ExitFailure _ ->
                                        let err = K8sError (T.pack errStr)
                                         in if isConflictError err && attempt < maxRetries
                                                then do
                                                    logWarningG $ "[VS-ROLLOUT] Conflict on attempt " <> T.pack (show attempt) <> ", retrying..."
                                                    go (attempt + 1)
                                                else pure (Left err)
    buildUpdatedVS (Object root) = do
        spec <- getObj "spec" root
        httpRules <- getArr "http" spec
        let updatedHttp = map updateHttpRule httpRules
            newSpec = KM.insert (K.fromText "http") (A.toJSON updatedHttp) spec
            newRoot = KM.insert (K.fromText "spec") (Object newSpec) root
        pure (jsonToText (Object newRoot))
    buildUpdatedVS _ = Nothing

    updateHttpRule (Object httpObj) =
        case KM.lookup (K.fromText "route") httpObj of
            Just (Array routes) ->
                let (targetRoutes, otherRoutes) = partitionTargetRoutes (toList routes)
                    hasTarget = not (null targetRoutes)
                    oldTemplate = findTemplate (oldVersion ctx) targetRoutes
                    newTemplate = findTemplate (newVersion ctx) targetRoutes
                    fallbackTemplate = safeHead targetRoutes
                    mkOld = if oldW > 0 then maybe (mkRoute (oldVersion ctx) oldW) (\t -> setSubsetAndWeight t (oldVersion ctx) oldW) (oldTemplate <|> fallbackTemplate) else Null
                    mkNew = if newW > 0 then maybe (mkRoute (newVersion ctx) newW) (\t -> setSubsetAndWeight t (newVersion ctx) newW) (newTemplate <|> fallbackTemplate) else Null
                    normalizedTarget = if hasTarget then filter (/= Null) [mkOld, mkNew] else []
                    finalRoutes = if hasTarget then otherRoutes <> normalizedTarget else toList routes
                 in Object (KM.insert (K.fromText "route") (A.toJSON finalRoutes) httpObj)
            _ -> Object httpObj
    updateHttpRule v = v

    partitionTargetRoutes = foldr (\r (t, o) -> if isTargetRoute r then (r : t, o) else (t, r : o)) ([], [])
    isTargetRoute (Object routeObj) = case getObj "destination" routeObj >>= getTxt "host" of Just host -> hostEq host (serviceName ctx); _ -> False
    isTargetRoute _ = False
    findTemplate subsetName = safeHead . filter (hasSubset subsetName)
    hasSubset subsetName (Object routeObj) = case getObj "destination" routeObj >>= getTxt "subset" of Just s -> s == subsetName; Nothing -> False
    hasSubset _ _ = False
    setSubsetAndWeight (Object routeObj) subsetName weightVal =
        let destObj = case getObj "destination" routeObj of Just d -> d; Nothing -> KM.empty
            newDest = KM.insert (K.fromText "subset") (String subsetName) destObj
            withDest = KM.insert (K.fromText "destination") (Object newDest) routeObj
         in Object (KM.insert (K.fromText "weight") (A.toJSON weightVal) withDest)
    setSubsetAndWeight _ subsetName weightVal = mkRoute subsetName weightVal
    mkRoute subsetName weightVal = Object (KM.fromList [(K.fromText "destination", Object (KM.fromList [(K.fromText "host", String (serviceName ctx)), (K.fromText "subset", String subsetName)])), (K.fromText "weight", A.toJSON weightVal)])
    safeHead [] = Nothing; safeHead (x : _) = Just x

isSubsetReceivingTraffic :: Config -> Text -> Text -> Text -> Text -> IO (Either K8sError Bool)
isSubsetReceivingTraffic cfg ns vsName svcHost subsetName = do
    vsRes <- getVirtualServiceJson cfg ns vsName
    pure $ case vsRes of
        Left e -> Left e
        Right body ->
            case A.decodeStrict' (encodeUtf8 body) :: Maybe Value of
                Nothing -> Left (K8sError "Failed to decode virtualservice JSON")
                Just v -> Right (hasTraffic v)
  where
    hasTraffic (Object root) = case getObj "spec" root >>= getArr "http" of Nothing -> False; Just rules -> any httpHasTraffic rules
    hasTraffic _ = False
    httpHasTraffic (Object hObj) = case getArr "route" hObj of Nothing -> False; Just routes -> any routeMatches routes
    httpHasTraffic _ = False
    routeMatches (Object routeObj) = case getObj "destination" routeObj of
        Just dest -> case (getTxt "host" dest, getTxt "subset" dest) of
            (Just host, Just subset) -> hostEq host svcHost && subset == subsetName && getInt "weight" routeObj > 0
            _ -> False
        Nothing -> False
    routeMatches _ = False

getPrimarySubsetFromVirtualService :: Config -> Text -> Text -> Text -> IO (Either Text (Maybe Text))
getPrimarySubsetFromVirtualService cfg ns vsName svcHost = do
    res <- getVirtualServiceJson cfg ns vsName
    case res of
        Left (K8sError e) -> pure (Left e)
        Right out ->
            case A.decodeStrict' (encodeUtf8 out) :: Maybe Value of
                Nothing -> pure (Left "Failed to decode virtualservice JSON")
                Just v -> pure (Right (pickSubset v))
  where
    pickSubset (Object root) = case getObj "spec" root >>= getArr "http" of
        Nothing -> Nothing
        Just rules -> case concatMap parseHttp rules of [] -> Nothing; pairs -> Just (fst (maximumByWeight pairs))
    pickSubset _ = Nothing
    parseHttp (Object httpRule) = case getArr "route" httpRule of Nothing -> []; Just routes -> mapMaybe parseRoute routes
    parseHttp _ = []
    parseRoute (Object routeObj) = do
        dest <- getObj "destination" routeObj
        host <- getTxt "host" dest
        subset <- getTxt "subset" dest
        if hostEq host svcHost then Just (subset, getInt "weight" routeObj) else Nothing
    parseRoute _ = Nothing
    maximumByWeight = foldr1 (\a b -> if snd a < snd b then b else a)
    mapMaybe f = foldr (\x acc -> maybe acc (: acc) (f x)) []

-- Shared JSON helpers
hostEq :: Text -> Text -> Bool
hostEq a b = a == b || T.takeWhile (/= '.') a == T.takeWhile (/= '.') b

getObj :: Text -> KM.KeyMap Value -> Maybe (KM.KeyMap Value)
getObj key obj = case KM.lookup (K.fromText key) obj of Just (Object o) -> Just o; _ -> Nothing

getArr :: Text -> KM.KeyMap Value -> Maybe [Value]
getArr key obj = case KM.lookup (K.fromText key) obj of Just (Array a) -> Just (toList a); _ -> Nothing

getTxt :: Text -> KM.KeyMap Value -> Maybe Text
getTxt key obj = case KM.lookup (K.fromText key) obj of Just (String t) -> Just t; _ -> Nothing

getInt :: Text -> KM.KeyMap Value -> Int
getInt key obj = case KM.lookup (K.fromText key) obj of Just (Number n) -> round n; _ -> 0

toList :: (Foldable t) => t a -> [a]
toList = foldr (:) []
