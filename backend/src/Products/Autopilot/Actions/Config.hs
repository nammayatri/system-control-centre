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
    , deleteServerConfigH
    ) where

import Control.Applicative ((<|>))
import Control.Monad.IO.Class (liftIO)
import Core.Utils.FlowMonad (Flow, getDBEnv)
import Data.Aeson (Value (..), toJSON)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Int (Int32)
import Products.Autopilot.Actions.Release (upsertProductH, upsertServiceH)
import Products.Autopilot.Queries.ProductService
import Products.Autopilot.Queries.ServerConfig (listServerConfigsByProduct, upsertServerConfig, deleteServerConfig)
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

toProductConfigResponse :: S.DeploymentConfig -> ProductConfigResponse
toProductConfigResponse p =
    ProductConfigResponse
        { id = S.dcId p
        , appGroup = S.dcAppGroup p
        , productType = fromMaybe "SERVICE" (S.dcAppGroupType p)
        , productAcronym = fromMaybe "" (S.dcAppGroupAcronym p)
        , needInfraApproval = S.dcNeedInfraApproval p
        , cluster = S.dcCluster p
        , namespace = S.dcNamespace p
        , vsName = S.dcVsName p
        , syncCluster = S.dcSyncCluster p
        }

createProductConfigH :: UpsertProductReq -> Flow APIResponse
createProductConfigH req = upsertProductH req

getProductConfigH :: Int32 -> Flow Value
getProductConfigH pid = do
    db <- getDBEnv
    m <- liftIO $ findProductConfigById db pid
    case m of
        Nothing -> pure $ toJSON $ ErrorResponse "Product config not found" Nothing
        Just p -> pure $ toJSON (toProductConfigResponse p)

updateProductConfigH :: Int32 -> UpsertProductReq -> Flow APIResponse
updateProductConfigH pathId req = upsertProductH (req { Products.Autopilot.Types.API.id = Just pathId })

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

toReleaseConfigResponse :: S.DeploymentConfig -> ReleaseConfigResponse
toReleaseConfigResponse r =
    ReleaseConfigResponse
        { id = S.dcId r
        , serviceName = fromMaybe "" (S.dcService r)
        , serviceProduct = S.dcAppGroup r
        , serviceType = fromMaybe "SERVICE" (S.dcServiceType r)
        , rolloutStrategy = S.dcRolloutStrategy r
        , decisionConfig = S.dcDecisionConfig r
        , flags = Nothing
        , slackWebhookUrls = S.dcSlackChannel r
        , microserviceType = Nothing
        , revertStrategy = S.dcRevertStrategy r
        , jiraWebhookUrl = Nothing
        , serviceHost = S.dcServiceHost r
        }

createReleaseConfigH :: UpsertServiceReq -> Flow APIResponse
createReleaseConfigH req = upsertServiceH req

getReleaseConfigH :: Int32 -> Flow Value
getReleaseConfigH rid = do
    db <- getDBEnv
    m <- liftIO $ findReleaseConfigById db rid
    case m of
        Nothing -> pure $ toJSON $ ErrorResponse "Release config not found" Nothing
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

listServerConfigH :: Maybe Text -> Flow ServerConfigResponse
listServerConfigH mProduct = do
    db <- getDBEnv
    rows <- liftIO $ listServerConfigsByProduct db mProduct
    -- Build a map of DB rows by name
    let dbMap :: Map.Map Text (Int, Text, Text, Text, Int, Maybe Text)
        dbMap = Map.fromList [(n, row) | row@(_, _, n, _, _, _) <- rows]
        -- Merge registry entries with DB state
        mergedConfigs = map (mergeEntry dbMap) allConfigEntries
        -- Also include DB rows that are NOT in registry (unknown/legacy configs)
        registryKeys = map ceKey allConfigEntries
        extraDbConfigs = [mkUnknownEntry row | row@(_, _, n, _, _, _) <- rows, n `notElem` registryKeys]
        allConfigs = mergedConfigs ++ extraDbConfigs
        -- Group by group name
        grouped = Map.toAscList $ Map.fromListWith (++) [(g, [c]) | (g, c) <- allConfigs]
        groupObjs = map (\(gName, cs) -> ServerConfigGroup gName cs) grouped
    -- Also return flat configs list for backward compat
    let flatConfigs = map toFlatItem rows
    pure $ ServerConfigResponse groupObjs flatConfigs
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
                    , ServerConfigEntry
                        { sceKey = key
                        , sceValue = val
                        , sceType = typTag
                        , sceDefault = defVal
                        , sceDescription = desc
                        , sceProduct = dbProd <|> prod
                        , sceEnabled = enabled == 1
                        , sceId = _rowId
                        }
                    )
                Nothing ->
                    ( groupName
                    , ServerConfigEntry
                        { sceKey = key
                        , sceValue = defVal
                        , sceType = typTag
                        , sceDefault = defVal
                        , sceDescription = desc
                        , sceProduct = prod
                        , sceEnabled = True
                        , sceId = 0
                        }
                    )
    mkUnknownEntry (_rowId, typ, name, val, enabled, prod) =
        ( "General" :: Text
        , ServerConfigEntry
            { sceKey = name
            , sceValue = val
            , sceType = typ
            , sceDefault = ""
            , sceDescription = ""
            , sceProduct = prod
            , sceEnabled = enabled == 1
            , sceId = _rowId
            }
        )
    toFlatItem (_rowId, typ, name, val, enabled, prod) =
        ServerConfigFlatItem
            { scfId = _rowId
            , scfType = typ
            , scfName = name
            , scfValue = val
            , scfEnabled = enabled
            , scfProduct = prod
            }

upsertServerConfigH :: UpsertServerConfigReq -> Flow APIResponse
upsertServerConfigH req = do
    db <- getDBEnv
    let name = uscName req
        value = fromMaybe "" (uscValue req)
        enabled = maybe True (\t -> t == "1" || T.toLower t == "true") (uscEnabled req)
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

deleteServerConfigH :: Int32 -> Flow APIResponse
deleteServerConfigH configId = do
    db <- getDBEnv
    liftIO $ deleteServerConfig db configId
    pure $ APIResponse "SUCCESS" "Server config deleted"
