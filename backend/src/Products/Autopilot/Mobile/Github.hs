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
    Job (..),
    JobsResp (..),

    -- * Operations
    dispatchWorkflow,
    listWorkflowRuns,
    listJobs,
    listTags,
    cancelRun,
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
    (.:),
    (.:?),
    (.=),
 )
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as LBS
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (UTCTime)
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
    }
    deriving (Show, Generic)

instance FromJSON WorkflowRun where
    parseJSON = withObject "WorkflowRun" $ \o ->
        WorkflowRun
            <$> o .: "id"
            <*> o .: "event"
            <*> o .: "status"
            <*> o .:? "conclusion"
            <*> o .: "created_at"
            <*> o .: "html_url"
            <*> o .: "name"
            <*> o .:? "display_title"

newtype WorkflowRunsResp = WorkflowRunsResp {wrrRuns :: [WorkflowRun]}
    deriving (Show)

instance FromJSON WorkflowRunsResp where
    parseJSON = withObject "WorkflowRunsResp" $ \o ->
        WorkflowRunsResp <$> o .: "workflow_runs"

-- | One row from @\/actions\/runs\/{run_id}\/jobs@.
data Job = Job
    { jId :: Int64
    , jName :: Text
    , jStatus :: Text
    , jConclusion :: Maybe Text
    , jStartedAt :: Maybe UTCTime
    , jCompletedAt :: Maybe UTCTime
    , jHtmlUrl :: Text
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
                , reqRetries = 1
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
    let url = apiBase owner repo <> "/actions/runs/" <> runId <> "/jobs"
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

-- ─── Internal helpers ──────────────────────────────────────────────

-- | One entry from @\/git\/matching-refs\/tags\/{prefix}@.
newtype RefItem = RefItem {riRef :: Text}
    deriving (Show)

instance FromJSON RefItem where
    parseJSON = withObject "RefItem" $ \o -> RefItem <$> o .: "ref"
