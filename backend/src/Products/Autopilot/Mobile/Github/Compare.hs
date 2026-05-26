{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}

{- | GitHub Compare API client.

Used by the mobile-revert flow to materialise the list of commits
introduced between the previous good release tag and the bad release
tag, so the auto-generated changelog can show "rolling back these N
commits."

The Compare API endpoint:

> GET /repos/{owner}/{repo}/compare/{base}...{head}

returns the commits that exist on @head@ but not on @base@, plus a
status code (@"ahead"@, @"behind"@, @"identical"@, @"diverged"@) and
ahead/behind counts.

The PR-number extractor is a best-effort parser of conventional commit
message subjects: if the subject ends with @"(#NNN)"@ (the default GH
squash-merge format), we surface it. Otherwise the field is @Nothing@.
-}
module Products.Autopilot.Mobile.Github.Compare (
    -- * Types
    CommitInfo (..),
    CompareResult (..),

    -- * Client
    compareRefs,

    -- * Helpers (exposed for tests)
    extractPrNumber,
    shortSha,
) where

import Control.Monad.IO.Class (liftIO)
import Core.Environment (MonadFlow)
import Core.Http.Client (
    HttpReq (..),
    Method (..),
    defaultReq,
    httpJson,
 )
import Core.Types.Time (Seconds (..))
import Data.Aeson (FromJSON (..), ToJSON (..), defaultOptions, genericToJSON, withObject, (.:), (.:?))
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)
import Products.Autopilot.Mobile.Github (
    apiBase,
    ghHeaders,
    renderHttpError,
 )
import Products.Autopilot.Mobile.Github.Auth (GhAppCreds, getInstallationToken)
import Text.Read (readMaybe)

-- ─── Types ─────────────────────────────────────────────────────────

{- | One commit between two refs. Fields are the subset the UI/changelog
needs — the GH response carries more (tree, parents, verification,
files-changed) which we drop on decode.
-}
data CommitInfo = CommitInfo
    { ciSha :: Text
    -- ^ Full 40-char SHA.
    , ciShortSha :: Text
    -- ^ First 7 chars of 'ciSha'. Convenience for UI.
    , ciMessage :: Text
    -- ^ Full commit message (subject + body).
    , ciSubject :: Text
    -- ^ First line of 'ciMessage'. The conventional "what changed" line.
    , ciAuthorLogin :: Text
    -- ^ GH login of the author. Falls back to @"unknown"@ when the
    -- commit author is not associated with a GH account (e.g.
    -- email-only commits, rebased commits where the original author
    -- can't be resolved).
    , ciHtmlUrl :: Text
    -- ^ Direct URL to the commit on github.com. Used for UI links.
    , ciPrNumber :: Maybe Int
    -- ^ Parsed from @(#NNN)@ in 'ciSubject' if present, else 'Nothing'.
    }
    deriving (Eq, Show, Generic)

instance ToJSON CommitInfo where
    toJSON = genericToJSON defaultOptions

instance FromJSON CommitInfo where
    parseJSON = withObject "CommitInfo" $ \o -> do
        sha <- o .: "sha"
        commitObj <- o .: "commit"
        message <- commitObj .: "message"
        -- author (top-level) is the GH user; commit.author is the git
        -- author. Prefer the GH user since we want a @login.
        mAuthor <- o .:? "author"
        login <- case mAuthor of
            Just authorObj -> authorObj .:? "login"
            Nothing -> pure Nothing
        htmlUrl <- o .: "html_url"
        let subject = firstLine message
        pure
            CommitInfo
                { ciSha = sha
                , ciShortSha = shortSha sha
                , ciMessage = message
                , ciSubject = subject
                , ciAuthorLogin = case login of
                    Just l | not (T.null l) -> l
                    _ -> "unknown"
                , ciHtmlUrl = htmlUrl
                , ciPrNumber = extractPrNumber subject
                }

{- | Decoded GH @\/compare\/{base}...{head}@ response. We keep the
status + ahead\/behind counts in case future callers want them; today
only 'crCommits' is consumed.
-}
data CompareResult = CompareResult
    { crCommits :: [CommitInfo]
    , crStatus :: Text
    -- ^ One of @"ahead"@, @"behind"@, @"identical"@, @"diverged"@.
    , crAheadBy :: Int
    , crBehindBy :: Int
    , crTotalCommits :: Int
    }
    deriving (Eq, Show, Generic)

instance FromJSON CompareResult where
    parseJSON = withObject "CompareResult" $ \o ->
        CompareResult
            <$> o .: "commits"
            <*> o .: "status"
            <*> o .: "ahead_by"
            <*> o .: "behind_by"
            <*> o .: "total_commits"

-- ─── Client ────────────────────────────────────────────────────────

{- | List commits introduced on @head@ relative to @base@.

GitHub accepts branch names, tag names, or commit SHAs in either
position. Tags contain @/@ characters which we URL-encode so the path
segment isn't broken (the GH compare endpoint treats the part between
@compare/@ and @...@ as a single ref name).

Returns @Right CompareResult@ on 200, @Left <message>@ on 404 /
rate-limit / decode failure / network error.
-}
compareRefs ::
    (MonadFlow m) =>
    GhAppCreds ->
    Text ->
    -- ^ owner
    Text ->
    -- ^ repo
    Text ->
    -- ^ base ref (branch, tag, or sha)
    Text ->
    -- ^ head ref (branch, tag, or sha)
    m (Either Text CompareResult)
compareRefs creds owner repo base headRef = do
    token <- getInstallationToken creds
    let url =
            apiBase owner repo
                <> "/compare/"
                <> urlEncodePathSegment base
                <> "..."
                <> urlEncodePathSegment headRef
        req =
            (defaultReq url)
                { reqMethod = GET
                , reqHeaders = ghHeaders token
                , reqTimeout = Seconds 30
                , reqLogTag = "gh-compare"
                }
    resp <- liftIO (httpJson @CompareResult req)
    pure $ case resp of
        Right r -> Right r
        Left e -> Left ("compareRefs: " <> renderHttpError e)

-- ─── Helpers ───────────────────────────────────────────────────────

{- | URL-encode characters that are illegal in a path segment. Mainly
@\/@ → @%2F@ so a tag like @nammayatri\/prod\/android\/v1.2.3+456@
doesn't get split across path segments. The @+@ is also escaped
because some intermediaries interpret it as a space in query strings;
we encode it conservatively even on path segments.
-}
urlEncodePathSegment :: Text -> Text
urlEncodePathSegment = T.concatMap encChar
  where
    encChar c = case c of
        '/' -> "%2F"
        '+' -> "%2B"
        ' ' -> "%20"
        '#' -> "%23"
        '?' -> "%3F"
        _ -> T.singleton c

{- | Best-effort PR-number extraction. Looks for @(#NNN)@ anywhere in
the subject and returns the first numeric match. Examples:

* @"feat: add foo (#123)"@ → @Just 123@
* @"fix (#12) and (#34)"@ → @Just 12@
* @"chore: bump deps"@ → @Nothing@
* @"Merge pull request #45 from foo/bar"@ → @Nothing@ (no parens)
-}
extractPrNumber :: Text -> Maybe Int
extractPrNumber subject =
    case T.breakOn "(#" subject of
        (_, rest)
            | not (T.null rest) ->
                let afterHash = T.drop 2 rest
                    (numStr, _) = T.breakOn ")" afterHash
                 in readMaybe (T.unpack numStr)
        _ -> Nothing

{- | First 7 characters of a SHA. Empty string in, empty string out
(defensive; ResolveRunId already guards against empty SHAs upstream).
-}
shortSha :: Text -> Text
shortSha = T.take 7

-- ─── Internal ──────────────────────────────────────────────────────

firstLine :: Text -> Text
firstLine = T.takeWhile (/= '\n')
