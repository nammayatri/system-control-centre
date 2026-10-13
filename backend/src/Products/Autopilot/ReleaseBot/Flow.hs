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
    linkToken,
    botEnabled,
) where

import Control.Monad (forM, forever, unless, void, when)
import qualified Control.Monad.Catch as C
import Control.Monad.IO.Class (liftIO)
import Core.Admin.Queries (writeAuditLog)
import Core.Auth.Protected (AuthedPerson (..), checkPersonPermission)
import Core.Auth.Queries (findPersonByEmail)
import Core.Environment (Flow, logError, logInfo)
import Core.Secrets (lookupEnvSecret)
import Core.Types.Time (Seconds (..), threadDelay)
import Crypto.Hash.Algorithms (SHA256)
import Crypto.MAC.HMAC (HMAC, hmac)
import Data.Aeson (Result (..), Value (..), fromJSON, object, toJSON, (.=))
import qualified Data.Aeson as A
import Data.ByteArray (constEq)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Maybe (fromMaybe, listToMaybe, maybeToList)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (addUTCTime, getCurrentTime)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import Products.Autopilot.Actions.ConfigMap (createConfigMapH, updateConfigMapH)
import Products.Autopilot.ConfigReview (reviewStatusInfo)
import Products.Autopilot.Actions.Release (createReleaseH)
import Products.Autopilot.ProdRelease.Config
import Products.Autopilot.ReleaseBot.ConfigSource (loadBotConfig)
import Products.Autopilot.Mobile.Github.Auth (getInstallationToken, loadGhCreds)
import Products.Autopilot.ProdRelease.Github
import Products.Autopilot.ProdRelease.Intent
import Products.Autopilot.ProdRelease.Jenkins (BuildStatus (..), TriggerResult (..), pollBuild, triggerBuild)
import Products.Autopilot.Queries.ReleaseTracker (findReleaseTracker)
import Products.Autopilot.ReleaseBot.Engine
import Products.Autopilot.ReleaseBot.Live (LiveEnv (..), readServiceEnv, replaceEnvVar)
import Products.Autopilot.ReleaseBot.Store
import qualified Products.Autopilot.ReleaseBot.Xyne as X
import Products.Autopilot.Types.API (K8sCreateReleaseReq)
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

-- | Hex HMAC-SHA256 of the request id; the capability in the no-VPN diff link.
linkToken :: Text -> Text -> Text
linkToken secret rid =
    let mac = hmac (TE.encodeUtf8 secret) (TE.encodeUtf8 rid) :: HMAC SHA256
     in TE.decodeUtf8 (convertToBase Base16 mac :: BS.ByteString)

publicLink :: Text -> Flow (Maybe Text)
publicLink rid = do
    base <- lookupEnvSecret "SC_PUBLIC_BASE_URL"
    sec <- lookupEnvSecret "SC_RELEASE_BOT_LINK_SECRET"
    pure $ case (base, sec) of
        (Just b, Just s) -> Just (T.dropWhileEnd (== '/') b <> "/r/" <> rid <> "?t=" <> linkToken s rid)
        _ -> Nothing

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

{- | A GitHub read token: an explicit @SC_GITHUB_TOKEN@ if set, otherwise an installation
token minted from the GitHub App the backend already has (@SC_GITHUB_APP_*@), so no new
GitHub secret is required. The App installation must cover the repo (Contents: read).
-}
githubTokenFlow :: Flow (Either Text Text)
githubTokenFlow = do
    pat <- githubTokenFromEnv
    case pat of
        Right t -> pure (Right t)
        Left _ -> do
            r <- tryAny (loadGhCreds >>= getInstallationToken)
            pure $ case r of
                Right t -> Right t
                Left e -> Left ("no GitHub credentials (set SC_GITHUB_TOKEN, or install the GitHub App on this repo): " <> T.take 160 (T.pack (show e)))

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
        -- Approve/Reject card goes top-level: buttons are not supported inside threads.
        root <- say (X.mChannel m) Nothing ("🛠 Release request from " <> X.mSenderName m <> " received — checking…")
        let reply = void . say (X.mChannel m) root
        ecfg <- loadBotConfig
        case ecfg of
            Left e -> reply ("⚠️ Release bot is not configured yet: " <> e <> "\nAdd release rules on the Deployment Config page (or release_bot_config_json); see RELEASE_BOT.md.")
            Right pc -> case findChannel pc (X.mChannel m) of
                Nothing -> reply "This channel is not enabled for release requests."
                Just ch -> case findRepo pc (chRepo ch) of
                    Nothing -> reply ("⚠️ Channel is mapped to unknown repo " <> chRepo ch)
                    Just repo0 -> do
                        let repo = forEnv (chEnv ch) repo0
                        newRequest pc{prcRepos = [repo]} ch repo root m

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
    let branch = fromMaybe (head' (rcBranches repo)) (inBranch parsed)
        services = inServices parsed
    etoken <- githubTokenFlow
    case (etoken, inCommit parsed) of
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
                            onBranch <- compareFiles token (repoSlug repo) branch fullSha
                            case onBranch of
                                Left e -> stop ("Could not verify the commit is on `" <> branch <> "`: " <> e)
                                Right c
                                    | crStatus c `notElem` ["behind", "identical"] ->
                                        stop ("Commit `" <> T.take 7 fullSha <> "` is not on `" <> branch <> "` (it is " <> crStatus c <> " of it). Refusing.")
                                    | otherwise -> startRequest ch repo ap rid thread m token branch fullSha services
  where
    head' (x : _) = x
    head' [] = ""
    recentList [] = ""
    recentList cs = "\nRecent commits on `" <> head' (rcBranches repo) <> "`:\n" <> T.unlines ["• `" <> T.take 7 (csSha c) <> "` " <> csMessage c | c <- cs]

startRequest :: ChannelCfg -> RepoCfg -> AuthedPerson -> Text -> Maybe Text -> X.Mention -> Text -> Text -> Text -> [Text] -> Flow ()
startRequest ch repo ap rid thread m token branch fullSha services = do
    an <- analyze ap token repo (chEnv ch) (Just branch) fullSha services
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
        j = jenkinsFor repo (chEnv ch)
    jr <-
        if dry
            then pure (Right Nothing)
            else fmap Just <$> triggerBuild (jcJob j) (M.insert (jcCommitParam j) (fromMaybe "" (jcCommitPrefix j) <> T.take (fromMaybe 6 (jcCommitLength j)) fullSha) (jcFixedParams j))
    let patch =
            object
                [ "branch" .= branch
                , "commit" .= fullSha
                , "services" .= services
                , "analysis" .= toJSON an
                , "mode" .= mode
                , "envApproved" .= approved
                , "approvedContentHash" .= anContentHash an
                , "liveFingerprint" .= anLiveFingerprint an
                , "publicLink" .= link
                , "jenkinsQueueUrl" .= (jr' >>= trQueueUrl)
                , "jenkinsJob" .= jcJob j
                ]
        jr' = either (const Nothing) id jr
        summary = summaryText rid an link
    case jr of
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
                reply (summary <> "\n🏗 Jenkins build started: " <> maybe "" trJobUrl jr')
                card <- X.postApprovalCard (X.mChannel m) (approvalCardText rid an link) rid
                case card of
                    Right mid -> patchRequest rid (object ["cardMessageId" .= mid])
                    Left e -> reply ("⚠️ Could not post the approval card: " <> e <> ". Ask an approver to open the diff link.")
            | otherwise -> do
                patchRequest rid patch
                void (transition rid "RECEIVED" "BUILDING" (object []))
                reply (summary <> "\n🏗 Jenkins build started: " <> maybe "" trJobUrl jr' <> "\n" <> nextStep mode)
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
handleClick c = do
    (name, email0) <- if T.null (X.cEmail c) then X.getUser (X.cUserId c) else pure (X.cUserName c, X.cEmail c)
    let rid = X.cRequestId c
        approving = X.cVerb c == X.approveVerb
    mr <- getRequest rid
    case mr of
        Nothing -> pure (ack "Unknown request.")
        Just req -> do
            selfOk <- envFlag "SC_RELEASE_BOT_ALLOW_SELF_APPROVE" False
            auth <- authorize email0 "RELEASE_APPROVE"
            let requester = T.toLower (fromMaybe "" (rqRequester req))
                isSelf = T.toLower (T.strip email0) == requester
            case auth of
                Left why -> do
                    audit Nothing "RELEASE_BOT_APPROVE_DENIED" rid (object ["email" .= email0, "why" .= why])
                    sayReq req ("⛔ " <> (if T.null name then email0 else name) <> " cannot approve this: " <> why <> ". Nothing was run.")
                    pure (ack "You are not authorized to approve this.")
                Right ap
                    | isSelf && not selfOk -> do
                        sayReq req "⛔ The requester cannot approve their own release. Ask another approver."
                        pure (ack "You cannot approve your own request.")
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

-- | Poll Jenkins and persist the result; returns the refreshed request.
refreshBuild :: Req -> Flow Req
refreshBuild req = case dText "jenkinsResult" (rqData req) of
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
    ch <- maybe (Left "request channel is no longer configured") Right (rqChannel req >>= findChannel pc)
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
                        let rollout =
                                if null (scDefaultRollout svc)
                                    then [object ["rolloutPercent" .= (100 :: Int), "cooloffMinutes" .= (0 :: Int), "podCount" .= (1 :: Int)]]
                                    else [object ["rolloutPercent" .= rsRolloutPercent r, "cooloffMinutes" .= rsCooloffMinutes r, "podCount" .= rsPodCount r] | r <- scDefaultRollout svc]
                            body =
                                object $
                                    [ "appGroup" .= scAppGroup svc
                                    , "service" .= [scService svc]
                                    , "env" .= chEnv ch
                                    , "trackerType" .= ("BackendService" :: Text)
                                    , "release_manager" .= fromMaybe "" (rqRequester req)
                                    , "release_tag" .= (scService svc <> "-" <> short)
                                    , "old_version" .= ("unknown" :: Text)
                                    , "new_version" .= short
                                    , "rollout_strategy" .= rollout
                                    , "mode" .= ("AUTO" :: Text)
                                    , "is_approved" .= False
                                    , "globalId" .= (rqId req <> "-" <> scService svc)
                                    , "description" .= ("Created by release bot request " <> shortId (rqId req))
                                    ]
                                        ++ maybe [] (\o -> ["envOverrideData" .= o]) ov
                        case fromJSON body :: Result K8sCreateReleaseReq of
                            A.Error e -> pure (scService svc, Left (T.pack e))
                            Success r -> do
                                resp <- createReleaseH ap Nothing Nothing r
                                pure (scService svc, maybe (Left (R.message resp)) Right (idOfResponse resp))
            let okIds = [i | (_, Right i) <- results]
                errs = [s <> ": " <> e | (s, Left e) <- results]
            patchRequest (rqId req) (object ["trackerIds" .= okIds])
            if null errs
                then do
                    ok <- transition (rqId req) from "COMPLETED" (object [])
                    when ok $ sayReq req ("✅ Release tracker(s) created: " <> T.intercalate ", " okIds <> " (status CREATED — approve the rollout in SCC).")
                else failReq req from ("Some trackers were not created: " <> T.intercalate "; " errs <> (if null okIds then "" else ". Created: " <> T.intercalate ", " okIds))


