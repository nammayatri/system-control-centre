{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | GitHub Actions REST client for the Mobile release runner.

Five operations, each authenticated with a fresh installation token
obtained from "Products.Autopilot.Mobile.Github.Auth":

* 'dispatchWorkflow' — trigger a @workflow_dispatch@ event.
* 'listWorkflowRuns' — list the most recent @workflow_dispatch@ runs
  (used to resolve a freshly-dispatched run by looking up its
  recently-created sibling whose @inputs.nonce@ matches).
* 'listJobs'         — fetch the jobs of a run; we watch a specific
  matrix job by name.
* 'listTags'         — list refs/tags whose names match a prefix.
* 'cancelRun'        — abort an in-flight run.

Each call returns @Either Text a@ rather than throwing, because the
runner often wants to retry or move to a failed state cleanly rather
than crash the worker.
-}
module Products.Autopilot.Mobile.Github (
    -- * Request types
    WorkflowDispatchReq (..),

    -- * Response shapes
    WorkflowRun (..),
    WorkflowRunsResp (..),
    dispatchRunCandidates,
    ownDispatchCandidates,
    getWorkflowRun,
    findRunWithJob,
    Job (..),
    JobStep (..),
    JobsResp (..),

    -- * Operations
    dispatchWorkflow,
    listWorkflowRuns,
    listWorkflowRunsForSha,
    listJobs,
    fetchJobLog,
    listTags,
    listTagsWithShas,
    compareCommits,
    CommitComparison (..),
    listBranches,
    cancelRun,
    createGitRef,
    getCommitInfo,
    searchBranches,
    CommitDetail (..),

    -- * Branch response type
    BranchInfo (..),

    -- * Shared HTTP helpers (re-used by sibling clients)
    apiBase,
    ghHeaders,
    renderHttpError,
) where

import Control.Monad.IO.Class (liftIO)
import Core.Environment (MonadFlow)
import Core.Http.Client (
    HttpError (..),
    HttpReq (..),
    HttpResponse (..),
    Method (..),
    defaultReq,
    httpJson,
    httpRaw,
 )
import Core.Types.Time (Seconds (..))
import Data.Aeson (
    FromJSON (..),
    ToJSON (..),
    encode,
    object,
    withObject,
    (.!=),
    (.:),
    (.:?),
    (.=),
 )
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as LBS
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Maybe (catMaybes, fromMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Text.Encoding.Error (lenientDecode)
import Data.Time.Clock (UTCTime, addUTCTime)
import GHC.Generics (Generic)
import Products.Autopilot.Mobile.Github.Auth (GhAppCreds, getInstallationToken)

-- ─── Types ─────────────────────────────────────────────────────────

{- | Payload for the @workflow_dispatch@ endpoint. @inputs@ is whatever
KeyMap the workflow YAML declares — typed as the loose 'Aeson.Object'
because mobile workflows already have many input shapes.
-}
data WorkflowDispatchReq = WorkflowDispatchReq
    { wdrRef :: Text
    , wdrInputs :: Aeson.Object
    }
    deriving (Show)

instance ToJSON WorkflowDispatchReq where
    toJSON WorkflowDispatchReq{..} =
        object
            [ "ref" .= wdrRef
            , "inputs" .= wdrInputs
            ]

-- | One row from @\/actions\/workflows\/{file}\/runs@.
data WorkflowRun = WorkflowRun
    { wrId :: Int64
    , wrEvent :: Text
    , wrStatus :: Text
    , wrConclusion :: Maybe Text
    , wrCreatedAt :: UTCTime
    , wrHtmlUrl :: Text
    , wrName :: Text
    , wrDisplayTitle :: Maybe Text
    , wrHeadSha :: Text
    -- ^ SHA of HEAD at dispatch time. Returned by GH on every run.
    -- Captured into 'release_tracker.commit_sha' so revert flows can
    -- look up exactly which commit a release built from.
    , wrHeadBranch :: Maybe Text
    -- ^ Branch the run was dispatched on. OTA run correlation filters
    -- candidates on this to reject runs dispatched from other branches.
    , wrActorId :: Maybe Int64
    -- ^ Numeric user id of whoever started the run. For runs we dispatch
    -- this is the App's @\<slug\>[bot]@ account ('BotIdentity') — run
    -- adoption filters on it so a human's manual run never matches.
    , wrActorLogin :: Maybe Text
    -- ^ Login of the run's actor (for logs/events only; match on the id).
    , wrRunAttempt :: Maybe Int
    -- ^ Attempt number (>1 after "re-run failed jobs"). The default jobs
    -- listing only shows the LATEST attempt's jobs, so job-absence evidence
    -- is only trustworthy on attempt 1.
    }
    deriving (Show, Generic)

instance FromJSON WorkflowRun where
    parseJSON = withObject "WorkflowRun" $ \o -> do
        mActor <- o .:? "actor"
        actorId <- maybe (pure Nothing) (.:? "id") mActor
        actorLogin <- maybe (pure Nothing) (.:? "login") mActor
        WorkflowRun
            <$> o .: "id"
            <*> o .: "event"
            <*> o .: "status"
            <*> o .:? "conclusion"
            <*> o .: "created_at"
            <*> o .: "html_url"
            <*> o .: "name"
            <*> o .:? "display_title"
            <*> o .: "head_sha"
            <*> o .:? "head_branch"
            <*> pure actorId
            <*> pure actorLogin
            <*> o .:? "run_attempt"

newtype WorkflowRunsResp = WorkflowRunsResp {wrrRuns :: [WorkflowRun]}
    deriving (Show)

instance FromJSON WorkflowRunsResp where
    parseJSON = withObject "WorkflowRunsResp" $ \o ->
        WorkflowRunsResp <$> o .: "workflow_runs"

-- | Candidate runs for a dispatch: @workflow_dispatch@ runs created within
-- [dispatchedAt - 30s, dispatchedAt + 5m], newest first. Shared by ResolveRunId and
-- the abort-cancel path so both match the dispatched run with one window.
dispatchRunCandidates :: UTCTime -> [WorkflowRun] -> [WorkflowRun]
dispatchRunCandidates dispatchedAt = sortOn (Down . wrCreatedAt) . filter inWindow
  where
    lo = addUTCTime (-30) dispatchedAt
    hi = addUTCTime 300 dispatchedAt
    inWindow r = wrEvent r == "workflow_dispatch" && wrCreatedAt r >= lo && wrCreatedAt r <= hi

{- | Candidates for OUR dispatch, strongest evidence first. Keeps a run iff:

* it is a @workflow_dispatch@ run, AND
* its actor is our App's bot account (when the identity is known — a run a
  human started from the GitHub UI can never match), AND
* its id is strictly above the pre-dispatch watermark when one was recorded
  (run ids are monotonically increasing, so above-the-mark means created
  after our POST — no wall clocks involved); rows persisted before the
  watermark existed fall back to the legacy created-at window.

Sorted OLDEST first: the run created immediately after our watermark
snapshot is ours; a later unclaimed run belongs to a later dispatch.
-}
ownDispatchCandidates ::
    -- | Bot user id ('BotIdentity'), when discovered
    Maybe Int64 ->
    -- | Pre-dispatch run-id watermark (the receipt), when recorded
    Maybe Int64 ->
    -- | Receipt time — window fallback for pre-watermark rows
    UTCTime ->
    [WorkflowRun] ->
    [WorkflowRun]
ownDispatchCandidates mBotId mWatermark dispatchedAt = sortOn wrId . filter ok
  where
    lo = addUTCTime (-30) dispatchedAt
    hi = addUTCTime 300 dispatchedAt
    ok r =
        wrEvent r == "workflow_dispatch"
            -- Exclude only on a PRESENT, mismatching actor. GitHub's schema
            -- marks actor nullable — a null-actor row must not hide our own
            -- run (job verification still gates any bind).
            && ( case mBotId of
                    Nothing -> True
                    Just bid -> maybe True (== bid) (wrActorId r)
               )
            -- A run created before the receipt can NEVER be ours, whatever
            -- the watermark says — the watermark snapshot comes from one
            -- listing call, and a stale/partial GitHub page once produced an
            -- ancient watermark that made every old run on the page a
            -- "candidate" (and oldest-first then surfaced a months-old run).
            -- The created-at floor and the id watermark back each other up.
            && wrCreatedAt r >= lo
            && case mWatermark of
                Just w -> wrId r > w
                Nothing -> wrCreatedAt r <= hi

{- | The first candidate run (in the given order) whose job list contains ANY
of @jobNames@ — a dispatch group's matrix job names. Two dispatches on the
SAME workflow file can land inside each other's windows (provider version
cohorts, concurrent operators), so the window alone can cross-bind — the
matrix job names are the disambiguator: each run only contains its own
cohort's app jobs.

Callers pass the WHOLE group's job names, not just the executing row's: any
one job proves the run belongs to the group, and the executing row's own job
alone is NOT reliable evidence — CI's matrix step silently drops apps missing
from the repo's config, so the group leader's own job may never exist in a
perfectly good group run.

'Nothing' = no candidate verified YET. Matrix jobs only appear once the run's
setup job finishes expanding the matrix (minutes), so callers must treat
Nothing as "wait and retry", not "no such run". Probes at most 3 candidates
per call to bound API cost; a probe error just skips that candidate.
-}
findRunWithJob ::
    (MonadFlow m) =>
    GhAppCreds ->
    Text -> -- owner
    Text -> -- repo
    [Text] -> -- the dispatch group's matrix job names (any one match binds)
    [WorkflowRun] ->
    m (Maybe WorkflowRun)
findRunWithJob creds owner repo jobNames = go . take 3
  where
    go [] = pure Nothing
    go (r : rs) = do
        eJobs <- listJobs creds owner repo (T.pack (show (wrId r)))
        case eJobs of
            Right jobs | any ((`elem` jobNames) . jName) jobs -> pure (Just r)
            _ -> go rs

-- | One row from @\/actions\/runs\/{run_id}\/jobs@.
-- | One step of a CI job (checkout, build, upload …).
data JobStep = JobStep
    { jsName :: Text
    , jsStatus :: Text
    , jsConclusion :: Maybe Text
    , jsNumber :: Int
    , jsStartedAt :: Maybe UTCTime
    , jsCompletedAt :: Maybe UTCTime
    }
    deriving (Show, Generic)

instance FromJSON JobStep where
    parseJSON = withObject "JobStep" $ \o ->
        JobStep
            <$> o .: "name"
            <*> o .: "status"
            <*> o .:? "conclusion"
            <*> o .: "number"
            <*> o .:? "started_at"
            <*> o .:? "completed_at"

data Job = Job
    { jId :: Int64
    , jName :: Text
    , jStatus :: Text
    , jConclusion :: Maybe Text
    , jStartedAt :: Maybe UTCTime
    , jCompletedAt :: Maybe UTCTime
    , jHtmlUrl :: Text
    , jSteps :: [JobStep]
    }
    deriving (Show, Generic)

instance FromJSON Job where
    parseJSON = withObject "Job" $ \o ->
        Job
            <$> o .: "id"
            <*> o .: "name"
            <*> o .: "status"
            <*> o .:? "conclusion"
            <*> o .:? "started_at"
            <*> o .:? "completed_at"
            <*> o .: "html_url"
            <*> (o .:? "steps" .!= [])

newtype JobsResp = JobsResp {jrJobs :: [Job]}
    deriving (Show)

instance FromJSON JobsResp where
    parseJSON = withObject "JobsResp" $ \o ->
        JobsResp <$> o .: "jobs"

-- ─── Common header builders ────────────────────────────────────────

ghHeaders :: Text -> [(Text, Text)]
ghHeaders token =
    [ ("Authorization", "Bearer " <> token)
    , ("Accept", "application/vnd.github+json")
    , ("X-GitHub-Api-Version", "2022-11-28")
    , ("User-Agent", "system-control-centre")
    ]

apiBase :: Text -> Text -> Text
apiBase owner repo = "https://api.github.com/repos/" <> owner <> "/" <> repo

{- | GitHub's @actions/workflows/{workflow_id}/dispatches@ accepts either a
numeric workflow id OR the workflow's filename (e.g. @"fastlane-android.yaml"@).
It does NOT accept the full repo-relative path. Strip any directory prefix
so callers can pass @".github/workflows/fastlane-android.yaml"@ unmodified.
-}
workflowFilenameOnly :: Text -> Text
workflowFilenameOnly path =
    let parts = T.splitOn "/" path
     in if null parts then path else last parts

renderHttpError :: HttpError -> Text
renderHttpError (HttpExceptionError m) = m
renderHttpError (HttpStatusError s b) =
    "HTTP " <> T.pack (show s) <> ": " <> TE.decodeUtf8 (LBS.toStrict b)
renderHttpError (HttpDecodeError m) = "decode error: " <> T.pack m

-- ─── Operations ────────────────────────────────────────────────────

{- | Trigger a @workflow_dispatch@. GitHub returns HTTP 204 with an
empty body on success; anything else is a failure.
-}
dispatchWorkflow ::
    (MonadFlow m) =>
    GhAppCreds ->
    Text -> -- owner
    Text -> -- repo
    Text -> -- workflowFile (full path OK, e.g. ".github/workflows/fastlane-android.yaml")
    WorkflowDispatchReq ->
    m (Either Text ())
dispatchWorkflow creds owner repo workflowFile body = do
    token <- getInstallationToken creds
    let url =
            apiBase owner repo
                <> "/actions/workflows/"
                <> workflowFilenameOnly workflowFile
                <> "/dispatches"
        req =
            (defaultReq url)
                { reqMethod = POST
                , reqHeaders = ghHeaders token <> [("Content-Type", "application/json")]
                , reqBody = Just (encode body)
                , reqTimeout = Seconds 30
                , reqLogTag = "gh-dispatch"
                , -- NEVER blind-retry this POST: workflow_dispatch is not
                  -- idempotent and a timeout after GitHub already accepted the
                  -- first attempt would mint a second run the caller never
                  -- learns about. Retry policy lives in the workflow stage,
                  -- which adopts an existing run before re-dispatching.
                  reqRetries = 0
                }
    resp <- liftIO (httpRaw req)
    pure $ case resp of
        Right HttpResponse{respStatus = s, respBody = b}
            | s == 204 -> Right ()
            | otherwise ->
                Left
                    ( "dispatchWorkflow failed: HTTP "
                        <> T.pack (show s)
                        <> ": "
                        <> TE.decodeUtf8 (LBS.toStrict b)
                    )
        Left e -> Left ("dispatchWorkflow: " <> renderHttpError e)

{- | List the most recent @workflow_dispatch@ runs for a workflow file
(@per_page=20@). Used to resolve a freshly-dispatched run by scanning
for one whose @inputs.nonce@ matches the dispatch nonce we generated.
-}
listWorkflowRuns ::
    (MonadFlow m) =>
    GhAppCreds ->
    Text -> -- owner
    Text -> -- repo
    Text -> -- workflowFile
    m (Either Text [WorkflowRun])
listWorkflowRuns creds owner repo workflowFile = do
    token <- getInstallationToken creds
    let url =
            apiBase owner repo
                <> "/actions/workflows/"
                <> workflowFilenameOnly workflowFile
                <> "/runs?event=workflow_dispatch&per_page=20"
        req =
            (defaultReq url)
                { reqMethod = GET
                , reqHeaders = ghHeaders token
                , reqTimeout = Seconds 30
                , reqLogTag = "gh-runs"
                }
    resp <- liftIO (httpJson @WorkflowRunsResp req)
    pure $ case resp of
        Right r -> Right (wrrRuns r)
        Left e -> Left ("listWorkflowRuns: " <> renderHttpError e)

{- | One run by id — @GET \/actions\/runs\/{run_id}@. Exact and
pagination-proof (the runs LIST shows only the newest 20); use it where a
decision hangs on the run's settled status\/attempt rather than discovery.
-}
getWorkflowRun ::
    (MonadFlow m) =>
    GhAppCreds ->
    Text -> -- owner
    Text -> -- repo
    Text -> -- run id
    m (Either Text WorkflowRun)
getWorkflowRun creds owner repo runId = do
    token <- getInstallationToken creds
    let url = apiBase owner repo <> "/actions/runs/" <> runId
        req =
            (defaultReq url)
                { reqMethod = GET
                , reqHeaders = ghHeaders token
                , reqTimeout = Seconds 30
                , reqLogTag = "gh-run"
                }
    resp <- liftIO (httpJson @WorkflowRun req)
    pure $ case resp of
        Right r -> Right r
        Left e -> Left ("getWorkflowRun: " <> renderHttpError e)

{- | Runs of ONE workflow file filtered to an exact head commit — the build
event record for that sha. @head_branch@ of the (unanimous) result is the
branch the build was actually created from; no @event@ filter, a build can
arrive via dispatch or push.
-}
listWorkflowRunsForSha ::
    (MonadFlow m) =>
    GhAppCreds ->
    Text -> -- owner
    Text -> -- repo
    Text -> -- workflowFile
    Text -> -- head sha
    m (Either Text [WorkflowRun])
listWorkflowRunsForSha creds owner repo workflowFile sha = do
    token <- getInstallationToken creds
    let url =
            apiBase owner repo
                <> "/actions/workflows/"
                <> workflowFilenameOnly workflowFile
                <> "/runs?head_sha="
                <> sha
                <> "&per_page=30"
        req =
            (defaultReq url)
                { reqMethod = GET
                , reqHeaders = ghHeaders token
                , reqTimeout = Seconds 30
                , reqLogTag = "gh-runs-sha"
                }
    resp <- liftIO (httpJson @WorkflowRunsResp req)
    pure $ case resp of
        Right r -> Right (wrrRuns r)
        Left e -> Left ("listWorkflowRunsForSha: " <> renderHttpError e)

-- | List the jobs of a specific run.
listJobs ::
    (MonadFlow m) =>
    GhAppCreds ->
    Text -> -- owner
    Text -> -- repo
    Text -> -- run_id (rendered as Text)
    m (Either Text [Job])
listJobs creds owner repo runId = do
    token <- getInstallationToken creds
    -- per_page=100: the default 30 truncates fleet-batch runs; a matrix job
    -- past page 1 would look "missing" to PollMatrixJobs and could trip its
    -- not_in_matrix abort on a healthy build.
    let url = apiBase owner repo <> "/actions/runs/" <> runId <> "/jobs?per_page=100"
        req =
            (defaultReq url)
                { reqMethod = GET
                , reqHeaders = ghHeaders token
                , reqTimeout = Seconds 30
                , reqLogTag = "gh-jobs"
                }
    resp <- liftIO (httpJson @JobsResp req)
    pure $ case resp of
        Right r -> Right (jrJobs r)
        Left e -> Left ("listJobs: " <> renderHttpError e)

{- | Fetch the complete plain-text log of one job. GitHub answers with a 302
to short-lived blob storage; http-client follows it and (since 0.7.8) drops
the Authorization header on the cross-host hop, which the blob store requires.
Logs are retained ~90 days and can transiently 404 right after job completion,
so callers must treat 'Left' as "evidence unavailable", never as fatal.
-}
fetchJobLog ::
    (MonadFlow m) =>
    GhAppCreds ->
    Text -> -- owner
    Text -> -- repo
    Int64 -> -- job id
    m (Either Text Text)
fetchJobLog creds owner repo jobId = do
    token <- getInstallationToken creds
    -- GitHub answers with a 302 to a pre-signed blob-storage URL. Following
    -- it automatically forwards our Authorization header, which the blob
    -- store rejects (HTTP 401 — a signed URL and an auth header may not be
    -- combined). So: take the redirect by hand, then fetch the blob BARE.
    let url = apiBase owner repo <> "/actions/jobs/" <> T.pack (show jobId) <> "/logs"
        req =
            (defaultReq url)
                { reqMethod = GET
                , reqHeaders = ghHeaders token
                , reqTimeout = Seconds 30
                , reqLogTag = "gh-job-log"
                , reqNoRedirect = True
                }
        asLog b = Right (TE.decodeUtf8With lenientDecode (LBS.toStrict b))
    resp <- liftIO (httpRaw req)
    case resp of
        Left e -> pure (Left ("fetchJobLog: " <> renderHttpError e))
        Right HttpResponse{respStatus = s, respBody = b, respHeaders = hs}
            -- Tiny logs may come back inline.
            | s == 200 -> pure (asLog b)
            | s `elem` [301, 302, 303, 307, 308] ->
                case lookup "location" [(T.toLower k, v) | (k, v) <- hs] of
                    Nothing -> pure (Left ("fetchJobLog: HTTP " <> T.pack (show s) <> " without a Location header"))
                    Just loc -> do
                        blob <-
                            liftIO $
                                httpRaw
                                    (defaultReq loc)
                                        { reqMethod = GET
                                        , -- a 15-minute build's log runs to tens of MB
                                          reqTimeout = Seconds 120
                                        , reqLogTag = "gh-job-log-blob"
                                        }
                        pure $ case blob of
                            Right HttpResponse{respStatus = 200, respBody = lb} -> asLog lb
                            Right HttpResponse{respStatus = s2} -> Left ("fetchJobLog blob: HTTP " <> T.pack (show s2))
                            Left e -> Left ("fetchJobLog blob: " <> renderHttpError e)
            | otherwise -> pure (Left ("fetchJobLog: HTTP " <> T.pack (show s)))

{- | List refs/tags whose names begin with @prefix@. Returns the bare
ref names (no @refs\/tags\/@ prefix is stripped — caller decides).
-}
listTags ::
    (MonadFlow m) =>
    GhAppCreds ->
    Text -> -- owner
    Text -> -- repo
    Text -> -- prefix (passed verbatim after refs/tags/)
    m (Either Text [Text])
listTags creds owner repo prefix = do
    token <- getInstallationToken creds
    let url = apiBase owner repo <> "/git/matching-refs/tags/" <> prefix
        req =
            (defaultReq url)
                { reqMethod = GET
                , reqHeaders = ghHeaders token
                , reqTimeout = Seconds 30
                , reqLogTag = "gh-tags"
                }
    resp <- liftIO (httpJson @[RefItem] req)
    pure $ case resp of
        Right xs -> Right (map riRef xs)
        Left e -> Left ("listTags: " <> renderHttpError e)

{- | Like 'listTags' but returns @(tagName, targetCommitSha)@ pairs, with
the @refs\/tags\/@ prefix stripped. Lightweight tags point straight at a
commit; annotated tags point at a tag object, dereferenced here with one
extra call each (@\/git\/tags\/{sha}@). A failed deref drops that tag
rather than failing the listing.
-}
listTagsWithShas ::
    (MonadFlow m) =>
    GhAppCreds ->
    Text -> -- owner
    Text -> -- repo
    Text -> -- prefix (passed verbatim after refs/tags/)
    m (Either Text [(Text, Text)])
listTagsWithShas creds owner repo prefix = do
    token <- getInstallationToken creds
    let url = apiBase owner repo <> "/git/matching-refs/tags/" <> prefix
        req =
            (defaultReq url)
                { reqMethod = GET
                , reqHeaders = ghHeaders token
                , reqTimeout = Seconds 30
                , reqLogTag = "gh-tags-sha"
                }
    resp <- liftIO (httpJson @[TagRefItem] req)
    case resp of
        Left e -> pure (Left ("listTagsWithShas: " <> renderHttpError e))
        Right xs -> do
            pairs <- mapM (derefTag token) xs
            pure (Right (catMaybes pairs))
  where
    stripRefPrefix r = fromMaybe r (T.stripPrefix "refs/tags/" r)
    derefTag token TagRefItem{triRef = ref, triSha = sha, triType = ty}
        | ty /= "tag" = pure (Just (stripRefPrefix ref, sha))
        | otherwise = do
            let req =
                    (defaultReq (apiBase owner repo <> "/git/tags/" <> sha))
                        { reqMethod = GET
                        , reqHeaders = ghHeaders token
                        , reqTimeout = Seconds 30
                        , reqLogTag = "gh-tag-deref"
                        }
            r <- liftIO (httpJson @TagObjectResp req)
            pure $ case r of
                Right TagObjectResp{torSha = target} -> Just (stripRefPrefix ref, target)
                Left _ -> Nothing

-- | Result of @\/compare\/{base}...{head}@ — the git-ancestry verdict between
-- two commits. Both shas are immutable, so callers may cache this forever.
data CommitComparison = CommitComparison
    { ccStatus :: Text -- "identical" | "ahead" | "behind" | "diverged"
    , ccAheadBy :: Int
    , ccBehindBy :: Int
    }
    deriving (Show)

instance FromJSON CommitComparison where
    parseJSON = withObject "CommitComparison" $ \o ->
        CommitComparison
            <$> o .: "status"
            <*> o .: "ahead_by"
            <*> o .: "behind_by"

{- | Relate two commits by ancestry: is @head@ identical to \/ ahead of \/
behind \/ diverged from @base@? Powers OTA provenance ("was this bundle built
on top of this native build's commit?").
-}
compareCommits ::
    (MonadFlow m) =>
    GhAppCreds ->
    Text -> -- owner
    Text -> -- repo
    Text -> -- base sha
    Text -> -- head sha
    m (Either Text CommitComparison)
compareCommits creds owner repo base headSha = do
    token <- getInstallationToken creds
    let url = apiBase owner repo <> "/compare/" <> base <> "..." <> headSha
        req =
            (defaultReq url)
                { reqMethod = GET
                , reqHeaders = ghHeaders token
                , reqTimeout = Seconds 30
                , reqLogTag = "gh-compare"
                }
    resp <- liftIO (httpJson @CommitComparison req)
    pure $ case resp of
        Right c -> Right c
        Left e -> Left ("compareCommits: " <> renderHttpError e)

-- | One entry from @\/repos\/{owner}\/{repo}\/branches@.
data BranchInfo = BranchInfo
    { biName :: Text
    , biSha :: Text
    }
    deriving (Show, Generic)

instance FromJSON BranchInfo where
    parseJSON = withObject "BranchInfo" $ \o -> do
        name <- o .: "name"
        commit <- o .: "commit"
        sha <- withObject "BranchCommit" (\c -> c .: "sha") commit
        pure BranchInfo{biName = name, biSha = sha}

instance ToJSON BranchInfo where
    toJSON BranchInfo{..} =
        object
            [ "name" .= biName
            , "sha" .= biSha
            ]

{- | List up to 100 branches sorted by most-recently-committed.
Used by the branch-picker on the Create Release form.
-}
listBranches ::
    (MonadFlow m) =>
    GhAppCreds ->
    Text -> -- owner
    Text -> -- repo
    m (Either Text [BranchInfo])
listBranches creds owner repo = do
    token <- getInstallationToken creds
    let url = apiBase owner repo <> "/branches?per_page=100&sort=updated&direction=desc"
        req =
            (defaultReq url)
                { reqMethod = GET
                , reqHeaders = ghHeaders token
                , reqTimeout = Seconds 30
                , reqLogTag = "gh-branches"
                }
    resp <- liftIO (httpJson @[BranchInfo] req)
    pure $ case resp of
        Right xs -> Right xs
        Left e -> Left ("listBranches: " <> renderHttpError e)

searchBranches ::
    (MonadFlow m) =>
    GhAppCreds ->
    Text -> -- owner
    Text -> -- repo
    Text -> -- query (prefix to match)
    m (Either Text [BranchInfo])
searchBranches creds owner repo query = do
    token <- getInstallationToken creds
    let url = apiBase owner repo <> "/git/matching-refs/heads/" <> query
        req =
            (defaultReq url)
                { reqMethod = GET
                , reqHeaders = ghHeaders token
                , reqTimeout = Seconds 30
                , reqLogTag = "gh-search-branches"
                }
    resp <- liftIO (httpJson @[BranchRefItem] req)
    pure $ case resp of
        Right xs -> Right (map branchRefToBranchInfo xs)
        Left e -> Left ("searchBranches: " <> renderHttpError e)

{- | Cancel an in-flight run. GitHub returns HTTP 202 with a small JSON
body; we treat any 2xx as success.
-}
cancelRun ::
    (MonadFlow m) =>
    GhAppCreds ->
    Text -> -- owner
    Text -> -- repo
    Text -> -- run_id
    m (Either Text ())
cancelRun creds owner repo runId = do
    token <- getInstallationToken creds
    let url = apiBase owner repo <> "/actions/runs/" <> runId <> "/cancel"
        req =
            (defaultReq url)
                { reqMethod = POST
                , reqHeaders = ghHeaders token
                , reqBody = Nothing
                , reqTimeout = Seconds 30
                , reqLogTag = "gh-cancel"
                , reqRetries = 1
                }
    resp <- liftIO (httpRaw req)
    pure $ case resp of
        Right HttpResponse{respStatus = s, respBody = b}
            | s >= 200 && s < 300 -> Right ()
            | otherwise ->
                Left
                    ( "cancelRun failed: HTTP "
                        <> T.pack (show s)
                        <> ": "
                        <> TE.decodeUtf8 (LBS.toStrict b)
                    )
        Left e -> Left ("cancelRun: " <> renderHttpError e)

{- | Create a Git reference (lightweight tag). Used by the revert flow
to create a temporary tag at a user-specified commit SHA so
@workflow_dispatch@ can target it (the API requires a branch or tag
name, not a raw SHA).

@tagName@ should be the bare name (e.g. @"scc-revert/abc123"@); this
function prepends @refs\/tags\/@.
-}
createGitRef ::
    (MonadFlow m) =>
    GhAppCreds ->
    Text -> -- owner
    Text -> -- repo
    Text -> -- tagName (bare, no refs/tags/ prefix)
    Text -> -- sha (full 40-char commit SHA)
    m (Either Text ())
createGitRef creds owner repo tagName sha = do
    token <- getInstallationToken creds
    let url = apiBase owner repo <> "/git/refs"
        body =
            encode $
                object
                    [ "ref" .= ("refs/tags/" <> tagName :: Text)
                    , "sha" .= sha
                    ]
        req =
            (defaultReq url)
                { reqMethod = POST
                , reqHeaders = ghHeaders token <> [("Content-Type", "application/json")]
                , reqBody = Just body
                , reqTimeout = Seconds 30
                , reqLogTag = "gh-create-ref"
                , reqRetries = 1
                }
    resp <- liftIO (httpRaw req)
    pure $ case resp of
        Right HttpResponse{respStatus = s, respBody = b}
            | s == 201 -> Right ()
            | otherwise ->
                Left
                    ( "createGitRef failed: HTTP "
                        <> T.pack (show s)
                        <> ": "
                        <> TE.decodeUtf8 (LBS.toStrict b)
                    )
        Left e -> Left ("createGitRef: " <> renderHttpError e)

data CommitDetail = CommitDetail
    { cdSha :: Text
    , cdMessage :: Text
    , cdAuthorLogin :: Text
    , cdHtmlUrl :: Text
    }
    deriving (Show, Generic)

instance ToJSON CommitDetail
instance FromJSON CommitDetail where
    parseJSON = withObject "CommitDetail" $ \o -> do
        sha <- o .: "sha"
        htmlUrl <- o .: "html_url"
        commit <- o .: "commit"
        message <- withObject "commit" (.: "message") commit
        authorObj <- o .:? "author"
        login <- case authorObj of
            Just ao -> withObject "author" (\a -> a .:? "login") ao
            Nothing -> pure Nothing
        pure
            CommitDetail
                { cdSha = sha
                , cdMessage = T.takeWhile (/= '\n') message
                , cdAuthorLogin = fromMaybe "unknown" login
                , cdHtmlUrl = htmlUrl
                }

getCommitInfo ::
    (MonadFlow m) =>
    GhAppCreds ->
    Text -> -- owner
    Text -> -- repo
    Text -> -- sha (short or full)
    m (Either Text CommitDetail)
getCommitInfo creds owner repo sha = do
    token <- getInstallationToken creds
    let url = apiBase owner repo <> "/commits/" <> sha
        req =
            (defaultReq url)
                { reqMethod = GET
                , reqHeaders = ghHeaders token
                , reqTimeout = Seconds 30
                , reqLogTag = "gh-commit"
                }
    resp <- liftIO (httpJson @CommitDetail req)
    pure $ case resp of
        Right c -> Right c
        Left e -> Left ("getCommitInfo: " <> renderHttpError e)

-- ─── Internal helpers ──────────────────────────────────────────────

-- | One entry from @\/git\/matching-refs\/tags\/{prefix}@.
newtype RefItem = RefItem {riRef :: Text}
    deriving (Show)

instance FromJSON RefItem where
    parseJSON = withObject "RefItem" $ \o -> RefItem <$> o .: "ref"

-- | Same endpoint, keeping the target object for sha correlation.
data TagRefItem = TagRefItem
    { triRef :: Text
    , triSha :: Text
    , triType :: Text -- "commit" (lightweight) | "tag" (annotated)
    }
    deriving (Show)

instance FromJSON TagRefItem where
    parseJSON = withObject "TagRefItem" $ \o -> do
        ref <- o .: "ref"
        obj <- o .: "object"
        (sha, ty) <- withObject "TagRefObject" (\t -> (,) <$> t .: "sha" <*> t .: "type") obj
        pure TagRefItem{triRef = ref, triSha = sha, triType = ty}

-- | Annotated tag object (@\/git\/tags\/{sha}@) — its @object.sha@ is the commit.
newtype TagObjectResp = TagObjectResp {torSha :: Text}
    deriving (Show)

instance FromJSON TagObjectResp where
    parseJSON = withObject "TagObjectResp" $ \o -> do
        obj <- o .: "object"
        TagObjectResp <$> withObject "TagObjectTarget" (.: "sha") obj

data BranchRefItem = BranchRefItem
    { briRef :: Text
    , briSha :: Text
    }
    deriving (Show)

instance FromJSON BranchRefItem where
    parseJSON = withObject "BranchRefItem" $ \o -> do
        ref <- o .: "ref"
        obj <- o .: "object"
        sha <- withObject "object" (.: "sha") obj
        pure BranchRefItem{briRef = ref, briSha = sha}

branchRefToBranchInfo :: BranchRefItem -> BranchInfo
branchRefToBranchInfo BranchRefItem{..} =
    BranchInfo
        { biName = T.replace "refs/heads/" "" briRef
        , biSha = briSha
        }
