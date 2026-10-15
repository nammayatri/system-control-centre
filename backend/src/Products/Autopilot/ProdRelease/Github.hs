{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | Minimal GitHub REST client for the prod-release assistant, authenticated
with a personal/service token read from @SC_GITHUB_TOKEN@ (env secret — never
stored in the DB or repo). Read-only: list commits, compare two commits.
-}
module Products.Autopilot.ProdRelease.Github (
    CommitSummary (..),
    CompareResult (..),
    CheckSummary (..),
    FilePatch (..),
    getCommitChecks,
    githubTokenFromEnv,
    listBranchCommits,
    compareFiles,
    resolveFullSha,
    resolveBaseSha,
    getFileAt,
) where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Core.Http.Client (HttpError (..), HttpReq (..), HttpResponse (..), Method (..), defaultReq, httpJson, httpRaw)
import Core.Secrets (lookupEnvSecret)
import Core.Types.Time (Seconds (..))
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Types (Parser)
import qualified Data.ByteString.Lazy as LBS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Text.Encoding.Error (lenientDecode)

data CommitSummary = CommitSummary
    { csSha :: Text
    , csMessage :: Text
    -- ^ first line only
    , csAuthor :: Text
    , csDate :: Text
    }

instance ToJSON CommitSummary where
    toJSON c =
        object
            [ "sha" .= csSha c
            , "shortSha" .= T.take 6 (csSha c)
            , "message" .= csMessage c
            , "author" .= csAuthor c
            , "date" .= csDate c
            ]

instance FromJSON CommitSummary where
    parseJSON = withObject "Commit" $ \o -> do
        sha <- o .: "sha"
        c <- o .: "commit"
        msg <- c .: "message"
        a <- c .: "author"
        name <- a .:? "name"
        date <- a .:? "date"
        pure
            CommitSummary
                { csSha = sha
                , csMessage = T.takeWhile (/= '\n') msg
                , csAuthor = fromMaybe "" name
                , csDate = fromMaybe "" date
                }

data CompareResult = CompareResult
    { crFiles :: [Text]
    , crTotalCommits :: Int
    , crStatus :: Text
    -- ^ @identical@ | @ahead@ | @behind@ | @diverged@ (head relative to base)
    , crPatches :: [FilePatch]
    -- ^ Per-file status and unified-diff patch (absent for huge/binary files)
    , crTruncated :: Bool
    -- ^ GitHub keeps at most 3000 files of a compare (we page through them); at that ceiling we cannot
    -- prove a dhall file did NOT change, so callers must fail closed.
    }

data FilePatch = FilePatch
    { fpName :: Text
    , fpStatus :: Text
    , fpPatch :: Maybe Text
    }
    deriving (Show, Eq)

newtype FileEntry = FileEntry FilePatch
instance FromJSON FileEntry where
    parseJSON = withObject "File" $ \o -> (\n st p -> FileEntry (FilePatch n (fromMaybe "" st) p)) <$> o .: "filename" <*> o .:? "status" <*> o .:? "patch"

instance FromJSON CompareResult where
    parseJSON = withObject "Compare" $ \o -> do
        fs <- o .:? "files"
        n <- o .:? "total_commits"
        st <- o .:? "status"
        let ps = [f | FileEntry f <- fromMaybe [] fs]
        pure CompareResult{crFiles = map fpName ps, crTotalCommits = fromMaybe 0 n, crStatus = fromMaybe "" st, crPatches = ps, crTruncated = False}

githubTokenFromEnv :: (MonadIO m) => m (Either Text Text)
githubTokenFromEnv =
    maybe (Left "SC_GITHUB_TOKEN is not set on the backend") Right <$> lookupEnvSecret "SC_GITHUB_TOKEN"

headers :: Text -> [(Text, Text)]
headers token =
    [("Authorization", "Bearer " <> token) | not (T.null token)]
        ++ [ ("Accept", "application/vnd.github+json")
           , ("X-GitHub-Api-Version", "2022-11-28")
           , ("User-Agent", "system-control-centre")
           ]

render :: HttpError -> Text
render (HttpExceptionError m) = m
render (HttpStatusError s b) = "GitHub HTTP " <> T.pack (show s) <> ": " <> T.take 300 (TE.decodeUtf8With lenientDecode (LBS.toStrict b))
render (HttpDecodeError m) = "GitHub decode error: " <> T.pack m

get :: (MonadIO m, FromJSON a) => Text -> Text -> Text -> m (Either Text a)
get token tag url = do
    r <- liftIO (httpJson (defaultReq url){reqMethod = GET, reqHeaders = headers token, reqTimeout = Seconds 30, reqLogTag = tag})
    pure (either (Left . render) Right r)

-- | Most recent commits on a branch (newest first).
listBranchCommits :: (MonadIO m) => Text -> Text -> Text -> Int -> m (Either Text [CommitSummary])
listBranchCommits token slug branch n =
    get token "gh-commits" $
        "https://api.github.com/repos/" <> slug <> "/commits?per_page=" <> T.pack (show n) <> "&sha=" <> branch

{- | Files changed between @base@ and @head@ (three-dot compare). GitHub returns the file list in pages
of 100 and keeps at most 3000 files, so we page until a short page; 'crTruncated' is only set when we
hit that 3000 ceiling (then the list really is incomplete).
-}
compareFiles :: (MonadIO m) => Text -> Text -> Text -> Text -> m (Either Text CompareResult)
compareFiles token slug base headSha = do
    first <- page 1
    case first of
        Left e -> pure (Left e)
        Right r0 -> go r0 (crFiles r0) (crPatches r0) (2 :: Int)
  where
    page n =
        get token "gh-compare" $
            "https://api.github.com/repos/" <> slug <> "/compare/" <> base <> "..." <> headSha <> "?per_page=100&page=" <> T.pack (show n)
    go r0 acc accP n
        | length acc `mod` 100 /= 0 || null acc || n > 30 = pure (Right r0{crFiles = acc, crPatches = accP, crTruncated = length acc >= 3000})
        | otherwise = do
            nxt <- page n
            case nxt of
                Left e -> pure (Left e)
                Right r
                    | null (crFiles r) -> pure (Right r0{crFiles = acc, crPatches = accP, crTruncated = False})
                    | otherwise -> go r0 (acc ++ crFiles r) (accP ++ crPatches r) (n + 1)

-- | Expand a short sha to the full 40-char sha (also proves the commit exists).
resolveFullSha :: (MonadIO m) => Text -> Text -> Text -> m (Either Text Text)
resolveFullSha token slug sha = do
    r <- get @_ @CommitSummary token "gh-commit" ("https://api.github.com/repos/" <> slug <> "/commits/" <> sha)
    pure (csSha <$> r)

{- | Like 'resolveFullSha' but also accepts the 6-char shas the deployed image tags carry:
GitHub's API refuses prefixes shorter than 7, so those are matched against the repo's recent history.
-}
resolveBaseSha :: (MonadIO m) => Text -> Text -> Text -> m (Either Text Text)
resolveBaseSha token slug sha
    | T.length sha >= 7 = resolveFullSha token slug sha
    | otherwise = go (1 :: Int)
  where
    go pg
        | pg > 10 = pure (Left ("commit " <> sha <> " not found in the last 1000 commits"))
        | otherwise = do
            r <- get @_ @[CommitSummary] token "gh-commits" ("https://api.github.com/repos/" <> slug <> "/commits?per_page=100&page=" <> T.pack (show pg))
            case r of
                Left e -> pure (Left e)
                Right [] -> pure (Left ("commit " <> sha <> " not found"))
                Right cs -> case [csSha c | c <- cs, sha `T.isPrefixOf` csSha c] of
                    (x : _) -> pure (Right x)
                    [] -> go (pg + 1)

{- | Raw content of @path@ at @sha@ (GitHub contents API, raw media type).
'Left' when the file does not exist at that commit or is not valid UTF-8.
-}
getFileAt :: (MonadIO m) => Text -> Text -> Text -> Text -> m (Either Text Text)
getFileAt token slug path sha = do
    let url = "https://api.github.com/repos/" <> slug <> "/contents/" <> path <> "?ref=" <> sha
        hs = [if k == "Accept" then (k, "application/vnd.github.raw") else (k, v) | (k, v) <- headers token]
    r <- liftIO (httpRaw (defaultReq url){reqMethod = GET, reqHeaders = hs, reqTimeout = Seconds 30, reqLogTag = "gh-file"})
    pure $ case r of
        Left e -> Left (render e)
        Right resp
            | respStatus resp == 404 -> Left ("file not found at " <> T.take 7 sha <> ": " <> path)
            | respStatus resp /= 200 -> Left ("GitHub HTTP " <> T.pack (show (respStatus resp)) <> " for " <> path)
            | otherwise -> either (const (Left ("not valid UTF-8: " <> path))) Right (TE.decodeUtf8' (LBS.toStrict (respBody resp)))


-- | One CI signal on a commit: a check run or a legacy commit status.
data CheckSummary = CheckSummary
    { ckName :: Text
    , ckState :: Text
    -- ^ @success@ | @pending@ | @failure@
    , ckUrl :: Maybe Text
    }
    deriving (Show, Eq)

newtype CheckRuns = CheckRuns [CheckSummary]
instance FromJSON CheckRuns where
    parseJSON = withObject "check-runs" $ \o -> do
        rs <- o .: "check_runs"
        CheckRuns <$> mapM one rs
      where
        one = withObject "check-run" $ \r -> do
            name <- r .: "name"
            status <- r .:? "status"
            concl <- r .:? "conclusion" :: Parser (Maybe Text)
            url <- r .:? "html_url"
            let st
                    | (status :: Maybe Text) /= Just "completed" = "pending"
                    | concl `elem` map Just ["success", "neutral", "skipped"] = "success"
                    | otherwise = "failure"
            pure (CheckSummary name st url)

newtype CommitStatuses = CommitStatuses [CheckSummary]
instance FromJSON CommitStatuses where
    parseJSON = withObject "status" $ \o -> do
        rs <- o .: "statuses"
        CommitStatuses <$> mapM one rs
      where
        one = withObject "status" $ \r -> do
            name <- r .: "context"
            state <- r .: "state"
            url <- r .:? "target_url"
            pure (CheckSummary name (case (state :: Text) of "success" -> "success"; "pending" -> "pending"; _ -> "failure") url)

{- | Every CI signal GitHub has for the commit (check runs + commit statuses). Any API error is
returned as @Left@ so the caller can fail safe (never treat "could not look" as "passed").
-}
getCommitChecks :: (MonadIO m) => Text -> Text -> Text -> m (Either Text [CheckSummary])
getCommitChecks token slug sha = do
    runs <- get token "gh-check-runs" ("https://api.github.com/repos/" <> slug <> "/commits/" <> sha <> "/check-runs?per_page=100")
    sts <- get token "gh-statuses" ("https://api.github.com/repos/" <> slug <> "/commits/" <> sha <> "/status?per_page=100")
    pure $ case (runs, sts) of
        (Right (CheckRuns a), Right (CommitStatuses b)) -> Right (a ++ b)
        (Left e, _) -> Left ("check runs: " <> e)
        (_, Left e) -> Left ("commit statuses: " <> e)
