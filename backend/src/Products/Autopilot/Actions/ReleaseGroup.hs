{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Release bundles (reusable ordered recipes) and grouped release runs.

Bundle CRUD rides on the Deployment Config permission, like release locks.
A run is created with one normal tracker per bundle step, approved once as a
group, and then driven by "Products.Autopilot.ReleaseGroup.Coordinator".
-}
module Products.Autopilot.Actions.ReleaseGroup (
    BundleReq (..),
    ArchiveBundleReq (..),
    CreateGroupReq (..),
    ResumeGroupReq (..),
    AbortGroupReq (..),
    listBundlesH,
    createBundleH,
    updateBundleH,
    archiveBundleH,
    listGroupsH,
    getGroupH,
    createGroupH,
    approveGroupH,
    resumeGroupH,
    abortGroupH,
)
where

import Control.Monad (foldM, forM, forM_, unless, when)
import Control.Monad.Catch (throwM)
import Control.Monad.IO.Class (liftIO)
import Core.AppError (APIError (..))
import Core.Auth.Protected (AuthedPerson (..), requireDeploymentPermission)
import Core.Environment (Flow)
import Data.Aeson (FromJSON (..), object, (.=))
import Data.List (nub, sort)
import Data.Maybe (fromMaybe)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import GHC.Generics (Generic)
import Products.Autopilot.Actions.Release (createGroupMemberRelease, discardReleaseCore)
import Products.Autopilot.ConfigReview (reviewBlocksApproval)
import Products.Autopilot.Queries.ReleaseTracker (findReleaseTrackerForCloud, insertReleaseEvent)
import Products.Autopilot.ReleaseGroup.Store
import Products.Autopilot.ReleaseGroup.Types
import Products.Autopilot.Types qualified as NT
import Products.Autopilot.Types.API (DiscardReleaseReq (..), K8sCreateReleaseReq)
import Products.Autopilot.Types.API qualified as API
import Products.Autopilot.Types.Permission (AutopilotPermission (..))
import Shared.API.Response (APIResponse (..))

-- ── Requests ─────────────────────────────────────────────────────────────

data BundleReq = BundleReq
    { name :: Text
    , description :: Maybe Text
    , stages :: [StageDef]
    }
    deriving (Generic)

instance FromJSON BundleReq

newtype ArchiveBundleReq = ArchiveBundleReq {archived :: Bool}
    deriving (Generic)

instance FromJSON ArchiveBundleReq

-- | One release request per bundle step, in the same shape as a normal create.
data CreateGroupReq = CreateGroupReq
    { bundleId :: Text
    , description :: Maybe Text
    , releases :: [K8sCreateReleaseReq]
    }
    deriving (Generic)

instance FromJSON CreateGroupReq

-- | @skipFailed@ moves past steps whose release failed instead of waiting for
-- them to be restarted.
newtype ResumeGroupReq = ResumeGroupReq {skipFailed :: Maybe Bool}
    deriving (Generic)

instance FromJSON ResumeGroupReq

newtype AbortGroupReq = AbortGroupReq {reason :: Maybe Text}
    deriving (Generic)

instance FromJSON AbortGroupReq

-- ── Permissions ──────────────────────────────────────────────────────────

editPerm :: Proxy 'AP_PRODUCT_CONFIG_EDIT
editPerm = Proxy

groupsOf :: [StageDef] -> [Text]
groupsOf stgs = nub [s.appGroup | stg <- stgs, s <- stg.steps]

runGroups :: GroupRun -> [Text]
runGroups r = nub [s.appGroup | s <- r.steps]

-- ── Bundles ──────────────────────────────────────────────────────────────

listBundlesH :: AuthedPerson -> Maybe Bool -> Flow [Bundle]
listBundlesH _ap includeArchived = listBundles (fromMaybe False includeArchived)

checkBundle :: AuthedPerson -> BundleReq -> Flow (Text, Text)
checkBundle ap req = do
    let nm = T.strip req.name
    when (T.null nm) $ throwM (BadRequest "Bundle name is required")
    either (throwM . BadRequest) pure (validateStages req.stages)
    -- You can only put services into a bundle that you could configure yourself.
    forM_ (groupsOf req.stages) $ requireDeploymentPermission editPerm ap
    pure (nm, maybe "" T.strip req.description)

createBundleH :: AuthedPerson -> BundleReq -> Flow Bundle
createBundleH ap req = do
    (nm, desc) <- checkBundle ap req
    bid <- liftIO (UUID.toText <$> UUID.nextRandom)
    ok <- insertBundle bid nm desc req.stages (apEmail ap)
    unless ok $ throwM (Conflict ("A bundle named " <> nm <> " already exists"))
    getBundle bid >>= maybe (throwM (InternalError "Bundle vanished after insert")) pure

updateBundleH :: AuthedPerson -> Text -> BundleReq -> Flow Bundle
updateBundleH ap bid req = do
    (nm, desc) <- checkBundle ap req
    existing <- getBundle bid >>= maybe (throwM (NotFound ("Bundle not found: " <> bid))) pure
    forM_ (groupsOf existing.stages) $ requireDeploymentPermission editPerm ap
    ok <- updateBundle bid nm desc req.stages
    unless ok $ throwM (Conflict ("A bundle named " <> nm <> " already exists"))
    getBundle bid >>= maybe (throwM (InternalError "Bundle vanished after update")) pure

archiveBundleH :: AuthedPerson -> Text -> ArchiveBundleReq -> Flow APIResponse
archiveBundleH ap bid req = do
    b <- getBundle bid >>= maybe (throwM (NotFound ("Bundle not found: " <> bid))) pure
    forM_ (groupsOf b.stages) $ requireDeploymentPermission editPerm ap
    archiveBundle bid req.archived
    pure $ APIResponse "SUCCESS" (if req.archived then "Bundle archived" else "Bundle restored")

-- ── Runs ─────────────────────────────────────────────────────────────────

-- | Fill each step's live tracker status.
withLiveStatus :: GroupRun -> Flow GroupRun
withLiveStatus r = do
    stps <- forM r.steps $ \s -> do
        m <- findReleaseTrackerForCloud s.releaseId
        pure (s {releaseStatus = fmap (T.pack . show . NT.status . fst) m} :: RunStep)
    pure (withSteps stps r)

loadRun :: Text -> Flow GroupRun
loadRun rid = getRun rid >>= maybe (throwM (NotFound ("Group release not found: " <> rid))) withLiveStatus

listGroupsH :: AuthedPerson -> Flow [GroupRun]
listGroupsH _ap = listRuns 50 >>= mapM withLiveStatus

getGroupH :: AuthedPerson -> Text -> Flow GroupRun
getGroupH _ap = loadRun

createGroupH :: AuthedPerson -> CreateGroupReq -> Flow GroupRun
createGroupH ap req = do
    b <- getBundle req.bundleId >>= maybe (throwM (NotFound ("Bundle not found: " <> req.bundleId))) pure
    when b.archived $ throwM (BadRequest "This bundle is archived")
    let planned = flattenSteps b.stages
        wanted = sort [(s.appGroup, s.service) | (_, _, _, s) <- planned]
        given = sort [(r.appGroup, r.service) | r <- req.releases]
        envs = nub [r.env | r <- req.releases]
    when (wanted /= given) $
        throwM (BadRequest "Provide exactly one release per service in the bundle, no more and no fewer")
    when (length envs /= 1) $
        throwM (BadRequest "Every release in a group must target the same env")
    forM_ (groupsOf b.stages) $ requireDeploymentPermission (Proxy :: Proxy 'AP_RELEASE_CREATE) ap
    rid <- liftIO (UUID.toText <$> UUID.nextRandom)
    -- Create in execution order. If any step is refused (lock, in-flight
    -- release, validation) discard the ones already made: they are still
    -- unapproved CREATED trackers, so nothing has deployed.
    (made, failure) <-
        foldM
            ( \acc@(done, failed) (si, pi', stg, stp) -> case failed of
                Just _ -> pure acc
                Nothing -> case [r | r <- req.releases, r.appGroup == stp.appGroup, r.service == stp.service] of
                    [] -> pure (done, Just (stp.service <> ": missing release"))
                    (r : _) -> do
                        res <- createGroupMemberRelease ap r
                        pure $ case res of
                            Left e -> (done, Just (stp.appGroup <> "/" <> stp.service <> ": " <> e))
                            Right relId -> (done <> [NewStep si pi' stg.name stg.mode stp.appGroup stp.service relId], Nothing)
            )
            ([], Nothing)
            planned
    case failure of
        Just e -> do
            forM_ made $ \s -> discardUnstarted s.releaseId "group release was not created"
            throwM (BadRequest ("Group release not created. " <> e))
        Nothing -> do
            insertRun rid b (firstEnv envs) (maybe "" T.strip req.description) (apEmail ap) made
            forM_ made $ \s ->
                insertReleaseEvent s.releaseId "BUSINESS" "GROUP_MEMBER" $
                    object ["runId" .= rid, "bundle" .= b.name, "stage" .= s.stageName]
            loadRun rid
  where
    firstEnv (x : _) = x
    firstEnv [] = ""

-- | Discard a tracker that has not started. Anything past CREATED is left alone:
-- a running release is never torn down from here.
discardUnstarted :: Text -> Text -> Flow ()
discardUnstarted relId why = do
    m <- findReleaseTrackerForCloud relId
    case m of
        Just (t, mts) | NT.status t == NT.CREATED -> do
            _ <- discardReleaseCore (DiscardReleaseReq (Just why)) t mts
            pure ()
        _ -> pure ()

-- ── Group actions ────────────────────────────────────────────────────────

approveGroupH :: AuthedPerson -> Text -> Flow GroupRun
approveGroupH ap rid = do
    run <- loadRun rid
    when (run.state /= PendingApproval) $
        throwM (BadRequest ("Group is " <> runStateText run.state <> "; only a pending group can be approved"))
    forM_ (runGroups run) $ requireDeploymentPermission (Proxy :: Proxy 'AP_RELEASE_APPROVE) ap
    -- Check every member now, so a problem surfaces before anything starts
    -- rather than halting the group halfway through.
    forM_ run.steps $ \s -> do
        m <- findReleaseTrackerForCloud s.releaseId
        case m of
            Nothing -> throwM (BadRequest (s.appGroup <> "/" <> s.service <> ": release " <> s.releaseId <> " not found"))
            Just (t, _) -> do
                when (NT.status t /= NT.CREATED || NT.isApproved t) $
                    throwM (BadRequest (s.appGroup <> "/" <> s.service <> " is " <> T.pack (show (NT.status t)) <> "; cannot approve the group"))
                when (reviewBlocksApproval t) $
                    throwM (BadRequest (s.appGroup <> "/" <> s.service <> ": AI review flagged the env change. Acknowledge it in the AI Review tab before approving the group."))
    setRunApprover rid (apEmail ap)
    ok <- transitionRun rid [PendingApproval] Running ""
    unless ok $ throwM (BadRequest "Group was approved or changed by a concurrent request")
    forM_ run.steps $ \s ->
        insertReleaseEvent s.releaseId "BUSINESS" "GROUP_APPROVED" (object ["runId" .= rid, "approvedBy" .= apEmail ap])
    loadRun rid

resumeGroupH :: AuthedPerson -> Text -> ResumeGroupReq -> Flow GroupRun
resumeGroupH ap rid req = do
    run <- loadRun rid
    forM_ (runGroups run) $ requireDeploymentPermission (Proxy :: Proxy 'AP_RELEASE_APPROVE) ap
    when (run.state /= Halted) $
        throwM (BadRequest ("Group is " <> runStateText run.state <> "; only a halted group can be resumed"))
    when (fromMaybe False req.skipFailed) $
        skipStarted rid [(s.stageIdx, s.stepIdx) | s <- run.steps, s.state == Started, failedStatus s.releaseStatus]
    ok <- transitionRun rid [Halted] Running ""
    unless ok $ throwM (BadRequest "Group changed state concurrently")
    loadRun rid
  where
    failedStatus (Just st) = case classifyStatus st of
        Failed _ -> True
        _ -> False
    failedStatus Nothing = False

abortGroupH :: AuthedPerson -> Text -> AbortGroupReq -> Flow GroupRun
abortGroupH ap rid req = do
    run <- loadRun rid
    forM_ (runGroups run) $ requireDeploymentPermission (Proxy :: Proxy 'AP_RELEASE_DISCARD) ap
    let why = fromMaybe "Aborted" req.reason <> " (by " <> apEmail ap <> ")"
    -- Flip the run first so the coordinator stops starting steps.
    ok <- transitionRun rid [PendingApproval, Running, Halted] Aborted why
    unless ok $ throwM (BadRequest ("Group is " <> runStateText run.state <> "; nothing to abort"))
    -- Steps that never started are discarded. Steps already running keep going:
    -- stop those individually from their own release page.
    forM_ [s | s <- run.steps, s.state == Waiting] $ \s -> do
        discardUnstarted s.releaseId why
        setStepState rid s.stageIdx s.stepIdx Skipped
    loadRun rid
