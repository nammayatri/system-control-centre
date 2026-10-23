{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Follows the GitHub runs of devbox releases (every 10 s).

The devbox workflow runs one step per stage, named exactly like the stage
(Preparing, Sync, Build, Start, Data, Control centre, Result). GitHub reports
each step's status while the job runs, so every tick:

  * each step that started / finished becomes an event (written once);
  * the step running now is the release's stage;
  * a finished spawn run: success → read DEVBOX_RESULT from the job log →
    READY with its URLs; anything else → FAILED at the failing step, with the
    error line from the log;
  * a finished stop run: success → STOPPED; failure → error noted, still STOPPING.

Runs on every SCC replica: events are written once and status updates only
move forward, so duplicate ticks are harmless.
-}
module Products.Devbox.Poller (devboxPollLoop) where

import Control.Monad (forM_, forever, when)
import Control.Monad.Catch (SomeException, catch, try)
import Core.Environment (Flow, logError, logInfo, logWarning)
import Core.Types.Time (Seconds (..), threadDelay)
import Data.Aeson (object, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Types qualified as AT
import Data.ByteString.Lazy qualified as BL
import Data.Int (Int64)
import Data.List (find)
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (diffUTCTime)
import Data.Aeson.KeyMap qualified as KM
import Products.Autopilot.Mobile.Github (Job (..), JobStep (..), WorkflowRun (..), cancelRun, fetchJobLog, getWorkflowRun, listJobs)
import Products.Autopilot.Mobile.Github.Auth (GhAppCreds, loadGhCreds)
import Products.Autopilot.Mobile.Github (DispatchRunDetails (..))
import Products.Devbox.Github (AppBuild (..), appBuildFor, dispatch, dispatchAppBuild)
import Products.Devbox.Queries
import Products.Devbox.Types (DevboxBuild (..), DevboxRelease (..))

owner, repo :: Text
owner = "nammayatri"
repo = "nammayatri"

-- | Workflow step name → the stage it reports.
stageSteps :: [(Text, Text)]
stageSteps =
    [ ("Preparing", "preparing")
    , ("Sync", "sync")
    , ("Build", "build")
    , ("Start", "start")
    , ("Data", "data")
    , ("Control centre", "cc")
    , ("Result", "ready")
    ]

devboxPollLoop :: Flow ()
devboxPollLoop =
    try loadGhCreds >>= \case
        Left (e :: SomeException) ->
            logWarning ("[devbox-poller] GitHub App not configured, poller disabled: " <> T.pack (show e))
        Right creds -> do
            logInfo "[devbox-poller] started"
            forever $ do
                tick creds `catch` \(e :: SomeException) -> logError ("[devbox-poller] tick failed: " <> T.pack (show e))
                threadDelay (Seconds 10)

tick :: GhAppCreds -> Flow ()
tick creds = do
    rows <- pollableReleases
    forM_ rows $ \r ->
        follow creds r `catch` \(e :: SomeException) ->
            logWarning ("[devbox-poller] " <> drId r <> ": " <> T.pack (show e))
    expired <- expiredReleases
    forM_ expired $ \r ->
        expire creds r `catch` \(e :: SomeException) ->
            logWarning ("[devbox-poller] expiry of " <> drId r <> ": " <> T.pack (show e))
    ready <- releasesNeedingBuilds
    forM_ ready $ \r ->
        startBuilds creds r `catch` \(e :: SomeException) ->
            logWarning ("[devbox-poller] app builds of " <> drId r <> ": " <> T.pack (show e))
    builds <- openBuilds
    forM_ builds $ \b ->
        followBuild creds b `catch` \(e :: SomeException) ->
            logWarning ("[devbox-poller] build " <> T.pack (show (dbId b)) <> ": " <> T.pack (show e))

{- | A release just became READY and asked for app builds: start each one on
the app branch with the release's backend as its base URL. Each build row is
claimed first, so one SCC replica dispatches it.
-}
startBuilds :: GhAppCreds -> DevboxRelease -> Flow ()
startBuilds creds r =
    case (drFrontendBranch r, drBackendUrl r) of
        (Just ref, Just backendUrl) ->
            forM_ (mapMaybe appBuildFor (drAppBuilds r)) $ \ab ->
                insertBuild (drId r) (abApp ab) (abPlatform ab) >>= \case
                    Nothing -> pure ()
                    Just bid -> do
                        res <- dispatchAppBuild creds ab ref backendUrl (drWorkspace r) (drId r)
                        case res of
                            Right (Just d) -> () <$ setBuildRun bid (drdRunId d) (drdHtmlUrl d)
                            Right Nothing -> () <$ setBuildFailed bid "GitHub started the build but did not say which run"
                            Left err -> () <$ setBuildFailed bid ("could not start the build: " <> err)
                        insertEvent (drId r) (abPlatform ab) "started" (object ["app" .= abApp ab]) Nothing
        _ -> logWarning ("[devbox-poller] " <> drId r <> ": app builds need an app branch and a backend URL")

{- | Follow one app build: when its run ends, read DEVBOX_APP_LINK (printed by
the Fastfile) from the job logs → DONE with the Firebase link / TestFlight
build number, or FAILED.
-}
followBuild :: GhAppCreds -> DevboxBuild -> Flow ()
followBuild creds b = forM_ (dbGhRunId b) $ \runId -> do
    let appOwner = "nammayatri"
        appRepoName = "ny-react-native"
        runText = T.pack (show runId)
    getWorkflowRun creds appOwner appRepoName runText >>= \case
        Left e -> logWarning ("[devbox-poller] build run " <> runText <> ": " <> e)
        Right run -> when (wrStatus run == "completed") $
            case wrConclusion run of
                Just "success" -> do
                    jobs <- either (const []) id <$> listJobs creds appOwner appRepoName runText
                    logs <- mapM (fmap (either (const "") id) . fetchJobLog creds appOwner appRepoName . jId) jobs
                    let line = listToMaybe [l | lg <- logs, l <- T.lines lg, "DEVBOX_APP_LINK " `T.isInfixOf` l]
                        value = T.strip . snd . T.breakOnEnd "DEVBOX_APP_LINK " <$> line
                        (link, buildNo) = case value of
                            Just v | "http" `T.isPrefixOf` v -> (Just v, Nothing)
                            Just v | "testflight build " `T.isPrefixOf` v -> (Nothing, Just (T.drop 17 v))
                            _ -> (Nothing, Nothing)
                    _ <- setBuildDone (dbId b) link buildNo
                    insertEvent (dbReleaseId b) (dbPlatform b) "done" (object ["app" .= dbApp b, "link" .= link, "build" .= buildNo]) Nothing
                conclusion -> do
                    let msg = "build " <> fromMaybe "ended" conclusion <> "; see its GitHub logs"
                    _ <- setBuildFailed (dbId b) msg
                    insertEvent (dbReleaseId b) (dbPlatform b) "failed" (object ["app" .= dbApp b, "error" .= msg]) Nothing

{- | Auto-stop a release past its lifetime (devbox_lifetime_days). Only the
replica whose STOPPING update wins goes on, so the stop is sent once.
-}
expire :: GhAppCreds -> DevboxRelease -> Flow ()
expire creds r = do
    won <- setStopping (drId r) "system"
    when won $ do
        insertEvent (drId r) "stop" "started" (object ["by" .= ("system" :: Text), "reason" .= ("expired" :: Text)]) Nothing
        logInfo ("[devbox-poller] " <> drId r <> " expired, stopping")
        case (drDevboxHost r, drDevboxUser r) of
            (Just host, Just user) ->
                dispatch creds (drId r) "stop" $
                    KM.fromList
                        [ ("action", A.String "stop")
                        , ("workspace", A.String (drWorkspace r))
                        , ("release_id", A.String (drId r))
                        , ("owner", A.String (drCreatedBy r))
                        , ("devbox_host", A.String host)
                        , ("devbox_user", A.String user)
                        ]
            _ -> do
                -- Never reported a dev-box: cancel the run if it is still going.
                forM_ (drGhRunId r) $ \runId ->
                    () <$ cancelRun creds owner repo (T.pack (show runId))
                _ <- setStopped (drId r) "expired"
                insertEvent (drId r) "stop" "done" (object ["reason" .= ("expired" :: Text)]) Nothing

follow :: GhAppCreds -> DevboxRelease -> Flow ()
follow creds r = forM_ (drGhRunId r) $ \runId -> do
    let runText = T.pack (show runId)
    eRun <- getWorkflowRun creds owner repo runText
    eJobs <- listJobs creds owner repo runText
    case (eRun, eJobs) of
        (Right run, Right jobs) -> do
            let mJob = listToMaybe jobs
            case drCurrentAction r of
                "stop" -> followStop r runId run mJob
                _ -> followSpawn creds r runId run mJob
        (Left e, _) -> logWarning ("[devbox-poller] " <> drId r <> ": run " <> runText <> ": " <> e)
        (_, Left e) -> logWarning ("[devbox-poller] " <> drId r <> ": jobs of " <> runText <> ": " <> e)

followSpawn :: GhAppCreds -> DevboxRelease -> Int64 -> WorkflowRun -> Maybe Job -> Flow ()
followSpawn creds r runId run mJob = do
    let steps = maybe [] jSteps mJob
        stageOf s = lookup (jsName s) stageSteps
        ours = [(stage, s) | s <- steps, Just stage <- [stageOf s]]
        stepUrl s = (\j -> jHtmlUrl j <> "#step:" <> T.pack (show (jsNumber s)) <> ":1") <$> mJob
    -- Events: started when a step began, then done / skipped / failed when it ended.
    forM_ ours $ \(stage, s) -> do
        when (jsStatus s /= "queued" && jsStatus s /= "pending") $
            insertEventOnce (drId r) stage "started" runId (object []) (stepUrl s)
        when (jsStatus s == "completed") $
            insertEventOnce (drId r) stage (labelFor (jsConclusion s)) runId (object ["ms" .= durationMs s]) (stepUrl s)
    -- The stage now: the step in progress, else the last one that started.
    let running = find ((== "in_progress") . jsStatus . snd) ours
        lastStarted = listToMaybe (reverse [st | st@(_, s) <- ours, jsStatus s /= "queued", jsStatus s /= "pending"])
    forM_ (running <|> lastStarted) $ \(stage, _) ->
        when (stage /= "ready") $ () <$ setStage (drId r) stage
    when (wrStatus run == "completed") $
        case wrConclusion run of
            Just "success" -> do
                result <- maybe (pure Nothing) (fmap (either (const Nothing) parseResult) . fetchJobLog creds owner repo . jId) mJob
                case result of
                    Just ri -> do
                        _ <- setReady (drId r) ri
                        insertEventOnce (drId r) "ready" "done" runId (object ["backendUrl" .= riBackendUrl ri]) Nothing
                        logInfo ("[devbox-poller] " <> drId r <> " ready")
                    Nothing -> do
                        _ <- setFailed (drId r) "the run finished but printed no DEVBOX_RESULT"
                        insertEventOnce (drId r) "ready" "failed" runId (object ["error" .= ("no DEVBOX_RESULT in the log" :: Text)]) Nothing
            conclusion -> do
                let failedStep = find ((`elem` [Just "failure", Just "cancelled", Just "timed_out"]) . jsConclusion . snd) ours
                    stage = maybe (drStage r) fst failedStep
                logText <- maybe (pure Nothing) (fmap (either (const Nothing) Just) . fetchJobLog creds owner repo . jId) mJob
                let detail = fromMaybe ("run " <> fromMaybe "ended" conclusion) (logText >>= lastErrorLine)
                    msg = stageLabel stage <> " failed: " <> detail
                _ <- setStage (drId r) stage
                _ <- setFailed (drId r) msg
                insertEventOnce (drId r) stage "failed" runId (object ["error" .= detail]) Nothing
  where
    (<|>) a b = maybe b Just a

followStop :: DevboxRelease -> Int64 -> WorkflowRun -> Maybe Job -> Flow ()
followStop r runId run _ =
    when (wrStatus run == "completed") $
        case wrConclusion run of
            Just "success" -> do
                let reason = if drStoppedBy r == Just "system" then "expired" else "user"
                _ <- setStopped (drId r) reason
                insertEventOnce (drId r) "stop" "done" runId (object ["reason" .= reason]) Nothing
            conclusion -> do
                let msg = "stop run " <> fromMaybe "ended" conclusion <> " — the workspace may still be on the dev-box; see the GitHub logs"
                _ <- setError (drId r) msg
                insertEventOnce (drId r) "stop" "failed" runId (object ["error" .= msg]) Nothing

labelFor :: Maybe Text -> Text
labelFor = \case
    Just "success" -> "done"
    Just "skipped" -> "skipped"
    _ -> "failed"

durationMs :: JobStep -> Maybe Int
durationMs s = case (jsStartedAt s, jsCompletedAt s) of
    (Just a, Just b) -> Just (round (realToFrac (diffUTCTime b a) * 1000 :: Double))
    _ -> Nothing

stageLabel :: Text -> Text
stageLabel st = maybe st fst (find ((== st) . snd) stageSteps)

{- | The DEVBOX_RESULT line of the Result step. GitHub prefixes every log line
with a timestamp, so search for the marker anywhere in the line.
-}
parseResult :: Text -> Maybe ReadyInfo
parseResult logText = do
    line <- listToMaybe (reverse (filter ("DEVBOX_RESULT " `T.isInfixOf`) (T.lines logText)))
    let json = T.strip (snd (T.breakOnEnd "DEVBOX_RESULT " line))
    obj <- A.decode (BL.fromStrict (TE.encodeUtf8 json)) :: Maybe A.Object
    let get k = AT.parseMaybe (A..: k) obj :: Maybe Text
        nonEmpty = \case Just t | not (T.null t) -> Just t; _ -> Nothing
        dataVersion = nonEmpty (get "data") >>= listToMaybe . drop 1 . T.words
    pure
        ReadyInfo
            { riDevboxName = nonEmpty (get "devbox")
            , riDevboxHost = nonEmpty (get "host")
            , riDevboxUser = nonEmpty (get "user")
            , riBackendUrl = nonEmpty (get "backend_url")
            , riCcUrl = nonEmpty (get "cc_url")
            , riDataVersion = dataVersion
            }

{- | The most useful error line: devbox_core prints {"error": "…"} on failure;
otherwise GitHub's own ::error:: annotations.
-}
lastErrorLine :: Text -> Maybe Text
lastErrorLine logText = listToMaybe (reverse (mapMaybe fromJsonError ls)) `orElse` listToMaybe (reverse (mapMaybe fromAnnotation ls))
  where
    ls = T.lines logText
    fromJsonError l = do
        let j = snd (T.breakOn "{\"error\"" l)
        if T.null j
            then Nothing
            else do
                obj <- A.decode (BL.fromStrict (TE.encodeUtf8 j)) :: Maybe A.Object
                T.take 300 <$> (AT.parseMaybe (A..: "error") obj :: Maybe Text)
    fromAnnotation l =
        let a = snd (T.breakOn "##[error]" l)
         in if T.null a then Nothing else Just (T.take 300 (T.drop 9 a))
    orElse a b = maybe b Just a
