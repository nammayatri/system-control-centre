{-# LANGUAGE OverloadedStrings #-}

{- | Trigger a parameterised Jenkins build over the Jenkins REST API.

Config comes from env secrets (never the DB): @SC_JENKINS_URL@ (base URL of the
Jenkins controller), @SC_JENKINS_USER@, @SC_JENKINS_TOKEN@ (API token — token
auth is exempt from CSRF crumbs). Trigger-only: it does not wait for the build.
-}
module Products.Autopilot.ProdRelease.Jenkins (
    TriggerResult (..),
    triggerBuild,
    jobPath,
    BuildStatus (..),
    pollBuild,
    rebaseUrl,
    ExistingBuild (..),
    findExistingBuild,
) where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson (Value (..), decode)
import qualified Data.Vector as V
import Data.Maybe (fromMaybe)
import qualified Data.Aeson.KeyMap as KM
import Core.Http.Client (HttpError (..), HttpReq (..), HttpResponse (..), Method (..), defaultReq, httpRaw)
import Core.Secrets (lookupEnvSecret)
import Core.Types.Time (Seconds (..))
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Network.HTTP.Types.URI (urlEncode)

data TriggerResult = TriggerResult
    { trQueueUrl :: Maybe Text
    , trJobUrl :: Text
    }

-- | @a/b/c@ -> @job/a/job/b/job/c@
jobPath :: Text -> Text
jobPath full = T.intercalate "/" [ "job/" <> encode seg | seg <- T.splitOn "/" full, not (T.null seg)]

encode :: Text -> Text
encode = TE.decodeUtf8 . urlEncode True . TE.encodeUtf8

triggerBuild :: (MonadIO m) => Text -> M.Map Text Text -> m (Either Text TriggerResult)
triggerBuild jobFullName params = do
    mUrl <- lookupEnvSecret "SC_JENKINS_URL"
    mUser <- lookupEnvSecret "SC_JENKINS_USER"
    mTok <- lookupEnvSecret "SC_JENKINS_TOKEN"
    case (mUrl, mUser, mTok) of
        (Just base, Just user, Just tok) -> do
            mWeb <- lookupEnvSecret "SC_JENKINS_WEB_URL"
            let jobUrl = T.dropWhileEnd (== '/') base <> "/" <> jobPath jobFullName
                webJobUrl = T.dropWhileEnd (== '/') (fromMaybe base mWeb) <> "/" <> jobPath jobFullName
                query = T.intercalate "&" [encode k <> "=" <> encode v | (k, v) <- M.toList params]
                auth = "Basic " <> TE.decodeUtf8 (B64.encode (TE.encodeUtf8 (user <> ":" <> tok)))
                req =
                    (defaultReq (jobUrl <> "/buildWithParameters?" <> query))
                        { reqMethod = POST
                        , reqHeaders = [("Authorization", auth)]
                        , reqBody = Just LBS.empty
                        , reqTimeout = Seconds 30
                        , -- A retry could queue a second prod build.
                          reqRetries = 0
                        , reqLogTag = "jenkins-trigger"
                        }
            r <- liftIO (httpRaw req)
            pure $ case r of
                Left (HttpExceptionError m) -> Left m
                Left e -> Left (T.pack (show e))
                Right resp
                    | respStatus resp `elem` [200, 201, 202] ->
                        Right TriggerResult{trQueueUrl = lookupHeader "location" (respHeaders resp), trJobUrl = webJobUrl}
                    | otherwise -> Left ("Jenkins HTTP " <> T.pack (show (respStatus resp)))
        _ -> pure (Left "SC_JENKINS_URL / SC_JENKINS_USER / SC_JENKINS_TOKEN are not all set on the backend")
  where
    lookupHeader k hs = case [v | (n, v) <- hs, T.toLower n == k] of
        (v : _) -> Just v
        [] -> Nothing

data BuildStatus
    = BuildQueued
    | BuildRunning Text
    | -- | build url, result (@SUCCESS@, @FAILURE@, @ABORTED@, ...)
      BuildFinished Text Text
    | BuildCancelled
    deriving (Show, Eq)

jenkinsAuth :: (MonadIO m) => m (Maybe Text)
jenkinsAuth = do
    mUser <- lookupEnvSecret "SC_JENKINS_USER"
    mTok <- lookupEnvSecret "SC_JENKINS_TOKEN"
    pure $ case (mUser, mTok) of
        (Just u, Just t) -> Just ("Basic " <> TE.decodeUtf8 (B64.encode (TE.encodeUtf8 (u <> ":" <> t))))
        _ -> Nothing

{- | Jenkins reports queue/build URLs on its own configured root URL (the SSO-fronted
human host), which rejects API/Basic-auth calls. Re-root any absolute URL onto the API base
we were configured with (@SC_JENKINS_URL@), keeping only its path. Relative URLs and an
unset base are returned unchanged.
-}
rebaseUrl :: Text -> Text -> Text
rebaseUrl base url = case T.breakOn "://" url of
    (_, rest)
        | not (T.null rest) && not (T.null (T.strip base)) ->
            T.dropWhileEnd (== '/') base <> T.dropWhile (/= '/') (T.drop 3 rest)
    _ -> url

getJson :: (MonadIO m) => Text -> m (Either Text Value)
getJson rawUrl = do
    mBase <- lookupEnvSecret "SC_JENKINS_URL"
    let url = maybe rawUrl (`rebaseUrl` rawUrl) mBase
    mAuth <- jenkinsAuth
    case mAuth of
        Nothing -> pure (Left "SC_JENKINS_USER / SC_JENKINS_TOKEN are not set on the backend")
        Just auth -> do
            r <- liftIO (httpRaw (defaultReq url){reqHeaders = [("Authorization", auth)], reqTimeout = Seconds 30, reqLogTag = "jenkins-poll"})
            pure $ case r of
                Left (HttpExceptionError m) -> Left m
                Left e -> Left (T.pack (show e))
                Right resp
                    | respStatus resp == 200 -> maybe (Left "Jenkins returned invalid JSON") Right (decode (respBody resp))
                    | respStatus resp == 404 -> Left "not-found"
                    | otherwise -> Left ("Jenkins HTTP " <> T.pack (show (respStatus resp)))

withSlash :: Text -> Text
withSlash u = if "/" `T.isSuffixOf` u then u else u <> "/"

{- | Where is the build? Starts from the queue item URL @Location@ header; once the
queue item has an executable, follows the build URL. A queue item that has been
cleaned up (404) after the build exists is reported as 'BuildQueued' so the caller
keeps the build URL it already stored.
-}
pollBuild :: (MonadIO m) => Maybe Text -> Maybe Text -> m (Either Text BuildStatus)
pollBuild mQueueUrl mBuildUrl = case mBuildUrl of
    Just b -> buildState b
    Nothing -> case mQueueUrl of
        Nothing -> pure (Left "no queue url or build url to poll")
        Just q -> do
            r <- getJson (withSlash q <> "api/json")
            case r of
                Left "not-found" -> pure (Left "queue item expired before a build url was recorded")
                Left e -> pure (Left e)
                Right (Object o)
                    | Just (Bool True) <- KM.lookup "cancelled" o -> pure (Right BuildCancelled)
                    | Just (Object ex) <- KM.lookup "executable" o
                    , Just (String u) <- KM.lookup "url" ex -> buildState u
                    | otherwise -> pure (Right BuildQueued)
                Right _ -> pure (Left "unexpected Jenkins queue response")
  where
    buildState b = do
        r <- getJson (withSlash b <> "api/json")
        pure $ case r of
            Left e -> Left e
            Right (Object o) -> case (KM.lookup "building" o, KM.lookup "result" o) of
                (_, Just (String res)) -> Right (BuildFinished b res)
                _ -> Right (BuildRunning b)
            Right _ -> Left "unexpected Jenkins build response"


-- | A previous Jenkins build of the same job with the same parameters.
data ExistingBuild = ExistingBuild
    { ebUrl :: Text
    , ebResult :: Maybe Text
    -- ^ @Just "SUCCESS"@ = the image is already built; @Nothing@ = that build is still running
    }
    deriving (Show, Eq)

{- | The newest build of @job@ (among the last 100) whose parameters include every one of @params@
and that either succeeded or is still running. Failed/aborted builds are skipped, so a retry builds again.
-}
findExistingBuild :: (MonadIO m) => Text -> M.Map Text Text -> m (Either Text (Maybe ExistingBuild))
findExistingBuild job params = do
    mBase <- lookupEnvSecret "SC_JENKINS_URL"
    case mBase of
        Nothing -> pure (Left "SC_JENKINS_URL is not set on the backend")
        Just base -> do
            let tree = "builds[number,url,result,building,actions[parameters[name,value]]]{0,100}"
                url = T.dropWhileEnd (== '/') base <> "/" <> jobPath job <> "/api/json?tree=" <> encode tree
            r <- getJson url
            pure $ case r of
                Left e -> Left e
                Right (Object o)
                    | Just (Array bs) <- KM.lookup "builds" o -> Right (firstMatch (V.toList bs))
                _ -> Left "unexpected Jenkins job response"
  where
    firstMatch bs = case [eb | Object b <- bs, Just eb <- [candidate b]] of
        (eb : _) -> Just eb
        [] -> Nothing
    candidate b = do
        String u <- KM.lookup "url" b
        let bps = buildParams b
            matches = all (\(k, v) -> M.lookup k bps == Just v) (M.toList params)
            result = case KM.lookup "result" b of Just (String x) -> Just x; _ -> Nothing
            building = KM.lookup "building" b == Just (Bool True)
        if not matches
            then Nothing
            else case result of
                Just "SUCCESS" -> Just (ExistingBuild u (Just "SUCCESS"))
                Nothing | building -> Just (ExistingBuild u Nothing)
                _ -> Nothing
    buildParams b = M.fromList
        [ (n, renderV v)
        | Array acts <- maybe [] pure (KM.lookup "actions" b)
        , Object a <- V.toList acts
        , Just (Array ps) <- [KM.lookup "parameters" a]
        , Object p <- V.toList ps
        , Just (String n) <- [KM.lookup "name" p]
        , Just v <- [KM.lookup "value" p]
        ]
    renderV (String t) = t
    renderV (Bool True) = "true"
    renderV (Bool False) = "false"
    renderV other = T.pack (show other)
