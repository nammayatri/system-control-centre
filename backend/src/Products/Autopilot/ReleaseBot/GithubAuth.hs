{-# LANGUAGE OverloadedStrings #-}

-- | A GitHub read token for the release bot and the tracker cards.
module Products.Autopilot.ReleaseBot.GithubAuth (githubTokenFlow) where

import Control.Exception (SomeException)
import Control.Monad.Catch (try)
import Core.Environment (Flow)
import Data.Text (Text)
import qualified Data.Text as T
import Products.Autopilot.Mobile.Github.Auth (getInstallationToken, loadGhCreds)
import Products.Autopilot.ProdRelease.Github (githubTokenFromEnv)

{- | An explicit @SC_GITHUB_TOKEN@ if set, otherwise an installation token minted from the GitHub
App the backend already has (@SC_GITHUB_APP_*@). The installation must cover the repo (Contents: read).
-}
githubTokenFlow :: Flow (Either Text Text)
githubTokenFlow = do
    pat <- githubTokenFromEnv
    case pat of
        Right t -> pure (Right t)
        Left _ -> do
            r <- try (loadGhCreds >>= getInstallationToken) :: Flow (Either SomeException Text)
            pure $ case r of
                Right t -> Right t
                Left e -> Left ("no GitHub credentials (set SC_GITHUB_TOKEN, or install the GitHub App on this repo): " <> T.take 160 (T.pack (show e)))
