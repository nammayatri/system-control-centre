{-# LANGUAGE OverloadedStrings #-}

{- | GitHub changelog diff links, generated server-side at release creation.

This is an exact semantic port of the frontend helpers in
@frontend/src/products/releases/pages/CreateRelease.tsx@ (normalizeRepo /
toCommitId / buildDiffLink). Single-service creates build the link on the
frontend; multi-service creates (and any API client that sends no changelog)
have it generated here, per service, once the old version has been resolved
from K8s. Keep the two in sync — a divergence produces links that differ
depending on which path created the release.
-}
module Products.Autopilot.DiffLink (
    normalizeRepo,
    toCommitId,
    buildDiffLink,
)
where

import Data.Char (isHexDigit)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

{- | Normalise whatever an admin typed into the product config's repo field into
a bare @owner/repo@ slug. Tolerates a full GitHub URL and a trailing @.git@.
Mirrors the frontend @normalizeRepo@.
-}
normalizeRepo :: Text -> Text
normalizeRepo raw =
    let trimmed = T.strip raw
        noScheme = stripGithubPrefix trimmed
        noGit =
            if ".git" `T.isSuffixOf` T.toLower noScheme
                then T.dropEnd 4 noScheme
                else noScheme
     in T.dropAround (== '/') noGit
  where
    stripGithubPrefix t =
        let lower = T.toLower t
         in case listToMaybe [p | p <- ["https://github.com/", "http://github.com/"], p `T.isPrefixOf` lower] of
                Just p -> T.drop (T.length p) t
                Nothing -> t
    listToMaybe [] = Nothing
    listToMaybe (x : _) = Just x

{- | Release versions look like @a1b2c3-v2@: a 6-char commit SHA prefix,
sometimes followed by a suffix (@-v1@/@-v2@) that is not part of any git ref.
Take the first 6 chars and confirm they are a short SHA (hex); otherwise the
ref is unusable. Case is preserved. Mirrors the frontend @toCommitId@.
-}
toCommitId :: Text -> Maybe Text
toCommitId version =
    let candidate = T.take 6 (T.strip version)
     in if T.length candidate == 6 && T.all isHexDigit candidate
            then Just candidate
            else Nothing

{- | Build a GitHub link that shows what shipped in this release. Prefer a
compare view (@old...new@); fall back to the new ref's commit history when
there is no usable old version. 'Nothing' when there is no repo or no valid
new commit — the caller then leaves the changelog untouched. Mirrors the
frontend @buildDiffLink@.
-}
buildDiffLink :: Maybe Text -> Text -> Text -> Maybe Text
buildDiffLink mRepo oldV newV =
    case toCommitId newV of
        Just n | not (T.null repo) ->
            Just $ case toCommitId oldV of
                Just o -> "https://github.com/" <> repo <> "/compare/" <> o <> "..." <> n
                Nothing -> "https://github.com/" <> repo <> "/commits/" <> n
        _ -> Nothing
  where
    repo = normalizeRepo (fromMaybe "" mRepo)
