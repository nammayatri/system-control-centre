{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Products.Autopilot.Actions.K8sResource (
    -- * K8s Resource Handlers
    fetchResourcesH,
    fetchEnvsH,
    fetchSecondaryEnvsH,
)
where

import Control.Monad.IO.Class (liftIO)
import Core.Auth.Protected (AuthedPerson)
import Core.Config (Config (..))
import Core.Environment (Flow, getConfig, logInfo)
import Core.Http.Client (HttpReq (..), HttpResponse (..), Method (..), defaultReq, httpRaw)
import Core.Types.Time (Seconds (..))
import Data.Aeson (Value (..), encode, object, (.=))
import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy as LBS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Products.Autopilot.K8s.Deployment (getDeploymentEnvs)
import Products.Autopilot.K8s.Execute (K8sError (..), K8sResult (..), runCmd)
import Products.Autopilot.K8s.Kubectl (getPrimarySubsetFromVirtualService)
import Products.Autopilot.Queries.ProductService
import Products.Autopilot.Types.API (ResourcesResponse (..))

fetchResourcesH :: AuthedPerson -> Maybe Text -> Maybe Text -> Flow ResourcesResponse
fetchResourcesH _ap mProduct mService = do
    cfg <- getConfig
    let emptyResources = ResourcesResponse Nothing Nothing
    case (mProduct, mService) of
        (Just productName, Just serviceName') -> do
            p <- findProductByName productName
            case p of
                Nothing -> pure emptyResources
                Just pCfg -> do
                    svc <- findServiceByProductAndName productName serviceName'
                    let svcHost = case svc of
                            Just s -> fromMaybe serviceName' (getServiceHost s)
                            Nothing -> serviceName'
                        ns = getProductNamespace pCfg
                        vsName' = getProductVsName pCfg
                    versionResult <- liftIO $ getPrimarySubsetFromVirtualService cfg ns vsName' svcHost
                    case versionResult of
                        Left _ -> pure emptyResources
                        Right Nothing -> pure emptyResources
                        Right (Just runningVersion) -> do
                            let fullDepName = svcHost <> "-" <> runningVersion
                            resResult <- liftIO $ runCmd (unwords [kubectlBin cfg, "-n", T.unpack ns, "get deployment", T.unpack fullDepName, "-o jsonpath='{.spec.template.spec.containers[0].resources}'"])
                            case resResult of
                                Left (K8sError _) -> pure emptyResources
                                Right (K8sResult out) ->
                                    let cleaned = T.strip (T.dropWhile (== '\'') (T.dropWhileEnd (== '\'') (T.strip out)))
                                     in case A.decodeStrict' (encodeUtf8 cleaned) :: Maybe ResourcesResponse of
                                            Just v -> pure v
                                            Nothing -> pure emptyResources
        _ -> pure emptyResources

fetchEnvsH :: AuthedPerson -> Maybe Text -> Maybe Text -> Maybe Text -> Flow Value
fetchEnvsH _ap mProduct _mEnv mService = do
    cfg <- getConfig
    case (mProduct, mService) of
        (Just product', Just service') -> do
            p <- findProductByName product'
            case p of
                Nothing -> pure $ A.toJSON ([] :: [Value])
                Just pCfg -> do
                    svc <- findServiceByProductAndName product' service'
                    let svcHost = case svc of
                            Just s -> fromMaybe service' (getServiceHost s)
                            Nothing -> service'
                    envResult <- liftIO $ getDeploymentEnvs cfg (getProductNamespace pCfg) (getProductVsName pCfg) svcHost
                    case envResult of
                        Left _ -> pure $ A.toJSON ([] :: [Value])
                        Right envJson -> pure envJson
        _ -> pure $ A.toJSON ([] :: [Value])

{- | Proxy env fetch to secondary cluster. Tries scc format (GET /envs)
first, falls back to ny-autopilot (POST /release/getenvs/).
-}
fetchSecondaryEnvsH :: AuthedPerson -> Maybe Text -> Maybe Text -> Maybe Text -> Flow Value
fetchSecondaryEnvsH _ap mProduct mEnv mService = do
    cfg <- getConfig
    case (mProduct, mEnv, mService) of
        (Just product', Just env', Just service') -> do
            let rawUrl = syncClusterUrl cfg
            if null rawUrl
                then pure $ A.toJSON ([] :: [Value])
                else do
                    let normalised =
                            let u = if "http" `T.isPrefixOf` T.pack rawUrl then T.pack rawUrl else "http://" <> T.pack rawUrl
                             in if T.null u || T.last u == '/' then u else u <> "/"
                        baseAuth = syncClusterBaseAuth cfg
                        auth =
                            if null baseAuth
                                then []
                                else [("Authorization", "Bearer " <> T.pack baseAuth)]
                        getUrl = normalised <> "envs?product=" <> product' <> "&env=" <> env' <> "&service=" <> service'
                        getReq = (defaultReq getUrl){reqHeaders = auth, reqTimeout = Seconds 15, reqRetries = 0, reqLogTag = "sync-env"}
                    logInfo $ "[SYNC-ENV] Fetching secondary envs from: " <> getUrl
                    getResult <- liftIO (httpRaw getReq)
                    case getResult of
                        Right HttpResponse{respStatus = s, respBody = b}
                            | s < 400 && b /= "[]" && not (LBS.null b) ->
                                case A.decodeStrict' (LBS.toStrict b) :: Maybe Value of
                                    Just v -> pure v
                                    Nothing -> do
                                        logInfo "[SYNC-ENV] GET response not valid JSON, trying ny-autopilot format"
                                        tryNyAutopilotFormat normalised auth product' env' service'
                        Right _ -> do
                            logInfo "[SYNC-ENV] GET empty / non-200, trying ny-autopilot format"
                            tryNyAutopilotFormat normalised auth product' env' service'
                        Left e -> do
                            logInfo $ "[SYNC-ENV] GET exception: " <> T.pack (show e) <> ", trying ny-autopilot format"
                            tryNyAutopilotFormat normalised auth product' env' service'
        _ -> pure $ A.toJSON ([] :: [Value])
  where
    tryNyAutopilotFormat normalised auth product' env' service' = do
        let postUrl = normalised <> "release/getenvs/"
            bodyJson =
                encode $
                    object ["product" .= product', "env" .= env', "service" .= service', "secondary" .= True]
            postReq =
                (defaultReq postUrl)
                    { reqMethod = POST
                    , reqHeaders = ("Content-Type", "application/json") : auth
                    , reqBody = Just bodyJson
                    , reqTimeout = Seconds 15
                    , reqRetries = 0
                    , reqLogTag = "sync-env"
                    }
        logInfo $ "[SYNC-ENV] Trying ny-autopilot format: POST " <> postUrl
        postResult <- liftIO (httpRaw postReq)
        case postResult of
            Right HttpResponse{respStatus = s, respBody = b} | s < 400 ->
                case A.decodeStrict' (LBS.toStrict b) of
                    Just v -> pure v
                    Nothing -> pure $ A.toJSON ([] :: [Value])
            _ -> pure $ A.toJSON ([] :: [Value])
