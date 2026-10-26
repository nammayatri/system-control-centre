{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Where Devbox Releases meet GitHub: the repos, pinning a branch to a commit,
and starting nammayatri's devbox workflow. Used by the API (create / stop)
and by the poller (auto-stop on expiry).
-}
module Products.Devbox.Github (
    backendRepo,
    ccRepo,
    appRepo,
    workflowFile,
    pin,
    dispatch,
    AppBuild (..),
    appBuildFor,
    dispatchAppBuild,
)
where

import Control.Monad (when)
import Control.Monad.Catch (throwM)
import Core.AppError (APIError (..))
import Core.Environment (Flow)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.Text (Text)
import Products.Autopilot.Mobile.Github (CommitDetail (..), DispatchRunDetails (..), WorkflowDispatchReq (..), dispatchWorkflow, getCommitInfo)
import Products.Autopilot.Mobile.Github.Auth (GhAppCreds)
import Products.Devbox.Queries (insertEvent, setFailed, setRun)
import Shared.Config.Runtime (getConfigTextForProduct)

-- | nammayatri holds the backend and the devbox workflow.
backendRepo, ccRepo, appRepo :: (Text, Text)
backendRepo = ("nammayatri", "nammayatri")
ccRepo = ("nammayatri", "control-center")
appRepo = ("nammayatri", "ny-react-native")

workflowFile :: Text
workflowFile = ".github/workflows/devbox.yaml"

-- | The commit a branch points at now, or a 400 naming the repo and branch.
pin :: GhAppCreds -> (Text, Text) -> Text -> Flow Text
pin creds (owner, repo) branch =
    getCommitInfo creds owner repo branch >>= \case
        Right c -> pure (cdSha c)
        Left err -> throwM (BadRequest ("branch " <> branch <> " not found in " <> owner <> "/" <> repo <> ": " <> err))

{- | Start the workflow and remember its run (the logs button and the poller
both use it). A failed spawn dispatch fails the release with the reason; a
failed stop dispatch is recorded and raised to the caller.
-}
dispatch :: GhAppCreds -> Text -> Text -> KM.KeyMap Value -> Flow ()
dispatch creds rid action inputs = do
    ref <- getConfigTextForProduct "devbox_workflow_ref" (Just "devbox") "main"
    res <- dispatchWorkflow creds (fst backendRepo) (snd backendRepo) workflowFile (WorkflowDispatchReq ref inputs)
    let stage = if action == "stop" then "stop" else "preparing"
    case res of
        Right (Just d) -> do
            _ <- setRun rid action (drdRunId d) (drdHtmlUrl d)
            insertEvent rid stage "info" (object ["githubRun" .= drdRunId d]) Nothing
        Right Nothing ->
            -- Dispatched, but GitHub did not say which run (older API behaviour).
            insertEvent rid stage "info" (object ["githubRun" .= Null]) Nothing
        Left err -> do
            let msg = "could not start the GitHub run: " <> err
            _ <- if action == "stop" then pure False else setFailed rid msg
            insertEvent rid stage "failed" (object ["error" .= msg]) Nothing
            when (action == "stop") $ throwM (InternalError msg)

-- ─── App builds (ny-react-native debug workflows) ──────────────────

-- | One app build: which ny-react-native workflow and which base URL path.
data AppBuild = AppBuild
    { abApp :: Text
    -- ^ rider | driver
    , abPlatform :: Text
    -- ^ android | ios
    , abWorkflow :: Text
    , abUrlPath :: Text
    -- ^ appended to the release's backend URL (front desk route of that service)
    }

-- | 'rider:android' etc. → the workflow that builds it. Nothing for anything else.
appBuildFor :: Text -> Maybe AppBuild
appBuildFor = \case
    "rider:android" -> Just (AppBuild "rider" "android" ".github/workflows/fastlane-android-debug.yaml" "/rider-app/v2")
    "rider:ios" -> Just (AppBuild "rider" "ios" ".github/workflows/fastlane-ios-debug.yaml" "/rider-app/v2")
    "driver:android" -> Just (AppBuild "driver" "android" ".github/workflows/provider-debug-apk-gen.yaml" "/dynamic-offer-driver-app/ui")
    "driver:ios" -> Just (AppBuild "driver" "ios" ".github/workflows/provider-debug-ios-gen.yaml" "/dynamic-offer-driver-app/ui")
    _ -> Nothing

{- | Start one app build on the app branch, pointed at the release's backend.
The rider workflows take a change log; the driver ones a version name and
release notes. Apps (catalyst names) and the driver version name come from
server config.
-}
dispatchAppBuild :: GhAppCreds -> AppBuild -> Text -> Text -> Text -> Text -> Flow (Either Text (Maybe DispatchRunDetails))
dispatchAppBuild creds ab ref backendUrl workspace rid = do
    riderApp <- getConfigTextForProduct "devbox_rider_app" (Just "devbox") "NammaYatri"
    driverApp <- getConfigTextForProduct "devbox_driver_app" (Just "devbox") "NammaYatriPartner"
    versionName <- getConfigTextForProduct "devbox_driver_version_name" (Just "devbox") "9.9.9"
    let note = "Devbox release " <> workspace <> " (" <> rid <> ")"
        common = [("base_url", String (backendUrl <> abUrlPath ab)), ("devbox_release", String rid)]
        inputs =
            KM.fromList $
                common
                    <> if abApp ab == "rider"
                        then [("selected_apps", String riderApp), ("change_log", String note)]
                        else [("selected_apps", String driverApp), ("version_name", String versionName), ("release_notes", String note)]
    dispatchWorkflow creds (fst appRepo) (snd appRepo) (abWorkflow ab) (WorkflowDispatchReq ref inputs)
