{-# LANGUAGE OverloadedStrings #-}

{- | AI changelog generation for BACKEND (k8s) releases.

Mirrors the mobile create-time changelog minus the surface split: fetch the
commits between the previous and new release versions from GitHub, then run the
shared 'Shared.AI' chunked map-reduce generator (each change carries its GitHub
author). Used by the completion Slack hook in "Products.Autopilot.Notifications".

Returns 'Nothing' — meaning "post nothing" — whenever notes can't be produced:
an unusable repo/ref, a GitHub fetch failure, AI disabled/unconfigured, no
commits in range, or every model failing. Callers treat 'Nothing' as a clean
no-op (no fallback message).
-}
module Products.Autopilot.ReleaseChangelog (generateBackendChangelog) where

import Core.Environment (MonadFlow)
import Core.Logging (logInfoG, logWarningG)
import Data.Text (Text)
import Data.Text qualified as T
import Products.Autopilot.DiffLink (normalizeRepo, toCommitId)
import Products.Autopilot.Mobile.Github.Auth (loadGhCreds)
import Products.Autopilot.Mobile.Github.Compare (CommitInfo, CompareResult (..), ciDisplayAuthor, ciShortSha, ciSubject, compareRefs, isBotCommit)
import Shared.AI.Changelog (CommitItem (..), dropAutomationCommits)
import Shared.AI.Config (loadAiConfig)
import Shared.AI.ReleaseSummary (generateWithFallback)
import Prelude

-- | GitHub commit → the app-neutral 'CommitItem' the AI generator consumes.
-- 'ciDisplayAuthor' is the GitHub login (falling back to the commit author name),
-- so the generated changelog attributes every change to a user.
toItem :: CommitInfo -> CommitItem
toItem c = CommitItem (ciShortSha c) (ciSubject c) (ciDisplayAuthor c)

{- | Generate AI changelog notes for a backend release's @old → new@ range.

@repo@ is the app group's configured @repo_name@ (any of @owner/repo@, a full
GitHub URL, or a @.git@ suffix — 'normalizeRepo' handles it). @oldVer@/@newVer@
are release version strings whose 6-char commit-SHA prefix is the git ref
('toCommitId'). @label@ heads the changelog (the service name); @createdBy@ is
recorded on the AI audit rows.
-}
generateBackendChangelog ::
    (MonadFlow m) =>
    -- | repo (app group @repo_name@)
    Text ->
    -- | old version
    Text ->
    -- | new version
    Text ->
    -- | label for the changelog header (service)
    Text ->
    -- | createdBy (audit)
    Text ->
    m (Maybe Text)
generateBackendChangelog repo oldVer newVer label createdBy =
    case (splitRepo (normalizeRepo repo), toCommitId oldVer, toCommitId newVer) of
        (Just (owner, name), Just base, Just headRef) -> do
            creds <- loadGhCreds
            res <- compareRefs creds owner name base headRef
            case res of
                Left e -> do
                    logWarningG ("[CHANGELOG] compareRefs failed for " <> repo <> " (" <> base <> "..." <> headRef <> "): " <> e)
                    pure Nothing
                Right cr -> do
                    let commits = filter (not . isBotCommit) (crCommits cr)
                        items = dropAutomationCommits (map toItem commits)
                    if null items
                        then do
                            logInfoG ("[CHANGELOG] no changelog-worthy commits for " <> label <> " " <> oldVer <> " → " <> newVer)
                            pure Nothing
                        else do
                            ecfg <- loadAiConfig
                            case ecfg of
                                -- AI off/unconfigured → post nothing (per product decision).
                                Left _ -> pure Nothing
                                Right cfg -> do
                                    -- No surface split for backend: excluded = 0, excludedSide = "".
                                    mRes <- generateWithFallback createdBy cfg label newVer 0 "" items
                                    pure (fmap (\(long, _short, _model) -> long) mRes)
        _ -> pure Nothing
  where
    -- "owner/repo" → (owner, repo). 'normalizeRepo' already stripped any scheme
    -- and trailing ".git", so a well-formed slug has exactly one leading "/".
    splitRepo slug =
        let (owner, rest) = T.breakOn "/" slug
            name = T.drop 1 rest
         in if not (T.null owner) && not (T.null name)
                then Just (owner, name)
                else Nothing
