{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- | HTTP handlers for mobile release revert.

Two endpoints:

* @GET  \/releases\/:id\/mobile-revert\/draft@ — preview what the revert
  would look like (previous good version, suggested version-name and
  version-code, auto-generated changelog, count of commits being
  rolled back). Read-only; nothing is persisted.

* @POST \/releases\/:id\/mobile-revert@ — actually create the revert
  release row. Validates that the operator-supplied version-name and
  version-code are strictly greater than the bad release's. Inserts a
  new @release_tracker@ row with @source_ref@ pointing at the previous
  good tag and @reverts_release_id@ linking back to the bad release.
  The new row enters the standard CREATED → approval → dispatch
  lifecycle from there.

Both endpoints are gated by @'AP_RELEASE_REVERT@.
-}
module Products.Autopilot.Mobile.Handlers.Revert (
    -- * Types
    RevertDraft (..),
    RevertReq (..),
    RevertResp (..),
    VerifyCommitResp (..),

    -- * Handlers
    mobileRevertDraftH,
    mobileRevertCreateH,
    verifyCommitH,
) where

import Control.Monad.Catch (throwM)
import Control.Monad.IO.Class (liftIO)
import Core.AppError (APIError (..))
import Core.Auth.Protected (AuthedPerson (..))
import Core.Environment (Flow)
import Data.Aeson (FromJSON, ToJSON, object, (.=))
import Data.Functor.Identity (Identity)
import Data.Int (Int32)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import GHC.Generics (Generic)
import Products.Autopilot.Mobile.Changelog (bumpPatch, renderRevertChangelog)
import Products.Autopilot.Mobile.Github (CommitDetail (..), createGitRef, getCommitInfo)
import Products.Autopilot.Mobile.Github.Auth (loadGhCreds)
import Products.Autopilot.Mobile.Github.Compare (CommitInfo (..), compareRefs, crCommits, shortSha)
import Products.Autopilot.Mobile.Queries.AppCatalog (
    LatestBuildRow (..),
    fetchLatestBuildsPerApp,
 )
import Products.Autopilot.Mobile.Queries.Tracker (
    appCatalogForRowRaw,
    findMobileReleaseById,
    findPreviousGoodMobileRelease,
    findPreviousGoodSCCRelease,
    gitOwner,
    gitRepo,
    insertMobileRevertTracker,
    logEvent,
 )
import Products.Autopilot.Mobile.Types (
    MobileBuildContext (..),
    MobileBuildTargetState (..),
    MobileBuildWFStatus (..),
    isDebugDestination,
 )
import Products.Autopilot.Mobile.Types.Storage (AppCatalogT (..))
import Products.Autopilot.Types.Storage.Schema (ReleaseTrackerT (..))

-- ─── Wire types ────────────────────────────────────────────────────

{- | Read-only preview of what a revert would do. Returned by the
draft endpoint; the FE renders a confirmation modal from this.
-}
{- | One commit being rolled back, as exposed to the FE. Mirrors
the upstream 'CommitInfo' from "Mobile.Github.Compare" but with a
narrower projection: the FE doesn't need 'ciMessage' (full body)
or 'ciSha' (long form) when 'ciSubject' + 'ciShortSha' suffice.
-}
data RevertCommit = RevertCommit
    { rcShortSha :: Text
    , rcSubject :: Text
    , rcAuthorLogin :: Text
    , rcHtmlUrl :: Text
    -- ^ Direct link to the commit on github.com.
    , rcPrNumber :: Maybe Int
    -- ^ Extracted from `(#NNN)` in the subject if present.
    }
    deriving (Eq, Show, Generic)

instance ToJSON RevertCommit
instance FromJSON RevertCommit

data RevertDraft = RevertDraft
    { rdBadReleaseId :: Text
    , rdBadVersion :: Text
    , rdBadVersionCode :: Maybe Int32
    , rdPrevGoodReleaseId :: Text
    , rdPrevGoodVersion :: Text
    , rdPrevGoodShortSha :: Text
    , rdPrevGoodTag :: Text
    , rdSuggestedVersion :: Text
    , rdSuggestedCode :: Maybe Int32
    , rdChangelog :: Text
    , rdCommits :: [RevertCommit]
    , rdCommitCount :: Int
    , rdPlatform :: Text
    , rdIsStoreSyncRevert :: Bool
    -- ^ True when the bad release is a store-sync row (may still have derived tag/commits).
    , rdStoreVersion :: Maybe Text
    -- ^ Current live store version for this app (from latest build data).
    , rdStoreVersionCode :: Maybe Int32
    -- ^ Current live store version code (Android only).
    }
    deriving (Eq, Show, Generic)

instance ToJSON RevertDraft
instance FromJSON RevertDraft

-- | Project a raw 'CommitInfo' (from the GH Compare client) to the
-- FE-facing 'RevertCommit' shape. Drops fields the UI doesn't render.
toRevertCommit :: CommitInfo -> RevertCommit
toRevertCommit ci =
    RevertCommit
        { rcShortSha = ciShortSha ci
        , rcSubject = ciSubject ci
        , rcAuthorLogin = ciAuthorLogin ci
        , rcHtmlUrl = ciHtmlUrl ci
        , rcPrNumber = ciPrNumber ci
        }

{- | Operator-confirmed revert request. Fields are pre-populated from
'RevertDraft' but editable in the UI.
-}
data RevertReq = RevertReq
    { rrNewVersionName :: Text
    , rrNewVersionCode :: Maybe Int32
    -- ^ Required for Android; ignored for iOS.
    , rrChangelog :: Text
    , rrSourceCommit :: Maybe Text
    -- ^ Optional custom commit SHA to build from instead of the previous good tag.
    }
    deriving (Eq, Show, Generic)

instance ToJSON RevertReq
instance FromJSON RevertReq

-- | Response from the create endpoint — the new revert release id.
newtype RevertResp = RevertResp
    { rrRevertReleaseId :: Text
    }
    deriving (Eq, Show, Generic)

instance ToJSON RevertResp
instance FromJSON RevertResp

data VerifyCommitResp = VerifyCommitResp
    { vcFullSha :: Text
    , vcShortSha :: Text
    , vcMessage :: Text
    , vcAuthor :: Text
    , vcHtmlUrl :: Text
    }
    deriving (Eq, Show, Generic)

instance ToJSON VerifyCommitResp

-- ─── Verify commit handler ───────────────────────────────────────────

verifyCommitH :: AuthedPerson -> Text -> Text -> Flow VerifyCommitResp
verifyCommitH _ap releaseId' sha = do
    mBad <- findMobileReleaseById releaseId'
    (bad, _) <- case mBad of
        Just x -> pure x
        Nothing -> throwM $ BadRequest ("Mobile release not found: " <> releaseId')
    ac <- appCatalogForRowRaw bad
    creds <- loadGhCreds
    res <- getCommitInfo creds (gitOwner ac) (gitRepo ac) sha
    case res of
        Right cd ->
            pure
                VerifyCommitResp
                    { vcFullSha = cdSha cd
                    , vcShortSha = T.take 7 (cdSha cd)
                    , vcMessage = cdMessage cd
                    , vcAuthor = cdAuthorLogin cd
                    , vcHtmlUrl = cdHtmlUrl cd
                    }
        Left e ->
            throwM $
                BadRequest ("Commit not found: " <> e)

-- ─── Draft handler ─────────────────────────────────────────────────

mobileRevertDraftH :: AuthedPerson -> Text -> Flow RevertDraft
mobileRevertDraftH _ap releaseId' = do
    mBad <- findMobileReleaseById releaseId'
    (bad, badState) <- case mBad of
        Just x -> pure x
        Nothing ->
            throwM $
                BadRequest ("Mobile release not found: " <> releaseId')

    case rtStatus bad of
        "COMPLETED" -> pure ()
        s ->
            throwM $
                BadRequest
                    ( "Cannot revert release in status "
                        <> s
                        <> "; only COMPLETED releases are revertable."
                    )

    case badState >>= Just . mbcDestination . mbContext of
        Just d | isDebugDestination d ->
            throwM $
                BadRequest "Debug builds (Firebase / TestFlight) cannot be reverted."
        _ -> pure ()

    case rtRevertsReleaseId bad of
        Just _ ->
            throwM $
                BadRequest "This release was created by a revert and cannot be reverted further. Create a new release instead."
        Nothing -> pure ()

    builds <- fetchLatestBuildsPerApp
    let buildMap =
            Map.fromList
                [ ((lbrAppGroup b, lbrSurface b, lbrPlatform b, lbrBuildType b), b)
                | b <- builds
                ]
        storeKey = (rtAppGroup bad, rtService bad, rtEnv bad, "release" :: Text)
        mStoreBuild = Map.lookup storeKey buildMap
        storeVersion = fmap lbrVersion mStoreBuild
        storeVersionCode = mStoreBuild >>= lbrVersionCode

    let isStoreSync = rtMode bad == Just "STORE_SYNC"

    if isStoreSync
        then draftForStoreSyncRevert bad badState storeVersion storeVersionCode
        else draftForSCCRevert bad badState storeVersion storeVersionCode

draftForSCCRevert ::
    ReleaseTrackerT Identity ->
    Maybe MobileBuildTargetState ->
    Maybe Text ->
    Maybe Int32 ->
    Flow RevertDraft
draftForSCCRevert bad badState storeVersion storeVersionCode = do
    mPrev <-
        findPreviousGoodMobileRelease
            (rtAppGroup bad)
            (rtService bad)
            (rtEnv bad)
            (rtCreatedAt bad)
    (prev, prevState) <- case mPrev of
        Just x -> pure x
        Nothing ->
            throwM $
                BadRequest
                    "No previous good release found for this app — cannot revert."

    let prevTagFromState = prevState >>= mbcTagPushed . mbContext
        badTagFromState = badState >>= mbcTagPushed . mbContext
    prevTag <- case prevTagFromState of
        Just t | not (T.null t) -> pure t
        _ -> throwM $ BadRequest "Previous good release has no pushed tag — cannot revert."
    badTag <- case badTagFromState of
        Just t | not (T.null t) -> pure t
        _ -> throwM $ BadRequest "Bad release has no pushed tag — cannot revert."

    let badCode = badState >>= mbcVersionCode . mbContext
        effectiveCode = maxCode badCode storeVersionCode
        suggestedCode = fmap (+ 1) effectiveCode
        suggestedVer = bumpPatch (rtNewVersion bad)
        prevCommitShort = shortSha (fromMaybe "" (rtCommitSha prev))

    ac <- appCatalogForRowRaw bad
    creds <- loadGhCreds
    compareRes <- compareRefs creds (gitOwner ac) (gitRepo ac) prevTag badTag
    commits <- case compareRes of
        Right cr -> pure (crCommits cr)
        Left e ->
            throwM $
                BadRequest
                    ( "GitHub compare failed: "
                        <> e
                        <> ". If the previous tag has been deleted, try a manual release instead."
                    )

    let changelog =
            renderRevertChangelog
                (rtNewVersion bad)
                (rtNewVersion prev)
                prevCommitShort
                suggestedVer
                (fmap fromIntegral suggestedCode)
                commits

    pure
        RevertDraft
            { rdBadReleaseId = rtId bad
            , rdBadVersion = rtNewVersion bad
            , rdBadVersionCode = badCode
            , rdPrevGoodReleaseId = rtId prev
            , rdPrevGoodVersion = rtNewVersion prev
            , rdPrevGoodShortSha = prevCommitShort
            , rdPrevGoodTag = prevTag
            , rdSuggestedVersion = suggestedVer
            , rdSuggestedCode = suggestedCode
            , rdChangelog = changelog
            , rdCommits = map toRevertCommit commits
            , rdCommitCount = length commits
            , rdPlatform = rtEnv bad
            , rdIsStoreSyncRevert = False
            , rdStoreVersion = storeVersion
            , rdStoreVersionCode = storeVersionCode
            }

draftForStoreSyncRevert ::
    ReleaseTrackerT Identity ->
    Maybe MobileBuildTargetState ->
    Maybe Text ->
    Maybe Int32 ->
    Flow RevertDraft
draftForStoreSyncRevert bad badState storeVersion storeVersionCode = do
    mPrev <-
        findPreviousGoodSCCRelease
            (rtAppGroup bad)
            (rtService bad)
            (rtEnv bad)
    (prev, prevState) <- case mPrev of
        Just x -> pure x
        Nothing ->
            throwM $
                BadRequest
                    "No previous SCC-dispatched release found for this app — cannot revert a store-synced release without a prior build to dispatch from."

    let prevTagFromState = prevState >>= mbcTagPushed . mbContext
    prevTag <- case prevTagFromState of
        Just t | not (T.null t) -> pure t
        _ -> throwM $ BadRequest "Previous SCC release has no pushed tag — cannot revert."

    let badCode = badState >>= mbcVersionCode . mbContext
        badTagFromState = badState >>= mbcTagPushed . mbContext
        effectiveCode = maxCode badCode storeVersionCode
        suggestedCode = fmap (+ 1) effectiveCode
        suggestedVer = bumpPatch (rtNewVersion bad)
        prevCommitShort = shortSha (fromMaybe "" (rtCommitSha prev))

    (commits, hasCommitDiff) <- case badTagFromState of
        Just badTag | not (T.null badTag) -> do
            ac <- appCatalogForRowRaw bad
            creds <- loadGhCreds
            compareRes <- compareRefs creds (gitOwner ac) (gitRepo ac) prevTag badTag
            case compareRes of
                Right cr -> pure (crCommits cr, True)
                Left _ -> pure ([], False)
        _ -> pure ([], False)

    let changelog =
            if hasCommitDiff
                then
                    renderRevertChangelog
                        (rtNewVersion bad)
                        (rtNewVersion prev)
                        prevCommitShort
                        suggestedVer
                        (fmap fromIntegral suggestedCode)
                        commits
                else
                    "Revert store version v"
                        <> rtNewVersion bad
                        <> " — rebuilding from SCC release v"
                        <> rtNewVersion prev
                        <> " ("
                        <> prevCommitShort
                        <> ")"

    pure
        RevertDraft
            { rdBadReleaseId = rtId bad
            , rdBadVersion = rtNewVersion bad
            , rdBadVersionCode = badCode
            , rdPrevGoodReleaseId = rtId prev
            , rdPrevGoodVersion = rtNewVersion prev
            , rdPrevGoodShortSha = prevCommitShort
            , rdPrevGoodTag = prevTag
            , rdSuggestedVersion = suggestedVer
            , rdSuggestedCode = suggestedCode
            , rdChangelog = changelog
            , rdCommits = map toRevertCommit commits
            , rdCommitCount = length commits
            , rdPlatform = rtEnv bad
            , rdIsStoreSyncRevert = True
            , rdStoreVersion = storeVersion
            , rdStoreVersionCode = storeVersionCode
            }

maxCode :: Maybe Int32 -> Maybe Int32 -> Maybe Int32
maxCode Nothing Nothing = Nothing
maxCode (Just a) Nothing = Just a
maxCode Nothing (Just b) = Just b
maxCode (Just a) (Just b) = Just (max a b)

-- ─── Create handler ────────────────────────────────────────────────

mobileRevertCreateH :: AuthedPerson -> Text -> RevertReq -> Flow RevertResp
mobileRevertCreateH ap releaseId' RevertReq{..} = do
    mBad <- findMobileReleaseById releaseId'
    (bad, badState) <- case mBad of
        Just x -> pure x
        Nothing -> throwM $ BadRequest ("Mobile release not found: " <> releaseId')
    case rtStatus bad of
        "COMPLETED" -> pure ()
        s -> throwM $ BadRequest ("Cannot revert release in status " <> s)

    case badState >>= Just . mbcDestination . mbContext of
        Just d | isDebugDestination d ->
            throwM $ BadRequest "Debug builds cannot be reverted."
        _ -> pure ()

    case rtRevertsReleaseId bad of
        Just _ ->
            throwM $ BadRequest "This release was created by a revert and cannot be reverted further."
        Nothing -> pure ()

    let isStoreSync = rtMode bad == Just "STORE_SYNC"

    (prev, prevState) <-
        if isStoreSync
            then do
                mPrev <-
                    findPreviousGoodSCCRelease
                        (rtAppGroup bad)
                        (rtService bad)
                        (rtEnv bad)
                case mPrev of
                    Just x -> pure x
                    Nothing -> throwM $ BadRequest "No previous SCC-dispatched release found"
            else do
                mPrev <-
                    findPreviousGoodMobileRelease
                        (rtAppGroup bad)
                        (rtService bad)
                        (rtEnv bad)
                        (rtCreatedAt bad)
                case mPrev of
                    Just x -> pure x
                    Nothing -> throwM $ BadRequest "No previous good release found"

    let prevTagFromState = prevState >>= mbcTagPushed . mbContext
    prevTag <- case prevTagFromState of
        Just t | not (T.null t) -> pure t
        _ -> throwM $ BadRequest "Previous good release has no pushed tag"

    when' (rrNewVersionName == rtNewVersion bad) $
        BadRequest "new version name must differ from bad release's"

    builds <- fetchLatestBuildsPerApp
    let buildMap =
            Map.fromList
                [ ((lbrAppGroup b, lbrSurface b, lbrPlatform b, lbrBuildType b), b)
                | b <- builds
                ]
        storeKey = (rtAppGroup bad, rtService bad, rtEnv bad, "release" :: Text)
        storeCode = Map.lookup storeKey buildMap >>= lbrVersionCode
        badCode = badState >>= mbcVersionCode . mbContext
        floorCode = maxCode badCode storeCode
        isAndroid = rtEnv bad == "android"
    when' (isAndroid && rrNewVersionCode == Nothing) $
        BadRequest "version_code is required for Android reverts"
    case (isAndroid, rrNewVersionCode, floorCode) of
        (True, Just newC, Just oldC) ->
            when' (newC <= oldC) $
                BadRequest
                    ( "version_code must be strictly greater than "
                        <> T.pack (show oldC)
                        <> " (max of bad release + current store version); got "
                        <> T.pack (show newC)
                    )
        _ -> pure ()

    newId <- liftIO (UUID.toText <$> UUID.nextRandom)
    now <- liftIO getCurrentTime
    ac <- appCatalogForRowRaw bad
    destinationVal <- case (badState, prevState) of
        (Just s, _) -> pure (mbcDestination (mbContext s))
        (_, Just s) -> pure (mbcDestination (mbContext s))
        _ -> throwM $ BadRequest "Both bad and previous good releases have unparseable mobile state"
    let ctx =
            MobileBuildContext
                { mbcVersionCode = rrNewVersionCode
                , mbcChangeLog = rrChangelog
                , mbcDestination = destinationVal
                , mbcReleaseGroupId = newId
                , mbcMatrixJobName = acName ac <> if isDebugDestination destinationVal then "-Debug" else "-Release"
                , mbcOtaNamespace = Nothing
                , mbcTagPushed = Nothing
                }
        targetState =
            MobileBuildTargetState
                { mbWfStatus = MBInit
                , mbContext = ctx
                , mbExternalRunId = Nothing
                , mbMatrixJobStatus = Nothing
                , mbBuildStartedAt = Nothing
                , mbBuildCompletedAt = Nothing
                , mbResolveAttempts = Nothing
                }
    sourceRefStr <- case rrSourceCommit of
        Just commitSha | not (T.null commitSha) -> do
            creds <- loadGhCreds
            verifyRes <- getCommitInfo creds (gitOwner ac) (gitRepo ac) commitSha
            fullSha <- case verifyRes of
                Right cd -> pure (cdSha cd)
                Left e ->
                    throwM $
                        BadRequest ("Commit not found in repo: " <> e)
            let tagName = "scc-revert/" <> newId
            tagRes <- createGitRef creds (gitOwner ac) (gitRepo ac) tagName fullSha
            case tagRes of
                Right () -> pure ("refs/tags/" <> tagName)
                Left e ->
                    throwM $
                        BadRequest ("Failed to create tag for custom commit: " <> e)
        _ -> pure ("refs/tags/" <> prevTag)
    insertMobileRevertTracker
        newId
        ac
        targetState
        rrNewVersionName
        rrChangelog
        sourceRefStr
        (rtId bad)
        (apEmail ap)
        now

    logEvent
        newId
        "REVERT_CREATED"
        ( object
            [ "reverts" .= rtId bad
            , "prev_good" .= rtId prev
            , "prev_tag" .= prevTag
            , "new_version" .= rrNewVersionName
            , "new_version_code" .= rrNewVersionCode
            , "source_ref" .= sourceRefStr
            , "source_commit" .= rrSourceCommit
            , "is_store_sync_revert" .= isStoreSync
            ]
        )

    pure RevertResp{rrRevertReleaseId = newId}

-- ─── Internal helpers ──────────────────────────────────────────────

when' :: Bool -> APIError -> Flow ()
when' True err = throwM err
when' False _ = pure ()
