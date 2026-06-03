{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Products.Autopilot.Actions.ConfigMap (
    -- * ConfigMap Tracker Handlers
    listConfigMapsH,
    getConfigMapH,
    createConfigMapH,
    updateConfigMapH,

    -- * K8s ConfigMap Lookup
    fetchConfigMapFromK8sH,
    fetchSecondaryConfigMapH,
)
where

import Control.Exception (SomeException, try)
import Control.Monad (void, when)
import Control.Monad.IO.Class (liftIO)
import Core.Auth.Protected (AuthedPerson)
import Core.Config (Config (..))
import Core.Environment (Flow, forkFlow, getConfig, logInfo)
import Core.Http.Client (HttpReq (..), HttpResponse (..), Method (..), defaultReq, httpRaw)
import Core.Logging (logErrorG, logInfoG)
import Core.Types.Time (Seconds (..))
import Data.Aeson (Value (..), object, toJSON, (.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import qualified Data.Yaml as Yaml
import Products.Autopilot.Notifications
import Products.Autopilot.Queries.ProductService (findProductByName, getProductNamespace)
import Products.Autopilot.Queries.ReleaseTracker
import Products.Autopilot.Types
import qualified Products.Autopilot.Types as NT
import Products.Autopilot.Types.API
import qualified Products.Autopilot.Types.Storage.Schema as S
import Products.Autopilot.Types.Target (TargetState (..), emptyConfigState)
import Products.Autopilot.Workflow.Helpers (captureConfigMapSnapshot)
import Shared.API.Response (APIResponse (..))
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

listConfigMapsH :: AuthedPerson -> Maybe Text -> Maybe Text -> Flow ConfigMapListResponse
listConfigMapsH _ap mFrom mTo = do
    now <- liftIO getCurrentTime
    let tryParse t = case parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" (T.unpack t) of
            Just v -> Just v
            Nothing -> parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Q%z" (T.unpack t)
        from = fromMaybe (addUTCTime (-2592000) now) (mFrom >>= tryParse)
        to = fromMaybe now (mTo >>= tryParse)
    pairs <- findReleaseTrackersByCategory "BackendConfig" from to
    pure $ ConfigMapListResponse (map (toConfigMapResponse . fst) pairs)

getConfigMapH :: AuthedPerson -> Text -> Flow Value
getConfigMapH _ap cmId' = do
    m <- findReleaseTracker cmId'
    case m of
        Nothing -> pure Null
        Just (rt, _) -> pure $ toJSON (toConfigMapResponse rt)

createConfigMapH :: AuthedPerson -> Value -> Flow APIResponse
createConfigMapH _ap body = do
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
                        , status = CREATED
                        , releaseWFStatus = INIT
                        , mode = AUTO
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
                        , syncEnabled = Nothing
                        , envOverrideData = Nothing
                        , slackThreadTs = Nothing
                        , -- ConfigMap releases carry no K8s context, but the record
                          -- field must be initialised or access crashes at runtime.
                          releaseContext = Nothing
                        , -- Mobile/revert-only fields — not applicable to a configmap
                          -- release. Must be set or the record is partial and crashes.
                          sourceRef = Nothing
                        , commitSha = Nothing
                        , revertsReleaseId = Nothing
                        }
                targetState = ConfigState emptyConfigState
            insertReleaseTracker tracker (Just targetState)
            insertReleaseEvent rid "BUSINESS" "TRACKER_CREATED" (toJSON tracker)
            -- Snapshot at creation so diff is immediately available.
            cfg <- getConfig
            let cmName = fromMaybe service' name'
            p <- findProductByName product'
            let ns = maybe product' getProductNamespace p
            captureConfigMapSnapshot cfg rid ns cmName "CONFIGMAP_BEFORE"
            notifyConfigMapCreated tracker
            let isSync = case body of
                    Object o -> isTruthy "isSync" o
                    _ -> False
            when (isSync && not (null (syncClusterUrl cfg))) $ do
                let rawUrl = syncClusterUrl cfg
                    normalised =
                        let u = if "http" `T.isPrefixOf` T.pack rawUrl then T.pack rawUrl else "http://" <> T.pack rawUrl
                         in if T.null u || T.last u == '/' then u else u <> "/"
                    baseAuth = syncClusterBaseAuth cfg
                    auth =
                        if null baseAuth
                            then []
                            else [("Authorization", "Basic " <> T.pack baseAuth)]
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
                    postReq =
                        (defaultReq postUrl)
                            { reqMethod = POST
                            , reqHeaders = ("Content-Type", "application/json") : auth
                            , reqBody = Just (A.encode syncBody)
                            , reqTimeout = Seconds 30
                            , reqRetries = 0
                            , reqLogTag = "configmap-sync"
                            }
                insertReleaseEvent
                    rid
                    "BUSINESS"
                    "CONFIGMAP_SYNC_REQUEST"
                    (toJSON (T.pack (LBS.unpack (A.encode syncBody))))
                void $
                    forkFlow $ do
                        syncResult <- liftIO $ httpRaw postReq
                        case syncResult of
                            Right HttpResponse{respStatus = s, respBody = b} | s < 400 -> do
                                logInfoG $ "[CONFIGMAP-SYNC] success (" <> T.pack (show s) <> ")"
                                insertReleaseEvent rid "BUSINESS" "CONFIGMAP_SYNC_RESPONSE" (toJSON (T.pack (LBS.unpack b)))
                            Right HttpResponse{respStatus = s, respBody = b} -> do
                                logErrorG $ "[CONFIGMAP-SYNC] failed (HTTP " <> T.pack (show s) <> ")"
                                insertReleaseEvent rid "BUSINESS" "CONFIGMAP_SYNC_FAILED" (toJSON (T.pack (LBS.unpack b)))
                            Left e -> do
                                logErrorG $ "[CONFIGMAP-SYNC] exception: " <> T.pack (show e)
                                insertReleaseEvent rid "BUSINESS" "CONFIGMAP_SYNC_FAILED" (toJSON (T.pack (show e)))
            pure $ APIResponse "SUCCESS" ("ConfigMap tracker created: " <> rid)

updateConfigMapH :: AuthedPerson -> Text -> Value -> Flow APIResponse
updateConfigMapH _ap cmId' body = do
    m <- findReleaseTracker cmId'
    case m of
        Nothing -> pure $ APIResponse "ERROR" "ConfigMap tracker not found"
        Just (rt, mts) -> do
            let isRevert = case body of
                    Object obj -> getStrM "status" obj == Just "revert"
                    _ -> False
            if isRevert
                then handleConfigMapRevert rt mts cmId'
                else do
                    let updated = applyCmUpdates rt body
                    -- CAS on snapshot status so concurrent writers can't be clobbered.
                    casOk <- conditionalUpdateTracker updated mts (releaseStatusToText (NT.status rt))
                    if not casOk
                        then pure $ APIResponse "ERROR" "ConfigMap was modified by another request. Please refresh and try again."
                        else do
                            case body of
                                Object obj -> do
                                    case getStrM "status" obj of
                                        Just "INPROGRESS" -> notifyConfigMapInProgress updated
                                        Just "COMPLETED" -> notifyConfigMapCompleted updated
                                        Just "ABORTED" -> do
                                            notifyConfigMapAborted updated
                                            restoreOriginalOnRevertCancel updated
                                        Just "PAUSED" -> notifyConfigMapPaused updated
                                        Just "RESUMED" -> notifyConfigMapResumed updated
                                        Just "DISCARDED" -> do
                                            notifyConfigMapDiscarded updated
                                            restoreOriginalOnRevertCancel updated
                                        Just "restart" -> notifyConfigMapUpdated updated "restarted"
                                        _ -> pure ()
                                    when (isTruthy "is_approved" obj) $
                                        notifyConfigMapApproved updated
                                    case getStrM "current_cool_off" obj of
                                        Just "0" -> notifyConfigMapFastForwarded updated
                                        _ -> pure ()
                                _ -> pure ()
                            pure $ APIResponse "SUCCESS" "ConfigMap tracker updated"

{- | When a revert tracker is discarded or aborted, restore the original
tracker from REVERTING back to COMPLETED.
-}
restoreOriginalOnRevertCancel :: ReleaseTracker -> Flow ()
restoreOriginalOnRevertCancel rt = do
    case NT.info rt of
        Just "REVERT" -> do
            let origId = T.stripPrefix "Revert of " =<< NT.description rt
            case origId of
                Just oid -> do
                    mOrig <- findReleaseTracker oid
                    case mOrig of
                        Just (origRt, origTs) | NT.status origRt == REVERTING -> do
                            let restored = origRt{NT.status = COMPLETED}
                            -- CAS: only restore if original is still REVERTING.
                            casOk <- conditionalUpdateTracker restored origTs (releaseStatusToText (NT.status origRt))
                            if casOk
                                then logInfo $ "[CONFIGMAP] Restored original tracker " <> oid <> " from REVERTING to COMPLETED"
                                else logInfo $ "[CONFIGMAP] CAS miss restoring original tracker " <> oid <> "; concurrent writer wins."
                        _ -> pure ()
                Nothing -> pure ()
        _ -> pure ()

handleConfigMapRevert :: ReleaseTracker -> Maybe TargetState -> Text -> Flow APIResponse
handleConfigMapRevert rt mts cmId' = do
    events <- listReleaseEvents cmId'
    let mBeforeSnap = find (\e -> S.reCategory e == "SNAPSHOT" && S.reLabel e == "CONFIGMAP_BEFORE") events
    case mBeforeSnap of
        Nothing -> pure $ APIResponse "ERROR" "No CONFIGMAP_BEFORE snapshot found to revert to"
        Just beforeEvt -> do
            newRid <- liftIO (UUID.toText <$> UUID.nextRandom)
            -- Extract just the data section so the workflow can patch the
            -- live configmap instead of replacing with a stale resourceVersion.
            let oldConfig = case S.rePayload beforeEvt of
                    String s -> Just (extractDataAsJson s)
                    _ -> Nothing
                revertTracker =
                    rt
                        { NT.releaseId = newRid
                        , NT.status = CREATED
                        , NT.releaseWFStatus = INIT
                        , NT.isApproved = False
                        , NT.description = Just ("Revert of " <> cmId')
                        , NT.changeLog = Just ("REVERTED from tracker " <> cmId')
                        , NT.info = Just "REVERT"
                        , NT.dateCreated = Nothing
                        , NT.lastUpdated = Nothing
                        }
                oldMeta = case NT.metadata revertTracker of
                    Just (Object o) -> o
                    _ -> KM.empty
                revertMeta = case oldConfig of
                    Just c ->
                        KM.insert (K.fromText "config") (String c) $
                            KM.insert (K.fromText "file") (String c) oldMeta
                    Nothing -> oldMeta
                finalTracker = revertTracker{NT.metadata = Just (Object revertMeta)}
                targetState = ConfigState emptyConfigState
            insertReleaseTracker finalTracker (Just targetState)
            insertReleaseEvent newRid "BUSINESS" "REVERT_TRACKER_CREATED" (toJSON ("Revert of " <> cmId'))
            cfg <- getConfig
            let cmName = NT.service finalTracker
            p <- findProductByName (NT.appGroup finalTracker)
            let ns = maybe (NT.appGroup finalTracker) getProductNamespace p
            captureConfigMapSnapshot cfg newRid ns cmName "CONFIGMAP_BEFORE"
            -- CAS: don't overwrite a concurrent status change on the original.
            casOk <- conditionalUpdateTracker (rt{NT.status = REVERTING}) mts (releaseStatusToText (NT.status rt))
            if not casOk
                then pure $ APIResponse "ERROR" "ConfigMap was modified by another request. Please refresh and try again."
                else do
                    notifyConfigMapReverted (rt{NT.status = REVERTING})
                    pure $ APIResponse "SUCCESS" ("Revert tracker created: " <> newRid)

-- | Fetch configmap names (no NAME) or data (with NAME) from K8s.
fetchConfigMapFromK8sH :: AuthedPerson -> Maybe Text -> Maybe Text -> Flow Value
fetchConfigMapFromK8sH _ap mProduct mName = do
    cfg <- getConfig
    case mProduct of
        Nothing -> pure $ object ["configMap" .= toJSON ([] :: [Text])]
        Just productName -> do
            p <- findProductByName productName
            case p of
                Nothing -> pure $ object ["configMap" .= toJSON ([] :: [Text])]
                Just pCfg -> do
                    let ns = getProductNamespace pCfg
                    case mName of
                        Nothing -> do
                            res <- liftIO $ try (readProcessWithExitCode (kubectlBin cfg) ["-n", T.unpack ns, "get", "configmap", "-o", "jsonpath={.items[*].metadata.name}"] "") :: Flow (Either SomeException (ExitCode, String, String))
                            case res of
                                Right (ExitSuccess, out, _) ->
                                    let cleaned = T.strip (T.pack out)
                                        names = filter (not . T.null) (T.words cleaned)
                                     in pure $ object ["configMap" .= names]
                                _ -> pure $ object ["configMap" .= toJSON ([] :: [Text])]
                        Just name' -> do
                            res <- liftIO $ try (readProcessWithExitCode (kubectlBin cfg) ["-n", T.unpack ns, "get", "configmap", T.unpack name', "-o", "jsonpath={.data}"] "") :: Flow (Either SomeException (ExitCode, String, String))
                            case res of
                                Right (ExitSuccess, out, _) ->
                                    let cleaned = T.strip (T.pack out)
                                     in pure $ object ["configMap" .= cleaned]
                                _ -> pure $ object ["configMap" .= ("" :: Text)]

-- | Fetch configmap from secondary cluster via sync URL.
fetchSecondaryConfigMapH :: AuthedPerson -> Maybe Text -> Maybe Text -> Flow Value
fetchSecondaryConfigMapH _ap mProduct mName = do
    cfg <- getConfig
    let rawUrl = syncClusterUrl cfg
    if null rawUrl
        then pure $ object ["configMap" .= toJSON ([] :: [Text])]
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
            logInfo $ "[SYNC-CONFIGMAP] Fetching secondary configmap from: " <> T.pack getUrl
            getResult <- liftIO (try (readProcessWithExitCode "curl" getCurlArgs "") :: IO (Either SomeException (ExitCode, String, String)))
            case getResult of
                Right (ExitSuccess, out, _) | not (null out) ->
                    case A.decodeStrict' (encodeUtf8 (T.pack out)) :: Maybe Value of
                        Just v -> pure v
                        Nothing -> pure $ object ["configMap" .= toJSON ([] :: [Text])]
                _ -> pure $ object ["configMap" .= toJSON ([] :: [Text])]

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
        statusText = T.pack (show (NT.status rt)) :: Text
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
            Just "CREATED" -> rt{NT.status = CREATED}
            Just "INPROGRESS" -> rt{NT.status = INPROGRESS}
            Just "COMPLETED" -> rt{NT.status = COMPLETED}
            Just "ABORTED" -> rt{NT.status = ABORTED}
            Just "DISCARDED" -> rt{NT.status = DISCARDED}
            Just "PAUSED" -> rt{NT.status = PAUSED}
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

{- | Extract the data section from a K8s ConfigMap YAML as JSON.
Input: "apiVersion: v1\ndata:\n  app.conf: |-\n    ...\nkind: ConfigMap\n..."
Output: "{\"app.conf\":\"...\"}" — just the data, no K8s wrapper.
If parsing fails, returns the input unchanged.
-}
extractDataAsJson :: Text -> Text
extractDataAsJson yamlText =
    case A.decodeStrict' (encodeUtf8 yamlText) :: Maybe Value of
        Just (Object obj) ->
            case KM.lookup (K.fromText "data") obj of
                Just dataVal -> TE.decodeUtf8 (LBS.toStrict (A.encode dataVal))
                Nothing -> yamlText
        _ ->
            case Yaml.decodeEither' (encodeUtf8 yamlText) :: Either Yaml.ParseException Value of
                Right (Object obj) ->
                    case KM.lookup (K.fromText "data") obj of
                        Just dataVal -> TE.decodeUtf8 (LBS.toStrict (A.encode dataVal))
                        Nothing -> yamlText
                _ -> yamlText
