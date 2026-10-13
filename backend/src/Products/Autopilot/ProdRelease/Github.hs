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
    githubTokenFromEnv,
    listBranchCommits,
    compareFiles,
    resolveFullSha,
    getFileAt,
) where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Core.Http.Client (HttpError (..), HttpReq (..), HttpResponse (..), Method (..), defaultReq, httpJson, httpRaw)
import Core.Secrets (lookupEnvSecret)
import Core.Types.Time (Seconds (..))
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.=))
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
    , crTruncated :: Bool
    -- ^ GitHub caps the compare file list at 300; at/above that we cannot
    -- prove a dhall file did NOT change, so callers must fail closed.
    }

newtype FileEntry = FileEntry Text
instance FromJSON FileEntry where
    parseJSON = withObject "File" $ \o -> FileEntry <$> o .: "filename"

instance FromJSON CompareResult where
    parseJSON = withObject "Compare" $ \o -> do
        fs <- o .:? "files"
        n <- o .:? "total_commits"
        st <- o .:? "status"
        let names = [f | FileEntry f <- fromMaybe [] fs]
        pure CompareResult{crFiles = names, crTotalCommits = fromMaybe 0 n, crStatus = fromMaybe "" st, crTruncated = length names >= 300}

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

-- | Files changed between @base@ and @head@ (three-dot compare).
compareFiles :: (MonadIO m) => Text -> Text -> Text -> Text -> m (Either Text CompareResult)
compareFiles token slug base headSha =
    get token "gh-compare" $
        "https://api.github.com/repos/" <> slug <> "/compare/" <> base <> "..." <> headSha

-- | Expand a short sha to the full 40-char sha (also proves the commit exists).
resolveFullSha :: (MonadIO m) => Text -> Text -> Text -> m (Either Text Text)
resolveFullSha token slug sha = do
    r <- get @_ @CommitSummary token "gh-commit" ("https://api.github.com/repos/" <> slug <> "/commits/" <> sha)
    pure (csSha <$> r)

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

