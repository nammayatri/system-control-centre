{-# LANGUAGE OverloadedStrings #-}

{- | Read-only views of live cluster state used by the release-bot diff:
the running deployment's container env, and a configmap's @data@.

Both go through the same kubectl binary / namespace / version-resolution the
release workflow itself uses, so "live" here means exactly what a release would
be replacing.
-}
module Products.Autopilot.ReleaseBot.Live (
    LiveEnv (..),
    readServiceEnv,
    readConfigMap,
    envVarValue,
    replaceEnvVar,
    DeployRefs (..),
    readServiceRefs,
    refsFromDeployment,
) where

import Control.Monad.IO.Class (liftIO)
import Core.Config (Config (..))
import Core.Environment (Flow, getConfig)
import Data.Aeson (Value (..), eitherDecodeStrict')
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.List (nub, sort)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Vector as V
import Products.Autopilot.Actions.Release (normalizeProductType)
import Products.Autopilot.K8s.Deployment (getDeploymentEnvs, getRunningSchedulerVersion, getRunningVersionFromVS)
import Products.Autopilot.K8s.Execute (K8sError (..), K8sResult (..), runCmd, shellQuote)
import Products.Autopilot.Queries.ProductService
import qualified Products.Autopilot.Types.Storage.Schema as S

-- | The running deployment's @containers[0].env@ array, verbatim.
newtype LiveEnv = LiveEnv {leEnv :: [Value]}

{- | Env of the deployment that currently takes traffic for @service@ (resolved via
the VirtualService, exactly as the release workflow does).
-}
readServiceEnv :: Text -> Text -> Flow (Either Text LiveEnv)
readServiceEnv appGroup svcName = do
    cfg <- getConfig
    mp <- findProductByName appGroup
    case mp of
        Nothing -> pure (Left ("unknown app group " <> appGroup))
        Just pCfg -> do
            svc <- findServiceByProductAndName appGroup svcName
            let svcHost = fromMaybe svcName (svc >>= getServiceHost)
                ns = getProductNamespace pCfg
                vs = getProductVsName pCfg
                isSched = either (const False) (== "BackendScheduler") (normalizeProductType (fromMaybe "" (S.dcAppGroupType pCfg)))
            r <- liftIO (getDeploymentEnvs cfg ns vs svcHost isSched)
            pure $ case r of
                Left (K8sError e) -> Left ("cannot read deployment env: " <> T.take 300 e)
                Right (Array a) -> Right (LiveEnv (V.toList a))
                Right _ -> Left "deployment env was not a list"

-- | Value of a plain (non-@valueFrom@) env var.
envVarValue :: Text -> [Value] -> Maybe Text
envVarValue name envs = case [v | Object o <- envs, Just (String n) <- [KM.lookup "name" o], n == name, Just (String v) <- [KM.lookup "value" o]] of
    (v : _) -> Just v
    [] -> Nothing

{- | Same env list with @name@'s value replaced; every other entry (including
@valueFrom@ ones) is preserved untouched. 'Nothing' when the var is not present
as a plain value — the caller must not invent it.
-}
replaceEnvVar :: Text -> Text -> [Value] -> Maybe [Value]
replaceEnvVar name new envs
    | any isTarget envs = Just (map swap envs)
    | otherwise = Nothing
  where
    isTarget (Object o) = KM.lookup "name" o == Just (String name) && KM.member "value" o
    isTarget _ = False
    swap v@(Object o)
        | isTarget v = Object (KM.insert (K.fromText "value") (String new) o)
    swap v = v

-- | (namespace, @data@) of a configmap in the app group's namespace.
readConfigMap :: Text -> Text -> Flow (Either Text (Text, M.Map Text Text))
readConfigMap appGroup cmName = do
    cfg <- getConfig
    mp <- findProductByName appGroup
    case mp of
        Nothing -> pure (Left ("unknown app group " <> appGroup))
        Just pCfg -> do
            let ns = getProductNamespace pCfg
            res <- liftIO (runCmd (unwords [kubectlBin cfg, "-n", shellQuote ns, "get configmap", shellQuote cmName, "-o json"]))
            pure $ case res of
                Left (K8sError e) -> Left ("cannot read configmap " <> cmName <> ": " <> T.take 300 e)
                Right (K8sResult out) -> case eitherDecodeStrict' (TE.encodeUtf8 out) of
                    Left e -> Left ("configmap " <> cmName <> " is not valid JSON: " <> T.pack e)
                    Right (Object o) -> case KM.lookup "data" o of
                        Just (Object d) -> Right (ns, M.fromList [(K.toText k, t) | (k, String t) <- KM.toList d])
                        _ -> Right (ns, M.empty)
                    Right _ -> Left ("configmap " <> cmName <> " has unexpected shape")


-- ─── What the running deployment actually references ───────────────

-- | ConfigMaps and Secrets (names only — Secret values are never read) the live deployment pulls in.
data DeployRefs = DeployRefs
    { drDeployment :: Text
    , drConfigMaps :: [Text]
    , drSecrets :: [Text]
    }
    deriving (Show, Eq)

{- | Every configmap / secret name referenced by a deployment manifest: container and
initContainer @env[].valueFrom@, @envFrom@, and volumes (plain and @projected@).
Pure, so the discovery logic is unit-tested without a cluster.
-}
refsFromDeployment :: Value -> ([Text], [Text])
refsFromDeployment dep = (uniq cms, uniq secs)
  where
    uniq = nub . sort . filter (not . T.null)
    podSpec = at ["spec", "template", "spec"] dep
    containers = arr "containers" podSpec ++ arr "initContainers" podSpec
    volumes = arr "volumes" podSpec
    cms =
        concat
            [ [n | e <- arr "env" c, Just n <- [txt "name" (at ["valueFrom", "configMapKeyRef"] e)]]
                ++ [n | f <- arr "envFrom" c, Just n <- [txt "name" (at ["configMapRef"] f)]]
            | c <- containers
            ]
            ++ [n | v <- volumes, Just n <- [txt "name" (at ["configMap"] v)]]
            ++ [n | v <- volumes, src <- arr "sources" (at ["projected"] v), Just n <- [txt "name" (at ["configMap"] src)]]
    secs =
        concat
            [ [n | e <- arr "env" c, Just n <- [txt "name" (at ["valueFrom", "secretKeyRef"] e)]]
                ++ [n | f <- arr "envFrom" c, Just n <- [txt "name" (at ["secretRef"] f)]]
            | c <- containers
            ]
            ++ [n | v <- volumes, Just n <- [txt "secretName" (at ["secret"] v)]]
            ++ [n | v <- volumes, src <- arr "sources" (at ["projected"] v), Just n <- [txt "name" (at ["secret"] src)]]
    at path v = foldl (\acc k -> case acc of Object o -> fromMaybe Null (KM.lookup (K.fromText k) o); _ -> Null) v path
    arr k v = case at [k] v of Array a -> V.toList a; _ -> []
    txt k v = case at [k] v of String t -> Just t; _ -> Nothing

{- | Resolve the deployment that currently takes traffic for @service@ (same resolution as
the release workflow) and list what it references.
-}
readServiceRefs :: Text -> Text -> Flow (Either Text DeployRefs)
readServiceRefs appGroup svcName = do
    cfg <- getConfig
    mp <- findProductByName appGroup
    case mp of
        Nothing -> pure (Left ("unknown app group " <> appGroup))
        Just pCfg -> do
            svc <- findServiceByProductAndName appGroup svcName
            let svcHost = fromMaybe svcName (svc >>= getServiceHost)
                ns = getProductNamespace pCfg
                vs = getProductVsName pCfg
                isSched = either (const False) (== "BackendScheduler") (normalizeProductType (fromMaybe "" (S.dcAppGroupType pCfg)))
            ver <-
                liftIO $
                    if isSched
                        then either Left (maybe (Left "no running scheduler deployment") Right) <$> getRunningSchedulerVersion cfg ns svcHost
                        else either (\(K8sError e) -> Left e) Right <$> getRunningVersionFromVS cfg ns vs svcHost
            case ver of
                Left e -> pure (Left ("cannot resolve the running deployment: " <> T.take 200 e))
                Right v -> do
                    let depName = svcHost <> "-" <> v
                    res <- liftIO (runCmd (unwords [kubectlBin cfg, "-n", shellQuote ns, "get deployment", shellQuote depName, "-o json"]))
                    pure $ case res of
                        Left (K8sError e) -> Left ("cannot read deployment " <> depName <> ": " <> T.take 200 e)
                        Right (K8sResult out) -> case eitherDecodeStrict' (TE.encodeUtf8 out) of
                            Left e -> Left ("deployment " <> depName <> " is not valid JSON: " <> T.pack e)
                            Right dep -> let (cms, secs) = refsFromDeployment dep in Right (DeployRefs depName cms secs)
