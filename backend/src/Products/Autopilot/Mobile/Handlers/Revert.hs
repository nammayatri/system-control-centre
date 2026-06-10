{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- | HTTP handlers for mobile release revert.

Four endpoints, all gated by @'AP_RELEASE_REVERT@:

* @GET  \/releases\/:id\/mobile-revert\/draft@ — preview what the revert
  would look like. The rollback target is resolved by /version order/
  (not creation time) via "Products.Autopilot.Mobile.RevertResolver", and
  is split into a display /target/ and a buildable /source/ (a target with
  no SCC artifact yields a @rebuild_lower@ or @manual_required@ plan). The
  draft carries suggested version-name\/code, an auto-generated changelog,
  and the commits being rolled back. Read-only; nothing is persisted.

* @POST \/releases\/:id\/mobile-revert@ — create the revert release row.
  Re-resolves the source (never trusts the draft), enforces a
  @version_code@ floor of @max(bad, live store) + 1@, and — when the target
  has no artifact — requires an operator-supplied @source_commit@. Inserts
  a new @release_tracker@ row with @source_ref@ and @reverts_release_id@,
  entering the standard CREATED → approval → dispatch lifecycle. A
  release created by a revert IS revertable; only an already-reverted
  release is blocked.

* @GET  \/releases\/:id\/mobile-revert\/verify-commit?sha=@ — resolve and
  validate a custom commit SHA or branch as a build source.

* @GET  \/releases\/:id\/mobile-revert\/diff?source=@ — live "commits being
  rolled back" between an arbitrary source (previous-good tag, custom SHA,
  or branch) and the bad release. The FE re-queries this on every source
  change so the list reflects the actual selection.
-}
module Products.Autopilot.Mobile.Handlers.Revert (
    -- * Types
    RevertDraft (..),
    RevertReq (..),
    RevertResp (..),
    RevertDiffResp (..),
    VerifyCommitResp (..),

    -- * Handlers
    mobileRevertDraftH,
    mobileRevertCreateH,
    mobileRevertDiffH,
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
import Products.Autopilot.Mobile.Github.Compare (CommitInfo (..), compareRefs, crCommits, crStatus, crTotalCommits, shortSha)
import Products.Autopilot.Mobile.Queries.AppCatalog (
    LatestBuildRow (..),
    fetchLatestBuildsForApp,
 )
import Products.Autopilot.Mobile.Queries.Tracker (
    appCatalogForRowRaw,
    fetchRevertCandidates,
    findMobileReleaseById,
    gitOwner,
    gitRepo,
    insertMobileRevertTracker,
    isReverted,
    logEvent,
 )
import Products.Autopilot.Mobile.RevertResolver (
    RevertCand (..),
    RollbackPlan (..),
    resolveRollback,
 )
import Products.Autopilot.Mobile.Types (
    MobileBuildContext (..),
    MobileBuildTargetState (..),
    MobileBuildWFStatus (..),
    isDebugBuildType,
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
    , rdTargetReleaseId :: Text
    -- ^ Release whose version users roll back TO (chosen by version order,
    -- not creation time). May differ from the build source below when that
    -- version has no SCC artifact.
    , rdTargetVersion :: Text
    -- ^ Version users roll back to (display). For a clean rollback this
    -- equals 'rdPrevGoodVersion'; for a rebuild-lower it is the higher,
    -- unbuildable version while 'rdPrevGoodVersion' is what we rebuild from.
    , rdBuildSourceKind :: Text
    -- ^ How the build source was resolved: @"tag"@ (target itself is
    -- buildable), @"rebuild_lower"@ (nearest lower version with a tag), or
    -- @"manual_required"@ (operator must supply a source commit).
    , rdWarnings :: [Text]
    -- ^ Operator-facing flags, e.g. @"target_has_no_artifact"@,
    -- @"manual_source_required"@.
    }
    deriving (Eq, Show, Generic)

instance ToJSON RevertDraft
instance FromJSON RevertDraft

{- | Project a raw 'CommitInfo' (from the GH Compare client) to the
FE-facing 'RevertCommit' shape. Drops fields the UI doesn't render.
-}
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

{- | Live commit diff between an arbitrary build source (the previous-good
tag, a custom commit SHA, or a branch) and the bad release. Powers the
"Commits being rolled back" list, which must react to the source the
operator actually selects — not just the draft's previous-good default.

@rdfCommits@ are the commits present in the bad release but NOT reachable
from the chosen source, i.e. the commits a rebuild from that source would
drop. Newest-first ordering is applied by the FE.
-}
data RevertDiffResp = RevertDiffResp
    { rdfCommits :: [RevertCommit]
    , rdfCommitCount :: Int
    , rdfBaseRef :: Text
    -- ^ The source we rebuild from (echoed back).
    , rdfHeadRef :: Text
    -- ^ The bad release ref we diff against (tag or commit SHA).
    , rdfStatus :: Text
    -- ^ GitHub compare status: @ahead@ / @behind@ / @identical@ / @diverged@.
    }
    deriving (Eq, Show, Generic)

instance ToJSON RevertDiffResp

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

-- ─── Diff handler ────────────────────────────────────────────────────

{- | Compute the commits being rolled back for a given build @source@
(previous-good tag, custom SHA, or branch) against the bad release. The
FE calls this whenever the operator changes the source, so the diff stays
in sync with the actual selection.
-}
mobileRevertDiffH :: AuthedPerson -> Text -> Text -> Flow RevertDiffResp
mobileRevertDiffH _ap releaseId' source = do
    let src = T.strip source
    when' (T.null src) $ BadRequest "source ref is required"

    mBad <- findMobileReleaseById releaseId'
    (bad, badState) <- case mBad of
        Just x -> pure x
        Nothing -> throwM $ BadRequest ("Mobile release not found: " <> releaseId')

    -- Diff against the bad release's tag if it has one, else its commit SHA.
    headRef <- case (badState >>= mbcTagPushed . mbContext, rtCommitSha bad) of
        (Just t, _) | not (T.null t) -> pure t
        (_, Just s) | not (T.null s) -> pure s
        _ -> throwM $ BadRequest "Bad release has no tag or commit to diff against."

    ac <- appCatalogForRowRaw bad
    creds <- loadGhCreds
    res <- compareRefs creds (gitOwner ac) (gitRepo ac) src headRef
    case res of
        Left e ->
            throwM $
                BadRequest
                    ( "GitHub compare failed for source "
                        <> src
                        <> ": "
                        <> e
                    )
        Right cr ->
            pure
                RevertDiffResp
                    { rdfCommits = map toRevertCommit (crCommits cr)
                    , rdfCommitCount = crTotalCommits cr
                    , rdfBaseRef = src
                    , rdfHeadRef = headRef
                    , rdfStatus = crStatus cr
                    }

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

    case badState >>= Just . mbcBuildType . mbContext of
        Just bt
            | isDebugBuildType bt ->
                throwM $
                    BadRequest "Debug builds (Firebase / TestFlight) cannot be reverted."
        _ -> pure ()

    -- A release created by a revert IS revertable (it is a real shipped
    -- build; the version-code floor prevents loops). What we block is
    -- reverting a release that has ALREADY been reverted, to avoid
    -- duplicate rollbacks of the same release.
    when' (isReverted bad) $
        BadRequest "This release has already been reverted. Create a new release instead."

    builds <- fetchLatestBuildsForApp (rtAppGroup bad) (rtService bad) (rtEnv bad)
    let buildMap =
            Map.fromList
                [ ((lbrAppGroup b, lbrSurface b, lbrPlatform b, lbrBuildType b), b)
                | b <- builds
                ]
        storeKey = (rtAppGroup bad, rtService bad, rtEnv bad, "release" :: Text)
        mStoreBuild = Map.lookup storeKey buildMap
        storeVersion = fmap lbrVersion mStoreBuild
        storeVersionCode = mStoreBuild >>= lbrVersionCode

    -- Revert ALWAYS rolls back to a strictly-lower good version (resolved by
    -- version order). Store-sync rows are reverted the same way — there is no
    -- "re-assert the latest build" path: if nothing below the bad version exists,
    -- the resolver returns NoPriorRelease and the revert is refused.
    draftForSCCRevert bad badState storeVersion storeVersionCode

draftForSCCRevert ::
    ReleaseTrackerT Identity ->
    Maybe MobileBuildTargetState ->
    Maybe Text ->
    Maybe Int32 ->
    Flow RevertDraft
draftForSCCRevert bad badState storeVersion storeVersionCode = do
    cands <- fetchRevertCandidates (rtAppGroup bad) (rtService bad) (rtEnv bad) (rtId bad)
    (target, mSource, srcKind, warnings) <-
        case resolveRollback (mkBadCand bad badState) cands of
            Rollback t s -> pure (t, Just s, "tag" :: Text, [] :: [Text])
            RebuildLower t s -> pure (t, Just s, "rebuild_lower", ["target_has_no_artifact"])
            NeedsManualSource t -> pure (t, Nothing, "manual_required", ["manual_source_required"])
            NoPriorRelease ->
                throwM $
                    BadRequest
                        ( "No good release below v"
                            <> rtNewVersion bad
                            <> " for this app — revert needs a lower version to roll back to. "
                            <> "Create a new release (optionally from a specific commit) instead."
                        )

    let badCode = badState >>= mbcVersionCode . mbContext
        badTagFromState = badState >>= mbcTagPushed . mbContext
        effectiveCode = maxCode badCode storeVersionCode
        suggestedCode = fmap (+ 1) effectiveCode
        suggestedVer = bumpPatch (rtNewVersion bad)
        mSrcTag = mSource >>= rcTag
        srcShort = shortSha (fromMaybe "" (mSource >>= rcCommitSha))

    -- A commit diff is only computable when we have both a buildable source
    -- tag and the bad release's tag. For a manual-source rollback (target has
    -- no artifact) we skip it and emit a templated note instead.
    (commits, changelog) <- case (mSrcTag, badTagFromState) of
        (Just srcTag, Just badTag)
            | not (T.null srcTag) && not (T.null badTag) -> do
                ac <- appCatalogForRowRaw bad
                creds <- loadGhCreds
                compareRes <- compareRefs creds (gitOwner ac) (gitRepo ac) srcTag badTag
                case compareRes of
                    Right cr ->
                        let cs = crCommits cr
                            cl =
                                renderRevertChangelog
                                    (rtNewVersion bad)
                                    (rcVersionName target)
                                    srcShort
                                    suggestedVer
                                    (fmap fromIntegral suggestedCode)
                                    cs
                         in pure (cs, cl)
                    Left e ->
                        throwM $
                            BadRequest
                                ( "GitHub compare failed: "
                                    <> e
                                    <> ". If the previous tag has been deleted, supply a source commit instead."
                                )
        _ ->
            pure
                ( []
                , "Roll back v"
                    <> rtNewVersion bad
                    <> " to v"
                    <> rcVersionName target
                    <> ( if srcKind == "manual_required"
                            then " — this version has no SCC build artifact; provide a source commit to rebuild from."
                            else ""
                       )
                )

    pure
        RevertDraft
            { rdBadReleaseId = rtId bad
            , rdBadVersion = rtNewVersion bad
            , rdBadVersionCode = badCode
            , rdPrevGoodReleaseId = maybe (rcId target) rcId mSource
            , rdPrevGoodVersion = maybe (rcVersionName target) rcVersionName mSource
            , rdPrevGoodShortSha = srcShort
            , rdPrevGoodTag = fromMaybe "" mSrcTag
            , rdSuggestedVersion = suggestedVer
            , rdSuggestedCode = suggestedCode
            , rdChangelog = changelog
            , rdCommits = map toRevertCommit commits
            , rdCommitCount = length commits
            , rdPlatform = rtEnv bad
            , rdIsStoreSyncRevert = rtMode bad == Just "STORE_SYNC"
            , rdStoreVersion = storeVersion
            , rdStoreVersionCode = storeVersionCode
            , rdTargetReleaseId = rcId target
            , rdTargetVersion = rcVersionName target
            , rdBuildSourceKind = srcKind
            , rdWarnings = warnings
            }

-- | Build the resolver's view of the bad release from its row + parsed state.
mkBadCand :: ReleaseTrackerT Identity -> Maybe MobileBuildTargetState -> RevertCand
mkBadCand bad badState =
    RevertCand
        { rcId = rtId bad
        , rcVersionName = rtNewVersion bad
        , rcVersionCode = badState >>= mbcVersionCode . mbContext
        , rcTag = badState >>= mbcTagPushed . mbContext
        , rcCommitSha = rtCommitSha bad
        , rcCreatedAt = rtCreatedAt bad
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

    case badState >>= Just . mbcBuildType . mbContext of
        Just bt
            | isDebugBuildType bt ->
                throwM $ BadRequest "Debug builds cannot be reverted."
        _ -> pure ()

    -- Revert-of-a-revert is allowed (a revert is a real shipped build); we
    -- only block re-reverting a release that has already been reverted.
    when' (isReverted bad) $
        BadRequest "This release has already been reverted. Create a new release instead."

    -- Resolve the build source by VERSION order (not creation time). The target
    -- is the highest good version STRICTLY BELOW the bad release — store-sync
    -- rows are reverted the same way (no "re-assert the latest build" path). If
    -- nothing lower exists, the revert is refused. May need an operator-supplied
    -- commit when the target version was never built by SCC. Re-resolved here
    -- rather than trusting the draft.
    cands <- fetchRevertCandidates (rtAppGroup bad) (rtService bad) (rtEnv bad) (rtId bad)
    (prevId, prevTag, manualNeeded) <-
        case resolveRollback (mkBadCand bad badState) cands of
            Rollback _ s -> pure (rcId s, fromMaybe "" (rcTag s), False)
            RebuildLower _ s -> pure (rcId s, fromMaybe "" (rcTag s), False)
            NeedsManualSource t -> pure (rcId t, "", True)
            NoPriorRelease ->
                throwM $
                    BadRequest
                        ( "No good release below v"
                            <> rtNewVersion bad
                            <> " for this app — revert needs a lower version to roll back to."
                        )

    -- When the rollback target has no SCC artifact, the operator MUST supply
    -- a source commit to rebuild from (resolved into sourceRefStr below).
    when' (manualNeeded && maybe True T.null rrSourceCommit) $
        BadRequest
            "This rollback target has no SCC build artifact; provide a source commit to rebuild from."

    when' (rrNewVersionName == rtNewVersion bad) $
        BadRequest "new version name must differ from bad release's"

    builds <- fetchLatestBuildsForApp (rtAppGroup bad) (rtService bad) (rtEnv bad)
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
    -- The revert build inherits the bad release's build type (debug already
    -- excluded above); default to release if its state is somehow unparseable.
    let buildTypeVal = maybe "release" (mbcBuildType . mbContext) badState
    let ctx =
            MobileBuildContext
                { mbcVersionCode = rrNewVersionCode
                , mbcChangeLog = rrChangelog
                , mbcBuildType = buildTypeVal
                , mbcReleaseGroupId = newId
                , mbcMatrixJobName = acName ac <> if isDebugBuildType buildTypeVal then "-Debug" else "-Release"
                , mbcOtaNamespace = Nothing
                , mbcTagPushed = Nothing
                , -- Inherit the bad release's store destination so a reverted
                  -- provider prod Android build re-targets the same place.
                  mbcDestination = badState >>= (mbcDestination . mbContext)
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
            , "prev_good" .= prevId
            , "prev_tag" .= prevTag
            , "new_version" .= rrNewVersionName
            , "new_version_code" .= rrNewVersionCode
            , "source_ref" .= sourceRefStr
            , "source_commit" .= rrSourceCommit
            , "is_store_sync_revert" .= (rtMode bad == Just "STORE_SYNC")
            ]
        )

    pure RevertResp{rrRevertReleaseId = newId}

-- ─── Internal helpers ──────────────────────────────────────────────

when' :: Bool -> APIError -> Flow ()
when' True err = throwM err
when' False _ = pure ()
