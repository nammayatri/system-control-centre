{-# LANGUAGE OverloadedStrings #-}

-- | Backend config workflow (K8s ConfigMap apply)
--
-- Implements the ConfigMap apply workflow using the Recorded monad pattern.
-- Migrated from Runner.hs's processConfigMapTracker.
module Products.Autopilot.Workflow.BackendConfigWorkflow
  ( backendConfigWorkflow
  ) where

import Prelude hiding (product)
import Control.Monad.State.Strict (gets, modify)
import Control.Monad.Trans.Class (lift)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value (..), encode, eitherDecodeStrict')
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Aeson.Key as K
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE

import Core.Config (Config(..))
import Core.Utils.FlowMonad (getConfig, getDBEnv)
import Products.Autopilot.K8s.Execute (K8sError(..), K8sResult(..), runCmd, shellQuote)
import Products.Autopilot.Queries.ProductService (findProductByName, getProductNamespace)
import Products.Autopilot.Workflow.Helpers
  ( (|>>)
  , getRT
  , updateRT
  )
import Products.Autopilot.Workflow.Types
  ( ReleaseWorkFlow
  , StateFlow
  , ReleaseState(..)
  )
import Products.Autopilot.Types.Release (ReleaseStatus(..), ReleaseTracker(..))
import Products.Autopilot.Types.Workflow (ReleaseWFStatus(..))
import Products.Autopilot.Types.Target (TargetState(..), ConfigDeploymentState(..), BackendConfigWFStatus(..), emptyConfigState)

-- ============================================================================
-- Workflow Definition
-- ============================================================================

-- | Backend config workflow using generic stages
backendConfigWorkflow :: ReleaseWorkFlow ()
backendConfigWorkflow = do
  Init      |>> validateConfig
  Preparing |>> resolveConfigContent
  Deploying |>> applyConfigMap
  Done      |>> notifyComplete

-- ============================================================================
-- Helpers
-- ============================================================================

getCfg :: StateFlow Config
getCfg = lift getConfig

-- | Get file content from metadata
getFileContent :: StateFlow (Maybe Text)
getFileContent = do
  rt <- getRT
  pure $ case metadata rt of
    Just (Object o) ->
      case KM.lookup (K.fromText "file") o of
        Just (String t) | not (T.null t) -> Just t
        _ -> case KM.lookup (K.fromText "config") o of
               Just (String t) | not (T.null t) -> Just t
               _ -> Nothing
    _ -> Nothing

-- | Update config workflow status in target state
updateConfigStatus :: BackendConfigWFStatus -> StateFlow ()
updateConfigStatus newStatus = do
  rs <- gets id
  case targetState rs of
    Just (ConfigState cs) ->
      modify $ \s -> s { targetState = Just (ConfigState (cs { categoryWorkflowStatus = newStatus })) }
    _ ->
      modify $ \s -> s { targetState = Just (ConfigState (emptyConfigState { categoryWorkflowStatus = newStatus })) }

-- ============================================================================
-- Workflow Step Implementations
-- ============================================================================

-- | Validate that the tracker has config/file content
validateConfig :: StateFlow ()
validateConfig = do
  rt <- getRT
  liftIO $ putStrLn $ "Validating config for " <> T.unpack (product rt)
  updateConfigStatus BCInit

  fileContent <- getFileContent
  case fileContent of
    Nothing -> error "No file/config content in metadata"
    Just fc | T.null (T.strip fc) -> error "Empty file/config content"
    Just _ -> pure ()

  liftIO $ putStrLn "Config validation passed"

-- | Resolve the config content: if raw K8s manifest use directly, otherwise patch existing ConfigMap
resolveConfigContent :: StateFlow ()
resolveConfigContent = do
  rt <- getRT
  cfg <- getCfg
  liftIO $ putStrLn $ "Resolving config content for " <> T.unpack (product rt)
  updateConfigStatus BCApplyConfigMap

  fileContent <- getFileContent
  case fileContent of
    Nothing -> error "No file content (should have been caught in validation)"
    Just fc -> do
      -- Resolve namespace from product config
      db <- lift getDBEnv
      p <- liftIO $ findProductByName db (product rt)
      let ns = case p of
            Just pCfg -> T.unpack (getProductNamespace pCfg)
            Nothing -> case metadata rt of
              Just (Object o) -> case KM.lookup (K.fromText "cluster") o of
                Just (String c) | not (T.null c) -> T.unpack c
                _ -> T.unpack (env rt)
              _ -> T.unpack (env rt)

      if isK8sManifest fc
        then do
          -- Store resolved content + namespace in workflowMetadata for Deploying stage
          let resolved = Object $ KM.fromList
                [ ("namespace", String (T.pack ns))
                , ("resolvedContent", String fc)
                ]
          modify $ \s -> s { workflowMetadata = Just resolved }
          liftIO $ putStrLn "  Content is raw K8s manifest, will apply directly"
        else do
          -- Fetch existing ConfigMap and patch it
          let cmName' = T.unpack (service rt)
              getCmd = unwords [kubectlBin cfg, "get configmap", cmName', "-n", ns, "-o json"]
          liftIO $ putStrLn $ "  Fetching existing ConfigMap: " <> cmName'
          getRes <- liftIO $ runCmd getCmd
          case getRes of
            Left (K8sError err) -> error $ "Failed to fetch existing ConfigMap: " <> T.unpack err
            Right (K8sResult existingJson) -> do
              case patchConfigMapJson existingJson fc of
                Left err -> error $ T.unpack err
                Right patchedContent -> do
                  let resolved = Object $ KM.fromList
                        [ ("namespace", String (T.pack ns))
                        , ("resolvedContent", String patchedContent)
                        ]
                  modify $ \s -> s { workflowMetadata = Just resolved }
                  liftIO $ putStrLn "  Patched existing ConfigMap with new data"

  liftIO $ putStrLn "Config content resolved"

-- | Apply the resolved ConfigMap content via kubectl replace
applyConfigMap :: StateFlow ()
applyConfigMap = do
  rt <- getRT
  cfg <- getCfg
  liftIO $ putStrLn $ "Applying ConfigMap for " <> T.unpack (product rt)

  rs <- gets id
  case workflowMetadata rs of
    Just (Object wm) -> do
      let ns = case KM.lookup "namespace" wm of
                 Just (String n) -> T.unpack n
                 _ -> error "Missing namespace in workflow metadata"
          content = case KM.lookup "resolvedContent" wm of
                      Just (String c) -> c
                      _ -> error "Missing resolvedContent in workflow metadata"
      result <- liftIO $ replaceFromStdin cfg ns content
      case result of
        Right () -> do
          updateConfigStatus BCDone
          modify $ \s -> s { targetState =
            case targetState s of
              Just (ConfigState cs) -> Just (ConfigState (cs { configMapsUpdated = [service rt], rolloutComplete = True }))
              _ -> Just (ConfigState (emptyConfigState { configMapsUpdated = [service rt], rolloutComplete = True }))
            }
          liftIO $ putStrLn "ConfigMap applied successfully"
        Left err -> error $ "kubectl replace failed: " <> T.unpack err
    _ -> error "Missing workflow metadata (resolveConfigContent did not run?)"

-- | Mark workflow as complete
notifyComplete :: StateFlow ()
notifyComplete = do
  rt <- getRT
  liftIO $ putStrLn $ "ConfigMap release " <> T.unpack (releaseId rt) <> " completed!"
  updateRT $ \r -> r { status = Completed }

-- ============================================================================
-- ConfigMap Helpers (moved from Runner.hs)
-- ============================================================================

-- | Pipe content into kubectl replace -f -
replaceFromStdin :: Config -> String -> Text -> IO (Either Text ())
replaceFromStdin cfg ns content = do
  let cmd = unwords ["echo", shellQuote content, "|", kubectlBin cfg, "-n", ns, "replace -f -"]
  res <- runCmd cmd
  case res of
    Right _ -> pure (Right ())
    Left (K8sError err) -> pure (Left ("kubectl replace failed: " <> err))

-- | Check if content looks like a raw K8s YAML manifest
isK8sManifest :: Text -> Bool
isK8sManifest t =
  let stripped = T.strip t
  in T.isPrefixOf "apiVersion:" stripped
     || T.isPrefixOf "kind:" stripped
     || T.isPrefixOf "---" stripped

-- | Patch an existing ConfigMap JSON: replace "data" with new content, strip extra metadata.
patchConfigMapJson :: Text -> Text -> Either Text Text
patchConfigMapJson existingJson newDataContent =
  case eitherDecodeStrict' (encodeUtf8 existingJson) of
    Left err -> Left ("Failed to parse existing ConfigMap JSON: " <> T.pack err)
    Right (Object obj) ->
      let newData = case eitherDecodeStrict' (encodeUtf8 newDataContent) of
            Right val -> val
            Left _ -> String newDataContent
          cleanMeta = case KM.lookup "metadata" obj of
            Just (Object meta) ->
              let kept = KM.fromList $ concat
                    [ maybe [] (\v -> [("name", v)]) (KM.lookup "name" meta)
                    , maybe [] (\v -> [("namespace", v)]) (KM.lookup "namespace" meta)
                    , maybe [] (\v -> [("labels", v)]) (KM.lookup "labels" meta)
                    ]
              in Object kept
            other -> fromMaybe (Object KM.empty) other
          cleaned = Object $ KM.fromList
            [ ("apiVersion", fromMaybe (String "v1") (KM.lookup "apiVersion" obj))
            , ("kind", fromMaybe (String "ConfigMap") (KM.lookup "kind" obj))
            , ("metadata", cleanMeta)
            , ("data", newData)
            ]
      in Right (TL.toStrict (TLE.decodeUtf8 (encode cleaned)))
    Right _ -> Left "Existing ConfigMap is not a JSON object"
