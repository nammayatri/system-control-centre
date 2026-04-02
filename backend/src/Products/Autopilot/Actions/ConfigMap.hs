{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Products.Autopilot.Actions.ConfigMap
    ( -- * ConfigMap Tracker Handlers
      listConfigMapsH
    , getConfigMapH
    , createConfigMapH
    , updateConfigMapH
    ) where

import Control.Concurrent (forkIO)
import Control.Exception (SomeException, try)
import Control.Monad (void, when)
import Control.Monad.IO.Class (liftIO)
import Core.Config (Config (..))
import Core.Utils.FlowMonad (Flow, getConfig, getDBEnv)
import Data.Aeson (Value (..), object, toJSON, (.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import Products.Autopilot.Notifications
import Products.Autopilot.Queries.ReleaseTracker
import Products.Autopilot.Types
import qualified Products.Autopilot.Types as NT
import Products.Autopilot.Types.API
import Products.Autopilot.Types.Target (TargetState (..), emptyConfigState)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

-- ============================================================================
-- ConfigMap Tracker Handlers
-- ============================================================================

listConfigMapsH :: Maybe Text -> Maybe Text -> Flow ConfigMapListResponse
listConfigMapsH mFrom mTo = do
    db <- getDBEnv
    now <- liftIO getCurrentTime
    let tryParse t = case parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" (T.unpack t) of
            Just v -> Just v
            Nothing -> parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Q%z" (T.unpack t)
        from = fromMaybe (addUTCTime (-2592000) now) (mFrom >>= tryParse)
        to = fromMaybe now (mTo >>= tryParse)
    pairs <- liftIO $ findReleaseTrackersByCategory db "BackendConfig" from to
    pure $ ConfigMapListResponse (map (toConfigMapResponse . fst) pairs)

getConfigMapH :: Text -> Flow Value
getConfigMapH cmId' = do
    db <- getDBEnv
    m <- liftIO $ findReleaseTracker db cmId'
    case m of
        Nothing -> pure Null
        Just (rt, _) -> pure $ toJSON (toConfigMapResponse rt)

createConfigMapH :: Value -> Flow APIResponse
createConfigMapH body = do
    db <- getDBEnv
    rid <- liftIO (UUID.toText <$> UUID.nextRandom)
    case extractCmFields body of
        Left err -> pure $ APIResponse "ERROR" err
        Right (product', service', env', cluster', desc, changeLog', config', releaseManager', priority', _scheduleTime', name') -> do
            let cmMetadata =
                    object $
                        concat
                            [ maybe [] (\c -> ["config" .= c]) config'
                            , maybe [] (\c -> ["file" .= c]) config'
                            , maybe [] (\n -> ["name" .= n]) name'
                            , maybe [] (\c -> ["cluster" .= c]) (if T.null cluster' then Nothing else Just cluster')
                            ]
                tracker =
                    ReleaseTracker
                        { releaseId = rid
                        , appGroup = product'
                        , service = fromMaybe service' name'
                        , env = env'
                        , category = BackendConfig
                        , status = Created
                        , releaseWFStatus = Init
                        , mode = Auto
                        , createdBy = releaseManager'
                        , approvedBy = Nothing
                        , isApproved = False
                        , isInfraApproved = False
                        , releaseTag = Nothing
                        , dateCreated = Nothing
                        , lastUpdated = Nothing
                        , scheduleTime = Nothing
                        , startTime = Nothing
                        , endTime = Nothing
                        , rolloutStrategy = []
                        , rolloutHistory = []
                        , oldVersion = ""
                        , newVersion = ""
                        , info = Nothing
                        , description = desc
                        , changeLog = changeLog'
                        , metadata = Just cmMetadata
                        , priority = fromIntegral priority'
                        , globalId = Nothing
                        , udf1 = Nothing
                        , udf2 = Nothing
                        , udf3 = Nothing
                        }
                targetState = ConfigState emptyConfigState
            liftIO $ insertReleaseTracker db tracker (Just targetState)
            liftIO $ insertReleaseEvent db rid "BUSINESS" "TRACKER_CREATED" (toJSON tracker)
            liftIO $ notifyConfigMapCreated db tracker
            -- Handle sync to secondary cluster
            let isSync = case body of
                    Object o -> isTruthy "isSync" o
                    _ -> False
            cfg <- getConfig
            when (isSync && not (null (syncClusterUrl cfg))) $ do
                let rawUrl = syncClusterUrl cfg
                    normalised =
                        let u = if "http" `T.isPrefixOf` T.pack rawUrl then rawUrl else "http://" <> rawUrl
                         in if not (null u) && Prelude.last u == '/' then u else u <> "/"
                    baseAuth = syncClusterBaseAuth cfg
                    authArgs = if null baseAuth then [] else ["-H", "Authorization: Basic " <> baseAuth]
                    secondaryFile = case body of
                        Object o -> getStrM "secondary_file" o
                        _ -> Nothing
                    syncBody = case body of
                        Object o ->
                            let o1 = KM.insert (K.fromText "isSync") (Bool False) o
                                o2 = case secondaryFile of
                                    Just sf -> KM.insert (K.fromText "file") (String sf) o1
                                    Nothing -> o1
                                o3 = KM.delete (K.fromText "secondary_file") o2
                             in Object o3
                        v -> v
                    postUrl = normalised <> "tracker/configmap"
                    postCurlArgs =
                        [ "-s"
                        , "-X"
                        , "POST"
                        , postUrl
                        , "-H"
                        , "Content-Type: application/json"
                        , "-d"
                        , LBS.unpack (A.encode syncBody)
                        , "--max-time"
                        , "30"
                        ]
                            <> authArgs
                liftIO $
                    insertReleaseEvent
                        db
                        rid
                        "BUSINESS"
                        "CONFIGMAP_SYNC_REQUEST"
                        (toJSON (T.pack (LBS.unpack (A.encode syncBody))))
                liftIO $ void $ forkIO $ do
                    putStrLn $ "[CONFIGMAP-SYNC] Posting to secondary: " <> postUrl
                    syncResult <- try (readProcessWithExitCode "curl" postCurlArgs "") :: IO (Either SomeException (ExitCode, String, String))
                    case syncResult of
                        Right (ExitSuccess, out, _) -> do
                            putStrLn $ "[CONFIGMAP-SYNC] Success, response: " <> out
                            insertReleaseEvent db rid "BUSINESS" "CONFIGMAP_SYNC_RESPONSE" (toJSON (T.pack out))
                        Right (ExitFailure code, _, err) -> do
                            putStrLn $ "[CONFIGMAP-SYNC] Failed (exit=" <> show code <> "): " <> err
                            insertReleaseEvent db rid "BUSINESS" "CONFIGMAP_SYNC_FAILED" (toJSON (T.pack err))
                        Left e -> do
                            putStrLn $ "[CONFIGMAP-SYNC] Exception: " <> show e
                            insertReleaseEvent db rid "BUSINESS" "CONFIGMAP_SYNC_FAILED" (toJSON (T.pack (show e)))
            pure $ APIResponse "SUCCESS" ("ConfigMap tracker created: " <> rid)

updateConfigMapH :: Text -> Value -> Flow APIResponse
updateConfigMapH cmId' body = do
    db <- getDBEnv
    m <- liftIO $ findReleaseTracker db cmId'
    case m of
        Nothing -> pure $ APIResponse "ERROR" "ConfigMap tracker not found"
        Just (rt, mts) -> do
            let updated = applyCmUpdates rt body
            liftIO $ insertReleaseTracker db updated mts
            liftIO $ notifyConfigMapUpdated db updated "status updated"
            pure $ APIResponse "SUCCESS" "ConfigMap tracker updated"

-- ============================================================================
-- Internal Helpers
-- ============================================================================

-- | Convert a ReleaseTracker (category=BackendConfig) to typed ConfigMapResponse
toConfigMapResponse :: ReleaseTracker -> ConfigMapResponse
toConfigMapResponse rt =
    let meta = case NT.metadata rt of
            Just (Object o) -> o
            _ -> KM.empty
        getMetaStr k = case KM.lookup (K.fromText k) meta of
            Just (String t) -> Just t
            _ -> Nothing
        configVal = getMetaStr "config"
        fileVal = getMetaStr "file"
        nameVal = getMetaStr "name"
        clusterVal = fromMaybe "" (getMetaStr "cluster")
        statusText = case NT.status rt of
            Created -> "CREATED" :: Text
            InProgress -> "INPROGRESS"
            Completed -> "COMPLETED"
            Aborted -> "ABORTED"
            UserAborted -> "ABORTED"
            _ -> T.pack (show (NT.status rt))
     in ConfigMapResponse
            { cmrId = NT.releaseId rt
            , cmrService = NT.service rt
            , cmrAppGroup = NT.appGroup rt
            , cmrName = nameVal
            , cmrStatus = statusText
            , cmrDescription = fromMaybe "" (NT.description rt)
            , cmrEnv = NT.env rt
            , cmrCluster = clusterVal
            , cmrDateCreated = NT.dateCreated rt
            , cmrLastUpdated = NT.lastUpdated rt
            , cmrStartTime = NT.startTime rt
            , cmrEndTime = NT.endTime rt
            , cmrReleaseManager = NT.createdBy rt
            , cmrIsApproved = if NT.isApproved rt then 1 else 0
            , cmrIsInfraApproved = if NT.isInfraApproved rt then 1 else 0
            , cmrEvents = []
            , cmrReleaseTag = NT.releaseTag rt
            , cmrConfig = configVal
            , cmrFile = fileVal
            , cmrCommit = getMetaStr "commit"
            , cmrChangeLog = fromMaybe "" (NT.changeLog rt)
            , cmrPriority = NT.priority rt
            , cmrScheduleTime = NT.scheduleTime rt
            , cmrSlackThreadId = ""
            }

extractCmFields :: Value -> Either Text (Text, Text, Text, Text, Maybe Text, Maybe Text, Maybe Text, Text, Int, Maybe UTCTime, Maybe Text)
extractCmFields (Object obj) =
    Right
        ( fromMaybe (getStr "product" obj) (getStrM "appGroup" obj)
        , getStr "service" obj
        , fromMaybe "UAT" (getStrM "env" obj)
        , fromMaybe "" (getStrM "cluster" obj)
        , getStrM "description" obj
        , getStrM "change_log" obj
        , firstJust (getStrM "file" obj) (getStrM "config" obj)
        , fromMaybe "local_admin" (getStrM "release_manager" obj)
        , fromMaybe 0 (getStrM "priority" obj >>= safeReadInt)
        , Nothing
        , getStrM "name" obj
        )
extractCmFields _ = Left "Invalid JSON body"

applyCmUpdates :: ReleaseTracker -> Value -> ReleaseTracker
applyCmUpdates rt (Object obj) =
    let rt1 = case getStrM "status" obj of
            Just "CREATED" -> rt{NT.status = Created}
            Just "INPROGRESS" -> rt{NT.status = InProgress}
            Just "COMPLETED" -> rt{NT.status = Completed}
            Just "ABORTED" -> rt{NT.status = Aborted}
            _ -> rt
        rt2 = maybe rt1 (\s -> rt1{NT.description = Just s}) (getStrM "description" obj)
        rt3 = maybe rt2 (\s -> rt2{NT.changeLog = Just s}) (getStrM "change_log" obj)
        rt4 = if isTruthy "is_approved" obj then rt3{NT.isApproved = True} else rt3
        rt5 = if isTruthy "is_infra_approved" obj then rt4{NT.isInfraApproved = True} else rt4
        -- Update metadata fields (config/file/commit)
        oldMeta = case NT.metadata rt5 of
            Just (Object o) -> o
            _ -> KM.empty
        newMeta1 = case firstJust (getStrM "file" obj) (getStrM "config" obj) of
            Just c ->
                KM.insert (K.fromText "config") (String c) $
                    KM.insert (K.fromText "file") (String c) oldMeta
            Nothing -> oldMeta
        newMeta2 = case getStrM "commit" obj of
            Just c -> KM.insert (K.fromText "commit") (String c) newMeta1
            Nothing -> newMeta1
        rt6 = rt5{NT.metadata = Just (Object newMeta2)}
     in rt6
applyCmUpdates rt _ = rt

isTruthy :: Text -> KM.KeyMap Value -> Bool
isTruthy k obj = case KM.lookup (K.fromText k) obj of
    Just (String t) -> t `elem` ["true", "1", "True", "yes"]
    Just (Number n) -> n > 0
    Just (Bool b) -> b
    _ -> False

getStr :: Text -> KM.KeyMap Value -> Text
getStr k obj = case KM.lookup (K.fromText k) obj of Just (String t) -> t; _ -> ""

getStrM :: Text -> KM.KeyMap Value -> Maybe Text
getStrM k obj = case KM.lookup (K.fromText k) obj of Just (String t) | not (T.null t) -> Just t; _ -> Nothing

safeReadInt :: Text -> Maybe Int
safeReadInt t = case reads (T.unpack t) of ((n, _) : _) -> Just n; _ -> Nothing

firstJust :: Maybe a -> Maybe a -> Maybe a
firstJust (Just x) _ = Just x
firstJust Nothing b = b
