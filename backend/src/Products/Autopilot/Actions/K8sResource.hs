{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Products.Autopilot.Actions.K8sResource
    ( -- * K8s Resource Handlers
      fetchResourcesH
    , fetchEnvsH
    , fetchSecondaryEnvsH
    , fetchConfigMapFromK8sH
    , fetchSecondaryConfigMapH
    ) where

import Control.Exception (SomeException, try)
import Control.Monad.IO.Class (liftIO)
import Core.Config (Config (..))
import Core.Utils.FlowMonad (Flow, getConfig, getDBEnv)
import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson as A
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import qualified Data.ByteString.Lazy.Char8 as LBS
import Products.Autopilot.K8s.Deployment (getDeploymentEnvs)
import Products.Autopilot.K8s.Execute (K8sError (..), K8sResult (..), runCmd)
import Products.Autopilot.K8s.Kubectl (getPrimarySubsetFromVirtualService)
import Products.Autopilot.Queries.ProductService
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

-- ============================================================================
-- Resources Endpoint (GET /resources?PRODUCT=&SERVICE=)
-- ============================================================================

fetchResourcesH :: Maybe Text -> Maybe Text -> Flow Value
fetchResourcesH mProduct mService = do
    cfg <- getConfig
    db <- getDBEnv
    case (mProduct, mService) of
        (Just productName, Just serviceName') -> do
            p <- liftIO $ findProductByName db productName
            case p of
                Nothing -> pure $ object ["error" .= ("Product not found" :: Text)]
                Just pCfg -> do
                    svc <- liftIO $ findServiceByProductAndName db productName serviceName'
                    let svcHost = case svc of
                            Just s -> fromMaybe serviceName' (getServiceHost s)
                            Nothing -> serviceName'
                        ns = getProductNamespace pCfg
                        vsName' = getProductVsName pCfg
                    -- Get the running version from VS
                    versionResult <- liftIO $ getPrimarySubsetFromVirtualService cfg ns vsName' svcHost
                    case versionResult of
                        Left err -> pure $ object ["error" .= err]
                        Right Nothing -> pure $ object ["error" .= ("No running version found" :: Text)]
                        Right (Just runningVersion) -> do
                            let fullDepName = svcHost <> "-" <> runningVersion
                            resResult <- liftIO $ runCmd (unwords [kubectlBin cfg, "-n", T.unpack ns, "get deployment", T.unpack fullDepName, "-o jsonpath='{.spec.template.spec.containers[0].resources}'"])
                            case resResult of
                                Left (K8sError err) -> pure $ object ["error" .= err]
                                Right (K8sResult out) ->
                                    let cleaned = T.strip (T.dropWhile (== '\'') (T.dropWhileEnd (== '\'') (T.strip out)))
                                     in case A.decodeStrict' (encodeUtf8 cleaned) :: Maybe Value of
                                            Just v -> pure v
                                            Nothing -> pure $ object ["requests" .= object [], "limits" .= object []]
        _ -> pure $ object ["error" .= ("PRODUCT and SERVICE query params required" :: Text)]

-- ============================================================================
-- Envs Endpoints
-- ============================================================================

fetchEnvsH :: Maybe Text -> Maybe Text -> Maybe Text -> Flow Value
fetchEnvsH mProduct mEnv mService = do
    cfg <- getConfig
    db <- getDBEnv
    case (mProduct, mService) of
        (Just product', Just service') -> do
            p <- liftIO $ findProductByName db product'
            case p of
                Nothing -> pure $ A.toJSON ([] :: [Value])
                Just pCfg -> do
                    svc <- liftIO $ findServiceByProductAndName db product' service'
                    let svcHost = case svc of
                            Just s -> fromMaybe service' (getServiceHost s)
                            Nothing -> service'
                    envResult <- liftIO $ getDeploymentEnvs cfg (getProductNamespace pCfg) (getProductVsName pCfg) svcHost
                    case envResult of
                        Left _ -> pure $ A.toJSON ([] :: [Value])
                        Right envJson -> pure envJson
        _ -> pure $ A.toJSON ([] :: [Value])

{- | Proxy env fetch to sync cluster URL for secondary cloud.
Tries the namma-ap endpoint format (GET /envs) first, then falls back to
ny-autopilot format (POST /release/getenvs/).
-}
fetchSecondaryEnvsH :: Maybe Text -> Maybe Text -> Maybe Text -> Flow Value
fetchSecondaryEnvsH mProduct mEnv mService = do
    cfg <- getConfig
    case (mProduct, mEnv, mService) of
        (Just product', Just env', Just service') -> do
            let rawUrl = syncClusterUrl cfg
            if null rawUrl
                then pure $ A.toJSON ([] :: [Value])
                else do
                    let normalised =
                            let u = if "http" `T.isPrefixOf` T.pack rawUrl then rawUrl else "http://" <> rawUrl
                             in if not (null u) && Prelude.last u == '/' then u else u <> "/"
                        baseAuth = syncClusterBaseAuth cfg
                        authArgs = if null baseAuth then [] else ["-H", "Authorization: Basic " <> baseAuth]
                        getUrl = normalised <> "envs?product=" <> T.unpack product' <> "&env=" <> T.unpack env' <> "&service=" <> T.unpack service'
                        getCurlArgs = ["-s", "-X", "GET", getUrl, "--max-time", "15"] <> authArgs
                    liftIO $ putStrLn $ "[SYNC-ENV] Fetching secondary envs from: " <> getUrl
                    getResult <- liftIO (try (readProcessWithExitCode "curl" getCurlArgs "") :: IO (Either SomeException (ExitCode, String, String)))
                    case getResult of
                        Right (ExitSuccess, out, _) | not (null out) && out /= "[]" -> do
                            liftIO $ putStrLn $ "[SYNC-ENV] GET success, response length=" <> show (length out)
                            case A.decodeStrict' (encodeUtf8 (T.pack out)) :: Maybe Value of
                                Just v -> pure v
                                Nothing -> do
                                    liftIO $ putStrLn $ "[SYNC-ENV] GET response not valid JSON, trying ny-autopilot format"
                                    tryNyAutopilotFormat normalised baseAuth authArgs product' env' service'
                        Right (ExitSuccess, out, _) -> do
                            liftIO $ putStrLn $ "[SYNC-ENV] GET returned empty/[], trying ny-autopilot format"
                            tryNyAutopilotFormat normalised baseAuth authArgs product' env' service'
                        Right (ExitFailure code, _, err) -> do
                            liftIO $ putStrLn $ "[SYNC-ENV] GET failed (exit=" <> show code <> "): " <> err <> ", trying ny-autopilot format"
                            tryNyAutopilotFormat normalised baseAuth authArgs product' env' service'
                        Left e -> do
                            liftIO $ putStrLn $ "[SYNC-ENV] GET exception: " <> show e <> ", trying ny-autopilot format"
                            tryNyAutopilotFormat normalised baseAuth authArgs product' env' service'
        _ -> pure $ A.toJSON ([] :: [Value])
  where
    tryNyAutopilotFormat normalised baseAuth authArgs product' env' service' = do
        let postUrl = normalised <> "release/getenvs/"
            bodyJson =
                A.encode $
                    object
                        [ "product" .= product'
                        , "env" .= env'
                        , "service" .= service'
                        , "secondary" .= True
                        ]
            postCurlArgs =
                [ "-s"
                , "-X"
                , "POST"
                , postUrl
                , "-H"
                , "Content-Type: application/json"
                , "-d"
                , LBS.unpack bodyJson
                , "--max-time"
                , "15"
                ]
                    <> authArgs
        liftIO $ putStrLn $ "[SYNC-ENV] Trying ny-autopilot format: POST " <> postUrl
        postResult <- liftIO (try (readProcessWithExitCode "curl" postCurlArgs "") :: IO (Either SomeException (ExitCode, String, String)))
        case postResult of
            Right (ExitSuccess, out, _) ->
                case A.decodeStrict' (encodeUtf8 (T.pack out)) of
                    Just v -> pure v
                    Nothing -> pure $ A.toJSON ([] :: [Value])
            _ -> pure $ A.toJSON ([] :: [Value])

-- ============================================================================
-- ConfigMap K8s Lookup
-- ============================================================================

fetchConfigMapFromK8sH :: Maybe Text -> Maybe Text -> Flow Value
fetchConfigMapFromK8sH mProduct mName = do
    cfg <- getConfig
    db <- getDBEnv
    case mProduct of
        Nothing -> pure $ object ["configMap" .= A.toJSON ([] :: [Text])]
        Just productName -> do
            p <- liftIO $ findProductByName db productName
            case p of
                Nothing -> pure $ object ["configMap" .= A.toJSON ([] :: [Text])]
                Just pCfg -> do
                    let ns = getProductNamespace pCfg
                    case mName of
                        Nothing -> do
                            res <- liftIO $ runCmd (unwords [kubectlBin cfg, "-n", T.unpack ns, "get configmap", "-o jsonpath='{.items[*].metadata.name}'"])
                            case res of
                                Left _ -> pure $ object ["configMap" .= A.toJSON ([] :: [Text])]
                                Right (K8sResult out) ->
                                    let cleaned = T.strip (T.dropWhile (== '\'') (T.dropWhileEnd (== '\'') (T.strip out)))
                                        names = filter (not . T.null) (T.words cleaned)
                                     in pure $ object ["configMap" .= names]
                        Just name' -> do
                            res <- liftIO $ runCmd (unwords [kubectlBin cfg, "-n", T.unpack ns, "get configmap", T.unpack name', "-o jsonpath='{.data}'"])
                            case res of
                                Left _ -> pure $ object ["configMap" .= ("" :: Text)]
                                Right (K8sResult out) ->
                                    let cleaned = T.strip (T.dropWhile (== '\'') (T.dropWhileEnd (== '\'') (T.strip out)))
                                     in pure $ object ["configMap" .= cleaned]

fetchSecondaryConfigMapH :: Maybe Text -> Maybe Text -> Flow Value
fetchSecondaryConfigMapH mProduct mName = do
    cfg <- getConfig
    let rawUrl = syncClusterUrl cfg
    if null rawUrl
        then pure $ object ["configMap" .= A.toJSON ([] :: [Text])]
        else do
            let normalised =
                    let u = if "http" `T.isPrefixOf` T.pack rawUrl then rawUrl else "http://" <> rawUrl
                     in if not (null u) && Prelude.last u == '/' then u else u <> "/"
                baseAuth = syncClusterBaseAuth cfg
                authArgs = if null baseAuth then [] else ["-H", "Authorization: Basic " <> baseAuth]
                queryParams = case (mProduct, mName) of
                    (Just p, Just n) -> "?PRODUCT=" <> T.unpack p <> "&NAME=" <> T.unpack n
                    (Just p, Nothing) -> "?PRODUCT=" <> T.unpack p
                    _ -> ""
                getUrl = normalised <> "configmap" <> queryParams
                getCurlArgs = ["-s", "-X", "GET", getUrl, "--max-time", "15"] <> authArgs
            liftIO $ putStrLn $ "[SYNC-CONFIGMAP] Fetching secondary configmap from: " <> getUrl
            getResult <- liftIO (try (readProcessWithExitCode "curl" getCurlArgs "") :: IO (Either SomeException (ExitCode, String, String)))
            case getResult of
                Right (ExitSuccess, out, _) | not (null out) ->
                    case A.decodeStrict' (encodeUtf8 (T.pack out)) :: Maybe Value of
                        Just v -> pure v
                        Nothing -> do
                            liftIO $ putStrLn $ "[SYNC-CONFIGMAP] Response not valid JSON"
                            pure $ object ["configMap" .= A.toJSON ([] :: [Text])]
                Right (ExitFailure code, _, err) -> do
                    liftIO $ putStrLn $ "[SYNC-CONFIGMAP] GET failed (exit=" <> show code <> "): " <> err
                    pure $ object ["configMap" .= A.toJSON ([] :: [Text])]
                _ -> pure $ object ["configMap" .= A.toJSON ([] :: [Text])]
