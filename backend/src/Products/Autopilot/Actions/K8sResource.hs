{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Products.Autopilot.Actions.K8sResource
  ( -- * K8s Resource Handlers
    fetchResourcesH,
    fetchEnvsH,
    fetchSecondaryEnvsH,
  )
where

import Control.Exception (SomeException, try)
import Control.Monad.IO.Class (liftIO)
import Core.Auth.Protected (AuthedPerson)
import Core.Config (Config (..))
import Core.Environment (logInfo)
import Core.Utils.FlowMonad (Flow, getConfig, getDBEnv)
import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Products.Autopilot.K8s.Deployment (getDeploymentEnvs)
import Products.Autopilot.K8s.Execute (K8sError (..), K8sResult (..), runCmd)
import Products.Autopilot.K8s.Kubectl (getPrimarySubsetFromVirtualService)
import Products.Autopilot.Queries.ProductService
import Products.Autopilot.Types.API (ResourcesResponse (..))
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

-- ============================================================================
-- Resources Endpoint (GET /resources?PRODUCT=&SERVICE=)
-- ============================================================================

fetchResourcesH :: AuthedPerson -> Maybe Text -> Maybe Text -> Flow ResourcesResponse
fetchResourcesH _ap mProduct mService = do
  cfg <- getConfig
  db <- getDBEnv
  let emptyResources = ResourcesResponse Nothing Nothing
  case (mProduct, mService) of
    (Just productName, Just serviceName') -> do
      p <- liftIO $ findProductByName db productName
      case p of
        Nothing -> pure emptyResources
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

-- ============================================================================
-- Envs Endpoints
-- ============================================================================

fetchEnvsH :: AuthedPerson -> Maybe Text -> Maybe Text -> Maybe Text -> Flow Value
fetchEnvsH _ap mProduct mEnv mService = do
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

-- | Proxy env fetch to sync cluster URL for secondary cloud.
-- Tries the namma-ap endpoint format (GET /envs) first, then falls back to
-- ny-autopilot format (POST /release/getenvs/).
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
                let u = if "http" `T.isPrefixOf` T.pack rawUrl then rawUrl else "http://" <> rawUrl
                 in if not (null u) && Prelude.last u == '/' then u else u <> "/"
              baseAuth = syncClusterBaseAuth cfg
              authArgs = if null baseAuth then [] else ["-H", "Authorization: Basic " <> baseAuth]
              getUrl = normalised <> "envs?product=" <> T.unpack product' <> "&env=" <> T.unpack env' <> "&service=" <> T.unpack service'
              getCurlArgs = ["-s", "-X", "GET", getUrl, "--max-time", "15"] <> authArgs
          -- TODO: migrate to structured logging (String-based URLs need T.pack conversion)
          logInfo $ "[SYNC-ENV] Fetching secondary envs from: " <> T.pack getUrl
          getResult <- liftIO (try (readProcessWithExitCode "curl" getCurlArgs "") :: IO (Either SomeException (ExitCode, String, String)))
          case getResult of
            Right (ExitSuccess, out, _) | not (null out) && out /= "[]" -> do
              -- TODO: migrate to structured logging (String-based URLs need T.pack conversion)
              logInfo $ "[SYNC-ENV] GET success, response length=" <> T.pack (show (length out))
              case A.decodeStrict' (encodeUtf8 (T.pack out)) :: Maybe Value of
                Just v -> pure v
                Nothing -> do
                  -- TODO: migrate to structured logging (String-based URLs need T.pack conversion)
                  logInfo $ "[SYNC-ENV] GET response not valid JSON, trying ny-autopilot format"
                  tryNyAutopilotFormat normalised baseAuth authArgs product' env' service'
            Right (ExitSuccess, out, _) -> do
              -- TODO: migrate to structured logging (String-based URLs need T.pack conversion)
              logInfo $ "[SYNC-ENV] GET returned empty/[], trying ny-autopilot format"
              tryNyAutopilotFormat normalised baseAuth authArgs product' env' service'
            Right (ExitFailure code, _, err) -> do
              -- TODO: migrate to structured logging (String-based URLs need T.pack conversion)
              logInfo $ "[SYNC-ENV] GET failed (exit=" <> T.pack (show code) <> "): " <> T.pack err <> ", trying ny-autopilot format"
              tryNyAutopilotFormat normalised baseAuth authArgs product' env' service'
            Left e -> do
              -- TODO: migrate to structured logging (String-based URLs need T.pack conversion)
              logInfo $ "[SYNC-ENV] GET exception: " <> T.pack (show e) <> ", trying ny-autopilot format"
              tryNyAutopilotFormat normalised baseAuth authArgs product' env' service'
    _ -> pure $ A.toJSON ([] :: [Value])
  where
    tryNyAutopilotFormat normalised baseAuth authArgs product' env' service' = do
      let postUrl = normalised <> "release/getenvs/"
          bodyJson =
            A.encode $
              object
                [ "product" .= product',
                  "env" .= env',
                  "service" .= service',
                  "secondary" .= True
                ]
          postCurlArgs =
            [ "-s",
              "-X",
              "POST",
              postUrl,
              "-H",
              "Content-Type: application/json",
              "-d",
              LBS.unpack bodyJson,
              "--max-time",
              "15"
            ]
              <> authArgs
      -- TODO: migrate to structured logging (String-based URLs need T.pack conversion)
      logInfo $ "[SYNC-ENV] Trying ny-autopilot format: POST " <> T.pack postUrl
      postResult <- liftIO (try (readProcessWithExitCode "curl" postCurlArgs "") :: IO (Either SomeException (ExitCode, String, String)))
      case postResult of
        Right (ExitSuccess, out, _) ->
          case A.decodeStrict' (encodeUtf8 (T.pack out)) of
            Just v -> pure v
            Nothing -> pure $ A.toJSON ([] :: [Value])
        _ -> pure $ A.toJSON ([] :: [Value])

-- ============================================================================
