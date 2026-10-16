{-# LANGUAGE OverloadedStrings #-}

{- | The release bot: @\@system-control-center-bot release <services> till <commit>@
in an allow-listed Xyne channel -> analysis -> Jenkins build -> (approval) -> apply
-> release trackers.

Safety properties, in order of importance:

  1. Nothing is applied without an authorised human: requester needs RELEASE_CREATE,
     approver needs RELEASE_APPROVE, and (by default) cannot be the requester.
  2. What runs is what was reviewed: the content hash fixed at approval time and the
     live-state fingerprint are both re-checked immediately before applying; any
     drift aborts the apply (no partial writes).
  3. Config is applied through SCC trackers (BackendConfig / BackendService with
     @envOverrideData@), never by patching the cluster directly, so staged rollout,
     health gates, audit and revert all still apply. Service trackers are created
     UNAPPROVED — the rollout itself is approved in SCC as usual.
  4. Everything unverifiable is a blocker, and a blocker means build-only.
  5. State changes are compare-and-set, so replicated workers cannot double-run a step.
-}
module Products.Autopilot.ReleaseBot.Flow (
    handleMention,
    handleClick,
    releaseBotLoop,
    publicRequestView,
    publicRequestSql,
    parseStoredStrategy,
    pickChannel,
    aggregateBuilds,
    BuildRec (..),
    linkToken,
    botEnabled,
) where

import Control.Monad (forM, forever, unless, void, when)
import qualified Control.Monad.Catch as C
import Control.Monad.IO.Class (liftIO)
import Core.Admin.Queries (writeAuditLog)
import Core.Auth.Protected (AuthedPerson (..), checkPersonPermission)
import Core.Auth.Queries (findPersonByEmail)
import Core.Environment (Flow, getConfig, logError, logInfo)
import Core.Secrets (lookupEnvSecret)
import Core.Types.Time (Seconds (..), threadDelay)
import Data.Aeson (Result (..), Value (..), fromJSON, object, toJSON, (.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.ByteArray (constEq)
import qualified Data.ByteString.Lazy as LBS
import Data.List (nub)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe, mapMaybe, maybeToList)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (addUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Text.Read (readMaybe)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import Products.Autopilot.Actions.ConfigMap (createConfigMapH, updateConfigMapH)
import Products.Autopilot.ConfigReview (reviewStatusInfo)
import Products.Autopilot.Actions.Release (approveReleaseH, createReleaseH, discardReleaseH, normalizeProductType)
import Products.Autopilot.K8s.Deployment (deploymentExists)
import Products.Autopilot.Queries.ProductService (findProductByName, findServiceByProductAndName, getProductNamespace, getServiceHost)
import qualified Products.Autopilot.Types.Storage.Schema as S
import Products.Autopilot.ProdRelease.Config
import Products.Autopilot.ReleaseBot.ConfigSource (loadBotConfig)
import Products.Autopilot.ProdRelease.Github
import Products.Autopilot.ProdRelease.Intent
import Products.Autopilot.ProdRelease.Jenkins (BuildStatus (..), ExistingBuild (..), TriggerResult (..), findExistingBuild, pollBuild, triggerBuild)
import Products.Autopilot.Queries.ReleaseTracker (findReleaseTracker)
import Products.Autopilot.ReleaseBot.Engine
import Products.Autopilot.ReleaseBot.Live (LiveEnv (..), readServiceEnv, replaceEnvVar)
import Products.Autopilot.ReleaseBot.Sql (SqlFile (..), countStatements, renderSql, sqlFromCompare, statementsFor, unattributed)
import Products.Autopilot.ReleaseBot.Store
import Products.Autopilot.ReleaseBot.GithubAuth (githubTokenFlow)
import Products.Autopilot.ReleaseBot.TrackerCard (closeTrackerCard)
import Products.Autopilot.ReleaseBot.PublicLink (linkToken, publicRequestLink)
import qualified Products.Autopilot.ReleaseBot.Xyne as X
import Products.Autopilot.ReleaseBot.DbManager (DbmItem (..), dbmConfigured, submitRequest)
import Products.Autopilot.Actions.K8sResource (resolveRolloutPodEstimateH, resolveRolloutPodEstimateSecondaryH, resolveSyncRolloutStrategyH)
import Products.Autopilot.Types.API (ApproveReleaseReq (..), DiscardReleaseReq (..), K8sCreateReleaseReq, RolloutPodEstimateReq (..))
import qualified Products.Autopilot.Types.Release as RT
import Products.Autopilot.Types.Release (ReleaseStatus (..))
import qualified Shared.API.Response as R

-- ─── Settings (env only) ───────────────────────────────────────────

envFlag :: String -> Bool -> Flow Bool
envFlag name def = do
    m <- lookupEnvSecret name
    pure $ case fmap T.toLower m of
        Just v -> v `elem` ["1", "true", "yes", "on"]
        Nothing -> def

-- | The whole feature is off unless explicitly enabled.
botEnabled :: Flow Bool
botEnabled = envFlag "SC_RELEASE_BOT_ENABLED" False

dryRun :: Flow Bool
dryRun = envFlag "SC_RELEASE_BOT_DRY_RUN" False

ttlMinutes :: Flow Int
ttlMinutes = do
    m <- lookupEnvSecret "SC_RELEASE_BOT_TTL_MINUTES"
    pure (fromMaybe 120 (m >>= readInt))
  where
    readInt t = case reads (T.unpack t) of [(n, "")] | n > 0 -> Just n; _ -> Nothing

-- ─── Public links ──────────────────────────────────────────────────

-- | Store one text value under a dynamic key of the request's data.
patchKey :: Req -> Text -> Text -> Flow ()
patchKey req k v = patchRequest (rqId req) (object [K.fromText k .= v])

publicLink :: Text -> Flow (Maybe Text)
publicLink = publicRequestLink

-- | Link to the request's combined SQL file (same HMAC token as the review page).
publicSqlLink :: Text -> Text -> Flow (Maybe Text)
publicSqlLink rid svc = do
    base <- lookupEnvSecret "SC_PUBLIC_BASE_URL"
    sec <- lookupEnvSecret "SC_RELEASE_BOT_LINK_SECRET"
    pure $ case (base, sec) of
        (Just b, Just s) -> Just (T.dropWhileEnd (== '/') b <> "/api/public/release-requests/" <> rid <> "/sql?s=" <> svc <> "&t=" <> linkToken s rid)
        _ -> Nothing

publicRequestSql :: Text -> Maybe Text -> Maybe Text -> Flow (Maybe Text)
publicRequestSql rid mTok mSvc = do
    sec <- lookupEnvSecret "SC_RELEASE_BOT_LINK_SECRET"
    case (sec, mTok) of
        (Just s, Just t) | constEq (TE.encodeUtf8 (linkToken s rid)) (TE.encodeUtf8 (T.toLower (T.strip t))) -> do
            mr <- getRequest rid
            pure (mr >>= \r -> mSvc >>= \sv -> dText ("sql:" <> sv) (rqData r))
        _ -> pure Nothing

{- | Public, read-only view for the no-VPN page. Valid only with the request's link
token; any mismatch is indistinguishable from "not found". Never includes apply
payloads — see 'publicView'.
-}
publicRequestView :: Text -> Maybe Text -> Flow (Maybe Value)
publicRequestView rid mTok = do
    sec <- lookupEnvSecret "SC_RELEASE_BOT_LINK_SECRET"
    case (sec, mTok) of
        (Just s, Just t) | constEq (TE.encodeUtf8 (linkToken s rid)) (TE.encodeUtf8 (T.toLower (T.strip t))) -> do
            mr <- getRequest rid
            pure $ flip fmap mr $ \r ->
                let d = rqData r
                 in object
                        [ "id" .= rqId r
                        , "state" .= rqState r
                        , "requester" .= dText "requesterName" d
                        , "repo" .= dText "repo" d
                        , "env" .= dText "env" d
                        , "branch" .= dText "branch" d
                        , "commit" .= dText "commit" d
                        , "expiresAt" .= rqExpiresAt r
                        , "buildResult" .= dText "jenkinsResult" d
                        , "buildUrl" .= dText "jenkinsBuildUrl" d
                        , "approver" .= dText "approver" d
                        , "analysis" .= fmap publicView (dField "analysis" d)
                        ]
        _ -> pure Nothing

-- ─── Helpers ───────────────────────────────────────────────────────

say :: Text -> Maybe Text -> Text -> Flow (Maybe Text)
say ch th txt = do
    r <- X.postText ch th txt
    case r of
        Left e -> logError ("[release-bot] xyne post failed: " <> e) >> pure Nothing
        Right ts -> pure (if T.null ts then Nothing else Just ts)

sayReq :: Req -> Text -> Flow ()
sayReq r txt = case rqChannel r of
    Just ch -> void (say ch (dText "threadTs" (rqData r)) txt)
    Nothing -> pure ()

shortId :: Text -> Text
shortId = T.take 8

authorize :: Text -> Text -> Flow (Either Text AuthedPerson)
authorize email perm = do
    mp <- findPersonByEmail (T.toLower (T.strip email))
    case mp of
        Nothing -> pure (Left ("no SCC account for " <> email))
        Just p -> do
            r <- checkPersonPermission "autopilot" perm p
            pure $ case r of
                Left (_, why) -> Left why
                Right ap -> Right ap

audit :: Maybe AuthedPerson -> Text -> Text -> Value -> Flow ()
audit mAp action rid details = case mAp of
    Just ap -> writeAuditLog (apPersonId ap) action (Just "release_request") (Just rid) (Just details)
    Nothing -> logInfo ("[release-bot] " <> action <> " " <> rid <> " " <> T.pack (show details))

idOfResponse :: R.APIResponse -> Maybe Text
idOfResponse r
    | R.status r == "SUCCESS" = case T.breakOnEnd ": " (R.message r) of
        (_, rid) | not (T.null rid) -> Just (T.strip rid)
        _ -> Nothing
    | otherwise = Nothing

-- ─── Mention -> request ────────────────────────────────────────────

handleMention :: X.Mention -> Flow ()
handleMention m = do
    enabled <- botEnabled
    forUs <- mentionIsForUs m
    when (enabled && forUs) $ do
        -- Webhook ids cannot be used as a thread_ts, so we open our own root message and
        -- keep everything else (errors, progress, summary) in its thread. Only the
        -- Config Approve/Reject card is posted into this thread; rollout cards go in each tracker's own thread.
        root <- say (X.mChannel m) Nothing ("🛠 Release request from " <> X.mSenderName m <> " received — checking…")
        let reply = void . say (X.mChannel m) root
        ecfg <- loadBotConfig
        case ecfg of
            Left e -> reply ("⚠️ Release bot is not configured yet: " <> e <> "\nAdd release rules on the Deployment Config page (or release_bot_config_json); see RELEASE_BOT.md.")
            Right pc -> case channelsFor pc (X.mChannel m) of
                [] -> reply "This channel is not enabled for release requests."
                cands -> case pickChannel pc (X.mText m) cands of
                    Left why -> reply why
                    Right ch -> case findRepo pc (chRepo ch) of
                        Nothing -> reply ("⚠️ Channel is mapped to unknown repo " <> chRepo ch)
                        Just repo0 -> do
                            let repo = forEnv (chEnv ch) repo0
                            newRequest pc{prcRepos = [repo]} ch repo root m

{- | A channel may serve several repos. Pick the one the message is about: the repo whose name,
service names or aliases appear in it, the LONGEST such mention winning ("control center backend"
beats a bare "backend"). A tie, or no mention at all, asks the requester to be specific.
-}
pickChannel :: ProdReleaseConfig -> Text -> [ChannelCfg] -> Either Text ChannelCfg
pickChannel _ _ [c] = Right c
pickChannel pc msg cands =
    let low = T.toLower msg
        score c = case findRepo pc (chRepo c) of
            Nothing -> 0
            Just r ->
                maximum
                    ( 0
                        : [ T.length t
                          | t <- T.toLower (rcName r) : concat [T.toLower (scService x) : map T.toLower (scAliases x) | x <- rcServices (forEnv (chEnv c) r)]
                          , not (T.null t)
                          , t `T.isInfixOf` low
                          ]
                    )
        top = maximum (map score cands)
        winners = [c | c <- cands, score c == top]
     in case winners of
            [c] | top > 0 -> Right c
            _ -> Left ("This channel serves several repos (" <> T.intercalate ", " (map chRepo cands) <> "). Say which one — mention the repo or one of its service names.")

{- | The webhook URL may be shared with other Xyne apps, so react only when THIS app was
tagged. If the message carries no mention ids, or our own id cannot be determined, we do
not filter (the signed webhook is already dedicated to this app in the normal setup).
-}
mentionIsForUs :: X.Mention -> Flow Bool
mentionIsForUs m
    | null (X.mMentioned m) = pure True
    | otherwise = maybe True (`elem` X.mMentioned m) <$> X.botUserId

newRequest :: ProdReleaseConfig -> ChannelCfg -> RepoCfg -> Maybe Text -> X.Mention -> Flow ()
newRequest pc ch repo root m = do
    rid <- UUID.toText <$> liftIO UUID.nextRandom
    now <- liftIO getCurrentTime
    ttl <- ttlMinutes
    email <- if T.null (X.mSenderEmail m) then snd <$> X.getUser (X.mUserId m) else pure (X.mSenderEmail m)
    let expires = addUTCTime (fromIntegral ttl * 60) now
        base =
            object
                [ "repo" .= rcName repo
                , "env" .= chEnv ch
                , "requesterName" .= X.mSenderName m
                , "requesterEmail" .= email
                , "text" .= T.take 500 (X.mText m)
                ]
    fresh <- insertRequest rid "RECEIVED" (nonEmpty (X.mMessageId m)) (X.mChannel m) email expires base
    when fresh $ do
        auth <- authorize email "RELEASE_CREATE"
        case auth of
            Left why -> do
                void (transition rid "RECEIVED" "DENIED" (object ["error" .= why]))
                audit Nothing "RELEASE_BOT_DENIED" rid (object ["email" .= email, "why" .= why])
                void (say (X.mChannel m) root ("⛔ " <> email <> " is not allowed to request releases: " <> why))
            Right ap -> do
                audit (Just ap) "RELEASE_BOT_REQUEST" rid (object ["text" .= T.take 300 (X.mText m), "channel" .= X.mChannel m])
                void (say (X.mChannel m) root ("Request `" <> shortId rid <> "` — analyzing…"))
                patchRequest rid (object ["threadTs" .= root])
                planRequest pc ch repo ap rid root m
  where
    nonEmpty t = if T.null t then Nothing else Just t

-- | Parse + validate the message, then analyze and start. Anything missing -> INFO_ONLY.
planRequest :: ProdReleaseConfig -> ChannelCfg -> RepoCfg -> AuthedPerson -> Text -> Maybe Text -> X.Mention -> Flow ()
planRequest pc ch repo ap rid thread m = do
    let reply t = void (say (X.mChannel m) thread t)
        stop why = void (transition rid "RECEIVED" "INFO_ONLY" (object ["error" .= why])) >> reply why
    parsed <- parseIntent pc emptyIntent{inRepo = Just (rcName repo)} (X.mText m)
    let services = inServices parsed
        svcCfgs = [x | n <- services, x <- take 1 [y | y <- rcServices repo, scService y == n]]
        -- a service may release from its own branches (service rule "branches"); empty = the repo's
        allowedFor x = if null (scBranches x) then rcBranches repo else scBranches x
        common = case map allowedFor svcCfgs of
            [] -> rcBranches repo
            (b : bs) -> foldl (\acc o -> [x | x <- acc, x `elem` o]) b bs
        branchE = case inBranch parsed of
            Just b
                | b `elem` common -> Right b
                | otherwise -> Left ("`" <> b <> "` is not a release branch for " <> T.intercalate ", " services <> " (allowed: " <> T.intercalate ", " common <> ").")
            Nothing -> case common of
                (b : _) -> Right b
                [] -> Left ("These services release from different branches (" <> T.intercalate "; " [scService x <> ": " <> T.intercalate "/" (allowedFor x) | x <- svcCfgs] <> "). Release them in separate requests.")
        branch = either (const (head' (rcBranches repo))) id branchE
    etoken <- githubTokenFlow
    -- "release X till latest main" / "head": no sha given, take the branch head
    let wantsHead = any (`T.isInfixOf` T.toLower (X.mText m)) ["latest", "newest", "head of", "tip of", "current main", "current head"]
    mSha <- case (etoken, inCommit parsed) of
        (Right token, Nothing) | wantsHead, Right _ <- branchE -> do
            hs <- listBranchCommits token (repoSlug repo) branch 1
            pure (case hs of Right (c : _) -> Just (csSha c); _ -> Nothing)
        (_, c) -> pure c
    case (etoken, mSha) of
        _ | Left w <- branchE -> stop w
        (Left e, _) -> stop ("⚠️ " <> e)
        (_, Nothing) -> do
            recent <- either (const []) id <$> either (const (pure (Right []))) (\t -> listBranchCommits t (repoSlug repo) branch 5) etoken
            stop ("I need the commit to release up to. Example: `release " <> T.intercalate " and " (take 2 (map scService (rcServices repo))) <> " till COMMIT_SHA`." <> recentList recent)
        (Right token, Just sha) ->
            if null services
                then stop ("Which service(s)? Available: " <> T.intercalate ", " (map scService (rcServices repo)) <> ".")
                else do
                    full <- resolveFullSha token (repoSlug repo) sha
                    case full of
                        Left e -> stop ("I can't find commit `" <> sha <> "` in " <> rcName repo <> ": " <> e)
                        Right fullSha -> do
                            -- no branch named: take the first allowed branch that contains the commit
                            let candidates = if isJust (inBranch parsed) then [branch] else common
                                tryBranches [] lastErr = pure (Left lastErr)
                                tryBranches (b : bs) _ = do
                                    r <- compareFiles token (repoSlug repo) b fullSha
                                    case r of
                                        Right c | crStatus c `elem` ["behind", "identical"] -> pure (Right b)
                                        Right c -> tryBranches bs ("Commit `" <> T.take 7 fullSha <> "` is not on `" <> b <> "` (it is " <> crStatus c <> " of it). Refusing.")
                                        Left e -> tryBranches bs ("Could not verify the commit is on `" <> b <> "`: " <> e)
                            chosen <- tryBranches candidates "No release branch configured."
                            case chosen of
                                Left why
                                    | length candidates > 1 -> stop ("Commit `" <> T.take 7 fullSha <> "` is not on any of the allowed branches (" <> T.intercalate ", " candidates <> ").")
                                    | otherwise -> stop why
                                Right branch' -> do
                                    headOk <- headGuard token branch' fullSha services
                                    case headOk of
                                        Left why -> stop why
                                        Right () -> startRequest ch repo ap rid thread m token branch' fullSha services
  where
    -- A Jenkins job without a commit parameter always builds the branch head: only that commit can be released.
    headGuard token branch fullSha services
        | all (isJust . jcCommitParam . jenkinsForSvc repo (chEnv ch)) [x | n <- services, x <- take 1 [y | y <- rcServices repo, scService y == n]] = pure (Right ())
        | otherwise = do
            r <- listBranchCommits token (repoSlug repo) branch 1
            pure $ case r of
                Right (c : _)
                    | csSha c == fullSha -> Right ()
                    | otherwise -> Left ("This repo's Jenkins job takes no commit — it always builds the latest `" <> branch <> "` (head is `" <> T.take 7 (csSha c) <> "`), but you asked for `" <> T.take 7 fullSha <> "`. Ask for the head commit instead.")
                Right [] -> Left ("`" <> branch <> "` has no commits?")
                Left e -> Left ("Could not read the head of `" <> branch <> "`: " <> e)
    head' (x : _) = x
    head' [] = ""
    recentList [] = ""
    recentList cs = "\nRecent commits on `" <> head' (rcBranches repo) <> "`:\n" <> T.unlines ["• `" <> T.take 7 (csSha c) <> "` " <> csMessage c | c <- cs]

data Gate = GateOk | GateFailed [CheckSummary] | GatePending [CheckSummary]

-- | GitHub CI signals on the commit, minus the ignored names. Fails safe: an API error is @Left@.
gateChecks :: RepoCfg -> Text -> Text -> Flow (Either Text Gate)
gateChecks repo token sha = do
    r <- getCommitChecks token (repoSlug repo) sha
    pure $ case r of
        Left e -> Left ("could not read the CI checks of `" <> T.take 7 sha <> "` (" <> e <> ")")
        Right cs ->
            let ignored c = any (\i -> T.toLower i `T.isInfixOf` T.toLower (ckName c)) (rcIgnoreChecks repo)
                live = filter (not . ignored) cs
                bad = [c | c <- live, ckState c == "failure"]
                pend = [c | c <- live, ckState c == "pending"]
             in if not (null bad) then Right (GateFailed bad) else if not (null pend) then Right (GatePending pend) else Right GateOk

checkNames :: [CheckSummary] -> Text
checkNames cs = T.intercalate ", " [ckName c <> maybe "" (\u -> " ([link](" <> u <> "))") (ckUrl c) | c <- take 8 cs] <> (if length cs > 8 then " …" else "")

{- | With @requireChecks@ on, the Jenkins build only starts once every GitHub check on the commit has
passed: pending checks park the request in WAITING_CHECKS (the worker re-checks), a failed one stops it.
-}
startRequest :: ChannelCfg -> RepoCfg -> AuthedPerson -> Text -> Maybe Text -> X.Mention -> Text -> Text -> Text -> [Text] -> Flow ()
startRequest ch repo ap rid thread m token branch fullSha services
    | not (rcRequireChecks repo) = startRequestNow ch repo ap rid thread m token branch fullSha services
    | otherwise = do
        let reply t = void (say (X.mChannel m) thread t)
        g <- gateChecks repo token fullSha
        case g of
            Left why -> do
                void (transition rid "RECEIVED" "FAILED" (object ["error" .= why]))
                reply ("❌ Not starting the build: " <> why <> ".")
            Right (GateFailed bs) -> do
                void (transition rid "RECEIVED" "FAILED" (object ["error" .= ("CI checks failed: " <> checkNames bs)]))
                reply ("❌ Not starting the Jenkins build — CI checks failed on `" <> T.take 7 fullSha <> "`: " <> checkNames bs)
            Right (GatePending ps) -> do
                now <- liftIO getPOSIXTime
                patchRequest rid (object ["repo" .= rcName repo, "branch" .= branch, "commit" .= fullSha, "services" .= services, "checksSince" .= (T.pack (show (round now :: Integer)))])
                ok <- transition rid "RECEIVED" "WAITING_CHECKS" (object [])
                when ok $ reply ("⏳ Waiting for " <> T.pack (show (length ps)) <> " CI check(s) on `" <> T.take 7 fullSha <> "` to finish before building: " <> checkNames ps)
            Right GateOk -> startRequestNow ch repo ap rid thread m token branch fullSha services

-- | Re-check a parked request; when the checks are green, carry on exactly as a fresh request would.
resumeChecks :: Either Text ProdReleaseConfig -> Req -> Flow ()
resumeChecks ecfg req = do
    let d = rqData req
        rid = rqId req
    case (ecfg, rqChannel req, dText "repo" d, dText "branch" d, dText "commit" d) of
        (Right pc, Just chan, Just rn, Just branch, Just sha)
            | Just repo <- listToMaybe [r | r <- prcRepos pc, rcName r == rn]
            , Just ch <- listToMaybe [c | c <- channelsFor pc chan, T.toLower (chRepo c) == T.toLower rn] -> do
                etoken <- githubTokenFlow
                case etoken of
                    Left e -> logError ("[release-bot] " <> rid <> " waiting for checks: " <> e)
                    Right token -> do
                        g <- gateChecks repo token sha
                        now <- liftIO getPOSIXTime
                        let since = fromMaybe 0 (dText "checksSince" d >>= readMaybe . T.unpack) :: Integer
                            timedOut = round now - since > 90 * 60
                        case g of
                            Left e -> logError ("[release-bot] " <> rid <> " waiting for checks: " <> e)
                            Right (GateFailed bs) -> failReq req "WAITING_CHECKS" ("CI checks failed on `" <> T.take 7 sha <> "`: " <> checkNames bs <> ". The Jenkins build was not started")
                            Right (GatePending ps)
                                | timedOut -> failReq req "WAITING_CHECKS" ("CI checks still pending after 90 minutes (" <> checkNames ps <> "). The Jenkins build was not started")
                                | otherwise -> pure ()
                            Right GateOk -> do
                                eap <- authorize (fromMaybe "" (rqRequester req)) "RELEASE_CREATE"
                                case eap of
                                    Left why -> failReq req "WAITING_CHECKS" ("requester can no longer create releases: " <> why)
                                    Right ap -> do
                                        won <- transition rid "WAITING_CHECKS" "RECEIVED" (object [])
                                        when won $ do
                                            sayReq req ("✅ CI checks passed on `" <> T.take 7 sha <> "` — starting the Jenkins build.")
                                            startRequestNow ch repo ap rid (dText "threadTs" d) (X.Mention chan "" "" "" "" "" []) token branch sha (dTexts "services" d)
        _ -> failReq req "WAITING_CHECKS" "the release configuration changed while waiting for CI checks"

startRequestNow :: ChannelCfg -> RepoCfg -> AuthedPerson -> Text -> Maybe Text -> X.Mention -> Text -> Text -> Text -> [Text] -> Flow ()
startRequestNow ch repo ap rid thread m token branch fullSha services = do
    an <- analyze ap token repo (chEnv ch) (Just branch) fullSha services
    if not (null (anServices an)) && all (atTarget . srBaseCommit) (anServices an)
        then do
            let why = "Nothing to release: " <> T.intercalate ", " (map srService (anServices an)) <> " already run `" <> T.take 7 fullSha <> "` (the deployed commit is the one you asked for). Ask for a newer commit on `" <> branch <> "`."
            void (transition rid "RECEIVED" "INFO_ONLY" (object ["error" .= why]))
            void (say (X.mChannel m) thread why)
        else do
            let current = [srService r | r <- anServices an, atTarget (srBaseCommit r)]
                todo = [srService r | r <- anServices an, not (atTarget (srBaseCommit r))]
            if null current || null todo
                then startAnalysed ch repo rid thread m branch fullSha services an
                else do
                    -- some services already run this commit: leave them out, release the rest
                    void (say (X.mChannel m) thread ("ℹ️ " <> T.intercalate ", " current <> " already run `" <> T.take 7 fullSha <> "` — skipping " <> (if length current > 1 then "them" else "it") <> ", releasing " <> T.intercalate ", " todo <> "."))
                    startRequestNow ch repo ap rid thread m token branch fullSha todo
  where
    atTarget = maybe False (\b -> not (T.null b) && (b `T.isPrefixOf` fullSha || fullSha `T.isPrefixOf` b))

startAnalysed :: ChannelCfg -> RepoCfg -> Text -> Maybe Text -> X.Mention -> Text -> Text -> [Text] -> Analysis -> Flow ()
startAnalysed ch repo rid thread m branch fullSha services an = do
    dry <- dryRun
    link <- publicLink rid
    let blockers = anBlockers an
        mode = if null blockers then "tracker" else "build_only" :: Text
        wantsApproval = needsApproval an && null blockers
        approved =
            [ object ["service" .= ecService e, "envVar" .= ecEnvVar e, "liveB64" .= ecLiveB64 e, "newB64" .= ecNewB64 e]
            | e <- anEnvChanges an
            , ecState e == "changed"
            ]
        reply t = void (say (X.mChannel m) thread t)
        svcs = [x | n <- services, x <- take 1 [y | y <- rcServices repo, scService y == n]]
        jOf = jenkinsForSvc repo (chEnv ch)
        tagOf j = fromMaybe "" (jcCommitPrefix j) <> T.take (fromMaybe 6 (jcCommitLength j)) fullSha
        paramsOf x =
            let j = jOf x
             in maybe id (\p -> M.insert p (tagOf j)) (jcCommitParam j) (M.union (scJenkinsParams x) (jcFixedParams j))
        -- services with the same Jenkins job AND parameters share ONE build
        addSet acc x =
            let k = (jcJob (jOf x), paramsOf x)
             in case break ((== k) . fst) acc of
                    (pre, (q, ns) : post) -> pre ++ [(q, ns ++ [scService x])] ++ post
                    (pre, []) -> pre ++ [(k, [scService x])]
        sets = foldl addSet [] svcs
        jobs = nub (map (jcJob . jOf) svcs)
        -- Is this image already built (or being built)? Then do not build it again.
        runAll [] acc = pure (Right (reverse acc))
        runAll (((job, p), names) : rest) acc = do
            let noCommit = case [jOf x | x <- svcs, scService x `elem` names] of (j : _) -> isNothing (jcCommitParam j); [] -> False
            ex <- findExistingBuild job p (if noCommit then Just fullSha else Nothing)
            existing <- case ex of
                Right found -> pure found
                Left e -> logError ("[release-bot] could not look up existing Jenkins builds, will trigger a new one: " <> e) >> pure Nothing
            case existing of
                Just eb -> runAll rest (BuildRec names Nothing (Just (ebUrl eb)) (Just (fromMaybe "RUNNING" (ebResult eb))) True Nothing : acc)
                Nothing -> do
                    t <- triggerBuild job p
                    case t of
                        Left e -> pure (Left e)
                        Right tr -> runAll rest (BuildRec names (trQueueUrl tr) Nothing (Just "QUEUED") False (Just (trJobUrl tr)) : acc)
    buildsE <- if dry then pure (Right []) else runAll sets []
    let patch =
            object $
                [ "branch" .= branch
                , "commit" .= fullSha
                , "services" .= services
                , "analysis" .= toJSON an
                , "mode" .= mode
                , "envApproved" .= approved
                , "approvedContentHash" .= anContentHash an
                , "liveFingerprint" .= anLiveFingerprint an
                , "publicLink" .= link
                , "jenkinsJob" .= T.intercalate ", " jobs
                ]
                    ++ case buildsE of
                        Right bs@(_ : _) ->
                            let (res, url, q) = aggregateBuilds bs
                             in ["jenkinsBuilds" .= map brToJson bs, "jenkinsQueueUrl" .= q, "jenkinsResult" .= res, "jenkinsBuildUrl" .= url, "buildReused" .= any brReused bs]
                        _ -> []
        buildLine = case buildsE of
            Right bs -> T.intercalate "\n" [buildLabel (length bs > 1) b <> describeBuild b | b <- bs]
            Left _ -> ""
        summary = summaryText rid an link
    case buildsE of
        Left e -> do
            patchRequest rid patch
            void (transition rid "RECEIVED" "FAILED" (object ["error" .= ("Jenkins trigger failed: " <> e)]))
            reply (summary <> "\n❌ Jenkins build could not be started: " <> e)
        Right _
            | dry -> do
                patchRequest rid patch
                void (transition rid "RECEIVED" "COMPLETED" (object ["note" .= ("dry run — nothing triggered" :: Text)]))
                reply (summary <> "\n🧪 Dry run: no build triggered and nothing applied.")
            | wantsApproval -> do
                patchRequest rid patch
                void (transition rid "RECEIVED" "AWAITING_APPROVAL" (object []))
                reply (summary <> "\n" <> buildLine)
                card <- X.postApprovalCard (X.mChannel m) thread (approvalCardText rid an link) rid
                case card of
                    Right (mid, _) -> patchRequest rid (object ["cardMessageId" .= mid])
                    Left e -> reply ("⚠️ Could not post the approval card: " <> e <> ". Ask an approver to open the diff link.")
            | otherwise -> do
                patchRequest rid patch
                void (transition rid "RECEIVED" "BUILDING" (object []))
                reply (summary <> "\n" <> buildLine <> "\n" <> nextStep mode)
  where
    nextStep mode
        | mode == "build_only" = "ℹ️ Build only — release tracker will NOT be created (see blockers above)."
        | otherwise = "✅ No config changes. The release tracker will be created when the build succeeds."

summaryText :: Text -> Analysis -> Maybe Text -> Text
summaryText rid an link =
    T.unlines $
        [ "*Release request* `" <> shortId rid <> "` — " <> anRepo an <> (maybe "" (\b -> "/" <> b) (anBranch an)) <> " @ `" <> T.take 7 (anCommit an) <> "` (" <> anEnv an <> ")"
        ]
            ++ [ "• " <> srService s <> ": " <> fromMaybe "?" (srOldVersion s) <> " → " <> T.take 6 (anCommit an) <> maybe "" (\u -> " ([diff](" <> u <> "))") (srDiffUrl s)
               | s <- anServices an
               ]
            ++ ["⚠️ *Secret file changed* — update the secret before rollout: " <> T.intercalate ", " (anSecretFiles an) | not (null (anSecretFiles an))]
            ++ ["⚠️ Could not fully verify whether secret files changed (diff incomplete)." | anSecretUnverifiable an]
            ++ ["🔴 Cannot auto-apply: " <> b | b <- anBlockers an]
            ++ ["🟡 Config change: " <> describeChanges an | needsApproval an]
            ++ ["Review the env/config diff: " <> l | Just l <- [link], needsApproval an]
            ++ coverageLines an

{- | The "did you check everything it references" checklist: per service, the dhall env var
rule, each configmap the running deployment references (checked / unchanged / not tracked),
and the secret names referenced (names only — values are never read).
-}
coverageLines :: Analysis -> [Text]
coverageLines an =
    concatMap perService (cvServices cv)
        ++ ["⚠️ dhall changed but no rule watches it: " <> T.intercalate ", " (cvUnmapped cv) | not (null (cvUnmapped cv))]
        ++ [ if cvComplete cv
                then "✅ Coverage: every configmap the deployment references was checked."
                else "⚠️ Coverage INCOMPLETE — some things the deployment references were not checked (listed above). Review them before approving."
           ]
  where
    cv = anCoverage an
    perService c = case covError c of
        Just why -> ["📋 " <> covService c <> ": ⚠️ could not read the deployment — " <> why]
        Nothing ->
            ["📋 " <> covService c <> maybe "" (\d -> " (" <> d <> ")") (covDeployment c) <> ":"]
                ++ ["   • env " <> v <> ": " <> st | Just (v, st) <- [covEnvVar c]]
                ++ ["   • configmap " <> n <> ": " <> st | (n, st) <- covConfigMaps c, st /= "ignored"]
                ++ ["   • secrets referenced (values not read): " <> T.intercalate ", " (covSecrets c) | not (null (covSecrets c))]

describeChanges :: Analysis -> Text
describeChanges an =
    T.intercalate "; " $
        [ "configmap `" <> ccName c <> "` (" <> T.pack (show (length (ccDiffs c))) <> " file(s))" | c <- anConfigMaps an]
            ++ ["env `" <> ecEnvVar e <> "` on " <> ecService e | e <- anEnvChanges an, ecState e == "changed"]
            ++ ["dhall changed for " <> srService s | s <- anServices an, not (null (srDhallHits s))]

approvalCardText :: Text -> Analysis -> Maybe Text -> Text
approvalCardText rid an link =
    T.unlines $
        [ "**Approval needed** — release request `" <> shortId rid <> "`"
        , anRepo an <> " @ `" <> T.take 7 (anCommit an) <> "` → " <> T.intercalate ", " (map srService (anServices an))
        , "Changes to apply: " <> describeChanges an
        ]
            ++ ["Review the diff (no VPN needed): " <> l | Just l <- [link]]
            ++ ["⚠️ Secret file changed: " <> T.intercalate ", " (anSecretFiles an) | not (null (anSecretFiles an))]
            ++ coverageLines an
            ++ ["Approving applies exactly the diff shown. Only authorized approvers can approve."]

-- ─── Approve / reject ──────────────────────────────────────────────

ack :: Text -> Value
ack msg = object ["type" .= ("ack" :: Text), "message" .= msg]

handleClick :: X.Click -> Flow Value
handleClick c
    | X.cVerb c `elem` [X.trackerApproveVerb, X.trackerDiscardVerb] = handleTrackerClick c
    | X.cVerb c `elem` [X.rolloutApproveVerb, X.rolloutRejectVerb] = handleRolloutClick c
    | otherwise = handleConfigClick c

-- | Approve or discard the tracker a thread card belongs to (any backend release, bot-made or manual).
handleTrackerClick :: X.Click -> Flow Value
handleTrackerClick c = do
    (name, email0) <- if T.null (X.cEmail c) then X.getUser (X.cUserId c) else pure (X.cUserName c, X.cEmail c)
    let tid = X.cRequestId c
        approving = X.cVerb c == X.trackerApproveVerb
        who = if T.null name then email0 else name
    auth <- authorize email0 (if approving then "RELEASE_APPROVE" else "RELEASE_DISCARD")
    case auth of
        Left why -> pure (ack ("⛔ " <> who <> " cannot " <> (if approving then "approve" else "discard") <> " this: " <> why <> ". Nothing was changed."))
        Right ap -> do
            r <-
                tryAny $
                    if approving
                        then void (approveReleaseH ap tid (ApproveReleaseReq{approvedBy = who, isInfraApproved = Nothing}))
                        else do
                            resp <- discardReleaseH ap tid (DiscardReleaseReq{reason = Just ("Discarded from Xyne by " <> who)})
                            when (R.status resp /= "SUCCESS") (C.throwM (userError (T.unpack (R.message resp))))
            let err = either (T.take 200 . T.pack . show) (const "") r
                alreadyDone = any (`T.isInfixOf` err) ["already approved", "Cannot approve again", "already discarded", "already been discarded"]
                outcome
                    | alreadyDone = "ℹ️ Already " <> (if approving then "approved" else "discarded") <> " — nothing more to do here."
                    | T.null err = if approving then "✅ Approved by " <> who <> " — rollout starting." else "🚫 Discarded by " <> who <> "."
                    | otherwise = "⚠️ " <> who <> ": " <> err
            audit (Just ap) (if approving then "RELEASE_BOT_TRACKER_APPROVED" else "RELEASE_BOT_TRACKER_DISCARDED") tid (object ["error" .= err])
            -- the buttons go away on every outcome: a failed or repeated action must not leave live buttons
            closeTrackerCard tid outcome
            pure (ack outcome)

-- | Approve (which starts the rollout) or discard ONE service's tracker (the card's service).
handleRolloutClick :: X.Click -> Flow Value
handleRolloutClick c = do
    (name, email0) <- if T.null (X.cEmail c) then X.getUser (X.cUserId c) else pure (X.cUserName c, X.cEmail c)
    let rid = X.cRequestId c
        approving = X.cVerb c == X.rolloutApproveVerb
        who = if T.null name then email0 else name
    mr <- getRequest rid
    case mr of
        Nothing -> pure (ack "Unknown request.")
        Just req -> do
            auth <- authorize email0 (if approving then "RELEASE_APPROVE" else "RELEASE_DISCARD")
            let d = rqData req
                svc = X.cService c
                label = maybe "" (\x -> x <> ": ") svc
                tids = case svc of
                    Just sv -> maybeToList (dText ("tracker:" <> sv) d)
                    Nothing -> case dField "trackerIds" d of
                        Just (Array xs) -> [t | String t <- foldr (:) [] xs]
                        _ -> []
                cardKey = maybe "rolloutCardId" ("rolloutCard:" <>) svc
            case auth of
                Left why -> do
                    sayReq req ("⛔ " <> who <> " cannot " <> (if approving then "approve" else "discard") <> " " <> fromMaybe "this" svc <> ": " <> why <> ". Nothing was changed.")
                    pure (ack "You are not authorized.")
                Right ap
                    | null tids -> pure (ack "No release tracker recorded for this card.")
                    | otherwise -> do
                        results <- forM tids $ \tid -> do
                            r <-
                                tryAny $
                                    if approving
                                        then void (approveReleaseH ap tid (ApproveReleaseReq{approvedBy = who, isInfraApproved = Nothing}))
                                        else do
                                            resp <- discardReleaseH ap tid (DiscardReleaseReq{reason = Just ("Discarded from Xyne by " <> who)})
                                            when (R.status resp /= "SUCCESS") (C.throwM (userError (T.unpack (R.message resp))))
                            pure (tid, either (Just . T.take 200 . T.pack . show) (const Nothing) r)
                        let bad = [t <> ": " <> e | (t, Just e) <- results]
                            alreadyDone = not (null bad) && all (\(_, e) -> any (`T.isInfixOf` fromMaybe "" e) ["already approved", "Cannot approve again", "already discarded", "already been discarded"]) [r | r@(_, Just _) <- results]
                            outcome
                                | alreadyDone = "ℹ️ " <> label <> "already " <> (if approving then "approved" else "discarded") <> " — nothing more to do here."
                                | null bad = label <> (if approving then "✅ Approved by " <> who <> " — rollout starting." else "🚫 Discarded by " <> who <> ".")
                                | otherwise = "⚠️ " <> label <> who <> ": " <> T.intercalate "; " bad
                        audit (Just ap) (if approving then "RELEASE_BOT_ROLLOUT_APPROVED" else "RELEASE_BOT_ROLLOUT_DISCARDED") rid (object ["trackers" .= tids, "service" .= svc])
                        -- The card is replaced (buttons gone) on EVERY outcome, errors included: a failed or
                        -- already-done action must not leave live buttons that can only fail again.
                        void $ case (rqChannel req, dText cardKey d) of
                            (Just ch, Just mid) -> X.updateCard (fromMaybe ch (dText ("rolloutCardCh:" <> fromMaybe "" svc) d)) mid outcome
                            _ -> pure (Right ())
                        sayReq req outcome
                        pure (ack outcome)

handleConfigClick :: X.Click -> Flow Value
handleConfigClick c = do
    (name, email0) <- if T.null (X.cEmail c) then X.getUser (X.cUserId c) else pure (X.cUserName c, X.cEmail c)
    let rid = X.cRequestId c
        approving = X.cVerb c == X.approveVerb
    mr <- getRequest rid
    case mr of
        Nothing -> pure (ack "Unknown request.")
        Just req -> do
            auth <- authorize email0 "RELEASE_APPROVE"
            case auth of
                Left why -> do
                    audit Nothing "RELEASE_BOT_APPROVE_DENIED" rid (object ["email" .= email0, "why" .= why])
                    sayReq req ("⛔ " <> (if T.null name then email0 else name) <> " cannot approve this: " <> why <> ". Nothing was run.")
                    pure (ack "You are not authorized to approve this.")
                Right ap
                    | otherwise -> do
                        now <- liftIO getCurrentTime
                        let to = if approving then "APPROVED" else "REJECTED" :: Text
                            patch = object ["approver" .= (if T.null name then email0 else name), "approverEmail" .= email0, "decidedAt" .= now]
                        won <- claimDecision rid to patch
                        case won of
                            Nothing -> pure (ack "This request is no longer awaiting approval (already decided or expired).")
                            Just r -> do
                                audit (Just ap) (if approving then "RELEASE_BOT_APPROVED" else "RELEASE_BOT_REJECTED") rid (object ["commit" .= dText "commit" (rqData r)])
                                let who = if T.null name then email0 else name
                                    outcome =
                                        if approving
                                            then "✅ Approved by " <> who <> ". Applying once the Jenkins build succeeds."
                                            else "🚫 Rejected by " <> who <> ". Nothing was applied."
                                _ <- case (rqChannel r, dText "cardMessageId" (rqData r)) of
                                    (Just ch, Just mid) -> X.updateCard ch mid outcome
                                    _ -> pure (Right ())
                                sayReq r outcome
                                pure (ack outcome)

-- ─── Worker ────────────────────────────────────────────────────────

releaseBotLoop :: Flow ()
releaseBotLoop = do
    enabled <- botEnabled
    if not enabled
        then logInfo "[release-bot] disabled (SC_RELEASE_BOT_ENABLED not set) — worker not started"
        else do
            logInfo "[release-bot] worker started"
            forever $ do
                r <- C.try tick
                case r of
                    Left e -> logError ("[release-bot] tick failed: " <> T.pack (show (e :: C.SomeException)))
                    Right () -> pure ()
                liftIO (threadDelay (Seconds 20))

tick :: Flow ()
tick = do
    reqs <- listActive
    unless (null reqs) $ do
        ecfg <- loadBotConfig
        forM_' reqs $ \r -> do
            e <- C.try (progress ecfg r)
            case e of
                Left ex -> logError ("[release-bot] " <> rqId r <> ": " <> T.pack (show (ex :: C.SomeException)))
                Right () -> pure ()
  where
    forM_' xs f = mapM_ f xs

progress :: Either Text ProdReleaseConfig -> Req -> Flow ()
progress ecfg req = do
    now <- liftIO getCurrentTime
    let st = rqState req
    if st == "AWAITING_APPROVAL" && maybe False (< now) (rqExpiresAt req)
        then do
            ok <- transition (rqId req) "AWAITING_APPROVAL" "EXPIRED" (object [])
            when ok $ do
                _ <- case (rqChannel req, dText "cardMessageId" (rqData req)) of
                    (Just ch, Just mid) -> X.updateCard ch mid "⌛ Approval window expired. Nothing was applied."
                    _ -> pure (Right ())
                sayReq req ("⌛ Request `" <> shortId (rqId req) <> "` expired without approval. Nothing was applied.")
        else case st of
            "BUILDING" -> withBuild (\r -> if dText "mode" (rqData r) == Just "build_only" then finishBuildOnly r else beginApply ecfg r "BUILDING")
            "WAITING_CHECKS" -> resumeChecks ecfg req
            "APPROVED" -> withBuild (\r -> beginApply ecfg r "APPROVED")
            "AWAITING_APPROVAL" -> void (refreshBuild req) -- keep build status current while waiting
            "APPLYING_CONFIG" -> checkConfigTrackers ecfg req
            _ -> pure ()
  where
    withBuild onSuccess = do
        r <- refreshBuild req
        case dText "jenkinsResult" (rqData r) of
            Just "SUCCESS" -> onSuccess r
            Just res
                | res `notElem` ["RUNNING", "QUEUED"] -> failReq r (rqState r) ("Jenkins build finished as " <> res <> dBuildUrl r)
            _ -> pure ()

dBuildUrl :: Req -> Text
dBuildUrl r = maybe "" (" — " <>) (dText "jenkinsBuildUrl" (rqData r))

-- | One Jenkins build of a request (a request may need several: one per distinct parameter set).
data BuildRec = BuildRec
    { brServices :: [Text]
    , brQueue :: Maybe Text
    , brUrl :: Maybe Text
    , brResult :: Maybe Text
    , brReused :: Bool
    , brJobUrl :: Maybe Text
    }

brToJson :: BuildRec -> Value
brToJson r = object ["services" .= brServices r, "queue" .= brQueue r, "url" .= brUrl r, "result" .= brResult r, "reused" .= brReused r, "jobUrl" .= brJobUrl r]

brFromJson :: Value -> Maybe BuildRec
brFromJson (Object o) =
    Just
        BuildRec
            { brServices = [t | Just (Array a) <- [KM.lookup "services" o], String t <- foldr (:) [] a]
            , brQueue = txt "queue"
            , brUrl = txt "url"
            , brResult = txt "result"
            , brReused = KM.lookup "reused" o == Just (Bool True)
            , brJobUrl = txt "jobUrl"
            }
  where
    txt k = case KM.lookup (K.fromText k) o of Just (String t) -> Just t; _ -> Nothing
brFromJson _ = Nothing

-- | (overall result, url to show, queue url): a failed build wins, then all-SUCCESS, then RUNNING, else QUEUED.
aggregateBuilds :: [BuildRec] -> (Text, Maybe Text, Maybe Text)
aggregateBuilds rs =
    let res r = fromMaybe "QUEUED" (brResult r)
        bad = [r | r <- rs, res r `notElem` ["SUCCESS", "QUEUED", "RUNNING"]]
        pick r = (brUrl r, brQueue r)
        firstR = listToMaybe rs
        (u0, q0) = maybe (Nothing, Nothing) pick firstR
     in case bad of
            (b : _) -> (res b, brUrl b, brQueue b)
            []
                | all ((== "SUCCESS") . res) rs -> ("SUCCESS", u0, q0)
                | any ((== "RUNNING") . res) rs -> ("RUNNING", u0, q0)
                | otherwise -> ("QUEUED", u0, q0)

buildLabel :: Bool -> BuildRec -> Text
buildLabel multi b = if multi then "**" <> T.intercalate ", " (brServices b) <> "**: " else ""

describeBuild :: BuildRec -> Text
describeBuild b = case (brReused b, brResult b) of
    (True, Just "SUCCESS") -> "♻️ This image is already built — reusing the successful Jenkins build: " <> fromMaybe "" (brUrl b)
    (True, _) -> "🏗 This image is already being built — waiting on the running Jenkins build: " <> fromMaybe "" (brUrl b)
    _ -> "🏗 Jenkins build started: " <> fromMaybe "" (brJobUrl b)

-- | Poll Jenkins and persist the result; returns the refreshed request.
refreshBuild :: Req -> Flow Req
refreshBuild req = case dField "jenkinsBuilds" (rqData req) of
    Just (Array xs) | recs@(_ : _) <- mapMaybe brFromJson (foldr (:) [] xs) -> refreshMulti req recs
    _ -> refreshSingle req

refreshMulti :: Req -> [BuildRec] -> Flow Req
refreshMulti req recs = case dText "jenkinsResult" (rqData req) of
    Just res | res `notElem` ["RUNNING", "QUEUED"] -> pure req
    _ -> do
        recs' <- forM recs $ \r -> case brResult r of
            Just res | res `notElem` ["RUNNING", "QUEUED"] -> pure r
            _ -> do
                p <- pollBuild (brQueue r) (brUrl r)
                case p of
                    Left e -> logError ("[release-bot] jenkins poll " <> rqId req <> ": " <> e) >> pure r
                    Right bs -> pure $ case bs of
                        BuildQueued -> r{brResult = Just "QUEUED"}
                        BuildRunning u -> r{brResult = Just "RUNNING", brUrl = Just u}
                        BuildFinished u res -> r{brResult = Just res, brUrl = Just u}
                        BuildCancelled -> r{brResult = Just "CANCELLED"}
        let (res, url, q) = aggregateBuilds recs'
        patchRequest (rqId req) (object ["jenkinsBuilds" .= map brToJson recs', "jenkinsResult" .= res, "jenkinsBuildUrl" .= url, "jenkinsQueueUrl" .= q])
        fresh <- getRequest (rqId req)
        pure (fromMaybe req fresh)

refreshSingle :: Req -> Flow Req
refreshSingle req = case dText "jenkinsResult" (rqData req) of
    Just res | res `notElem` ["RUNNING", "QUEUED"] -> pure req
    _ -> do
        r <- pollBuild (dText "jenkinsQueueUrl" (rqData req)) (dText "jenkinsBuildUrl" (rqData req))
        case r of
            Left e -> do
                logError ("[release-bot] jenkins poll " <> rqId req <> ": " <> e)
                pure req
            Right bs -> do
                let patch = case bs of
                        BuildQueued -> object ["jenkinsResult" .= ("QUEUED" :: Text)]
                        BuildRunning u -> object ["jenkinsResult" .= ("RUNNING" :: Text), "jenkinsBuildUrl" .= u]
                        BuildFinished u res -> object ["jenkinsResult" .= res, "jenkinsBuildUrl" .= u]
                        BuildCancelled -> object ["jenkinsResult" .= ("CANCELLED" :: Text)]
                patchRequest (rqId req) patch
                fresh <- getRequest (rqId req)
                pure (fromMaybe req fresh)

failReq :: Req -> Text -> Text -> Flow ()
failReq r from why = do
    ok <- transition (rqId r) from "FAILED" (object ["error" .= why])
    when ok $ sayReq r ("❌ Request `" <> shortId (rqId r) <> "` failed: " <> why)

finishBuildOnly :: Req -> Flow ()
finishBuildOnly r = do
    ok <- transition (rqId r) "BUILDING" "COMPLETED" (object ["note" .= ("build only" :: Text)])
    when ok $ sayReq r ("✅ Jenkins build succeeded" <> dBuildUrl r <> ". Build only — no release tracker was created.")

-- ─── Apply ─────────────────────────────────────────────────────────

-- | Leader-elect (CAS -> APPLYING), re-verify, then apply configmaps.
beginApply :: Either Text ProdReleaseConfig -> Req -> Text -> Flow ()
beginApply ecfg req from = do
    won <- transition (rqId req) from "APPLYING" (object [])
    when won $ do
        r <- C.try (applyConfig ecfg req)
        case r of
            Left e -> failReq req "APPLYING" ("apply error: " <> T.take 300 (T.pack (show (e :: C.SomeException))))
            Right () -> pure ()

requesterAp :: Req -> Flow (Either Text AuthedPerson)
requesterAp req = authorize (fromMaybe "" (rqRequester req)) "RELEASE_CREATE"

loadScope :: Either Text ProdReleaseConfig -> Req -> Flow (Either Text (RepoCfg, ChannelCfg, [Text]))
loadScope ecfg req = pure $ do
    pc <- ecfg
    repoName <- maybe (Left "request has no repo") Right (dText "repo" (rqData req))
    repo <- maybe (Left ("unknown repo " <> repoName)) Right (findRepo pc repoName)
    ch <- maybe (Left "request channel is no longer configured") Right (rqChannel req >>= \cid -> findChannelRepo pc cid repoName)
    pure (repo, ch, dTexts "services" (rqData req))

applyConfig :: Either Text ProdReleaseConfig -> Req -> Flow ()
applyConfig ecfg req = do
    scope <- loadScope ecfg req
    eap <- requesterAp req
    etok <- githubTokenFlow
    case (scope, eap, etok) of
        (Left e, _, _) -> failReq req "APPLYING" e
        (_, Left e, _) -> failReq req "APPLYING" ("requester no longer authorized: " <> e)
        (_, _, Left e) -> failReq req "APPLYING" e
        (Right (repo, ch, svcs), Right ap, Right token) -> do
            let d = rqData req
                commit = fromMaybe "" (dText "commit" d)
            fresh <- analyze ap token repo (chEnv ch) (dText "branch" d) commit svcs
            let drift
                    | not (null (anBlockers fresh)) = Just ("it can no longer be applied: " <> T.intercalate "; " (anBlockers fresh))
                    | Just (anLiveFingerprint fresh) /= dText "liveFingerprint" d = Just "the live configuration changed after the request was analyzed"
                    | Just (anContentHash fresh) /= dText "approvedContentHash" d = Just "the content to apply differs from what was reviewed"
                    | otherwise = Nothing
            case drift of
                Just why -> failReq req "APPLYING" ("Aborted before applying anything — " <> why <> ". Re-request to get a fresh diff.")
                Nothing -> do
                    let cms = anConfigMaps fresh
                        backup = object ["configMaps" .= [object ["name" .= ccName c, "liveData" .= ccLiveData c] | c <- cms]]
                    patchRequest (rqId req) (object ["backup" .= backup])
                    created <- createCmTrackers ap req fresh commit cms []
                    case created of
                        Left (why, done) ->
                            failReq req "APPLYING" ("Could not create ConfigMap tracker: " <> why <> ". Nothing was applied" <> (if null done then "" else "; already-created trackers " <> T.intercalate ", " done <> " are UNAPPROVED — discard them in SCC") <> ".")
                        Right good
                            | null good -> createServiceTrackers ecfg req "APPLYING"
                            | otherwise -> do
                                ok <- transition (rqId req) "APPLYING" "APPLYING_CONFIG" (object [])
                                when ok $ sayReq req ("🔧 Created ConfigMap release tracker(s) " <> T.intercalate ", " good <> ". Approving them now (the AI config review still applies); service trackers follow once the config is applied.")

{- | Create the ConfigMap trackers one at a time, UNAPPROVED, persisting the ids after
each so a crash never loses track of one. Stops at the first failure — and since none
is approved yet, a failure leaves nothing applying. Approval happens separately, via
the normal update path, so the AI breaking-change gate is honoured, not bypassed.
-}
createCmTrackers :: AuthedPerson -> Req -> Analysis -> Text -> [CmChange] -> [Text] -> Flow (Either (Text, [Text]) [Text])
createCmTrackers _ _ _ _ [] acc = pure (Right (reverse acc))
createCmTrackers ap req fresh commit (cm : rest) acc = do
    let body =
            object
                [ "appGroup" .= ccAppGroup cm
                , "service" .= ccName cm
                , "name" .= ccName cm
                , "env" .= anEnv fresh
                , "description" .= ("Release bot request " <> shortId (rqId req) <> " @ " <> T.take 7 commit)
                , "file" .= TE.decodeUtf8 (LBS.toStrict (A.encode (ccNewData cm)))
                , "release_manager" .= fromMaybe "" (rqRequester req)
                , "is_approved" .= False
                ]
    r <- tryAny (createConfigMapH ap body)
    case r of
        Left e -> pure (Left (ccName cm <> " (" <> T.take 200 (T.pack (show e)) <> ")", reverse acc))
        Right resp -> case idOfResponse resp of
            Nothing -> pure (Left (ccName cm <> " (" <> R.message resp <> ")", reverse acc))
            Just i -> do
                patchRequest (rqId req) (object ["cmTrackers" .= reverse (i : acc)])
                createCmTrackers ap req fresh commit rest (i : acc)

tryAny :: Flow a -> Flow (Either C.SomeException a)
tryAny = C.try

checkConfigTrackers :: Either Text ProdReleaseConfig -> Req -> Flow ()
checkConfigTrackers ecfg req = do
    let ids = dTexts "cmTrackers" (rqData req)
    found <- forM ids $ \i -> (,) i <$> findReleaseTracker i
    -- Approve (once each) any tracker that is waiting on us and whose AI review has settled.
    forM_ [(i, rt) | (i, Just (rt, _)) <- found, RT.status rt == CREATED, not (RT.isApproved rt)] $ \(i, rt) ->
        case reviewStatusInfo rt of
            Just ("pending", _) -> pure () -- AI review still running: look again next tick
            _ -> do
                first <- claimFlag (rqId req) ("cmApprove:" <> i)
                when first (approveCmTracker req i)
    let sts = [(i, fmap (RT.status . fst) mt) | (i, mt) <- found]
        failed = [i | (i, Just s) <- sts, s `elem` [ABORTED, USER_ABORTED, DISCARDED, DISCARDING, GCLT_ABORTED, REVERTING, REVERTED]]
        missing = [i | (i, Nothing) <- sts]
        done = all (\(_, s) -> s == Just COMPLETED) sts
    if not (null failed) || not (null missing)
        then failReq req "APPLYING_CONFIG" ("ConfigMap tracker(s) did not complete: " <> T.intercalate ", " (failed ++ missing) <> ". Service trackers were NOT created.")
        else when done $ do
            won <- transition (rqId req) "APPLYING_CONFIG" "APPLYING" (object [])
            when won $ do
                r <- C.try (createServiceTrackers ecfg req "APPLYING")
                case r of
                    Left e -> failReq req "APPLYING" ("tracker creation error: " <> T.take 300 (T.pack (show (e :: C.SomeException))))
                    Right () -> pure ()
  where
    forM_ xs f = mapM_ f xs

-- | Approve one configmap tracker as the human approver, through the normal update path
-- (which enforces the AI breaking-change gate). Any refusal is reported, never forced.
approveCmTracker :: Req -> Text -> Flow ()
approveCmTracker req tid = do
    let approverEmail = fromMaybe "" (dText "approverEmail" (rqData req))
    eap <- authorize approverEmail "RELEASE_UPDATE"
    case eap of
        Left why -> sayReq req ("⚠️ ConfigMap tracker " <> tid <> " needs approval in SCC (" <> approverEmail <> " cannot approve it here: " <> why <> ").")
        Right ap -> do
            r <- tryAny (updateConfigMapH ap tid (object ["is_approved" .= True]))
            case r of
                Right resp | R.status resp == "SUCCESS" -> sayReq req ("✅ ConfigMap tracker " <> tid <> " approved — applying.")
                Right resp -> sayReq req ("⚠️ ConfigMap tracker " <> tid <> " was not auto-approved: " <> R.message resp <> " Approve it in SCC to continue.")
                Left e -> sayReq req ("⚠️ ConfigMap tracker " <> tid <> " could not be approved automatically (" <> T.take 200 (T.pack (show e)) <> "). Approve it in SCC to continue.")

{- | The release's changed .sql files (statements split). Anything that cannot be checked is
flagged in the thread, never silently skipped; statements that name no configured service
schema are flagged once.
-}
loadSql :: Req -> RepoCfg -> Text -> Text -> Flow [SqlFile]
loadSql req repo token commit = do
    let d = rqData req
        bases = nub [b | an <- maybeToList (dField "analysis" d), Just (Array ss) <- [dField "services" an], x <- foldr (:) [] ss, Just b <- [dText "baseCommit" x]]
    case bases of
        [] -> sayReq req "⚠️ Could not determine the deployed commit, so SQL migrations in this release were NOT checked. Review the diff for .sql files before running." >> pure []
        (base : _) -> do
            cmp <- compareFiles token (repoSlug repo) base commit
            case cmp of
                Left e -> sayReq req ("⚠️ Could not list changed files to look for SQL migrations (" <> e <> "). Check the diff for .sql files manually.") >> pure []
                Right c -> do
                    (files, bad) <- sqlFromCompare token (repoSlug repo) commit (crPatches c)
                    unless (null bad) $ sayReq req ("⚠️ Could not read SQL file(s): " <> T.intercalate "; " bad)
                    let known = nub (concatMap scSqlSchemas (rcServices repo))
                        loose = unattributed known files
                    unless (null loose) $
                        sayReq req ("⚠️ " <> T.pack (show (countStatements loose)) <> " SQL statement(s) name none of the configured service schemas (" <> T.intercalate ", " known <> ") and are not attributed to any service — run them manually: " <> T.intercalate ", " (map sfPath loose))
                    pure files

{- | Post one service's SQL (the statements that act on its schemas) BEFORE its tracker is created,
inline when short and always as a downloadable file.
-}
postServiceSql :: Req -> ServiceCfg -> [SqlFile] -> Flow ()
postServiceSql req svc files = unless (null (scSqlSchemas svc)) $ do
    let schemas = T.intercalate ", " (scSqlSchemas svc)
        mine = statementsFor (scSqlSchemas svc) files
        n = countStatements mine
    if n == 0
        then sayReq req ("🗄 " <> scService svc <> ": no SQL changes for " <> schemas <> ".")
        else do
            let file = renderSql (scService svc <> " — release request " <> shortId (rqId req)) schemas mine
            patchKey req ("sql:" <> scService svc) file
            link <- publicSqlLink (rqId req) (scService svc)
            let inline = if T.length file <= 2500 then "\n```sql\n" <> T.stripEnd file <> "\n```" else "\n(too long to show here — use the link)"
            sayReq req ("🗄 **" <> scService svc <> " — SQL to run before the release:** " <> T.pack (show n) <> " statement(s) in " <> T.pack (show (length mine)) <> " file(s) on " <> schemas <> maybe "" ("\nFull file: " <>) link <> inline)

{- | The release's SQL as ONE request in the Multi-Cloud DB Manager (one query per target database /
cloud mode, identical statements across services de-duplicated), with the link posted in the thread. The
bot only files the request; a human with the right role approves and runs it there. Skipped silently
when no service has a @dbManager@ target or the DB Manager isn't configured; a failure is reported and the
inline SQL above stays the fallback.
-}
submitSqlRequest :: Req -> RepoCfg -> [ServiceCfg] -> [SqlFile] -> Flow ()
submitSqlRequest req repo svcs files = do
    configured <- dbmConfigured
    let targeted = [(t, x) | x <- svcs, Just t <- [scDbTarget x]]
        groups = nub (map fst targeted)
        itemFor t =
            let owners = [x | (t', x) <- targeted, t' == t]
                schemas = nub (concatMap scSqlSchemas owners)
                mine = statementsFor schemas files
                stmts = nub [ensureSemi s | f <- mine, s <- sfStatements f]
             in (t, owners, stmts)
        items = [i | t <- groups, let i@(_, _, ss) = itemFor t, not (null ss)]
    unless (null targeted || null items) $
        if not configured
            then sayReq req "ℹ️ SQL request not filed: the DB Manager isn't configured on this backend (SC_DBM_*). Use the per-service SQL posted in this thread."
            else do
                let reason = "Release " <> shortId (rqId req) <> " — " <> rcName repo <> "@" <> T.take 7 (fromMaybe "" (dText "commit" (rqData req))) <> ": SQL migrations for " <> T.intercalate ", " (nub (concat [map scService o | (_, o, _) <- items])) <> ". Requested by " <> fromMaybe "the release bot" (rqRequester req) <> " via the release bot."
                    dbmItems = [DbmItem (T.intercalate "\n" ss) (dtDatabase t) (dtMode t) (dtPgSchema t) | (t, _, ss) <- items]
                r <- submitRequest reason dbmItems
                case r of
                    Right link -> do
                        patchKey req "dbmRequest" link
                        sayReq req ("🗄 SQL migrations filed as one DB Manager request (" <> T.pack (show (length dbmItems)) <> " quer" <> (if length dbmItems == 1 then "y" else "ies") <> "): " <> link <> "\nRun it there (approve) before approving the rollouts.")
                    Left e -> sayReq req ("⚠️ Could not file the SQL request in the DB Manager (" <> e <> "). Run the per-service SQL posted in this thread manually.")
  where
    ensureSemi s = if ";" `T.isSuffixOf` T.stripEnd s then s else s <> ";"

{- | The service's own configured rollout (deployment_config.rollout_strategy), else the bot rule's, else
one 100% step. Rows hold either the flat step list, a double-encoded string of it, or the legacy
@[{"cluster":…,"rollouts":[{"rollout","cooloff","pods"}]}]@ wrapper — all are read; anything that
is not a valid strategy (empty, or not ending at 100%) falls through to the next source.
-}
serviceBaseline :: ServiceCfg -> Flow [RolloutStepCfg]
serviceBaseline svc = do
    m <- findServiceByProductAndName (scAppGroup svc) (scService svc)
    let fromDb = maybe [] parseStoredStrategy (m >>= S.dcRolloutStrategy)
    pure $ case (fromDb, scDefaultRollout svc) of
        (xs@(_ : _), _) -> xs
        ([], ys@(_ : _)) -> ys
        _ -> [RolloutStepCfg 100 0 1]

parseStoredStrategy :: Text -> [RolloutStepCfg]
parseStoredStrategy = go (3 :: Int)
  where
    go n t
        | n <= 0 = []
        | otherwise = case A.eitherDecodeStrict (TE.encodeUtf8 t) :: Either String Value of
            Right (String inner) -> go (n - 1) inner
            Right (Array xs) -> validSteps (stepsOf (foldr (:) [] xs))
            _ -> []
    -- legacy wrapper: take the first cluster entry's "rollouts"; otherwise the array IS the steps
    stepsOf xs = case [r | Object o <- xs, Just (Array r) <- [KM.lookup "rollouts" o]] of
        (r : _) -> mapMaybe step (foldr (:) [] r)
        [] -> mapMaybe step xs
    step (Object o) = do
        p <- num ["rolloutPercent", "rollout"] o
        c <- num ["cooloffMinutes", "cooloff"] o
        pure (RolloutStepCfg p c (fromMaybe 1 (num ["podCount", "pods"] o)))
    step _ = Nothing
    num ks o = listToMaybe [round n | k <- ks, Just (Number n) <- [KM.lookup (K.fromText k) o]] :: Maybe Int
    validSteps ss
        | not (null ss) && fmap rsRolloutPercent (listToMaybe (reverse ss)) == Just 100 = ss
        | otherwise = []

-- | Pod count for a requested step: the baseline step at that percent, else the nearest lower one.
{- | Pod counts for each step sized against the LIVE old version's ready pods — the same
"Min Pods" estimate the create form fetches (@/rollout-pod-estimate@, or the secondary cluster's
for the sync stagger): ceil(ready × percent / 100), at least 1. If the running version can't be
read the configured counts are kept (never guessed).
-}
estimatePods :: AuthedPerson -> Bool -> ServiceCfg -> [RolloutStepCfg] -> Flow [RolloutStepCfg]
estimatePods ap secondary svc steps = do
    let rq = RolloutPodEstimateReq (scAppGroup svc) (scService svc) (map rsRolloutPercent steps)
        run = if secondary then resolveRolloutPodEstimateSecondaryH else resolveRolloutPodEstimateH
    r <- tryAny (run ap rq)
    pure $ case r of
        Right (Object o)
            | Just (String _) <- KM.lookup "oldVersion" o
            , Just (Array a) <- KM.lookup "podCounts" o
            , counts <- [round n | Number n <- foldr (:) [] a]
            , length counts == length steps ->
                zipWith (\st c -> st{rsPodCount = max 1 c}) steps counts
        _ -> steps

createServiceTrackers :: Either Text ProdReleaseConfig -> Req -> Text -> Flow ()
createServiceTrackers ecfg req from = do
    scope <- loadScope ecfg req
    eap <- requesterAp req
    etok <- githubTokenFlow
    case (scope, eap, etok) of
        (Left e, _, _) -> failReq req from e
        (_, Left e, _) -> failReq req from ("requester no longer authorized: " <> e)
        (_, _, Left e) -> failReq req from e
        (Right (repo, ch, svcs), Right ap, Right token) -> do
            sqlFiles <- loadSql req repo token (fromMaybe "" (dText "commit" (rqData req)))
            submitSqlRequest req repo [s | n <- svcs, s <- take 1 [x | x <- rcServices repo, scService x == n]] sqlFiles
            let d = rqData req
                commit = fromMaybe "" (dText "commit" d)
                short = T.take 6 commit
                approvedEnv = case dField "envApproved" d of
                    Just (Array xs) -> [x | x <- foldr (:) [] xs]
                    _ -> []
                approvedFor svc = [x | x <- approvedEnv, dText "service" x == Just svc]
            results <- forM [s | n <- svcs, s <- take 1 [x | x <- rcServices repo, scService x == n]] $ \svc -> do
                envOverride <- case (approvedFor (scService svc), scEnvVar svc) of
                    ([appr], Just tgt) -> do
                        -- Re-verify THIS service's env right before use: untouched since review.
                        let storedBase = listToMaybe [b | an <- maybeToList (dField "analysis" d), Just (Array ss) <- [dField "services" an], x <- foldr (:) [] ss, dText "service" x == Just (scService svc), Just b <- [dText "baseCommit" x]]
                        chk <- analyzeEnv token (repoSlug repo) commit storedBase True svc
                        live <- readServiceEnv (scAppGroup svc) (scService svc)
                        pure $ case (chk, live) of
                            ((e, _), Right le)
                                | ecState e == "changed"
                                , ecLiveB64 e == dText "liveB64" appr
                                , ecNewB64 e == dText "newB64" appr
                                , Just newB64 <- dText "newB64" appr
                                , Just arr <- replaceEnvVar (evEnvVar tgt) newB64 (leEnv le) ->
                                    Right (Just (TE.decodeUtf8 (LBS.toStrict (A.encode arr))))
                            _ -> Left (scService svc <> ": env changed since it was reviewed — not creating this tracker")
                    ([], _) -> pure (Right Nothing)
                    _ -> pure (Left (scService svc <> ": ambiguous approved env record"))
                case envOverride of
                    Left e -> pure (scService svc, Left e)
                    Right ov -> do
                        postServiceSql req svc sqlFiles
                        let storedOld = listToMaybe [o | an <- maybeToList (dField "analysis" d), Just (Array ss) <- [dField "services" an], x <- foldr (:) [] ss, dText "service" x == Just (scService svc), Just o <- [dText "oldVersion" x]]
                        -- Schedulers/producers (BackendScheduler app groups) must be created as such so SCC
                        -- resolves their running version from deployment labels, not from a VirtualService.
                        pCfgM <- findProductByName (scAppGroup svc)
                        let trackerKind = case pCfgM >>= S.dcAppGroupType of
                                Just t | Right k <- normalizeProductType t -> k
                                _ -> "BackendService" :: Text
                            jk = jenkinsForSvc repo (chEnv ch) svc
                            -- the image tag Jenkins pushes: the same value the build was triggered with
                            image = fromMaybe "" (jcCommitPrefix jk) <> T.take (fromMaybe 6 (jcCommitLength jk)) commit
                        -- A deployment named <host>-<version> may already exist (an earlier attempt, a re-release of the
                        -- same commit): take the next free version label — <ver>v1, <ver>v2, … — instead of failing.
                        cfgK <- getConfig
                        svcRow <- findServiceByProductAndName (scAppGroup svc) (scService svc)
                        let hostName = fromMaybe (scService svc) (svcRow >>= getServiceHost)
                            nsName = maybe "" getProductNamespace pCfgM
                            candidates = short : [short <> "v" <> T.pack (show n) | n <- [1 .. 30 :: Int]]
                            firstFree [] = pure short
                            firstFree (v : vs) = do
                                taken <- liftIO (deploymentExists cfgK nsName (hostName <> "-" <> v))
                                if taken then firstFree vs else pure v
                        version <- if T.null nsName then pure short else firstFree candidates
                        when (version /= short) $
                            sayReq req ("ℹ️ " <> scService svc <> ": deployment `" <> hostName <> "-" <> short <> "` already exists — using version `" <> version <> "`.")
                        baseline <- serviceBaseline svc
                        -- "Sync to the secondary cloud": the secondary's own saved stagger (else this one's),
                        -- pods sized off the SECONDARY cluster's running version.
                        let syncOn = scSyncSecondary svc
                        syncSteps <-
                            if syncOn
                                then do
                                    secStrat <- tryAny (resolveSyncRolloutStrategyH ap (Just (scAppGroup svc)) (Just (scService svc)))
                                    let strat = case secStrat of
                                            Right (Object o) | Just (String t) <- KM.lookup "rolloutStrategy" o, xs@(_ : _) <- parseStoredStrategy t -> xs
                                            _ -> baseline
                                    estimatePods ap True svc strat
                                else pure []
                        let rolloutJson = map (\r -> object ["rolloutPercent" .= rsRolloutPercent r, "cooloffMinutes" .= rsCooloffMinutes r, "podCount" .= rsPodCount r])
                            mkBody rollout =
                                object $
                                    (if syncOn then ["isReleaseSync" .= True, "syncClusterRolloutStrategy" .= rolloutJson syncSteps] else []) ++
                                    [ "appGroup" .= scAppGroup svc
                                    , "service" .= [scService svc]
                                    , "env" .= chEnv ch
                                    , "trackerType" .= trackerKind
                                    , "release_manager" .= fromMaybe "" (rqRequester req)
                                    , "release_tag" .= (scService svc <> "-" <> version)
                                    , "old_version" .= fromMaybe "unknown" storedOld
                                    , "new_version" .= version
                                    , "rollout_strategy" .= rolloutJson rollout
                                    , "mode" .= ("AUTO" :: Text)
                                    , "is_approved" .= False
                                    , "globalId" .= (rqId req <> "-" <> scService svc)
                                    , "description" .= ("Created by release bot request " <> shortId (rqId req))
                                    ]
                                        ++ maybe [] (\o -> ["envOverrideData" .= o]) ov
                                        ++ ["docker_image" .= image | not (T.null image)]
                            create rollout = case fromJSON (mkBody rollout) :: Result K8sCreateReleaseReq of
                                A.Error e -> pure (Left (T.pack e))
                                Success r -> do
                                    x <- tryAny (createReleaseH ap Nothing Nothing r)
                                    pure $ case x of
                                        Left ex -> Left (T.take 200 (T.pack (show ex)))
                                        Right resp -> maybe (Left (R.message resp)) Right (idOfResponse resp)
                        -- The rollout always comes from the service's saved strategy; the message cannot change it.
                        chosenP <- estimatePods ap False svc baseline
                        res <- create chosenP
                        when (either (const False) (const True) res) $
                            sayReq req ("📦 " <> scService svc <> ": pods sized from the running version — " <> T.intercalate ", " [T.pack (show (rsRolloutPercent x)) <> "% → " <> T.pack (show (rsPodCount x)) <> " pod(s)" | x <- chosenP] <> ".")
                        case res of
                            Right tid -> do
                                patchKey req ("tracker:" <> scService svc) tid
                            Left _ -> pure ()
                        pure (scService svc, res)
            let okIds = [i | (_, Right i) <- results]
                errs = [s <> ": " <> e | (s, Left e) <- results]
            patchRequest (rqId req) (object ["trackerIds" .= okIds])
            if null errs
                then do
                    ok <- transition (rqId req) from "COMPLETED" (object [])
                    when ok $ do
                        sayReq req ("✅ Release tracker(s) created: " <> T.intercalate ", " okIds <> " (status CREATED). Approve each service with the card in its release thread, or in SCC.")
                else failReq req from ("Some trackers were not created: " <> T.intercalate "; " errs <> (if null okIds then "" else ". Created: " <> T.intercalate ", " okIds))


