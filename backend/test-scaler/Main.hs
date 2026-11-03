{-# LANGUAGE OverloadedStrings #-}

{- | Integration tests for the capacity scaler: the real store, worker, reconciler and autoscaler editor against a
real Postgres, with an in-memory fake of Google Cloud (Memorystore, AlloyDB, Cloud Scheduler) in place of the HTTP
client. Like the HPA suite they exist to prove the crash-safety claims, so several scenarios kill a worker at an
awkward moment and check the next one finishes the job exactly once.

Runs only when @SC_SCALER_IT_DB@ is set to a postgres URL whose database has the seed schema and migrations
applied; otherwise it prints "skipped" and exits 0, so a plain @cabal test@ is unaffected.

    SC_SCALER_IT_DB=postgres://postgres@127.0.0.1:5441/system_control cabal test scc-scaler-it
-}
module Main (main) where

import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forM_, void)
import Core.Config (Config (..), loadConfig)
import Core.DB.Connection (mkDBEnv, withConn)
import Core.Environment (AppState (..), Flow, runFlow)
import Core.Logging (LogLevel (..), LoggerConfig (..), prepareLoggerEnv, setGlobalLoggerEnv)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.IORef
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Database.PostgreSQL.Simple (Only (..), Query, execute, query)
import Database.PostgreSQL.Simple.ToRow (ToRow)
import Products.Autopilot.Hpa.Types (ApplyStatus (..), ScheduleKind (..), isTerminalApply, parseApplyStatus)
import Products.Autopilot.Hpa.Worker (leaseSeconds)
import Products.Autopilot.Scaler.Autoscaler
import Products.Autopilot.Scaler.Gcp
import Products.Autopilot.Scaler.Logic qualified as VL
import Products.Autopilot.Scaler.Reconcile (reconcileTick)
import Products.Autopilot.Scaler.Store
import Products.Autopilot.Scaler.Types qualified as VT
import Products.Autopilot.Scaler.Worker (WorkerEnv (..), processApply)
import System.Environment (lookupEnv)
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
cloudName = "ITCLOUDS"

redisT, standaloneT, noJobT, dbT, dbNoJobT :: VT.Target
redisT = VT.Target "it-redis" VT.KindRedis "beckn" "it-proj" "it-loc" Nothing "beckn-redis-cluster-001" (Just "poll-cluster-metrics") Nothing
standaloneT = VT.Target "it-standalone" VT.KindRedis "lts" "it-proj" "it-loc" Nothing "lts-redis" Nothing Nothing
noJobT = redisT {VT.tgId = "it-redis-nojob", VT.tgName = "beckn without a job", VT.tgJob = Nothing}
dbT = VT.Target "it-db" VT.KindDb "driver pool" "it-proj" "it-loc" (Just "driver-db-cluster") "driver-db-cluster-reader-pool" (Just "poll-alloydb-readpool-metrics") Nothing
dbNoJobT = dbT {VT.tgId = "it-db-nojob", VT.tgName = "driver pool without a job", VT.tgJob = Nothing}

-- ---------------------------------------------------------------------------
-- Fake Google Cloud

data Fault
    = NoFault
    | -- | The pinned minimum was written, then the worker died before recording it.
      CrashAfterJobWrite
    | -- | The resize was accepted, then the worker died before recording it.
      CrashAfterUpdate
    deriving (Eq)

data Fake = Fake
    { fkState :: IORef VT.InstanceState
    , fkSettle :: IORef Int
    -- ^ Reads left before a busy instance turns idle again.
    , fkPending :: IORef (Maybe (Int, Int))
    , fkJob :: IORef Text
    , fkJobState :: IORef Text
    , fkUpdates :: IORef [InstanceUpdate]
    , fkJobWrites :: IORef Int
    , fkOpError :: IORef (Maybe Text)
    , fkFault :: IORef Fault
    , fkOps :: IORef Int
    , fkMissing :: IORef Bool
    }

redisState :: Int -> Int -> VT.InstanceState
redisState = VT.InstanceState VT.ModeCluster "ACTIVE"

standaloneState :: Int -> VT.InstanceState
standaloneState = VT.InstanceState VT.ModeStandalone "ACTIVE" 1

poolState :: Int -> VT.InstanceState
poolState n = VT.InstanceState VT.ModeReadPool "READY" n 0

rules :: Value
rules =
    A.toJSON
        [ rule "Scale OUT" "OUT" "greaterThan" 65
        , rule "Scale IN" "IN" "lessThan" 40
        ]
  where
    rule :: Text -> Text -> Text -> Int -> Value
    rule nm ty op v = object ["name" .= nm, "conditions" .= object ["any" .= [object ["fact" .= ("cpu_average_utilization" :: Text), "operator" .= op, "value" .= v]]], "event" .= object ["type" .= ty, "params" .= object []]]

redisPayload :: Text -> Int -> Value
redisPayload cluster mn =
    object ["projectId" .= ("it-proj" :: Text), "regionId" .= ("it-loc" :: Text), "clusterId" .= cluster, "minSize" .= mn, "maxSize" .= (250 :: Int), "scaleOutLimit" .= (20 :: Int), "scalingMethod" .= ("LINEAR" :: Text), "scalingRules" .= rules]

poolEntry :: Text -> Text -> Int -> Value
poolEntry cluster pid mn =
    object ["projectId" .= ("it-proj" :: Text), "regionId" .= ("it-loc" :: Text), "clusterId" .= cluster, "readPoolId" .= pid, "minNodeCount" .= mn, "maxNodeCount" .= (17 :: Int), "stepSize" .= (1 :: Int), "scalingRules" .= rules]

dbPayload :: Int -> Value
dbPayload mn = A.toJSON [poolEntry "driver-db-cluster" "driver-db-cluster-reader-pool" mn, poolEntry "driver-db-cluster" "driver-db-cluster-reader-non-critical" 3]

newFake :: VT.InstanceState -> Value -> IO Fake
newFake st payload =
    Fake
        <$> newIORef st
        <*> newIORef 0
        <*> newIORef Nothing
        <*> newIORef (VL.encodeJobData payload)
        <*> newIORef "ENABLED"
        <*> newIORef []
        <*> newIORef 0
        <*> newIORef Nothing
        <*> newIORef NoFault
        <*> newIORef 0
        <*> newIORef False

fakeGcp :: Fake -> Gcp
fakeGcp fk =
    Gcp
        { gcpGetState = \_ -> do
            missing <- readIORef (fkMissing fk)
            if missing then pure (Left (GcpNotFound "the instance is gone")) else Right <$> settle
        , gcpDiscover = \_ _ _ -> pure (Right [])
        , gcpResize = \_ upd -> do
            st <- readIORef (fkState fk)
            if VL.instanceBusy st
                then pure (Left (GcpConflict "the instance is being updated"))
                else do
                    modifyIORef' (fkUpdates fk) (<> [upd])
                    let (u, r) = case upd of
                            UpdateUnits n -> (n, VT.isReplicas st)
                            UpdateReplicas n -> (VT.isUnits st, n)
                    writeIORef (fkPending fk) (Just (u, r))
                    writeIORef (fkState fk) st {VT.isState = "UPDATING"}
                    writeIORef (fkSettle fk) 2
                    n <- atomicModifyIORef' (fkOps fk) (\x -> (x + 1, x + 1))
                    fault <- readIORef (fkFault fk)
                    if fault == CrashAfterUpdate
                        then writeIORef (fkFault fk) NoFault >> throwIO (userError "simulated crash after the resize was accepted")
                        else pure (Right (Op ("operations/op-" <> T.pack (show n)) False Nothing))
        , gcpGetOperation = \_ name -> do
            st <- readIORef (fkState fk)
            err <- readIORef (fkOpError fk)
            pure (Right (Op name (not (VL.instanceBusy st)) (if VL.instanceBusy st then Nothing else err)))
        , gcpGetJob = \t -> case VT.tgJob t of
            Nothing -> pure (Left (GcpFailed "this target has no autoscaler job configured"))
            Just _ -> do
                d <- readIORef (fkJob fk)
                js <- readIORef (fkJobState fk)
                pure (Right (SchedulerJob d js "*/1 * * * *" (object ["state" .= js, "pubsubTarget" .= object ["topicName" .= ("projects/p/topics/t" :: Text), "data" .= d]])))
        , gcpSetJobData = \_ _ newData -> do
            writeIORef (fkJob fk) newData
            modifyIORef' (fkJobWrites fk) (+ 1)
            fault <- readIORef (fkFault fk)
            if fault == CrashAfterJobWrite
                then writeIORef (fkFault fk) NoFault >> throwIO (userError "simulated crash after the job was written")
                else pure (Right ())
        , gcpSetJobPaused = \_ paused -> do
            writeIORef (fkJobState fk) (if paused then "PAUSED" else "ENABLED")
            pure (Right ())
        }
  where
    -- A busy instance turns idle after a couple of reads, at its new size unless the operation fails.
    settle = do
        st <- readIORef (fkState fk)
        if VL.instanceBusy st
            then do
                n <- atomicModifyIORef' (fkSettle fk) (\x -> (x - 1, x - 1))
                if n > 0
                    then pure st
                    else do
                        pend <- readIORef (fkPending fk)
                        err <- readIORef (fkOpError fk)
                        let idle = if VT.isMode st == VT.ModeReadPool then "READY" else "ACTIVE"
                            st' = case (err, pend) of
                                (Nothing, Just (u, r)) -> st {VT.isState = idle, VT.isUnits = u, VT.isReplicas = r}
                                _ -> st {VT.isState = idle}
                        writeIORef (fkState fk) st'
                        writeIORef (fkPending fk) Nothing
                        pure st'
            else pure st

-- ---------------------------------------------------------------------------
-- DB helpers

data Env = Env {eSt :: AppState, eFake :: Fake, eWorker :: WorkerEnv, eTarget :: VT.Target}

sql :: (ToRow p) => AppState -> Query -> p -> IO ()
sql st q p = withConn (dbEnv st) (\c -> void (execute c q p))

sqlCount :: (ToRow p) => AppState -> Query -> p -> IO Int
sqlCount st q p = withConn (dbEnv st) (\c -> maybe 0 fromOnly . headMay <$> query c q p)
  where
    headMay (x : _) = Just x
    headMay [] = Nothing

flow :: AppState -> Flow a -> IO a
flow = runFlow

cleanDb :: AppState -> IO ()
cleanDb st =
    forM_
        ["scaler_apply", "scaler_event", "scaler_schedule", "scaler_guardrail", "scaler_autoscaler_history", "redis_config", "db_config", "hpa_loop_lease"]
        $ \t -> sql st ("DELETE FROM " <> t <> " WHERE cloud = ?") (Only cloudName)

-- | A clean database with this target registered and a fake cloud holding it.
newEnv :: AppState -> VT.Target -> VT.InstanceState -> Value -> IO Env
newEnv st tg inst payload = do
    cleanDb st
    fk <- newFake inst payload
    ok <- flow st (insertTarget cloudName tg "it")
    check ("target registered: " <> T.unpack (VT.tgName tg)) ok
    pure (Env st fk (WorkerEnv (fakeGcp fk) cloudName "it-worker-1") tg)

nowT :: IO UTCTime
nowT = getCurrentTime

anHour :: IO UTCTime
anHour = addUTCTime 3600 <$> nowT

change :: Int -> Bool -> Bool -> VT.ScaleChange
change units block shrink = VT.ScaleChange (Just units) Nothing block shrink

startApply :: Env -> VT.ScaleChange -> Maybe UTCTime -> IO Text
startApply e ch windowEnd = do
    aid <- (\u -> "it-" <> UUID.toText u) <$> UUID.nextRandom
    ok <-
        flow (eSt e) $
            insertApply
                ApplyNew
                    { anId = aid
                    , anCloud = cloudName
                    , anScheduleId = Nothing
                    , anTrigger = "MANUAL"
                    , anKind = VT.tgKind (eTarget e)
                    , anTargetId = VT.tgId (eTarget e)
                    , anChange = A.toJSON ch
                    , anWindowStart = Nothing
                    , anWindowEnd = windowEnd
                    , anCreatedBy = "it"
                    }
    check ("insertApply accepted " <> T.unpack aid) ok
    pure aid

fetch :: Env -> Text -> IO ApplyRow
fetch e aid = do
    r <- flow (eSt e) (getApply cloudName aid)
    maybe (fail ("apply vanished: " <> T.unpack aid)) pure r

status :: ApplyRow -> ApplyStatus
status r = fromMaybe (error "bad status") (parseApplyStatus (arStatus r))

afterOf :: ApplyRow -> VT.ScaleAfter
afterOf r = case arAfterSpec r of
    Just v | A.Success a <- A.fromJSON v -> a
    _ -> VT.emptyAfter

events :: Env -> Text -> IO [(Text, Text)]
events e aid = do
    evs <- flow (eSt e) (listEventsForApply cloudName aid)
    pure [(k, m) | Object o <- evs, Just (String k) <- [KM.lookup "kind" o], Just (String m) <- [KM.lookup "message" o]]

eventKinds :: Env -> Text -> IO [Text]
eventKinds e aid = map fst <$> events e aid

{- | Run the worker over one apply until @done@ says stop, like the real loop but with the back-off waits skipped. A
step that throws behaves like a worker thread that died mid-step: the row keeps its claim, and when nothing else can
claim it the lease is expired, as the passage of time would.
-}
driveUntil :: Env -> Text -> (ApplyRow -> Bool) -> IO ApplyRow
driveUntil e aid done = go (80 :: Int)
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
                sql st "UPDATE scaler_apply SET next_run_at = now() WHERE id = ?" (Only aid)
                m <- flow st (claimNextApply cloudName (weWorker (eWorker e)) leaseSeconds)
                case m of
                    Nothing -> expireLease e aid >> go (n - 1)
                    Just row -> do
                        _ <- try (flow st (processApply (eWorker e) row)) :: IO (Either SomeException ())
                        go (n - 1)

expireLease :: Env -> Text -> IO ()
expireLease e aid = sql (eSt e) "UPDATE scaler_apply SET lease_expires_at = now() - interval '1 second' WHERE id = ? AND lease_expires_at IS NOT NULL" (Only aid)

drive :: Env -> Text -> IO ApplyRow
drive e aid = do
    t <- nowT
    driveUntil e aid (\r -> case status r of s | isTerminalApply s -> True; NeedsAttention -> True; Applied -> maybe True (> t) (arWindowEnd r); _ -> False)

endWindowNow :: Env -> Text -> IO ()
endWindowNow e aid = sql (eSt e) "UPDATE scaler_apply SET window_end = now() - interval '1 minute' WHERE id = ?" (Only aid)

minimumOf :: VT.Target -> Env -> IO (Either Text Int)
minimumOf tg e = do
    d <- readIORef (fkJob (eFake e))
    pure (VL.decodeJobData d >>= VL.readMinimum (VT.autoscalerKeys tg))

minNow :: Env -> IO (Either Text Int)
minNow e = minimumOf (eTarget e) e

instNow :: Env -> IO VT.InstanceState
instNow e = readIORef (fkState (eFake e))

updateCount, jobWrites :: Env -> IO Int
updateCount e = length <$> readIORef (fkUpdates (eFake e))
jobWrites e = readIORef (fkJobWrites (eFake e))

-- ---------------------------------------------------------------------------
-- Main

main :: IO ()
main = do
    murl <- lookupEnv "SC_SCALER_IT_DB"
    case murl of
        Nothing -> putStrLn "Capacity scaler integration tests skipped (set SC_SCALER_IT_DB to run them)"
        Just url -> run url

run :: String -> IO ()
run url = do
    cfg0 <- loadConfig
    let cfg = cfg0 {databaseUrl = Just url, cloudProvider = cloudName}
    db <- mkDBEnv cfg
    logEnv <- prepareLoggerEnv (LoggerConfig ERROR False "" False)
    setGlobalLoggerEnv logEnv
    let st = AppState cfg db logEnv
    putStrLn "Capacity scaler integration tests"
    section "[1] Redis cluster: scale up, pin the autoscaler, hold, restore at window end" (happyPath st)
    section "[2] Redis cluster: shrink back at the end (opt-in)" (shrinkOnEnd st)
    section "[3] Redis cluster: resize only, the autoscaler job is never touched" (resizeOnly st)
    section "[4] Redis cluster: capacity already enough, only the scale-in block is applied" (blockOnly st)
    section "[5] Redis standalone: scale replicas, no autoscaler involved" (standalone st)
    section "[6] AlloyDB read pool: nodes, pinning minNodeCount in a payload shared with another pool" (readPool st)
    section "[7] nothing to do is skipped; guardrails, freezes and a missing job refuse" (refusals st)
    section "[8] worker dies after pinning: resumed, pinned once, restored correctly" (crashAfterPin st)
    section "[9] rollback in the gap between writing the pin and recording it still puts the autoscaler back" (rollbackInGap st)
    section "[10] a minimum that already equals the target but was not written by us is left alone" (notOurs st)
    section "[11] the instance disappears after the pin: rolled back, not left pinned" (disappearsAfterPin st)
    section "[12] worker dies after the resize was accepted: resumed, resized once" (crashAfterResize st)
    section "[13] target busy at the start: deferred, then proceeds" (busyAtStart st)
    section "[14] a failed resize is not retried; acknowledging it puts the autoscaler back" (resizeFails st)
    section "[15] someone else changed the minimum: restore leaves it alone" (drift st)
    section "[16] an autoscaler payload for another target fails before anything changes" (wrongCluster st)
    section "[17] rollback restores the autoscaler but never takes capacity away" (rollbackKeepsCapacity st)
    section "[18] one in-flight apply per target; one apply per schedule window" (uniqueness st)
    section "[19] leases are exclusive, and writes check them" (leases st)
    section "[20] reconciler: an open window becomes exactly one apply, idempotently" (reconciler st)
    section "[21] targets: register, list, edit, remove (not while in use)" (targets st)
    section "[22] autoscaler editor: edit, history, stale edits, hold interaction, revert, pause/resume" (autoscalerEditor st)
    cleanDb st
    putStrLn "\nAll capacity scaler integration tests passed."

happyPath :: AppState -> IO ()
happyPath st = do
    e <- newEnv st redisT (redisState 11 0) (redisPayload "beckn-redis-cluster-001" 2)
    end <- anHour
    aid <- startApply e (change 16 True False) (Just end)
    r <- drive e aid
    checkEq "reaches APPLIED" Applied (status r)
    inst <- instNow e
    checkEq "the instance has 16 shards" 16 (VT.isUnits inst)
    checkEq "the autoscaler is pinned at 16" (Right 16) =<< minNow e
    n <- updateCount e
    checkEq "exactly one resize was requested" 1 n
    w <- jobWrites e
    checkEq "exactly one job write (the pin)" 1 w
    checkEq "the original values were saved before the change" (Just (A.toJSON (VT.ScaleSnapshot 11 0 (Just 2)))) (arBeforeSpec r)
    let a = afterOf r
    checkEq "the pin intent and the pin are both recorded" (Just 16, Just 16) (VT.saPinIntent a, VT.saPinned a)
    kinds <- eventKinds e aid
    check "timeline has started / pinned / resize_started / applied" (all (`elem` kinds) ["started", "pinned", "resize_started", "applied"])
    payload <- readIORef (fkJob (eFake e))
    check "the other autoscaler settings are untouched" $
        case VL.decodeJobData payload of
            Right (Object o) -> KM.lookup "maxSize" o == Just (A.Number 250) && KM.member "scalingRules" o
            _ -> False
    endWindowNow e aid
    r2 <- drive e aid
    checkEq "restored when the window ends" Restored (status r2)
    checkEq "the autoscaler minimum is back at 2" (Right 2) =<< minNow e
    inst2 <- instNow e
    checkEq "capacity stays (the autoscaler decides later)" 16 (VT.isUnits inst2)
    n2 <- updateCount e
    checkEq "no second resize" 1 n2
    kinds2 <- eventKinds e aid
    check "timeline has window_ended / restored" (all (`elem` kinds2) ["window_ended", "restored"])
    check "lease released" (arClaimedBy r2 == Nothing)

shrinkOnEnd :: AppState -> IO ()
shrinkOnEnd st = do
    e <- newEnv st redisT (redisState 11 0) (redisPayload "beckn-redis-cluster-001" 2)
    end <- anHour
    aid <- startApply e (change 16 True True) (Just end)
    r <- drive e aid
    checkEq "applied" Applied (status r)
    endWindowNow e aid
    r2 <- drive e aid
    checkEq "restored" Restored (status r2)
    inst <- instNow e
    checkEq "capacity is back at the original 11 shards" 11 (VT.isUnits inst)
    checkEq "the autoscaler minimum is back at 2" (Right 2) =<< minNow e
    n <- updateCount e
    checkEq "one grow and one shrink" 2 n
    check "the shrink got a deadline" (isJust (VT.saShrinkDeadline (afterOf r2)))
    -- a shrink that fails is not re-issued forever
    e2 <- newEnv st redisT (redisState 11 0) (redisPayload "beckn-redis-cluster-001" 2)
    aid2 <- startApply e2 (change 16 True True) (Just end)
    _ <- drive e2 aid2
    writeIORef (fkOpError (eFake e2)) (Just "quota exceeded")
    endWindowNow e2 aid2
    r3 <- drive e2 aid2
    checkEq "a failed shrink parks the apply" NeedsAttention (status r3)
    n3 <- updateCount e2
    checkEq "and was requested exactly once (grow + one shrink)" 2 n3

resizeOnly :: AppState -> IO ()
resizeOnly st = do
    e <- newEnv st redisT (redisState 11 0) (redisPayload "beckn-redis-cluster-001" 2)
    end <- anHour
    aid <- startApply e (change 16 False False) (Just end)
    r <- drive e aid
    checkEq "applied" Applied (status r)
    w <- jobWrites e
    checkEq "the autoscaler job was never written" 0 w
    checkEq "its minimum is unchanged" (Right 2) =<< minNow e
    endWindowNow e aid
    r2 <- drive e aid
    checkEq "restored" Restored (status r2)
    w2 <- jobWrites e
    checkEq "still never written" 0 w2

blockOnly :: AppState -> IO ()
blockOnly st = do
    e <- newEnv st redisT (redisState 20 0) (redisPayload "beckn-redis-cluster-001" 2)
    end <- anHour
    aid <- startApply e (change 16 True False) (Just end)
    r <- drive e aid
    checkEq "applied" Applied (status r)
    checkEq "the autoscaler is pinned at 16" (Right 16) =<< minNow e
    n <- updateCount e
    checkEq "no resize (already 20 shards)" 0 n
    endWindowNow e aid
    r2 <- drive e aid
    checkEq "restored" Restored (status r2)
    checkEq "minimum back at 2" (Right 2) =<< minNow e

standalone :: AppState -> IO ()
standalone st = do
    e <- newEnv st standaloneT (standaloneState 0) (redisPayload "unused" 2)
    end <- anHour
    aid <- startApply e (VT.ScaleChange Nothing (Just 2) False False) (Just end)
    r <- drive e aid
    checkEq "applied" Applied (status r)
    inst <- instNow e
    checkEq "two replicas" 2 (VT.isReplicas inst)
    checkEq "still one shard" 1 (VT.isUnits inst)
    ups <- readIORef (fkUpdates (eFake e))
    checkEq "one replica resize, no shard resize" [UpdateReplicas 2] ups
    w <- jobWrites e
    checkEq "no autoscaler involved" 0 w
    endWindowNow e aid
    r2 <- drive e aid
    checkEq "restored" Restored (status r2)
    inst2 <- instNow e
    checkEq "replicas stay" 2 (VT.isReplicas inst2)
    e2 <- newEnv st standaloneT (standaloneState 0) (redisPayload "unused" 2)
    aid2 <- startApply e2 (VT.ScaleChange Nothing (Just 2) True False) (Just end)
    r3 <- drive e2 aid2
    checkEq "blocking a shard autoscaler on a standalone instance fails up front" Failed (status r3)
    n <- updateCount e2
    checkEq "and nothing was resized" 0 n

readPool :: AppState -> IO ()
readPool st = do
    e <- newEnv st dbT (poolState 1) (dbPayload 1)
    end <- anHour
    aid <- startApply e (VT.ScaleChange (Just 4) Nothing True False) (Just end)
    r <- drive e aid
    checkEq "applied" Applied (status r)
    inst <- instNow e
    checkEq "the read pool has 4 nodes" 4 (VT.isUnits inst)
    ups <- readIORef (fkUpdates (eFake e))
    checkEq "one node-count resize" [UpdateUnits 4] ups
    checkEq "minNodeCount of this pool is pinned at 4" (Right 4) =<< minNow e
    other <- minimumOf dbT {VT.tgResource = "driver-db-cluster-reader-non-critical"} e
    checkEq "the other pool's entry is untouched" (Right 3) other
    endWindowNow e aid
    r2 <- drive e aid
    checkEq "restored" Restored (status r2)
    checkEq "minNodeCount is back at 1" (Right 1) =<< minNow e
    inst2 <- instNow e
    checkEq "nodes stay" 4 (VT.isUnits inst2)
    -- a pool with no autoscaler job can still be scheduled
    e2 <- newEnv st dbNoJobT (poolState 1) (dbPayload 1)
    aid2 <- startApply e2 (VT.ScaleChange (Just 3) Nothing False False) (Just end)
    r3 <- drive e2 aid2
    checkEq "applied without any autoscaler" Applied (status r3)
    w <- jobWrites e2
    checkEq "no job write" 0 w
    -- shrinking back works by nodes too
    e3 <- newEnv st dbT (poolState 1) (dbPayload 1)
    aid3 <- startApply e3 (VT.ScaleChange (Just 4) Nothing True True) (Just end)
    _ <- drive e3 aid3
    endWindowNow e3 aid3
    r4 <- drive e3 aid3
    checkEq "restored with shrink" Restored (status r4)
    inst4 <- instNow e3
    checkEq "back to 1 node" 1 (VT.isUnits inst4)

refusals :: AppState -> IO ()
refusals st = do
    end <- anHour
    e <- newEnv st redisT (redisState 16 0) (redisPayload "beckn-redis-cluster-001" 2)
    aid <- startApply e (change 16 False False) (Just end)
    r <- drive e aid
    checkEq "already at the target: skipped" Skipped (status r)
    n <- updateCount e
    checkEq "no resize" 0 n
    e2 <- newEnv st redisT (redisState 11 0) (redisPayload "beckn-redis-cluster-001" 2)
    flow st (putGuardrailRow cloudName VT.KindRedis (VT.tgId redisT) (A.toJSON VT.defaultGuardrail {VT.grMaxUnits = Just 14}) "it")
    aid2 <- startApply e2 (change 16 True False) (Just end)
    r2 <- drive e2 aid2
    checkEq "above the guardrail: skipped" Skipped (status r2)
    n2 <- updateCount e2
    checkEq "no resize" 0 n2
    w2 <- jobWrites e2
    checkEq "autoscaler untouched" 0 w2
    kinds <- eventKinds e2 aid2
    check "timeline says refused" ("refused" `elem` kinds)
    e3 <- newEnv st redisT (redisState 11 0) (redisPayload "beckn-redis-cluster-001" 2)
    flow st (putGuardrailRow cloudName VT.KindRedis (VT.tgId redisT) (A.toJSON VT.defaultGuardrail {VT.grFrozen = True, VT.grFrozenReason = Just "sale"}) "it")
    aid3 <- startApply e3 (change 16 True False) (Just end)
    r3 <- drive e3 aid3
    checkEq "frozen: skipped" Skipped (status r3)
    e4 <- newEnv st redisT (redisState 11 0) (redisPayload "beckn-redis-cluster-001" 2)
    past <- addUTCTime (-60) <$> nowT
    aid4 <- startApply e4 (change 16 True False) (Just past)
    r4 <- drive e4 aid4
    checkEq "window already over: skipped" Skipped (status r4)
    e5 <- newEnv st noJobT (redisState 11 0) (redisPayload "beckn-redis-cluster-001" 2)
    aid5 <- startApply e5 (change 16 True False) (Just end)
    r5 <- drive e5 aid5
    checkEq "blocking scale-in with no autoscaler job fails up front" Failed (status r5)
    n5 <- updateCount e5
    checkEq "and nothing was resized" 0 n5
    e6 <- newEnv st dbT (poolState 1) (dbPayload 1)
    flow st (putGuardrailRow cloudName VT.KindDb (VT.tgId dbT) (A.toJSON VT.defaultGuardrail {VT.grMaxUnits = Just 3}) "it")
    aid6 <- startApply e6 (VT.ScaleChange (Just 5) Nothing False False) (Just end)
    r6 <- drive e6 aid6
    checkEq "the guardrail applies to read pools too" Skipped (status r6)

crashAfterPin :: AppState -> IO ()
crashAfterPin st = do
    e <- newEnv st redisT (redisState 11 0) (redisPayload "beckn-redis-cluster-001" 2)
    writeIORef (fkFault (eFake e)) CrashAfterJobWrite
    end <- anHour
    aid <- startApply e (change 16 True False) (Just end)
    r <- drive e aid
    checkEq "applied after the crash" Applied (status r)
    w <- jobWrites e
    checkEq "the pin was written exactly once" 1 w
    checkEq "and recorded as ours" (Just 16) (VT.saPinned (afterOf r))
    n <- updateCount e
    checkEq "one resize" 1 n
    endWindowNow e aid
    r2 <- drive e aid
    checkEq "restored" Restored (status r2)
    checkEq "the autoscaler minimum is back at 2" (Right 2) =<< minNow e
    w2 <- jobWrites e
    checkEq "one pin and one restore" 2 w2

rollbackInGap :: AppState -> IO ()
rollbackInGap st = do
    e <- newEnv st redisT (redisState 11 0) (redisPayload "beckn-redis-cluster-001" 2)
    writeIORef (fkFault (eFake e)) CrashAfterJobWrite
    end <- anHour
    aid <- startApply e (change 16 True False) (Just end)
    -- stop right after the crash: the intent is recorded, the pin is not
    r <- driveUntil e aid (\x -> VT.saPinIntent (afterOf x) == Just 16 && VT.saPinned (afterOf x) == Nothing)
    checkEq "the intent was recorded before the write" (Just 16, Nothing) (VT.saPinIntent (afterOf r), VT.saPinned (afterOf r))
    checkEq "the job really was written" (Right 16) =<< minNow e
    -- the schedule is deleted in that gap
    ok <- flow st (forceTransition aid cloudName [Applying] RollingBack (Just "the schedule was deleted"))
    check "rollback accepted" ok
    r2 <- drive e aid
    checkEq "rolled back" RolledBack (status r2)
    checkEq "the autoscaler minimum is put back although the pin was never recorded" (Right 2) =<< minNow e

notOurs :: AppState -> IO ()
notOurs st = do
    -- the job already holds the target value, set by someone else after our snapshot
    e <- newEnv st redisT (redisState 11 0) (redisPayload "beckn-redis-cluster-001" 16)
    end <- anHour
    aid <- startApply e (change 16 True False) (Just end)
    sql st "UPDATE scaler_apply SET status = 'APPLYING', before_spec = ?::jsonb WHERE id = ?" (A.toJSON (VT.ScaleSnapshot 11 0 (Just 2)), aid)
    r <- drive e aid
    checkEq "applied" Applied (status r)
    checkEq "we did not claim a value we never wrote" Nothing (VT.saPinned (afterOf r))
    w <- jobWrites e
    checkEq "the job was not written" 0 w
    endWindowNow e aid
    r2 <- drive e aid
    checkEq "restored" Restored (status r2)
    checkEq "their value is still there" (Right 16) =<< minNow e
    w2 <- jobWrites e
    checkEq "still not written" 0 w2

disappearsAfterPin :: AppState -> IO ()
disappearsAfterPin st = do
    e <- newEnv st redisT (redisState 11 0) (redisPayload "beckn-redis-cluster-001" 2)
    writeIORef (fkFault (eFake e)) CrashAfterJobWrite
    end <- anHour
    aid <- startApply e (change 16 True False) (Just end)
    _ <- driveUntil e aid (\x -> VT.saPinIntent (afterOf x) == Just 16)
    writeIORef (fkMissing (eFake e)) True
    r <- drive e aid
    checkEq "rolled back, not left failed with the pin in place" RolledBack (status r)
    checkEq "the autoscaler minimum is back at 2" (Right 2) =<< minNow e

crashAfterResize :: AppState -> IO ()
crashAfterResize st = do
    e <- newEnv st redisT (redisState 11 0) (redisPayload "beckn-redis-cluster-001" 2)
    writeIORef (fkFault (eFake e)) CrashAfterUpdate
    end <- anHour
    aid <- startApply e (change 16 True False) (Just end)
    r <- drive e aid
    checkEq "applied after the crash" Applied (status r)
    n <- updateCount e
    checkEq "the resize was requested exactly once" 1 n
    inst <- instNow e
    checkEq "16 shards" 16 (VT.isUnits inst)

busyAtStart :: AppState -> IO ()
busyAtStart st = do
    e <- newEnv st redisT (VT.InstanceState VT.ModeCluster "UPDATING" 11 0) (redisPayload "beckn-redis-cluster-001" 2)
    writeIORef (fkSettle (eFake e)) 4
    end <- anHour
    aid <- startApply e (change 16 True False) (Just end)
    r <- drive e aid
    checkEq "applied once the instance was free" Applied (status r)
    check "the wait was recorded as a deferral, not a failure" (arDeferCount r >= 1 && arAttempt r == 0)
    n <- updateCount e
    checkEq "one resize" 1 n
    inst <- instNow e
    checkEq "16 shards" 16 (VT.isUnits inst)

resizeFails :: AppState -> IO ()
resizeFails st = do
    e <- newEnv st redisT (redisState 11 0) (redisPayload "beckn-redis-cluster-001" 2)
    writeIORef (fkOpError (eFake e)) (Just "quota exceeded")
    end <- anHour
    aid <- startApply e (change 16 True False) (Just end)
    r <- drive e aid
    checkEq "a failed resize parks the apply for a human" NeedsAttention (status r)
    check "the error says why" (maybe False ("quota exceeded" `T.isInfixOf`) (arError r))
    n <- updateCount e
    checkEq "the resize was NOT retried" 1 n
    checkEq "the pin is still in place until someone decides" (Right 16) =<< minNow e
    -- acknowledging gives it up: the autoscaler is put back
    ok <- flow st (forceTransition aid cloudName [NeedsAttention] RollingBack (Just "acknowledged"))
    check "acknowledge accepted (as a rollback)" ok
    r2 <- drive e aid
    checkEq "rolled back" RolledBack (status r2)
    checkEq "the autoscaler minimum is back at 2" (Right 2) =<< minNow e

drift :: AppState -> IO ()
drift st = do
    e <- newEnv st redisT (redisState 11 0) (redisPayload "beckn-redis-cluster-001" 2)
    end <- anHour
    aid <- startApply e (change 16 True False) (Just end)
    r <- drive e aid
    checkEq "applied" Applied (status r)
    writeIORef (fkJob (eFake e)) (VL.encodeJobData (redisPayload "beckn-redis-cluster-001" 20))
    endWindowNow e aid
    r2 <- drive e aid
    checkEq "restored" Restored (status r2)
    checkEq "their value was left alone" (Right 20) =<< minNow e
    evs <- events e aid
    check "the timeline says it was left alone" (any (\(k, m) -> k == "restored" && "left at 20" `T.isInfixOf` m) evs)

wrongCluster :: AppState -> IO ()
wrongCluster st = do
    e <- newEnv st redisT (redisState 11 0) (redisPayload "some-other-cluster" 2)
    end <- anHour
    aid <- startApply e (change 16 True False) (Just end)
    r <- drive e aid
    checkEq "fails" Failed (status r)
    check "the error names what was expected" (maybe False ("beckn-redis-cluster-001" `T.isInfixOf`) (arError r))
    n <- updateCount e
    checkEq "nothing was resized" 0 n
    w <- jobWrites e
    checkEq "the job was not written" 0 w

rollbackKeepsCapacity :: AppState -> IO ()
rollbackKeepsCapacity st = do
    e <- newEnv st redisT (redisState 11 0) (redisPayload "beckn-redis-cluster-001" 2)
    end <- anHour
    aid <- startApply e (change 16 True True) (Just end)
    r <- drive e aid
    checkEq "applied" Applied (status r)
    ok <- flow st (forceTransition aid cloudName [Applied] RollingBack (Just "operator"))
    check "rollback accepted" ok
    r2 <- drive e aid
    checkEq "rolled back" RolledBack (status r2)
    checkEq "the autoscaler minimum is back at 2" (Right 2) =<< minNow e
    inst <- instNow e
    checkEq "capacity is kept even though shrinkOnEnd was set" 16 (VT.isUnits inst)
    n <- updateCount e
    checkEq "no shrink was requested" 1 n

uniqueness :: AppState -> IO ()
uniqueness st = do
    e <- newEnv st redisT (redisState 11 0) (redisPayload "beckn-redis-cluster-001" 2)
    end <- anHour
    _ <- startApply e (change 16 True False) (Just end)
    let new anId' kind tid sched ws =
            ApplyNew
                { anId = anId'
                , anCloud = cloudName
                , anScheduleId = sched
                , anTrigger = "MANUAL"
                , anKind = kind
                , anTargetId = tid
                , anChange = A.toJSON (change 16 True False)
                , anWindowStart = ws
                , anWindowEnd = Just end
                , anCreatedBy = "it"
                }
    ok2 <- flow st (insertApply (new "it-dup" VT.KindRedis (VT.tgId redisT) Nothing Nothing))
    check "a second in-flight apply for the same target is refused" (not ok2)
    ok3 <- flow st (insertApply (new "it-other" VT.KindDb (VT.tgId dbT) Nothing Nothing))
    check "a different target may have its own" ok3
    cleanDb st
    t <- nowT
    a <- flow st (insertApply (new "it-w1" VT.KindRedis (VT.tgId redisT) (Just "it-sched") (Just t)))
    check "the first apply of the window is accepted" a
    sql st "UPDATE scaler_apply SET status = 'RESTORED' WHERE id = 'it-w1'" ()
    b <- flow st (insertApply (new "it-w2" VT.KindRedis (VT.tgId redisT) (Just "it-sched") (Just t)))
    check "the same window is never applied twice, even after it finished" (not b)

leases :: AppState -> IO ()
leases st = do
    e <- newEnv st redisT (redisState 11 0) (redisPayload "beckn-redis-cluster-001" 2)
    end <- anHour
    aid <- startApply e (change 16 True False) (Just end)
    sql st "UPDATE scaler_apply SET next_run_at = now() WHERE id = ?" (Only aid)
    m1 <- flow st (claimNextApply cloudName "w1" 90)
    m2 <- flow st (claimNextApply cloudName "w2" 90)
    check "the first worker claims it" (fmap arId m1 == Just aid)
    check "a second worker cannot while the lease is live" (fmap arId m2 == Nothing)
    own <- flow st (holdsLease aid "w1")
    other <- flow st (holdsLease aid "w2")
    check "the holder holds the lease" own
    check "a stranger does not" (not other)
    hb <- flow st (heartbeatApply aid "w1" 90)
    check "the holder can heartbeat" hb
    hb2 <- flow st (heartbeatApply aid "w2" 90)
    check "a stranger cannot" (not hb2)
    sql st "UPDATE scaler_apply SET lease_expires_at = now() - interval '1 second' WHERE id = ?" (Only aid)
    stale <- flow st (holdsLease aid "w1")
    check "an expired lease is not held any more (so writes stop)" (not stale)
    m3 <- flow st (claimNextApply cloudName "w2" 90)
    check "an expired lease is reclaimed" (fmap arId m3 == Just aid)
    check "and the dead claim is counted" (fmap arAttempt m3 == Just 1)

reconciler :: AppState -> IO ()
reconciler st = do
    cleanDb st
    ok <- flow st (insertTarget cloudName redisT "it")
    check "target registered" ok
    now <- nowT
    let timing = Once (addUTCTime (-60) now) (Just (addUTCTime 3600 now))
        ch = change 16 True False
        sched sid tm = flow st (insertSchedule cloudName sid VT.KindRedis (VT.tgId redisT) "peak" (A.toJSON tm) (A.toJSON ch) "it")
        applyCount sid = sqlCount st "SELECT count(*)::int FROM scaler_apply WHERE cloud = ? AND schedule_id = ?" (cloudName, sid :: Text)
    sched "it-sched-1" timing
    flow st (reconcileTick cloudName)
    checkEq "an open window produces one apply" 1 =<< applyCount "it-sched-1"
    sql st "UPDATE scaler_schedule SET last_eval_at = NULL WHERE id = 'it-sched-1'" ()
    flow st (reconcileTick cloudName)
    checkEq "evaluating again adds nothing" 1 =<< applyCount "it-sched-1"
    cleanDb st
    _ <- flow st (insertTarget cloudName redisT "it")
    sched "it-sched-2" timing
    _ <- flow st (setScheduleStatus cloudName "it-sched-2" "PAUSED")
    flow st (reconcileTick cloudName)
    checkEq "a paused schedule produces no apply" 0 =<< applyCount "it-sched-2"
    cleanDb st
    _ <- flow st (insertTarget cloudName redisT "it")
    sched "it-sched-3" (Once (addUTCTime 7200 now) (Just (addUTCTime 10800 now)))
    flow st (reconcileTick cloudName)
    checkEq "a future window produces no apply yet" 0 =<< applyCount "it-sched-3"
    cleanDb st
    _ <- flow st (insertTarget cloudName redisT "it")
    sched "it-sched-4" (Once (addUTCTime (-7200) now) (Just (addUTCTime (-3600) now)))
    flow st (reconcileTick cloudName)
    s <- flow st (getSchedule cloudName "it-sched-4")
    checkEq "a finished one-off schedule is marked EXPIRED" (Just "EXPIRED") (fmap srStatus s)
    checkEq "and produces no apply" 0 =<< applyCount "it-sched-4"
    -- a DB schedule becomes a DB apply
    cleanDb st
    _ <- flow st (insertTarget cloudName dbT "it")
    flow st (insertSchedule cloudName "it-sched-5" VT.KindDb (VT.tgId dbT) "pool peak" (A.toJSON timing) (A.toJSON (VT.ScaleChange (Just 3) Nothing False False)) "it")
    flow st (reconcileTick cloudName)
    checkEq "a read-pool schedule produces its apply" 1 =<< applyCount "it-sched-5"
    k <- sqlCount st "SELECT count(*)::int FROM scaler_apply WHERE cloud = ? AND target_kind = 'DB'" (Only cloudName)
    checkEq "with the DB target kind" 1 k

targets :: AppState -> IO ()
targets st = do
    cleanDb st
    ok1 <- flow st (insertTarget cloudName redisT "it")
    check "a Valkey instance is registered" ok1
    ok2 <- flow st (insertTarget cloudName dbT "it")
    check "an AlloyDB read pool is registered" ok2
    dup <- flow st (insertTarget cloudName redisT {VT.tgId = "it-redis-2"} "it")
    check "the same instance cannot be registered twice" (not dup)
    all' <- flow st (listTargets cloudName Nothing)
    checkEq "both are listed" 2 (length all')
    reds <- flow st (listTargets cloudName (Just VT.KindRedis))
    checkEq "listing by kind" ["it-redis"] (map VT.tgId reds)
    dbs <- flow st (listTargets cloudName (Just VT.KindDb))
    checkEq "the read pool keeps its cluster" [Just "driver-db-cluster"] (map VT.tgParent dbs)
    g <- flow st (getTarget cloudName VT.KindDb "it-db")
    checkEq "fetched by kind and id" (Just dbT) g
    wrongKind <- flow st (getTarget cloudName VT.KindRedis "it-db")
    checkEq "an id is only valid for its own kind" Nothing wrongKind
    upd <- flow st (updateTarget cloudName redisT {VT.tgName = "renamed", VT.tgJob = Nothing})
    check "label and job can be edited" upd
    g2 <- flow st (getTarget cloudName VT.KindRedis "it-redis")
    checkEq "the edit stuck" (Just ("renamed", Nothing)) (fmap (\t -> (VT.tgName t, VT.tgJob t)) g2)
    -- in use
    soon <- addUTCTime 7200 <$> nowT
    flow st (insertSchedule cloudName "it-s" VT.KindRedis "it-redis" "s" (A.toJSON (Once soon Nothing)) (A.toJSON (change 4 False False)) "it")
    n <- flow st (targetInUse cloudName VT.KindRedis "it-redis")
    checkEq "a schedule makes the target in use" 1 n
    _ <- flow st (deleteSchedule cloudName "it-s")
    n2 <- flow st (targetInUse cloudName VT.KindRedis "it-redis")
    checkEq "not once the schedule is deleted" 0 n2
    del <- flow st (deleteTarget cloudName VT.KindRedis "it-redis")
    check "an unused target can be removed" del
    gone <- flow st (getTarget cloudName VT.KindRedis "it-redis")
    checkEq "and is gone" Nothing gone
    again <- flow st (insertTarget cloudName redisT {VT.tgId = "it-redis-again"} "it")
    check "the same instance can be registered again after removal (under a fresh id)" again

autoscalerEditor :: AppState -> IO ()
autoscalerEditor st = do
    e <- newEnv st redisT (redisState 11 0) (redisPayload "beckn-redis-cluster-001" 2)
    let gcp = fakeGcp (eFake e)
        tg = redisT
        run' = flow st
        hist = run' (listAutoscalerHistory cloudName VT.KindRedis (VT.tgId tg) 50)
        n :: Int -> Value
        n = A.toJSON
        view = do
            r <- run' (readAutoscaler gcp cloudName tg)
            either (\x -> fail ("cannot read the autoscaler: " <> T.unpack (editErrText x))) pure r
    v0 <- view
    checkEq "the editor shows this target's entry" (Right 2) (VL.entryFor (VT.autoscalerKeys tg) (A.toJSON [avEntry v0]) >>= VL.readMinimum (VT.autoscalerKeys tg))
    checkEq "and the job's state" "ENABLED" (avState v0)
    check "no scheduled change is holding it" (avHeldBy v0 == Nothing)
    -- a valid edit
    r1 <- run' (editAutoscaler gcp cloudName tg "alice" "EDIT" (VL.EditReq [("minSize", n 5)] Nothing) (avData v0) "raise the floor")
    check "a valid edit is accepted" (either (const False) (const True) r1)
    checkEq "the job now holds the new minimum" (Right 5) =<< minNow e
    h1 <- hist
    checkEq "one history entry" 1 (length h1)
    check "recording who and why" (case h1 of [Object o] -> KM.lookup "actor" o == Just (String "alice") && KM.lookup "note" o == Just (String "raise the floor") && KM.lookup "action" o == Just (String "EDIT"); _ -> False)
    -- a stale edit is refused
    r2 <- run' (editAutoscaler gcp cloudName tg "bob" "EDIT" (VL.EditReq [("maxSize", n 100)] Nothing) (avData v0) "")
    check "an edit made against an out-of-date payload is refused" (case r2 of Left (EditConflict _) -> True; _ -> False)
    checkEq "and changed nothing" 1 . length =<< hist
    v1 <- view
    -- invalid edits
    r3 <- run' (editAutoscaler gcp cloudName tg "bob" "EDIT" (VL.EditReq [("scalerPubSubTopic", String "x")] Nothing) (avData v1) "")
    check "a setting that cannot be edited is refused" (case r3 of Left (EditBad _) -> True; _ -> False)
    r4 <- run' (editAutoscaler gcp cloudName tg "bob" "EDIT" (VL.EditReq [("minSize", n 999)] Nothing) (avData v1) "")
    check "an out-of-range value is refused" (case r4 of Left (EditBad _) -> True; _ -> False)
    r5 <- run' (editAutoscaler gcp cloudName tg "bob" "EDIT" (VL.EditReq [("minSize", n 5)] Nothing) (avData v1) "")
    check "an edit that changes nothing is refused" (case r5 of Left (EditBad _) -> True; _ -> False)
    r6 <- run' (editAutoscaler gcp cloudName tg "bob" "EDIT" (VL.EditReq [] (Just (String "not rules"))) (avData v1) "")
    check "bad rules are refused" (case r6 of Left (EditBad _) -> True; _ -> False)
    writes <- jobWrites e
    checkEq "none of the refused edits reached the job" 1 writes
    -- new rules
    let newRules = A.toJSON [object ["name" .= ("only" :: Text), "conditions" .= object ["all" .= [object ["fact" .= ("cpu_average_utilization" :: Text), "operator" .= ("greaterThan" :: Text), "value" .= n 80]]], "event" .= object ["type" .= ("OUT" :: Text), "params" .= object []]]]
    r7 <- run' (editAutoscaler gcp cloudName tg "alice" "EDIT" (VL.EditReq [] (Just newRules)) (avData v1) "")
    check "the scaling rules can be replaced" (either (const False) (const True) r7)
    v2 <- view
    check "and read back" (case avEntry v2 of Object o -> KM.lookup "scalingRules" o == Just newRules; _ -> False)
    -- a scheduled change holds the minimum: that setting is read-only meanwhile, the others are not
    end <- anHour
    aid <- startApply e (change 16 True False) (Just end)
    r <- drive e aid
    checkEq "a scheduled change is holding the minimum" Applied (status r)
    v3 <- view
    check "the editor says who holds it" (avHeldBy v3 == Just aid)
    r8 <- run' (editAutoscaler gcp cloudName tg "alice" "EDIT" (VL.EditReq [("minSize", n 3)] Nothing) (avData v3) "")
    check "the held minimum cannot be edited" (case r8 of Left (EditConflict _) -> True; _ -> False)
    r9 <- run' (editAutoscaler gcp cloudName tg "alice" "EDIT" (VL.EditReq [("maxSize", n 200)] Nothing) (avData v3) "")
    check "other settings still can" (either (const False) (const True) r9)
    endWindowNow e aid
    r10 <- drive e aid
    checkEq "the hold is restored" Restored (status r10)
    checkEq "the minimum is back to what it was before the hold" (Right 5) =<< minNow e
    v4 <- view
    check "and the edit made during the hold survived" (case avEntry v4 of Object o -> KM.lookup "maxSize" o == Just (n 200); _ -> False)
    -- revert the first edit
    hs <- hist
    let firstId = case reverse hs of
            (Object o : _) | Just (A.Number i) <- KM.lookup "id" o -> truncate i
            _ -> 0 :: Int
    r11 <- run' (revertAutoscaler gcp cloudName tg "carol" firstId (avData v4))
    check "a past change can be reverted" (either (const False) (const True) r11)
    checkEq "the minimum is what it was before that edit" (Right 2) =<< minNow e
    hs2 <- hist
    check "the revert is in the history too" (any (\h -> case h of Object o -> KM.lookup "action" o == Just (String "REVERT"); _ -> False) hs2)
    r12 <- run' (revertAutoscaler gcp cloudName tg "carol" 999999 (avData v4))
    check "reverting something that is not there is refused" (case r12 of Left (EditNotFound _) -> True; _ -> False)
    -- pause / resume
    p1 <- run' (setAutoscalerPaused gcp cloudName tg "alice" True "freeze scaling")
    check "the autoscaler job can be paused" (either (const False) (const True) p1)
    v5 <- view
    checkEq "and shows as paused" "PAUSED" (avState v5)
    p2 <- run' (setAutoscalerPaused gcp cloudName tg "alice" False "")
    check "and resumed" (either (const False) (const True) p2)
    v6 <- view
    checkEq "back to enabled" "ENABLED" (avState v6)
    hs3 <- hist
    check "pause and resume are in the history" (length [() | Object o <- hs3, KM.lookup "action" o `elem` [Just (String "PAUSE"), Just (String "RESUME")]] == 2)
    -- no job
    e2 <- newEnv st noJobT (redisState 11 0) (redisPayload "beckn-redis-cluster-001" 2)
    r13 <- run' (readAutoscaler (fakeGcp (eFake e2)) cloudName noJobT)
    check "a target with no autoscaler job has nothing to edit" (case r13 of Left (EditNotFound _) -> True; _ -> False)
    -- a read pool
    e3 <- newEnv st dbT (poolState 1) (dbPayload 1)
    let gcp3 = fakeGcp (eFake e3)
    rv <- run' (readAutoscaler gcp3 cloudName dbT)
    v7 <- either (\x -> fail (T.unpack (editErrText x))) pure rv
    r14 <- run' (editAutoscaler gcp3 cloudName dbT "alice" "EDIT" (VL.EditReq [("maxNodeCount", n 10), ("stepSize", n 2)] Nothing) (avData v7) "")
    check "a read pool's settings are edited through the same path" (either (const False) (const True) r14)
    other <- minimumOf dbT {VT.tgResource = "driver-db-cluster-reader-non-critical"} e3
    checkEq "without touching the other pool" (Right 3) other
