{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The only place the capacity scaler talks to Google Cloud: the Memorystore for Valkey API, the AlloyDB
API (read pools), and the Cloud Scheduler API (read, rewrite, pause and resume the job that feeds an
autoscaler).

The client is a plain record ('Gcp') so tests can substitute an in-memory cloud. There is no @gcloud@
binary involved: the access token comes from the workload identity of the pod (the metadata server), or
from @SC_GCP_ACCESS_TOKEN@ for local development.
-}
module Products.Autopilot.Scaler.Gcp (
    Gcp (..),
    GcpErr (..),
    gcpErrText,
    Op (..),
    InstanceUpdate (..),
    SchedulerJob (..),
    Discovered (..),
    mkGcp,
    safeSegment,
    parseInstance,
    parseReadPool,
    parseDiscovered,
    parseOp,
    parseJob,
    resizeRequest,
    jobPatchBody,
    refreshableStatus,
)
where

import Control.Exception (SomeException, try)
import Core.Http.Client (HttpError (..), HttpReq (..), HttpResponse (..), Method (..), defaultReq, httpRaw)
import Core.Secrets (lookupEnvSecret)
import Core.Types.Time (Seconds (..))
import Data.Aeson (Value (..))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Data.Char (isAlphaNum)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)
import Data.Vector qualified as V
import Products.Autopilot.Scaler.Types
import System.IO.Unsafe (unsafePerformIO)

data GcpErr
    = GcpNotFound Text
    | -- | The target is busy with another operation, or a concurrent edit won. Retry later.
      GcpConflict Text
    | GcpFailed Text
    deriving (Eq, Show)

gcpErrText :: GcpErr -> Text
gcpErrText (GcpNotFound t) = t
gcpErrText (GcpConflict t) = t
gcpErrText (GcpFailed t) = t

-- | A long-running operation (Memorystore or AlloyDB).
data Op = Op
    { opName :: Text
    , opDone :: Bool
    , opError :: Maybe Text
    }
    deriving (Eq, Show)

-- | A resize. @UpdateUnits@ is the shard count (Valkey cluster) or node count (AlloyDB read pool).
data InstanceUpdate = UpdateUnits Int | UpdateReplicas Int
    deriving (Eq, Show)

-- | The Cloud Scheduler job that feeds an autoscaler, as read.
data SchedulerJob = SchedulerJob
    { sjData :: Text
    -- ^ The base64 payload (@pubsubTarget.data@).
    , sjState :: Text
    -- ^ @ENABLED@, @PAUSED@, ...
    , sjSchedule :: Text
    , sjRaw :: Value
    -- ^ The whole job, kept so the rest of @pubsubTarget@ survives a rewrite.
    }
    deriving (Eq, Show)

-- | Something that exists in a project and location and could be registered as a target.
data Discovered = Discovered
    { dsParent :: Maybe Text
    , dsResource :: Text
    , dsState :: InstanceState
    }
    deriving (Eq, Show)

data Gcp = Gcp
    { gcpGetState :: Target -> IO (Either GcpErr InstanceState)
    , gcpDiscover :: TargetKind -> Text -> Text -> IO (Either GcpErr [Discovered])
    , gcpResize :: Target -> InstanceUpdate -> IO (Either GcpErr Op)
    , gcpGetOperation :: Target -> Text -> IO (Either GcpErr Op)
    , gcpGetJob :: Target -> IO (Either GcpErr SchedulerJob)
    , gcpSetJobData :: Target -> SchedulerJob -> Text -> IO (Either GcpErr ())
    , gcpSetJobPaused :: Target -> Bool -> IO (Either GcpErr ())
    }

-- ---------------------------------------------------------------------------
-- Pure request / response shapes (exported for tests)

-- | Names go into URLs; accept only what GCP itself allows.
safeSegment :: Text -> Bool
safeSegment t = not (T.null t) && T.length t <= 128 && T.all (\c -> isAlphaNum c || c == '-' || c == '_') t

str :: A.Object -> Text -> Maybe Text
str o k = case KM.lookup (K.fromText k) o of
    Just (String t) -> Just t
    _ -> Nothing

-- | A count field. proto3 JSON leaves out a zero, so a missing one means @def@; int64 may arrive as a string.
count :: A.Object -> Text -> Maybe Int -> Either Text Int
count o k def = case KM.lookup (K.fromText k) o of
    Nothing -> maybe (Left (k <> " is missing")) Right def
    Just v -> case A.fromJSON v of
        A.Success n -> Right n
        A.Error _ -> case v of
            String s | [(n, "")] <- reads (T.unpack s) -> Right n
            _ -> Left (k <> " is not a number")

parseInstance :: Value -> Either Text InstanceState
parseInstance (Object o) = do
    mode <- maybe (Left "the instance has no mode") Right (str o "mode")
    m <- case parseInstanceMode mode of
        Just x | x /= ModeReadPool -> Right x
        _ -> Left ("unsupported instance mode: " <> mode)
    st <- maybe (Left "the instance has no state") Right (str o "state")
    units <- case m of
        ModeCluster -> do
            n <- count o "shardCount" (Just 0)
            if n < 1 then Left "the cluster instance reports no shardCount" else Right n
        _ -> count o "shardCount" (Just 1)
    replicas <- count o "replicaCount" (Just 0)
    pure (InstanceState m st units replicas)
parseInstance _ = Left "the instance response is not a JSON object"

-- | An AlloyDB instance; only a read pool can be scaled.
parseReadPool :: Value -> Either Text InstanceState
parseReadPool (Object o) = do
    ty <- maybe (Left "the AlloyDB instance has no instanceType") Right (str o "instanceType")
    if ty /= "READ_POOL"
        then Left ("only a read pool can be scaled, this is a " <> ty)
        else do
            st <- maybe (Left "the read pool has no state") Right (str o "state")
            cfg <- case KM.lookup "readPoolConfig" o of
                Just (Object c) -> Right c
                _ -> Left "the read pool has no readPoolConfig"
            n <- count cfg "nodeCount" Nothing
            pure (InstanceState ModeReadPool st n 0)
parseReadPool _ = Left "the instance response is not a JSON object"

{- | Split a resource name into its parts: @projects/p/locations/l/instances/i@ gives @(Nothing, i)@, and
@projects/p/locations/l/clusters/c/instances/i@ gives @(Just c, i)@.
-}
parseDiscovered :: TargetKind -> Value -> Maybe Discovered
parseDiscovered kind v@(Object o) = do
    name <- str o "name"
    let parts = T.splitOn "/" name
    st <- either (const Nothing) Just (case kind of KindRedis -> parseInstance v; KindDb -> parseReadPool v)
    case (kind, parts) of
        (KindRedis, [_, _, _, _, _, i]) | not (T.null i) -> Just (Discovered Nothing i st)
        (KindDb, [_, _, _, _, "clusters", c, _, i]) | not (T.null c) && not (T.null i) -> Just (Discovered (Just c) i st)
        _ -> Nothing
parseDiscovered _ _ = Nothing

parseOp :: Value -> Either Text Op
parseOp (Object o) = do
    name <- maybe (Left "the operation has no name") Right (str o "name")
    let done = case KM.lookup "done" o of
            Just (Bool b) -> b
            _ -> False
        err = case KM.lookup "error" o of
            Just (Object e) -> Just (maybe "the operation failed" id (str e "message"))
            _ -> Nothing
    pure (Op name done err)
parseOp _ = Left "the operation response is not a JSON object"

parseJob :: Value -> Either Text SchedulerJob
parseJob v@(Object o) = case KM.lookup "pubsubTarget" o of
    Just (Object t) -> case str t "data" of
        Just d -> Right (SchedulerJob d (maybe "" id (str o "state")) (maybe "" id (str o "schedule")) v)
        Nothing -> Left "the autoscaler job has no payload (pubsubTarget.data)"
    _ -> Left "the autoscaler job is not a Pub/Sub job"
parseJob _ = Left "the job response is not a JSON object"

-- | The update mask and request body for one resize of a target of this kind.
resizeRequest :: TargetKind -> InstanceUpdate -> Maybe (Text, Value)
resizeRequest KindRedis (UpdateUnits n) = Just ("shardCount", A.object [("shardCount", A.toJSON n)])
resizeRequest KindRedis (UpdateReplicas n) = Just ("replicaCount", A.object [("replicaCount", A.toJSON n)])
resizeRequest KindDb (UpdateUnits n) = Just ("readPoolConfig.nodeCount", A.object [("readPoolConfig", A.object [("nodeCount", A.toJSON n)])])
resizeRequest KindDb (UpdateReplicas _) = Nothing

{- | The job patch: the job's own @pubsubTarget@ with only @data@ replaced, so the topic and attributes are
written back exactly as they were.
-}
jobPatchBody :: SchedulerJob -> Text -> Value
jobPatchBody job newData = A.object [("pubsubTarget", target)]
  where
    target = case sjRaw job of
        Object o -> case KM.lookup "pubsubTarget" o of
            Just (Object t) -> Object (KM.insert "data" (String newData) t)
            _ -> A.object [("data", String newData)]
        _ -> A.object [("data", String newData)]

-- ---------------------------------------------------------------------------
-- Access token

{-# NOINLINE tokenRef #-}
tokenRef :: IORef (Maybe (Text, UTCTime))
tokenRef = unsafePerformIO (newIORef Nothing)

metadataTokenUrl :: Text
metadataTokenUrl = "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"

getToken :: IO (Either Text Text)
getToken = do
    fromEnv <- lookupEnvSecret "SC_GCP_ACCESS_TOKEN"
    case fromEnv of
        Just t | not (T.null (T.strip t)) -> pure (Right (T.strip t))
        _ -> do
            now <- getCurrentTime
            cached <- readIORef tokenRef
            case cached of
                Just (t, exp') | exp' > addUTCTime 60 now -> pure (Right t)
                _ -> fetch now
  where
    fetch now = do
        r <- httpRaw (defaultReq metadataTokenUrl) {reqHeaders = [("Metadata-Flavor", "Google")], reqTimeout = Seconds 5, reqRetries = 1, reqLogTag = "gcp-token"}
        case r of
            Left e -> pure (Left ("could not get a Google access token (is workload identity set up?): " <> httpErrText e))
            Right resp
                | respStatus resp /= 200 -> pure (Left ("the metadata server answered " <> T.pack (show (respStatus resp))))
                | otherwise -> case A.eitherDecode (respBody resp) of
                    Left e -> pure (Left ("unreadable token response: " <> T.pack e))
                    Right (Object o) -> case (str o "access_token", KM.lookup "expires_in" o) of
                        (Just tok, Just ex) | A.Success (secs :: Int) <- A.fromJSON ex -> do
                            writeIORef tokenRef (Just (tok, addUTCTime (fromIntegral secs) now))
                            pure (Right tok)
                        _ -> pure (Left "the token response has no access_token / expires_in")
                    Right _ -> pure (Left "the token response is not a JSON object")

httpErrText :: HttpError -> Text
httpErrText (HttpExceptionError t) = t
httpErrText (HttpStatusError s _) = "HTTP " <> T.pack (show s)
httpErrText (HttpDecodeError e) = T.pack e

-- ---------------------------------------------------------------------------
-- Calls

{- | Only a response that really says "someone else is changing this right now" is a retryable conflict.
Anything else that is a client error (a bad value, a quota, a missing permission) is a failure, so it is
counted and shown, not quietly retried as "busy".
-}
classify :: Int -> BL.ByteString -> GcpErr
classify status body
    | status == 404 = GcpNotFound msg
    | status == 409 = GcpConflict msg
    | status == 429 = GcpConflict ("rate limited: " <> msg)
    | (status == 400 || status == 412) && any (`T.isInfixOf` low) busyPhrases = GcpConflict msg
    | otherwise = GcpFailed ("HTTP " <> T.pack (show status) <> ": " <> msg)
  where
    raw = TE.decodeUtf8With (\_ _ -> Just '?') (BL.toStrict body)
    msg = apiMessage body raw
    low = T.toLower msg
    busyPhrases = ["in progress", "being updated", "currently being", "is updating", "another operation", "operation is running", "not in a state"]

-- | Google's error envelope is @{"error":{"message":...}}@; fall back to the raw body.
apiMessage :: BL.ByteString -> Text -> Text
apiMessage body raw = case A.decode body of
    Just (Object o) | Just (Object e) <- KM.lookup "error" o, Just m <- str e "message" -> m
    _ -> T.take 300 raw

{- | A rejected credential (401) or a denied permission (403) may only mean the cached token was issued before an
identity or role change (a Workload Identity binding, a new role). A fresh token is tried once before giving up.
-}
refreshableStatus :: Int -> Bool
refreshableStatus s = s == 401 || s == 403

-- | Forget the cached token; 'True' if there was one (so a retry would really use a different token).
dropCachedToken :: IO Bool
dropCachedToken = atomicModifyIORef' tokenRef (\c -> (Nothing, isJust c))

call :: Method -> Text -> Maybe Value -> Int -> IO (Either GcpErr Value)
call method url mbody retries = attempt True
  where
    attempt canRefresh = do
        tok <- getToken
        case tok of
            Left e -> pure (Left (GcpFailed e))
            Right t -> do
                r <-
                    try
                        ( httpRaw
                            (defaultReq url)
                                { reqMethod = method
                                , reqHeaders = [("Authorization", "Bearer " <> t), ("Content-Type", "application/json")]
                                , reqBody = A.encode <$> mbody
                                , reqTimeout = Seconds 30
                                , reqRetries = retries
                                , reqLogTag = "gcp"
                                }
                        )
                case r of
                    Left (e :: SomeException) -> pure (Left (GcpFailed (T.pack (show e))))
                    Right (Left e) -> pure (Left (GcpFailed (httpErrText e)))
                    Right (Right resp)
                        | refreshableStatus (respStatus resp) && canRefresh -> do
                            hadCached <- dropCachedToken
                            if hadCached then attempt False else pure (Left (classify (respStatus resp) (respBody resp)))
                        | respStatus resp >= 400 -> pure (Left (classify (respStatus resp) (respBody resp)))
                        | BL.null (respBody resp) -> pure (Right Null)
                        | otherwise -> pure (either (Left . GcpFailed . ("unreadable response: " <>) . T.pack) Right (A.eitherDecode (respBody resp)))

memorystore, alloydb, scheduler :: Text
memorystore = "https://memorystore.googleapis.com/v1/"
alloydb = "https://alloydb.googleapis.com/v1/"
scheduler = "https://cloudscheduler.googleapis.com/v1/"

apiOf :: TargetKind -> Text
apiOf KindRedis = memorystore
apiOf KindDb = alloydb

-- | The resource path of the target itself.
resourcePath :: Target -> Text
resourcePath t = case (tgKind t, tgParent t) of
    (KindDb, Just c) -> "projects/" <> tgProject t <> "/locations/" <> tgLocation t <> "/clusters/" <> c <> "/instances/" <> tgResource t
    _ -> "projects/" <> tgProject t <> "/locations/" <> tgLocation t <> "/instances/" <> tgResource t

jobPath :: Target -> Text -> Text
jobPath t job = "projects/" <> tgProject t <> "/locations/" <> jobLocationOf t <> "/jobs/" <> job

targetOk :: Target -> Bool
targetOk t =
    all safeSegment ([tgProject t, tgLocation t, tgResource t] <> maybe [] pure (tgParent t) <> maybe [] pure (tgJobLocation t))
        && (tgKind t /= KindDb || tgParent t /= Nothing)

guarded :: Target -> IO (Either GcpErr a) -> IO (Either GcpErr a)
guarded t act
    | targetOk t = act
    | otherwise = pure (Left (GcpFailed "project, location, parent and instance may only contain letters, digits, '-' and '_'"))

withJob :: Target -> (Text -> IO (Either GcpErr a)) -> IO (Either GcpErr a)
withJob t k = guarded t $ case tgJob t of
    Nothing -> pure (Left (GcpFailed "this target has no autoscaler job configured"))
    Just j
        | safeSegment j -> k j
        | otherwise -> pure (Left (GcpFailed "invalid autoscaler job name"))

validOpName :: Text -> Bool
validOpName name = not (T.null name) && T.all (\c -> isAlphaNum c || c `elem` ("-_/." :: String)) name && not (".." `T.isInfixOf` name)

mkGcp :: Gcp
mkGcp =
    Gcp
        { gcpGetState = \t -> guarded t $ do
            v <- call GET (apiOf (tgKind t) <> resourcePath t) Nothing 1
            pure (v >>= either (Left . GcpFailed) Right . (case tgKind t of KindRedis -> parseInstance; KindDb -> parseReadPool))
        , gcpDiscover = \kind project location ->
            if not (safeSegment project) || not (safeSegment location)
                then pure (Left (GcpFailed "invalid project or location"))
                else do
                    let url = case kind of
                            KindRedis -> memorystore <> "projects/" <> project <> "/locations/" <> location <> "/instances?pageSize=100"
                            KindDb -> alloydb <> "projects/" <> project <> "/locations/" <> location <> "/clusters/-/instances?pageSize=100"
                    v <- call GET url Nothing 1
                    pure (v >>= parseList kind)
        , gcpResize = \t upd -> guarded t $ case resizeRequest (tgKind t) upd of
            Nothing -> pure (Left (GcpFailed "this kind of target cannot be resized that way"))
            Just (mask, body) -> do
                v <- call PATCH (apiOf (tgKind t) <> resourcePath t <> "?updateMask=" <> mask) (Just body) 0
                pure (v >>= either (Left . GcpFailed) Right . parseOp)
        , gcpGetOperation = \t name ->
            if not (validOpName name)
                then pure (Left (GcpFailed "invalid operation name"))
                else do
                    v <- call GET (apiOf (tgKind t) <> name) Nothing 1
                    pure (v >>= either (Left . GcpFailed) Right . parseOp)
        , gcpGetJob = \t -> withJob t $ \j -> do
            v <- call GET (scheduler <> jobPath t j) Nothing 1
            pure (v >>= either (Left . GcpFailed) Right . parseJob)
        , gcpSetJobData = \t current newData -> withJob t $ \j -> do
            v <- call PATCH (scheduler <> jobPath t j <> "?updateMask=pubsubTarget") (Just (jobPatchBody current newData)) 0
            pure (() <$ v)
        , gcpSetJobPaused = \t paused -> withJob t $ \j -> do
            v <- call POST (scheduler <> jobPath t j <> (if paused then ":pause" else ":resume")) (Just (A.object [])) 0
            pure (() <$ v)
        }

-- | Instances this scaler understands; others (an unsupported mode, a primary) are left out of the list.
parseList :: TargetKind -> Value -> Either GcpErr [Discovered]
parseList kind (Object o) = case KM.lookup "instances" o of
    Just (Array xs) -> Right [d | x <- V.toList xs, Just d <- [parseDiscovered kind x]]
    _ -> Right []
parseList _ _ = Left (GcpFailed "unexpected instance list response")
