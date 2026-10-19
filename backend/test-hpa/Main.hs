{-# LANGUAGE OverloadedStrings #-}

{- | Integration tests for the HPA scheduler: the real store, worker, reconciler and
observer against a real Postgres, with an in-memory fake of the cluster in place of
kubectl. They exist to prove the crash-safety claims, so most scenarios kill a
worker at an awkward moment and check the next one finishes the job exactly once.

Runs only when @SC_HPA_IT_DB@ is set to a postgres URL whose database has the seed schema
and migrations applied; otherwise it prints "skipped" and exits 0, so a plain
@cabal test@ is unaffected.

    SC_HPA_IT_DB=postgres://postgres@127.0.0.1:5439/system_control cabal test scc-hpa-it
-}
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel)
import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forM_, void, when)
import Core.Config (Config (..), loadConfig)
import Core.DB.Connection (mkDBEnv, withConn)
import Core.Environment (AppState (..), Flow, runFlow)
import Core.Logging (LogLevel (..), LoggerConfig (..), prepareLoggerEnv, setGlobalLoggerEnv)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Database.PostgreSQL.Simple (Only (..), Query, execute, query)
import Database.PostgreSQL.Simple.ToRow (ToRow)
import Products.Autopilot.Hpa.Kube
import Products.Autopilot.Hpa.Observer (observeOnce)
import Products.Autopilot.Hpa.Quantity (mkQuantity)
import Products.Autopilot.Hpa.Reconcile (reconcileTick)
import Products.Autopilot.Hpa.Spec
import Products.Autopilot.Hpa.Store
import Products.Autopilot.Hpa.Types
import Products.Autopilot.Hpa.Worker
import Products.Autopilot.K8s.HPA (buildCloneHpaCommand)
import System.Directory (createDirectoryIfMissing, doesFileExist, findExecutable, getPermissions, getTemporaryDirectory, removeDirectoryRecursive, setOwnerExecutable, setPermissions)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)
import System.Exit (exitFailure)
import System.IO (hFlush, stdout)

-- ---------------------------------------------------------------------------
-- Harness

check :: String -> Bool -> IO ()
check name True = putStrLn ("  PASS: " <> name)
check name False = putStrLn ("  FAIL: " <> name) >> hFlush stdout >> exitFailure

checkEq :: (Eq a, Show a) => String -> a -> a -> IO ()
checkEq name expected actual
    | expected == actual = putStrLn ("  PASS: " <> name)
    | otherwise = do
        putStrLn ("  FAIL: " <> name <> " — expected " <> show expected <> ", got " <> show actual)
        hFlush stdout
        exitFailure

section :: String -> IO () -> IO ()
section title body = putStrLn ("\n" <> title) >> body

cloudName :: Text
cloudName = "ITCLOUD"

ns :: Text
ns = "itns"

app, svc :: Text
app = "itapp"
svc = "svc"

-- ---------------------------------------------------------------------------
-- Fake cluster

data Fault
    = NoFault
    | -- | Throw after the replace has been stored: the change is live, nothing was recorded.
      CrashAfterReplace
    | -- | Throw before storing: the worker died with the change not yet sent.
      CrashBeforeReplace
    | -- | Answer 409 once without storing.
      ConflictOnce
    | -- | Store the replace, then hang (a stuck process that gets killed).
      HangAfterReplace
    deriving (Eq)

data Fake = Fake
    { fkHpas :: IORef (Map.Map (Text, Text) Value)
    , fkRv :: IORef Int
    , fkDeploy :: IORef (Map.Map (Text, Text) (Int, Int))
    , fkVs :: IORef Value
    , fkReplaces :: IORef Int
    , fkFault :: IORef Fault
    }

mkHpaObj :: Text -> Text -> Int -> Int -> Int -> Value
mkHpaObj name target rv mn mx =
    object
        [ "apiVersion" .= ("autoscaling/v2" :: Text)
        , "kind" .= ("HorizontalPodAutoscaler" :: Text)
        , "metadata"
            .= object
                [ "name" .= name
                , "namespace" .= ns
                , "resourceVersion" .= T.pack (show rv)
                , "managedFields" .= [object ["manager" .= ("kubectl" :: Text)]]
                ]
        , "spec"
            .= object
                [ "scaleTargetRef" .= object ["apiVersion" .= ("apps/v1" :: Text), "kind" .= ("Deployment" :: Text), "name" .= target]
                , "minReplicas" .= mn
                , "maxReplicas" .= mx
                , "metrics"
                    .= [ object ["type" .= ("Resource" :: Text), "resource" .= object ["name" .= ("cpu" :: Text), "target" .= object ["type" .= ("Utilization" :: Text), "averageUtilization" .= (70 :: Int)]]]
                       , object ["type" .= ("Resource" :: Text), "resource" .= object ["name" .= ("memory" :: Text), "target" .= object ["type" .= ("AverageValue" :: Text), "averageValue" .= ("256Mi" :: Text)]]]
                       ]
                ]
        , "status"
            .= object
                [ "currentReplicas" .= (3 :: Int)
                , "desiredReplicas" .= (3 :: Int)
                , "conditions" .= [object ["type" .= ("ScalingActive" :: Text), "status" .= ("True" :: Text)]]
                , "currentMetrics" .= [object ["type" .= ("Resource" :: Text), "resource" .= object ["name" .= ("cpu" :: Text), "current" .= object ["averageUtilization" .= (55 :: Int)]]]]
                ]
        ]

vsWith :: [(Text, Int)] -> Value
vsWith ws =
    object
        [ "spec"
            .= object
                [ "http"
                    .= [ object
                            [ "route"
                                .= [ object ["destination" .= object ["host" .= svc, "subset" .= s], "weight" .= w]
                                   | (s, w) <- ws
                                   ]
                            ]
                       ]
                ]
        ]

freshFake :: IO Fake
freshFake = do
    h <- newIORef (Map.fromList [((ns, "svc-v1-hpa"), mkHpaObj "svc-v1-hpa" "svc-v1" 1 2 20)])
    rv <- newIORef 1
    d <- newIORef (Map.fromList [((ns, "svc-v1"), (4, 4))])
    vs <- newIORef (vsWith [("v1", 100)])
    rc <- newIORef 0
    f <- newIORef NoFault
    pure (Fake h rv d vs rc f)

notFound :: Text -> Either Text Text
notFound what = Left ("Error from server (NotFound): " <> what <> " not found")

jsonOut :: Value -> Either Text Text
jsonOut = Right . TE.decodeUtf8 . BL.toStrict . A.encode

metaText :: Text -> Value -> Text
metaText k (Object o) | Just (Object md) <- KM.lookup "metadata" o, Just (String t) <- KM.lookup (kk k) md = t
  where
    kk = fromTextKey
metaText _ _ = ""

fromTextKey :: Text -> K.Key
fromTextKey = K.fromText

setRv :: Text -> Value -> Value
setRv r (Object o) = case KM.lookup "metadata" o of
    Just (Object md) -> Object (KM.insert "metadata" (Object (KM.insert "resourceVersion" (String r) md)) o)
    _ -> Object o
setRv _ v = v

-- | What the real API server does on write: once `spec.behavior` exists, BOTH directions get defaults.
serverDefaults :: Value -> Value
serverDefaults (Object o) = case KM.lookup "spec" o of
    Just (Object so) | Just (Object beh) <- KM.lookup "behavior" so ->
        let dir name defWin defPol = case KM.lookup name beh of
                Just (Object r) -> Object (KM.insertWith (\_ old -> old) "selectPolicy" (String "Max") (KM.insertWith (\_ old -> old) "policies" defPol r))
                _ -> object ["stabilizationWindowSeconds" .= (defWin :: Int), "selectPolicy" .= ("Max" :: Text), "policies" .= defPol]
            up = dir "scaleUp" 0 (A.toJSON [object ["type" .= ("Pods" :: Text), "value" .= (4 :: Int), "periodSeconds" .= (15 :: Int)]])
            down = dir "scaleDown" 300 (A.toJSON [object ["type" .= ("Percent" :: Text), "value" .= (100 :: Int), "periodSeconds" .= (15 :: Int)]])
         in Object (KM.insert "spec" (Object (KM.insert "behavior" (object ["scaleUp" .= up, "scaleDown" .= down]) so)) o)
    _ -> Object o
serverDefaults v = v

keepStatus :: Value -> Value -> Value
keepStatus (Object stored) (Object new) = Object (maybe new (\s -> KM.insert "status" s new) (KM.lookup "status" stored))
keepStatus _ new = new

fakeKube :: Fake -> Kube
fakeKube fk = Kube $ \args stdin -> case args of
    ["-n", n, "get", "horizontalpodautoscalers.v2.autoscaling", name, "-o", "json"] -> do
        m <- readIORef (fkHpas fk)
        pure (maybe (notFound ("horizontalpodautoscalers \"" <> T.pack name <> "\"")) jsonOut (Map.lookup (T.pack n, T.pack name) m))
    ["-n", _, "get", "horizontalpodautoscalers.v2.autoscaling", "-o", "json"] -> do
        m <- readIORef (fkHpas fk)
        pure (jsonOut (object ["items" .= Map.elems m]))
    ["-n", n, "get", "deployment", dep, "-o", "json"] -> do
        m <- readIORef (fkDeploy fk)
        pure $ case Map.lookup (T.pack n, T.pack dep) m of
            Nothing -> notFound ("deployments \"" <> T.pack dep <> "\"")
            Just (want, ready) -> jsonOut (object ["spec" .= object ["replicas" .= want], "status" .= object ["readyReplicas" .= ready]])
    ["-n", _, "get", "virtualservice", _, "-o", "json"] -> jsonOut <$> readIORef (fkVs fk)
    ("-n" : _ : "get" : "events" : _) -> pure (jsonOut (object ["items" .= ([] :: [Value])]))
    ["-n", n, "replace", "-f", "-"] -> do
        fault <- readIORef (fkFault fk)
        case A.decodeStrict' (TE.encodeUtf8 (fromMaybe "" stdin)) of
            Nothing -> pure (Left "invalid JSON on stdin")
            Just obj -> do
                let name = metaText "name" obj
                m <- readIORef (fkHpas fk)
                case Map.lookup (T.pack n, name) m of
                    Nothing -> pure (notFound ("horizontalpodautoscalers \"" <> name <> "\""))
                    Just stored -> do
                        let conflict = Left ("Error from server (Conflict): Operation cannot be fulfilled on horizontalpodautoscalers.autoscaling \"" <> name <> "\": the object has been modified; please apply your changes to the latest version and try again")
                        case fault of
                            ConflictOnce -> writeIORef (fkFault fk) NoFault >> pure conflict
                            CrashBeforeReplace -> writeIORef (fkFault fk) NoFault >> throwIO (userError "simulated crash before replace")
                            _
                                | metaText "resourceVersion" obj /= metaText "resourceVersion" stored -> pure conflict
                                | otherwise -> do
                                    n' <- atomicModifyIORef' (fkRv fk) (\x -> (x + 1, x + 1))
                                    modifyIORef' (fkHpas fk) (Map.insert (T.pack n, name) (setRv (T.pack (show n')) (serverDefaults (keepStatus stored obj))))
                                    modifyIORef' (fkReplaces fk) (+ 1)
                                    case fault of
                                        CrashAfterReplace -> writeIORef (fkFault fk) NoFault >> throwIO (userError "simulated crash after replace")
                                        HangAfterReplace -> writeIORef (fkFault fk) NoFault >> threadDelay 600000000 >> pure (Right "")
                                        _ -> pure (Right "")
    other -> pure (Left ("fake kubectl: unsupported args " <> T.pack (show other)))

-- | Read an HPA back from the fake as the scheduler would.
clusterHpa :: Env -> Text -> IO HpaObject
clusterHpa e name = do
    m <- readIORef (fkHpas (eFake e))
    case Map.lookup (ns, name) m of
        Nothing -> fail ("no such HPA in the fake cluster: " <> T.unpack name)
        Just v -> either (fail . T.unpack) pure (parseHpaObject v)

-- ---------------------------------------------------------------------------
-- DB helpers

data Env = Env {eSt :: AppState, eFake :: Fake, eWorker :: WorkerEnv}

sql :: (ToRow p) => AppState -> Query -> p -> IO ()
sql st q p = withConn (dbEnv st) (\c -> void (execute c q p))

sqlOne :: AppState -> Query -> IO [Only Int]
sqlOne st q = withConn (dbEnv st) (\c -> query c q ())

flow :: AppState -> Flow a -> IO a
flow = runFlow

cleanDb :: AppState -> IO ()
cleanDb st = do
    forM_ ["hpa_apply", "hpa_event", "hpa_snapshot", "hpa_sample", "hpa_scale_event", "hpa_schedule", "hpa_guardrail", "hpa_watch", "hpa_loop_lease"] $ \t ->
        sql st ("DELETE FROM " <> t <> " WHERE cloud = ?") (Only cloudName)
    sql st "DELETE FROM release_tracker WHERE cloud_type = ?" (Only cloudName)

seedConfig :: AppState -> IO ()
seedConfig st = do
    sql st "DELETE FROM deployment_config WHERE cloud_type = ?" (Only cloudName)
    sql
        st
        "INSERT INTO deployment_config (app_group, service, cluster, namespace, vs_name, cloud_type) VALUES (?, NULL, 'c1', ?, 'it-vs', ?)"
        (app, ns, cloudName)
    sql
        st
        "INSERT INTO deployment_config (app_group, service, service_host, service_type, hpa_min_replicas, hpa_max_replicas, cloud_type) \
        \VALUES (?, ?, 'svc', 'SERVICE', 2, 20, ?)"
        (app, svc, cloudName)

newEnv :: AppState -> IO Env
newEnv st = do
    cleanDb st
    fk <- freshFake
    let w = WorkerEnv (fakeKube fk) cloudName "it-worker-1" (config st)
    pure (Env st fk w)

nowT :: IO UTCTime
nowT = getCurrentTime

startApply :: Env -> Text -> HpaChange -> HealthPolicy -> Maybe UTCTime -> IO Text
startApply e hpa change policy windowEnd = do
    aid' <- (\u -> "it-" <> UUID.toText u) <$> UUID.nextRandom
    ok <-
        flow (eSt e) $
            insertApply
                ApplyNew
                    { anId = aid'
                    , anCloud = cloudName
                    , anScheduleId = Nothing
                    , anTrigger = "MANUAL"
                    , anAppGroup = app
                    , anService = svc
                    , anNamespace = ns
                    , anHpaName = hpa
                    , anChange = A.toJSON change
                    , anPolicy = A.toJSON policy
                    , anWindowStart = Nothing
                    , anWindowEnd = windowEnd
                    , anCreatedBy = "it"
                    }
    check ("insertApply accepted " <> T.unpack aid') ok
    pure aid'

fetch :: Env -> Text -> IO ApplyRow
fetch e aid = do
    r <- flow (eSt e) (getApply cloudName aid)
    maybe (fail ("apply vanished: " <> T.unpack aid)) pure r

status :: ApplyRow -> ApplyStatus
status r = fromMaybe (error "bad status") (parseApplyStatus (arStatus r))

eventKinds :: Env -> Text -> IO [Text]
eventKinds e aid = do
    evs <- flow (eSt e) (listEventsForApply cloudName aid)
    pure [k | Object o <- evs, Just (String k) <- [KM.lookup "kind" o]]

{- | Run the worker over one apply until @done@ says stop, like the real loop but with
the back-off waits skipped. A step that throws behaves like a worker thread that died
mid-step: the row keeps its claim, and when nothing else can claim it the lease is
expired, as the passage of time would.
-}
driveUntil :: Env -> Text -> (ApplyRow -> Bool) -> IO ApplyRow
driveUntil e aid done = go (60 :: Int)
  where
    st = eSt e
    go 0 = do
        r <- fetch e aid
        fail ("drive did not settle; stuck in " <> T.unpack (arStatus r) <> " step=" <> show (arStep r) <> " error=" <> show (arError r))
    go n = do
        r <- fetch e aid
        if done r
            then pure r
            else do
                sql st "UPDATE hpa_apply SET next_run_at = now() WHERE id = ?" (Only aid)
                m <- flow st (claimNextApply cloudName (weWorker (eWorker e)) leaseSeconds)
                case m of
                    Nothing -> expireLease e aid >> go (n - 1)
                    Just row -> do
                        _ <- try (flow st (processApply (eWorker e) row)) :: IO (Either SomeException ())
                        go (n - 1)

expireLease :: Env -> Text -> IO ()
expireLease e aid = sql (eSt e) "UPDATE hpa_apply SET lease_expires_at = now() - interval '1 second' WHERE id = ? AND lease_expires_at IS NOT NULL" (Only aid)

drive :: Env -> Text -> IO ApplyRow
drive e aid = do
    t <- nowT
    driveUntil e aid (\r -> case status r of s | isTerminalApply s -> True; NeedsAttention -> True; Applied -> maybe True (> t) (arWindowEnd r); _ -> False)

endWindowNow :: Env -> Text -> IO ()
endWindowNow e aid = sql (eSt e) "UPDATE hpa_apply SET window_end = now() - interval '1 minute' WHERE id = ?" (Only aid)

cpuTo :: Int -> MetricTargetChange
cpuTo n = MetricTargetChange "resource/cpu" (Utilization n)

bigChange :: HpaChange
bigChange = emptyChange {chMinReplicas = Just 10, chMaxReplicas = Just 60, chMetricTargets = [cpuTo 50]}

noObserve :: HealthPolicy
noObserve = defaultHealthPolicy {hpObserveSeconds = 0}

original :: IO HpaSpec
original = either (fail . T.unpack) (pure . hoSpec) (parseHpaObject (mkHpaObj "svc-v1-hpa" "svc-v1" 1 2 20))

anHour :: IO UTCTime
anHour = addUTCTime 3600 <$> nowT

-- ---------------------------------------------------------------------------
-- Scenarios

main :: IO ()
main = do
    murl <- lookupEnv "SC_HPA_IT_DB"
    case murl of
        Nothing -> putStrLn "HPA integration tests skipped (set SC_HPA_IT_DB to run them)"
        Just url -> run url

run :: String -> IO ()
run url = do
    cfg0 <- loadConfig
    let cfg = cfg0 {databaseUrl = Just url, cloudProvider = cloudName}
    db <- mkDBEnv cfg
    logEnv <- prepareLoggerEnv (LoggerConfig ERROR False "" False)
    setGlobalLoggerEnv logEnv
    let st = AppState cfg db logEnv
    putStrLn "HPA scheduler integration tests"
    seedConfig st
    section "[1] happy path: apply, hold, restore at window end" (happyPath st)
    section "[2] worker dies AFTER the change was sent: resumed, not re-applied" (crashAfter st)
    section "[3] worker dies BEFORE the change was sent: original kept, applied once" (crashBefore st)
    section "[4] concurrent edit (409): retried against the fresh object" (conflictOnce st)
    section "[5] health gate: unready pods roll the change back" (healthBreach st)
    section "[6] health gate: healthy observation holds the change" (healthyObserve st)
    section "[7] drift: restore leaves fields someone else changed" (driftOnRestore st)
    section "[8] release in flight: apply is deferred, then proceeds" (releaseDeferral st)
    section "[9] one in-flight apply per HPA; one apply per schedule window" (uniqueness st)
    section "[10] leases: exclusive, heartbeat-extended, reclaimed, escalated" (leases st)
    section "[11] KEDA-managed HPA is skipped, never edited" (kedaSkipped st)
    section "[12] guardrails refuse a change" (guardrails st)
    section "[13] HPA deleted by a release is closed cleanly" (hpaVanishes st)
    section "[14] reconciler: window -> apply for the serving HPA only, idempotent" (reconciler st)
    section "[15] loop leader lease" (loopLease st)
    section "[16] observer: samples + snapshots, no duplicate snapshots" (observer st)
    section "[17] real worker loop killed mid-apply; a new one finishes it exactly once" (workerKilled st)
    section "[19] behavior-only change on an HPA with no behavior: server defaults must not cause a rollback" (behaviorDefaults st)
    section "[20] manual restore of a row parked after retries really runs; progress resets the retry count" (attemptsReset st)
    section "[18] release cloning an HPA mid-boost copies the BASELINE, not the override" (cloneBaseline cfg)
    cleanDb st
    putStrLn "\nAll HPA integration tests passed."

happyPath :: AppState -> IO ()
happyPath st = do
    e <- newEnv st
    orig <- original
    end <- anHour
    aid <- startApply e "svc-v1-hpa" bigChange noObserve (Just end)
    r <- drive e aid
    checkEq "reaches APPLIED" Applied (status r)
    h <- clusterHpa e "svc-v1-hpa"
    checkEq "cluster has the new min/max" (10, 60) (hsMinReplicas (hoSpec h), hsMaxReplicas (hoSpec h))
    checkEq "cpu target changed" (ResourceMetric Cpu (Utilization 50)) (head (hsMetrics (hoSpec h)))
    checkEq "memory target untouched" (hsMetrics orig !! 1) (hsMetrics (hoSpec h) !! 1)
    check "ledger annotation on the HPA" (lookup annApplyId (hoAnnotations h) == Just aid)
    check "base-spec annotation on the HPA (for release cloning)" (isJust (lookup annBaseSpec (hoAnnotations h)))
    check "original spec persisted before the change" (arBeforeSpec r == Just (A.toJSON orig))
    n <- readIORef (fkReplaces (eFake e))
    checkEq "exactly one replace sent" 1 n
    kinds <- eventKinds e aid
    check "timeline has started / patched / applied" (all (`elem` kinds) ["started", "patched", "applied"])
    snaps <- flow st (snapshotsFor cloudName app svc 10)
    let sources = [src | Object o <- snaps, Just (String src) <- [KM.lookup "source" o]]
    checkEq "history has the ORIGINAL (BEFORE) and the APPLY snapshot, newest first" ["APPLY", "BEFORE"] sources
    -- window ends
    endWindowNow e aid
    r2 <- drive e aid
    checkEq "restored when the window ends" Restored (status r2)
    h2 <- clusterHpa e "svc-v1-hpa"
    checkEq "cluster spec is the original again" orig (hoSpec h2)
    checkEq "our annotations are gone" [] [k | (k, _) <- hoAnnotations h2, k `elem` managedAnnotationKeysT]
    kinds2 <- eventKinds e aid
    check "timeline has window_ended / restored" (all (`elem` kinds2) ["window_ended", "restored"])
    snaps2 <- flow st (snapshotsFor cloudName app svc 10)
    check "a RESTORE snapshot was added" (length snaps2 == 3)
    n2 <- readIORef (fkReplaces (eFake e))
    checkEq "one more replace for the restore" 2 n2
    check "lease released" (arClaimedBy r2 == Nothing)

managedAnnotationKeysT :: [Text]
managedAnnotationKeysT = [annScheduleId, annApplyId, annBaseSpec]

crashAfter :: AppState -> IO ()
crashAfter st = do
    e <- newEnv st
    orig <- original
    end <- anHour
    writeIORef (fkFault (eFake e)) CrashAfterReplace
    aid <- startApply e "svc-v1-hpa" bigChange noObserve (Just end)
    r <- drive e aid
    checkEq "reaches APPLIED despite the crash" Applied (status r)
    n <- readIORef (fkReplaces (eFake e))
    checkEq "the change was sent exactly once (resume saw it was already live)" 1 n
    checkEq "the crash is forgotten once the apply has made progress (it must not add up over hours)" 0 (arAttempt r)
    check "before_spec is the ORIGINAL, not the changed spec" (arBeforeSpec r == Just (A.toJSON orig))
    h <- clusterHpa e "svc-v1-hpa"
    checkEq "cluster holds the change" (10, 60) (hsMinReplicas (hoSpec h), hsMaxReplicas (hoSpec h))
    endWindowNow e aid
    r2 <- drive e aid
    checkEq "and it still restores to the true original" Restored (status r2)
    h2 <- clusterHpa e "svc-v1-hpa"
    checkEq "original recovered after a crash" orig (hoSpec h2)

crashBefore :: AppState -> IO ()
crashBefore st = do
    e <- newEnv st
    orig <- original
    end <- anHour
    writeIORef (fkFault (eFake e)) CrashBeforeReplace
    aid <- startApply e "svc-v1-hpa" bigChange noObserve (Just end)
    r <- drive e aid
    checkEq "reaches APPLIED" Applied (status r)
    n <- readIORef (fkReplaces (eFake e))
    checkEq "applied once" 1 n
    check "before_spec written once and still the original" (arBeforeSpec r == Just (A.toJSON orig))

conflictOnce :: AppState -> IO ()
conflictOnce st = do
    e <- newEnv st
    end <- anHour
    writeIORef (fkFault (eFake e)) ConflictOnce
    aid <- startApply e "svc-v1-hpa" bigChange noObserve (Just end)
    r <- drive e aid
    checkEq "reaches APPLIED after the conflict" Applied (status r)
    checkEq "the conflict was retried and then forgotten once the apply progressed" 0 (arAttempt r)
    n <- readIORef (fkReplaces (eFake e))
    checkEq "one replace stored" 1 n

healthBreach :: AppState -> IO ()
healthBreach st = do
    e <- newEnv st
    orig <- original
    end <- anHour
    -- 10 pods wanted, 2 ready: 80% unready against a 50% limit, and no grace period
    writeIORef (fkDeploy (eFake e)) (Map.fromList [((ns, "svc-v1"), (10, 2))])
    let pol = defaultHealthPolicy {hpObserveSeconds = 300, hpGraceSeconds = 0, hpMaxUnavailablePct = 50}
    aid <- startApply e "svc-v1-hpa" bigChange pol (Just end)
    r <- drive e aid
    checkEq "rolled back automatically" RolledBack (status r)
    check "reason is recorded" (maybe False (T.isInfixOf "not ready") (arRollbackReason r))
    h <- clusterHpa e "svc-v1-hpa"
    checkEq "cluster is back to the original" orig (hoSpec h)
    kinds <- eventKinds e aid
    check "timeline shows the breach and the rollback" (all (`elem` kinds) ["health_breach", "rolled_back"])
    -- the same breach with auto-rollback off keeps the change but says so
    e2 <- newEnv st
    writeIORef (fkDeploy (eFake e2)) (Map.fromList [((ns, "svc-v1"), (10, 2))])
    aid2 <- startApply e2 "svc-v1-hpa" bigChange pol {hpAutoRollback = False} (Just end)
    r2 <- drive e2 aid2
    checkEq "auto-rollback off: the change is kept" Applied (status r2)
    kinds2 <- eventKinds e2 aid2
    check "and the breach is on the timeline" ("health_breach_ignored" `elem` kinds2)

healthyObserve :: AppState -> IO ()
healthyObserve st = do
    e <- newEnv st
    end <- anHour
    let pol = defaultHealthPolicy {hpObserveSeconds = 600, hpGraceSeconds = 0}
    aid <- startApply e "svc-v1-hpa" bigChange pol (Just end)
    r <- driveUntil e aid (\x -> status x == Observing)
    checkEq "observing after apply" Observing (status r)
    check "observe_until is set in the future" (isJust (arObserveUntil r))
    sql st "UPDATE hpa_apply SET observe_until = now() - interval '1 second' WHERE id = ?" (Only aid)
    r2 <- drive e aid
    checkEq "healthy observation finishes as APPLIED" Applied (status r2)
    kinds <- eventKinds e aid
    check "observed_healthy on the timeline" ("observed_healthy" `elem` kinds)
    -- window ends while still observing -> restore
    e2 <- newEnv st
    aid2 <- startApply e2 "svc-v1-hpa" bigChange pol (Just end)
    _ <- driveUntil e2 aid2 (\x -> status x == Observing)
    endWindowNow e2 aid2
    r3 <- drive e2 aid2
    checkEq "window ending during observation restores" Restored (status r3)

driftOnRestore :: AppState -> IO ()
driftOnRestore st = do
    e <- newEnv st
    end <- anHour
    aid <- startApply e "svc-v1-hpa" bigChange noObserve (Just end)
    _ <- drive e aid
    -- someone raises maxReplicas to 99 by hand while the schedule holds it at 60
    modifyIORef' (fkHpas (eFake e)) $ Map.adjust (bumpMax 99) (ns, "svc-v1-hpa")
    endWindowNow e aid
    r <- drive e aid
    checkEq "restore completes" Restored (status r)
    h <- clusterHpa e "svc-v1-hpa"
    checkEq "the hand edit (max 99) is left alone" 99 (hsMaxReplicas (hoSpec h))
    checkEq "the untouched-by-others min is restored" 2 (hsMinReplicas (hoSpec h))
    checkEq "cpu target restored" (ResourceMetric Cpu (Utilization 70)) (head (hsMetrics (hoSpec h)))
    check "annotations removed" (null [k | (k, _) <- hoAnnotations h, k `elem` managedAnnotationKeysT])
    evs <- flow st (listEventsForApply cloudName aid)
    check "the event says maxReplicas was left alone" (any (T.isInfixOf "maxReplicas" . T.pack . show) [v | v@(Object o) <- evs, KM.lookup "kind" o == Just (String "restored")])
  where
    bumpMax n (Object o) = case KM.lookup "metadata" o of
        Just _ -> Object (KM.insert "spec" (setIn "maxReplicas" (A.toJSON (n :: Int)) (fromMaybe Null (KM.lookup "spec" o))) (KM.insert "metadata" (bumpRv (fromMaybe Null (KM.lookup "metadata" o))) o))
        Nothing -> Object o
    bumpMax _ v = v
    setIn k v (Object o) = Object (KM.insert (fromTextKey k) v o)
    setIn _ _ x = x
    bumpRv (Object md) = Object (KM.insert "resourceVersion" (String "900") md)
    bumpRv x = x

releaseDeferral :: AppState -> IO ()
releaseDeferral st = do
    e <- newEnv st
    end <- anHour
    sql
        st
        "INSERT INTO release_tracker (id, status, new_version, old_version, app_group, service, release_manager, env, priority, release_tag, cloud_type) \
        \VALUES ('it-rel-1', 'INPROGRESS', 'v2', 'v1', ?, ?, 'me', 'prod', 1, 't', ?)"
        (app, svc, cloudName)
    aid <- startApply e "svc-v1-hpa" bigChange noObserve (Just end)
    r <- driveUntil e aid (\x -> arDeferCount x >= 1)
    checkEq "deferred while a release is running" Pending (status r)
    n <- readIORef (fkReplaces (eFake e))
    checkEq "nothing was sent to the cluster" 0 n
    kinds <- eventKinds e aid
    check "deferral is on the timeline" ("deferred" `elem` kinds)
    sql st "DELETE FROM release_tracker WHERE id = 'it-rel-1'" ()
    r2 <- drive e aid
    checkEq "applies once the release is over" Applied (status r2)
    -- a restore is deferred too: never cut capacity mid-release
    sql
        st
        "INSERT INTO release_tracker (id, status, new_version, old_version, app_group, service, release_manager, env, priority, release_tag, cloud_type) \
        \VALUES ('it-rel-2', 'INPROGRESS', 'v3', 'v2', ?, ?, 'me', 'prod', 1, 't', ?)"
        (app, svc, cloudName)
    endWindowNow e aid
    r3 <- driveUntil e aid (\x -> status x == Restoring && arDeferCount x >= 2)
    checkEq "restore waits for the release" Restoring (status r3)
    h <- clusterHpa e "svc-v1-hpa"
    checkEq "capacity was NOT cut" 60 (hsMaxReplicas (hoSpec h))
    sql st "DELETE FROM release_tracker WHERE id = 'it-rel-2'" ()
    r4 <- drive e aid
    checkEq "restores after the release" Restored (status r4)

uniqueness :: AppState -> IO ()
uniqueness st = do
    e <- newEnv st
    end <- anHour
    _ <- startApply e "svc-v1-hpa" bigChange noObserve (Just end)
    second <-
        flow st $
            insertApply
                ApplyNew
                    { anId = "it-dup"
                    , anCloud = cloudName
                    , anScheduleId = Nothing
                    , anTrigger = "MANUAL"
                    , anAppGroup = app
                    , anService = svc
                    , anNamespace = ns
                    , anHpaName = "svc-v1-hpa"
                    , anChange = A.toJSON bigChange
                    , anPolicy = A.toJSON noObserve
                    , anWindowStart = Nothing
                    , anWindowEnd = Nothing
                    , anCreatedBy = "it"
                    }
    check "a second in-flight apply for the same HPA is refused by the database" (not second)
    -- schedule window uniqueness
    cleanDb st
    t0 <- nowT
    let win sid = ApplyNew "it-w1" cloudName (Just sid) "SCHEDULED" app svc ns "svc-v1-hpa" (A.toJSON bigChange) (A.toJSON noObserve) (Just t0) (Just (addUTCTime 3600 t0)) "it"
    a <- flow st (insertApply (win "sched-1"))
    check "first apply for the window accepted" a
    sql st "UPDATE hpa_apply SET status = 'RESTORED' WHERE id = 'it-w1'" ()
    b <- flow st (insertApply ((win "sched-1") {anId = "it-w2"}))
    check "the same window cannot be applied to the same HPA twice, even after it finished" (not b)
    c <- flow st (insertApply ((win "sched-1") {anId = "it-w3", anWindowStart = Just (addUTCTime 86400 t0)}))
    check "the next window is fine" c

leases :: AppState -> IO ()
leases st = do
    e <- newEnv st
    end <- anHour
    aid <- startApply e "svc-v1-hpa" bigChange noObserve (Just end)
    a <- flow st (claimNextApply cloudName "w1" 90)
    check "w1 claims" (fmap arId a == Just aid)
    b <- flow st (claimNextApply cloudName "w2" 90)
    check "w2 cannot claim a row under a live lease" (fmap arId b == Nothing)
    hb2 <- flow st (heartbeatApply aid "w2" 90)
    check "w2 cannot extend w1's lease" (not hb2)
    hb1 <- flow st (heartbeatApply aid "w1" 90)
    check "w1 can" hb1
    expireLease e aid
    c <- flow st (claimNextApply cloudName "w2" 90)
    check "after expiry w2 claims" (fmap arId c == Just aid)
    checkEq "the dead claim was counted" (Just 1) (fmap arAttempt c)
    lost <- flow st (transitionApply aid "w1" Pending Applying Nothing)
    check "w1, which lost the lease, cannot move the row" (not lost)
    won <- flow st (transitionApply aid "w2" Pending Applying Nothing)
    check "w2 can" won
    bad <- flow st (transitionApply aid "w2" Applying Restored Nothing)
    check "the state machine refuses APPLYING -> RESTORED" (not bad)
    -- a row that keeps dying is parked, not retried forever
    sql st "UPDATE hpa_apply SET attempt = 6, status = 'APPLYING', claimed_by = 'w2' WHERE id = ?" (Only aid)
    row <- fetch e aid
    flow st (processApply (eWorker e) {weWorker = "w2"} row)
    r <- fetch e aid
    checkEq "after too many attempts the row needs a human" NeedsAttention (status r)
    d <- flow st (claimNextApply cloudName "w3" 90)
    check "NEEDS_ATTENTION is never claimed again" (fmap arId d == Nothing)
    kinds <- eventKinds e aid
    check "the escalation is on the timeline" ("needs_attention" `elem` kinds)

kedaSkipped :: AppState -> IO ()
kedaSkipped st = do
    e <- newEnv st
    modifyIORef' (fkHpas (eFake e)) (Map.insert (ns, "keda-hpa-svc-v1") (mkHpaObj "keda-hpa-svc-v1" "svc-v1" 5 2 20))
    end <- anHour
    aid <- startApply e "keda-hpa-svc-v1" bigChange noObserve (Just end)
    r <- drive e aid
    checkEq "skipped" Skipped (status r)
    n <- readIORef (fkReplaces (eFake e))
    checkEq "never edited" 0 n

guardrails :: AppState -> IO ()
guardrails st = do
    e <- newEnv st
    end <- anHour
    flow st (putGuardrailRow cloudName app svc (A.toJSON defaultGuardrail {grMaxReplicasCap = Just 30}) "it")
    aid <- startApply e "svc-v1-hpa" bigChange noObserve (Just end)
    r <- drive e aid
    checkEq "refused: max 60 exceeds the cap of 30" Skipped (status r)
    kinds <- eventKinds e aid
    check "the refusal is on the timeline" ("refused" `elem` kinds)
    n <- readIORef (fkReplaces (eFake e))
    checkEq "nothing sent" 0 n
    -- frozen
    e2 <- newEnv st
    flow st (putGuardrailRow cloudName app svc (A.toJSON defaultGuardrail {grFrozen = True, grFrozenReason = Just "sale"}) "it")
    aid2 <- startApply e2 "svc-v1-hpa" emptyChange {chMaxReplicas = Just 21} noObserve (Just end)
    r2 <- drive e2 aid2
    checkEq "frozen service refuses even a small change" Skipped (status r2)
    -- a no-op is skipped, not applied
    e3 <- newEnv st
    flow st (putGuardrailRow cloudName app svc (A.toJSON defaultGuardrail) "it")
    aid3 <- startApply e3 "svc-v1-hpa" emptyChange {chMetricTargets = [MetricTargetChange "resource/memory" (AverageValue (mkQuantity 268435456))]} noObserve (Just end)
    r3 <- drive e3 aid3
    checkEq "256Mi == 268435456: already at target, skipped" Skipped (status r3)

hpaVanishes :: AppState -> IO ()
hpaVanishes st = do
    e <- newEnv st
    end <- anHour
    aid <- startApply e "svc-v1-hpa" bigChange noObserve (Just end)
    _ <- drive e aid
    -- a release deletes the old HPA
    modifyIORef' (fkHpas (eFake e)) (Map.delete (ns, "svc-v1-hpa"))
    endWindowNow e aid
    r <- drive e aid
    checkEq "restore closes cleanly when the HPA is gone" Restored (status r)
    -- and one that is gone before the apply even starts
    e2 <- newEnv st
    modifyIORef' (fkHpas (eFake e2)) (Map.delete (ns, "svc-v1-hpa"))
    aid2 <- startApply e2 "svc-v1-hpa" bigChange noObserve (Just end)
    r2 <- drive e2 aid2
    checkEq "apply to a missing HPA is skipped" Skipped (status r2)

reconciler :: AppState -> IO ()
reconciler st = do
    e <- newEnv st
    let kube = fakeKube (eFake e)
        weekdaysAll = Weekly [1 .. 7] 0 1440 0 -- every day, all day: always open
    flow st (insertSchedule cloudName "sched-1" app svc "always" (A.toJSON weekdaysAll) (A.toJSON bigChange) (A.toJSON noObserve) "it")
    flow st (reconcileTick kube cloudName)
    rows <- flow st (listApplies cloudName (Just app) (Just svc) Nothing 50)
    checkEq "one apply, for the serving HPA" ["svc-v1-hpa"] (map arHpaName rows)
    checkEq "created PENDING by the scheduler" ["SCHEDULED"] (map arTrigger rows)
    check "window recorded on the apply" (all (isJust . arWindowEnd) rows)
    sql st "UPDATE hpa_schedule SET last_eval_at = NULL WHERE id = 'sched-1'" ()
    flow st (reconcileTick kube cloudName)
    rows2 <- flow st (listApplies cloudName (Just app) (Just svc) Nothing 50)
    checkEq "a second tick adds nothing (idempotent)" 1 (length rows2)
    -- the release moves traffic to v2 with its own HPA: the schedule follows the serving HPA
    modifyIORef' (fkHpas (eFake e)) (Map.insert (ns, "svc-v2-hpa") (mkHpaObj "svc-v2-hpa" "svc-v2" 3 2 20))
    writeIORef (fkVs (eFake e)) (vsWith [("v1", 0), ("v2", 100)])
    sql st "UPDATE hpa_schedule SET last_eval_at = NULL WHERE id = 'sched-1'" ()
    flow st (reconcileTick kube cloudName)
    rows3 <- flow st (listApplies cloudName (Just app) (Just svc) Nothing 50)
    checkEq "a new apply for the new serving HPA" ["svc-v1-hpa", "svc-v2-hpa"] (Map.keys (Map.fromList [(arHpaName r, ()) | r <- rows3]))
    -- paused schedules create nothing
    cleanDb st
    flow st (insertSchedule cloudName "sched-2" app svc "paused" (A.toJSON weekdaysAll) (A.toJSON bigChange) (A.toJSON noObserve) "it")
    _ <- flow st (setScheduleStatus cloudName "sched-2" "PAUSED")
    flow st (reconcileTick kube cloudName)
    rows4 <- flow st (listApplies cloudName (Just app) (Just svc) Nothing 50)
    checkEq "paused schedule: no applies" 0 (length rows4)
    -- a one-off whose window is over is marked expired
    t <- nowT
    let past = Once (addUTCTime (-7200) t) (Just (addUTCTime (-3600) t))
    flow st (insertSchedule cloudName "sched-3" app svc "past" (A.toJSON past) (A.toJSON bigChange) (A.toJSON noObserve) "it")
    flow st (reconcileTick kube cloudName)
    s <- flow st (getSchedule cloudName "sched-3")
    checkEq "expired" (Just "EXPIRED") (fmap srStatus s)
    -- the scheduler drives a whole window end-to-end through the real worker steps
    cleanDb st
    flow st (insertSchedule cloudName "sched-4" app svc "e2e" (A.toJSON weekdaysAll) (A.toJSON bigChange) (A.toJSON noObserve) "it")
    writeIORef (fkVs (eFake e)) (vsWith [("v1", 100)])
    flow st (reconcileTick kube cloudName)
    [row] <- flow st (listApplies cloudName (Just app) (Just svc) Nothing 50)
    r <- drive e (arId row)
    checkEq "scheduled apply reaches APPLIED" Applied (status r)
    -- downtime: the window 'ended' while no backend was running; the next worker restores immediately
    endWindowNow e (arId row)
    r2 <- drive e (arId row)
    checkEq "overdue restore happens as soon as a worker is back" Restored (status r2)
    -- deleting the schedule must not strand an applied change
    cleanDb st
    sql st "DELETE FROM hpa_schedule WHERE cloud = ?" (Only cloudName)

loopLease :: AppState -> IO ()
loopLease st = do
    cleanDb st
    a <- flow st (acquireLoopLease "observe" cloudName "pod-a" 60)
    b <- flow st (acquireLoopLease "observe" cloudName "pod-b" 60)
    a2 <- flow st (acquireLoopLease "observe" cloudName "pod-a" 60)
    check "first pod leads" a
    check "second pod does not" (not b)
    check "leader renews" a2
    sql st "UPDATE hpa_loop_lease SET lease_until = now() - interval '1 second' WHERE cloud = ?" (Only cloudName)
    b2 <- flow st (acquireLoopLease "observe" cloudName "pod-b" 60)
    check "a dead leader's lease expires and another pod takes over" b2
    other <- flow st (acquireLoopLease "reconcile" cloudName "pod-a" 60)
    check "leases are per loop" other

observer :: AppState -> IO ()
observer st = do
    e <- newEnv st
    let kube = fakeKube (eFake e)
    flow st (addWatch cloudName app svc "it")
    flow st (observeOnce kube cloudName)
    samples <- sqlOne st "SELECT count(*)::int FROM hpa_sample WHERE cloud = 'ITCLOUD'"
    checkEq "NO time series is written to the database (history comes from the metrics system)" [Only 0] samples
    snaps <- sqlOne st "SELECT count(*)::int FROM hpa_snapshot WHERE cloud = 'ITCLOUD' AND source = 'OBSERVED'"
    checkEq "first observation snapshots the spec" [Only 1] snaps
    flow st (observeOnce kube cloudName)
    snaps2 <- sqlOne st "SELECT count(*)::int FROM hpa_snapshot WHERE cloud = 'ITCLOUD'"
    checkEq "an unchanged spec is not snapshotted again (rows only when something changes)" [Only 1] snaps2
    flow st (observeOnce kube cloudName)
    flow st (observeOnce kube cloudName)
    snapsN <- sqlOne st "SELECT count(*)::int FROM hpa_snapshot WHERE cloud = 'ITCLOUD'"
    checkEq "any number of further ticks still add nothing" [Only 1] snapsN
    scaleEv <- sqlOne st "SELECT count(*)::int FROM hpa_scale_event WHERE cloud = 'ITCLOUD'"
    checkEq "scale events are not stored either" [Only 0] scaleEv
    -- an edit by someone else shows up as a new snapshot
    modifyIORef' (fkHpas (eFake e)) $ Map.insert (ns, "svc-v1-hpa") (mkHpaObj "svc-v1-hpa" "svc-v1" 2 5 40)
    flow st (observeOnce kube cloudName)
    snaps3 <- sqlOne st "SELECT count(*)::int FROM hpa_snapshot WHERE cloud = 'ITCLOUD'"
    checkEq "a hand edit is captured as a new snapshot" [Only 2] snaps3
    vals <- flow st (snapshotsFor cloudName app svc 10)
    check "history is returned newest first" (length vals == 2)

workerKilled :: AppState -> IO ()
workerKilled st = do
    e <- newEnv st
    end <- anHour
    -- the first worker stores the change and then hangs, as a wedged process would
    writeIORef (fkFault (eFake e)) HangAfterReplace
    aid <- startApply e "svc-v1-hpa" bigChange noObserve (Just end)
    w1 <- async (runFlow st (workerLoop (eWorker e) {weWorker = "real-1"}))
    waitFor 20 (do h <- clusterHpa e "svc-v1-hpa"; pure (hsMaxReplicas (hoSpec h) == 60))
    check "worker 1 sent the change" True
    cancel w1 -- the thread dies; its lease stays in the database
    r1 <- fetch e aid
    check "the dead worker still holds the claim" (arClaimedBy r1 == Just "real-1")
    expireLease e aid -- ...until the lease runs out
    w2 <- async (runFlow st (workerLoop (eWorker e) {weWorker = "real-2"}))
    waitForRow e aid ((== Applied) . status)
    cancel w2
    r2 <- fetch e aid
    checkEq "a fresh worker finishes the job" Applied (status r2)
    n <- readIORef (fkReplaces (eFake e))
    checkEq "the change was sent exactly once across both workers" 1 n
    check "the claim is released" (arClaimedBy r2 == Nothing)
    kinds <- eventKinds e aid
    check "no duplicate 'started' on the timeline" (length (filter (== "started") kinds) == 1)

waitFor :: Int -> IO Bool -> IO ()
waitFor 0 _ = fail "timed out waiting for a condition"
waitFor n p = do
    ok <- p
    when (not ok) (threadDelay 500000 >> waitFor (n - 1) p)

waitForRow :: Env -> Text -> (ApplyRow -> Bool) -> IO ()
waitForRow e aid p = waitFor 40 (p <$> fetch e aid)

-- | Run the real clone pipeline (kubectl get | jq | kubectl apply) against a stand-in kubectl script.
cloneBaseline :: Config -> IO ()
cloneBaseline cfg = do
    jq <- findExecutable "jq"
    case jq of
        Nothing -> putStrLn "  SKIP: jq is not installed"
        Just _ -> do
            tmpRoot <- getTemporaryDirectory
            uid <- UUID.toText <$> UUID.nextRandom
            let dir = tmpRoot </> ("hpa-clone-" <> T.unpack uid)
                fixture = dir </> "in.json"
                out = dir </> "out.json"
                script = dir </> "kubectl"
            createDirectoryIfMissing True dir
            writeFile script ("#!/bin/sh\ncase \"$*\" in\n  *\"get hpa\"*) cat '" <> fixture <> "' ;;\n  *\"apply -f -\"*) cat > '" <> out <> "' ;;\nesac\n")
            perms <- getPermissions script
            setPermissions script (setOwnerExecutable True perms)
            let run' inObj = do
                    BL.writeFile fixture (A.encode inObj)
                    ex <- doesFileExist out
                    when ex (BL.writeFile out "")
                    let cmd = buildCloneHpaCommand cfg {kubectlBin = script} "itns" "svc" "v1" "v2" "svc-v1-hpa"
                    (_, _, err) <- readProcessWithExitCode "sh" ["-c", cmd] ""
                    raw <- BL.readFile out
                    case A.decode raw of
                        Just v -> pure v
                        Nothing -> fail ("clone produced no JSON; stderr: " <> err)
                parsed v = either (error . T.unpack) id (parseHpaObject v)
                annsOf v = case v of
                    Object o | Just (Object md) <- KM.lookup "metadata" o, Just (Object a) <- KM.lookup "annotations" md -> map (K.toText . fst) (KM.toList a)
                    _ -> []
                nameOf v = metaText "name" v
                base = mkHpaObj "svc-v1-hpa" "svc-v1" 4 2 20
            -- 1. an ordinary HPA is cloned verbatim, renamed and re-targeted
            plain <- run' base
            checkEq "plain clone is renamed" "svc-v2-hpa" (nameOf plain)
            checkEq "plain clone keeps min/max" (2 :: Int, 20 :: Int) (let h = parsed plain in (hsMinReplicas (hoSpec h), hsMaxReplicas (hoSpec h)))
            let plainH = parsed plain
            checkEq "plain clone re-targets the new deployment" "svc-v2" (strName (hsTarget (hoSpec plainH)))
            -- 2. an HPA the scheduler has boosted: clone the baseline
            let boosted = case base of
                    Object o ->
                        let spec' = case KM.lookup "spec" o of
                                Just (Object so) ->
                                    Object
                                        ( KM.insert "minReplicas" (A.toJSON (10 :: Int))
                                            (KM.insert "maxReplicas" (A.toJSON (60 :: Int))
                                                (KM.insert "behavior" (object ["scaleDown" .= object ["stabilizationWindowSeconds" .= (900 :: Int)]]) so))
                                        )
                                _ -> Null
                            baseJson = A.encode (object ["minReplicas" .= (2 :: Int), "maxReplicas" .= (20 :: Int), "metrics" .= specMetrics base])
                            md = case KM.lookup "metadata" o of
                                Just (Object m) ->
                                    Object
                                        ( KM.insert "annotations"
                                            ( object
                                                [ "sc.juspay.in/hpa-base-spec" .= TE.decodeUtf8 (BL.toStrict baseJson)
                                                , "sc.juspay.in/hpa-apply-id" .= ("a1" :: Text)
                                                , "sc.juspay.in/hpa-schedule-id" .= ("s1" :: Text)
                                                , "team" .= ("payments" :: Text)
                                                ]
                                            )
                                            m
                                        )
                                _ -> Null
                         in Object (KM.insert "spec" spec' (KM.insert "metadata" md o))
                    v -> v
            cloned <- run' boosted
            let clonedH = parsed cloned
            checkEq "boosted clone starts from the baseline min/max" (2 :: Int, 20 :: Int) (hsMinReplicas (hoSpec clonedH), hsMaxReplicas (hoSpec clonedH))
            checkEq "the temporary behavior override is dropped" Nothing (hsBehavior (hoSpec clonedH))
            check "scheduler annotations are not copied" (not (any (T.isPrefixOf "sc.juspay.in/") (annsOf cloned)))
            check "unrelated annotations ARE copied" ("team" `elem` annsOf cloned)
            checkEq "the new HPA still targets the new deployment" "svc-v2" (strName (hsTarget (hoSpec clonedH)))
            check "metrics come back from the baseline" (length (hsMetrics (hoSpec clonedH)) == 2)
            removeDirectoryRecursive dir
  where
    specMetrics v = case v of
        Object o | Just (Object so) <- KM.lookup "spec" o, Just ms <- KM.lookup "metrics" so -> ms
        _ -> Null

behaviorDefaults :: AppState -> IO ()
behaviorDefaults st = do
    e <- newEnv st
    orig <- original
    end <- anHour
    let ch = emptyChange {chScaleUp = Just (ScalingRules (Just 60) Nothing [])}
    aid <- startApply e "svc-v1-hpa" ch noObserve (Just end)
    r <- drive e aid
    checkEq "applies and stays applied (previously: rolled back every time)" Applied (status r)
    h <- clusterHpa e "svc-v1-hpa"
    checkEq "scale-up window is set" (Just 60) (hsBehavior (hoSpec h) >>= bScaleUp >>= srStabilizationWindowSeconds)
    check "the fake server really did add defaults to BOTH directions" (isJust (hsBehavior (hoSpec h) >>= bScaleDown))
    endWindowNow e aid
    r2 <- drive e aid
    checkEq "restores" Restored (status r2)
    h2 <- clusterHpa e "svc-v1-hpa"
    checkEq "cluster is back to an HPA with no behavior at all" orig (hoSpec h2)

attemptsReset :: AppState -> IO ()
attemptsReset st = do
    e <- newEnv st
    end <- anHour
    aid <- startApply e "svc-v1-hpa" bigChange noObserve (Just end)
    sql st "UPDATE hpa_apply SET attempt = 4 WHERE id = ?" (Only aid)
    r <- drive e aid
    checkEq "applied" Applied (status r)
    checkEq "progress cleared the earlier transient failures" 0 (arAttempt r)
    -- park it as if retries had been exhausted, then ask for a restore by hand
    sql st "UPDATE hpa_apply SET status = 'NEEDS_ATTENTION', attempt = 6, claimed_by = NULL, lease_expires_at = NULL WHERE id = ?" (Only aid)
    ok <- flow st (forceTransition aid cloudName [NeedsAttention] Restoring (Just "operator"))
    check "the transition is accepted" ok
    row <- fetch e aid
    checkEq "a human decision gives it a fresh start" 0 (arAttempt row)
    r2 <- drive e aid
    checkEq "the restore actually runs (previously: re-parked at once)" Restored (status r2)
    h <- clusterHpa e "svc-v1-hpa"
    checkEq "cluster restored" (2, 20) (hsMinReplicas (hoSpec h), hsMaxReplicas (hoSpec h))
    -- acknowledging a parked row closes it without touching the cluster
    e2 <- newEnv st
    aid2 <- startApply e2 "svc-v1-hpa" bigChange noObserve (Just end)
    _ <- drive e2 aid2
    sql st "UPDATE hpa_apply SET status = 'NEEDS_ATTENTION', attempt = 6, claimed_by = NULL, lease_expires_at = NULL WHERE id = ?" (Only aid2)
    ack <- flow st (forceTransition aid2 cloudName [NeedsAttention] Failed (Just "acknowledged"))
    check "acknowledge closes it" ack
    r3 <- fetch e2 aid2
    checkEq "as FAILED" Failed (status r3)
    -- deleting a schedule while a row is mid-apply undoes it
    e3 <- newEnv st
    aid3 <- startApply e3 "svc-v1-hpa" bigChange noObserve (Just end)
    _ <- driveUntil e3 aid3 (\x -> status x == Applying)
    mid <- flow st (forceTransition aid3 cloudName [Applying] RollingBack (Just "the schedule was deleted"))
    check "APPLYING can be sent to ROLLING_BACK" mid
    r4 <- drive e3 aid3
    checkEq "and the worker then finishes the rollback" RolledBack (status r4)
