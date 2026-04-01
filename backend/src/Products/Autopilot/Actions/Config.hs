{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Products.Autopilot.Actions.Config
    ( -- * Product Config CRUD
      listProductConfigsH
    , createProductConfigH
    , getProductConfigH
    , updateProductConfigH
    , deleteProductConfigH
    -- * Release Config CRUD
    , listReleaseConfigsH
    , createReleaseConfigH
    , getReleaseConfigH
    , updateReleaseConfigH
    , deleteReleaseConfigH
    -- * Server Config
    , listServerConfigH
    , upsertServerConfigH
    ) where

import Control.Applicative ((<|>))
import Control.Monad.IO.Class (liftIO)
import Core.Utils.FlowMonad (Flow, getDBEnv)
import Data.Aeson (Value (..), object, toJSON, (.=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Int (Int32)
import Products.Autopilot.Actions.Release (upsertProductH, upsertServiceH)
import Products.Autopilot.Queries.ProductService
import Products.Autopilot.Queries.ServerConfig (listAllServerConfigs, upsertServerConfig)
import Products.Autopilot.Queries.VsEditTracker (findProductConfigById, deleteProductConfig, listAllReleaseConfigs, findReleaseConfigById, deleteReleaseConfig)
import Products.Autopilot.Types.API
import Shared.Config.Registry (allConfigEntries, findConfigEntry, validateConfigValue)
import Shared.Config.Types (ConfigEntry (..), configGroupToText, configTypeDefault, configTypeTag)
import qualified Shared.Types.Storage.Schema as S

-- ============================================================================
-- Product Config CRUD (GET/POST/GET/:id/PUT/:id/DELETE/:id /products/config)
-- ============================================================================

listProductConfigsH :: Flow [ProductConfigResponse]
listProductConfigsH = do
    db <- getDBEnv
    rows <- liftIO $ listProducts db
    pure $ map toProductConfigResponse rows

toProductConfigResponse :: S.ProductConfig -> ProductConfigResponse
toProductConfigResponse p =
    ProductConfigResponse
        { id = S.productConfigId p
        , product = S.productName p
        , repoName = S.productRepoName p
        , productType = S.productType p
        , productAcronym = S.productAcronym p
        , releaseBranch = S.productReleaseBranch p
        , needInfraApproval = S.productNeedInfraApproval p
        , cluster = Just (getProductCluster p)
        , namespace = Just (getProductNamespace p)
        , vsName = Just (getProductVsName p)
        , syncCluster = getProductSyncCluster p
        }

createProductConfigH :: UpsertProductReq -> Flow APIResponse
createProductConfigH req = upsertProductH req

getProductConfigH :: Int32 -> Flow Value
getProductConfigH pid = do
    db <- getDBEnv
    m <- liftIO $ findProductConfigById db pid
    case m of
        Nothing -> pure $ object ["error" .= ("Product config not found" :: Text)]
        Just p -> pure $ toJSON (toProductConfigResponse p)

updateProductConfigH :: Int32 -> UpsertProductReq -> Flow APIResponse
updateProductConfigH _ req = upsertProductH req

deleteProductConfigH :: Int32 -> Flow APIResponse
deleteProductConfigH pid = do
    db <- getDBEnv
    liftIO $ deleteProductConfig db pid
    pure $ APIResponse "SUCCESS" "Product config deleted"

-- ============================================================================
-- Release Config CRUD (GET/POST/GET/:id/PUT/:id/DELETE/:id /services/config)
-- ============================================================================

listReleaseConfigsH :: Maybe Text -> Flow [ReleaseConfigResponse]
listReleaseConfigsH mProduct = do
    db <- getDBEnv
    rows <- case mProduct of
        Just p -> liftIO $ listReleaseConfigByProduct db p
        Nothing -> liftIO $ listAllReleaseConfigs db
    pure $ map toReleaseConfigResponse rows

toReleaseConfigResponse :: S.ReleaseConfig -> ReleaseConfigResponse
toReleaseConfigResponse r =
    ReleaseConfigResponse
        { id = S.releaseConfigId r
        , serviceName = S.serviceName r
        , serviceProduct = S.serviceProduct r
        , serviceType = S.serviceType r
        , emails = S.releaseConfigEmails r
        , rolloutStrategy = S.releaseConfigRolloutStrategy r
        , decisionConfig = S.releaseConfigDecisionConfig r
        , flags = S.releaseConfigFlags r
        , slackWebhookUrls = S.releaseConfigSlackWebhookUrls r
        , serviceAcronym = S.serviceAcronym r
        , bitbucketPath = S.releaseConfigBitbucketPath r
        , microserviceType = S.releaseConfigMicroserviceType r
        , revertStrategy = S.releaseConfigRevertStrategy r
        , jiraWebhookUrl = S.releaseConfigJiraWebhookUrl r
        , serviceHost = getServiceHost r
        }

createReleaseConfigH :: UpsertServiceReq -> Flow APIResponse
createReleaseConfigH req = upsertServiceH req

getReleaseConfigH :: Int32 -> Flow Value
getReleaseConfigH rid = do
    db <- getDBEnv
    m <- liftIO $ findReleaseConfigById db rid
    case m of
        Nothing -> pure $ object ["error" .= ("Release config not found" :: Text)]
        Just r -> pure $ toJSON (toReleaseConfigResponse r)

updateReleaseConfigH :: Int32 -> UpsertServiceReq -> Flow APIResponse
updateReleaseConfigH _ req = upsertServiceH req

deleteReleaseConfigH :: Int32 -> Flow APIResponse
deleteReleaseConfigH rid = do
    db <- getDBEnv
    liftIO $ deleteReleaseConfig db rid
    pure $ APIResponse "SUCCESS" "Release config deleted"

-- ============================================================================
-- Server Config
-- ============================================================================

listServerConfigH :: Flow Value
listServerConfigH = do
    db <- getDBEnv
    rows <- liftIO $ listAllServerConfigs db
    -- Build a map of DB rows by name
    let dbMap :: Map.Map Text (Int, Text, Text, Text, Int, Maybe Text)
        dbMap = Map.fromList [(n, row) | row@(_, _, n, _, _, _) <- rows]
        -- Merge registry entries with DB state
        mergedConfigs = map (mergeEntry dbMap) allConfigEntries
        -- Also include DB rows that are NOT in registry (unknown/legacy configs)
        registryKeys = map ceKey allConfigEntries
        extraDbConfigs = [mkUnknownObj row | row@(_, _, n, _, _, _) <- rows, n `notElem` registryKeys]
        allConfigs = mergedConfigs ++ extraDbConfigs
        -- Group by group name
        grouped = Map.toAscList $ Map.fromListWith (++) [(g, [c]) | (g, c) <- allConfigs]
        groupObjs = map (\(gName, cs) -> object ["name" .= gName, "configs" .= cs]) grouped
    -- Also return flat configs list for backward compat
    let flatConfigs = map toFlatObj rows
    pure $ object ["groups" .= groupObjs, "configs" .= flatConfigs]
  where
    mergeEntry dbMap entry =
        let key = ceKey entry
            groupName = configGroupToText (ceGroup entry)
            typTag = configTypeTag (ceType entry)
            defVal = configTypeDefault (ceType entry)
            prod = ceProduct entry
            desc = ceDescription entry
         in case Map.lookup key dbMap of
                Just (_rowId, _typ, _name, val, enabled, dbProd) ->
                    ( groupName
                    , object
                        [ "key" .= key
                        , "value" .= val
                        , "type" .= typTag
                        , "default" .= defVal
                        , "description" .= desc
                        , "product" .= (dbProd <|> prod)
                        , "enabled" .= (enabled == 1)
                        , "id" .= _rowId
                        ]
                    )
                Nothing ->
                    ( groupName
                    , object
                        [ "key" .= key
                        , "value" .= defVal
                        , "type" .= typTag
                        , "default" .= defVal
                        , "description" .= desc
                        , "product" .= prod
                        , "enabled" .= True
                        , "id" .= (0 :: Int)
                        ]
                    )
    mkUnknownObj (_rowId, typ, name, val, enabled, prod) =
        ( "General" :: Text
        , object
            [ "key" .= name
            , "value" .= val
            , "type" .= typ
            , "default" .= ("" :: Text)
            , "description" .= ("" :: Text)
            , "product" .= prod
            , "enabled" .= (enabled == 1)
            , "id" .= _rowId
            ]
        )
    toFlatObj (_rowId, typ, name, val, enabled, prod) =
        object
            [ "id" .= _rowId
            , "type" .= typ
            , "name" .= name
            , "value" .= val
            , "enabled" .= enabled
            , "product" .= prod
            ]

upsertServerConfigH :: Value -> Flow APIResponse
upsertServerConfigH (Object obj) = do
    db <- getDBEnv
    let name = getStr "name" obj
        value = fromMaybe "" (getStrM "value" obj)
        enabled = maybe True (\t -> t == "1" || T.toLower t == "true") (getStrM "enabled" obj)
    if T.null name
        then pure $ APIResponse "ERROR" "name is required"
        else case findConfigEntry name of
            Nothing ->
                pure $ APIResponse "ERROR" ("Unknown config key: " <> name)
            Just entry ->
                case validateConfigValue entry value of
                    Left err ->
                        pure $ APIResponse "ERROR" ("Validation failed for " <> name <> ": " <> err)
                    Right _ -> do
                        let typ = configTypeTag (ceType entry)
                            product_ = ceProduct entry
                        liftIO $ upsertServerConfig db name typ value enabled product_
                        pure $ APIResponse "SUCCESS" ("server_config upserted: " <> name)
upsertServerConfigH _ = pure $ APIResponse "ERROR" "Invalid JSON body"

-- ============================================================================
-- Local Helpers
-- ============================================================================

getStr :: Text -> KM.KeyMap Value -> Text
getStr k obj = case KM.lookup (K.fromText k) obj of Just (String t) -> t; _ -> ""

getStrM :: Text -> KM.KeyMap Value -> Maybe Text
getStrM k obj = case KM.lookup (K.fromText k) obj of Just (String t) | not (T.null t) -> Just t; _ -> Nothing
