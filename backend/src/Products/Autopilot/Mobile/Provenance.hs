{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | Build provenance — common to every mobile build, OTA or not.

The anchor (which commit was this native binary cut from?) and the source
branch are properties of the BUILD, not of the OTA subsystem: SCC-built rows
carry both; store-observed rows recover the commit from the native tag ledger
and let a user adopt a branch (verified against that commit). This module owns
that logic; @Handlers.Ota@ reuses it for its group-scoped provenance verdicts.

Release-scoped API (no group / airborne prerequisites):
  * @GET  \/mobile\/releases\/:id\/provenance@  — resolve (and NULL-only
    backfill) the anchor commit for any mobile build row.
  * @POST \/mobile\/releases\/:id\/adopt-branch@ — record a user's branch pick
    on a row with no source_ref, verified for containment of the anchor.
-}
module Products.Autopilot.Mobile.Provenance (
    ReleaseAdoptBranchReq (..),
    ReleaseProvResp (..),
    releaseProvenanceH,
    adoptReleaseBranchH,
    resolveAnchor,
    resolveMissingBranchesViaRuns,
    verifyAndAdoptBranch,
    splitRepo,
    cacheGet,
    cachePut,
    ancestryCacheRef,
    anchorNegCacheRef,
) where

import Control.Monad (forM, unless, when)
import Control.Monad.Catch (SomeException, catch, throwM)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (FromJSON, ToJSON (..), defaultOptions, genericToJSON, object, omitNothingFields, (.=))
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.List (maximumBy, nub)
import Data.Ord (comparing)
import Data.Maybe (isJust, mapMaybe)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Text.Read (readMaybe)
import System.IO.Unsafe (unsafePerformIO)

import Core.AppError (APIError (..))
import Core.Auth.Protected (AuthedPerson (..))
import Core.Environment (Flow, logInfo, logWarning)
import Products.Autopilot.Mobile.Auth (requireAppPerm)
import Products.Autopilot.Mobile.Github (
    CommitComparison (..),
    WorkflowRun (..),
    compareCommits,
    listTagsWithShas,
    listWorkflowRunsForSha,
 )
import Products.Autopilot.Mobile.Github.Auth (GhAppCreds, loadGhCreds)
import Products.Autopilot.Mobile.Queries.AppCatalog (normalizeAppSegment)
import Products.Autopilot.Mobile.Queries.OtaPush (backfillTrackerCommitSha, setTrackerSourceRef)
import Products.Autopilot.Mobile.Queries.Tracker (appCatalogForRowRaw, findMobileReleaseById, rowToDomain)
import Products.Autopilot.Mobile.Types.Ota (OtaProvAnchor (..))
import Products.Autopilot.Mobile.Types.Storage (AppCatalog, AppCatalogT (..))
import Products.Autopilot.Types.Permission (AutopilotPermission (..))
import Products.Autopilot.Types.Release qualified as Rel

data ReleaseAdoptBranchReq = ReleaseAdoptBranchReq
    { branch :: Text
    , acknowledgeMismatch :: Maybe Bool
    -- ^ True = the user saw the "branch does not contain the build commit"
    -- warning and adopted anyway (legit after a squash-merge).
    }
    deriving (Show, Generic)

instance FromJSON ReleaseAdoptBranchReq

{- | Release-level provenance: the anchor fields plus the PREVIOUS build's tag
from the ledger (highest strictly below this build — Android by code, iOS by
version-then-code). Store-sync rows use it as the changelog base:
@previousTag → this build's tag@ is "what shipped in this build".
-}
data ReleaseProvResp = ReleaseProvResp
    { commitSha :: Maybe Text
    , sourceRef :: Maybe Text
    , resolvedVia :: Text
    , previousTag :: Maybe Text
    }
    deriving (Show, Generic)

instance ToJSON ReleaseProvResp where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}

splitRepo :: Text -> (Text, Text)
splitRepo ownerRepo = case T.breakOn "/" ownerRepo of
    (o, rest) | not (T.null rest) -> (o, T.drop 1 rest)
    _ -> (ownerRepo, "")

{-# NOINLINE ancestryCacheRef #-}

-- | (repo, baseSha, headSha) → (relation, aheadBy, behindBy). Immutable pair.
ancestryCacheRef :: IORef (Map.Map (Text, Text, Text) (Text, Maybe Int, Maybe Int))
ancestryCacheRef = unsafePerformIO (newIORef Map.empty)

{-# NOINLINE anchorNegCacheRef #-}

-- | Release ids whose native-tag anchor lookup came up empty this process.
anchorNegCacheRef :: IORef (Map.Map Text ())
anchorNegCacheRef = unsafePerformIO (newIORef Map.empty)

cacheGet :: (Ord k) => IORef (Map.Map k v) -> k -> Flow (Maybe v)
cacheGet ref k = Map.lookup k <$> liftIO (readIORef ref)

cachePut :: (Ord k) => IORef (Map.Map k v) -> k -> v -> Flow ()
cachePut ref k v = liftIO (atomicModifyIORef' ref (\m -> (Map.insert k v m, ())))

{-# NOINLINE branchRunCacheRef #-}

{- | (repo, workflowPath, sha) → run-derived branch verdict. @Just b@ = the
sha's build runs unanimously name branch b; @Nothing@ = no runs or
disagreeing branches (retried only after a restart — a late run for an old
sha is not a thing). Run facts are immutable, so entries never invalidate.
-}
branchRunCacheRef :: IORef (Map.Map (Text, Text, Text) (Maybe Text))
branchRunCacheRef = unsafePerformIO (newIORef Map.empty)

{-# NOINLINE prevTagCacheRef #-}

-- | releaseId → previous-build-tag verdict (immutable once computed: only
-- NEWER tags are ever added). Negative results retried after a restart.
prevTagCacheRef :: IORef (Map.Map Text (Maybe Text))
prevTagCacheRef = unsafePerformIO (newIORef Map.empty)

-- | Dotted numeric version key ("3.3.107" → [3,3,107]); non-numeric parts → 0.
verKey :: Text -> [Int]
verKey = map (\pt -> maybe 0 id (readMaybe (T.unpack pt))) . T.splitOn "."

{- | The PREVIOUS build's tag from the native tag ledger: the highest tag
strictly below THIS build's identity — Android by version code alone (the
Play-enforced order), iOS by version-then-code (build numbers reset per
version). Nothing when the row has no code, the ledger has nothing below, or
tag names don't parse.
-}
resolvePreviousTag :: GhAppCreds -> Rel.ReleaseTracker -> AppCatalog -> Flow (Maybe Text)
resolvePreviousTag creds rt ac = case Rel.versionCode rt of
    Nothing -> pure Nothing
    Just myCode -> do
        cached <- cacheGet prevTagCacheRef (Rel.releaseId rt)
        case cached of
            Just verdict -> pure verdict
            Nothing -> do
                let (owner, repo) = splitRepo (acGithubRepo ac)
                    isDriver = acSurface ac == "driver"
                    prefix
                        | isDriver = acName ac <> "-v"
                        | otherwise = normalizeAppSegment (acName ac) <> "/prod/" <> acPlatform ac <> "/v"
                eTags <- listTagsWithShas creds owner repo prefix
                case eTags of
                    -- Transient: not cached, retried on the next call.
                    Left err -> Nothing <$ logWarning ("[PROV] previous-tag listing failed: " <> err)
                    Right tags -> do
                        let parse (n, _) = do
                                rest <- T.stripPrefix prefix n
                                let (verT, codeT)
                                        | isDriver = let (a, b) = T.breakOnEnd "-" rest in (T.dropEnd 1 a, b)
                                        | otherwise = let (a, b) = T.breakOn "+" rest in (a, T.drop 1 b)
                                code <- readMaybe (T.unpack codeT)
                                pure (verKey verT, code :: Int, n)
                            cands = mapMaybe parse tags
                            myC = fromIntegral myCode :: Int
                            myKey = verKey (Rel.newVersion rt)
                            below
                                | acPlatform ac == "android" = [c | c@(_, code, _) <- cands, code < myC]
                                | otherwise = [c | c@(vk, code, _) <- cands, (vk, code) < (myKey, myC)]
                            order
                                | acPlatform ac == "android" = comparing (\(_, code, _) -> code)
                                | otherwise = comparing (\(vk, code, _) -> (vk, code))
                            verdict = case below of
                                [] -> Nothing
                                _ -> (\(_, _, n) -> Just n) (maximumBy order below)
                        cachePut prevTagCacheRef (Rel.releaseId rt) verdict
                        pure verdict

{- | Tier-1 branch resolution (§11b follow-up): a build's workflow run
records @head_branch@ — the branch the build was ACTUALLY created from, not
a containment guess. For every row with an anchor commit but no source_ref,
look up the app's own workflow runs for that exact sha; when every run agrees
on one branch, backfill @release_tracker.source_ref@ (NULL-only). No runs /
disagreeing runs (a same-sha rebuild off another branch) → leave NULL for the
human picker. Returns True if anything was written.
-}
resolveMissingBranchesViaRuns :: [(Rel.ReleaseTracker, AppCatalog)] -> Flow Bool
resolveMissingBranchesViaRuns pairs = do
    let targets =
            [ (rt, ac, sha)
            | (rt, ac) <- pairs
            , Nothing <- [Rel.sourceRef rt]
            , Just sha <- [Rel.commitSha rt]
            ]
    if null targets
        then pure False
        else do
            mCreds <- (Just <$> loadGhCreds) `catch` \(_ :: SomeException) -> pure Nothing
            case mCreds of
                Nothing -> pure False
                Just creds -> or <$> forM targets (resolveOne creds)
  where
    resolveOne :: GhAppCreds -> (Rel.ReleaseTracker, AppCatalog, Text) -> Flow Bool
    resolveOne creds (rt, ac, sha) = do
        let key = (acGithubRepo ac, acWorkflowPath ac, sha)
        cached <- cacheGet branchRunCacheRef key
        case cached of
            Just verdict -> writeVerdict rt verdict
            Nothing -> do
                let (owner, repo) = splitRepo (acGithubRepo ac)
                eRuns <- listWorkflowRunsForSha creds owner repo (acWorkflowPath ac) sha
                case eRuns of
                    -- Transient upstream trouble: no cache entry, retried next GET.
                    Left err -> False <$ logWarning ("[OTA] branch-run lookup failed for " <> sha <> ": " <> err)
                    Right runs -> do
                        let branches = nub (mapMaybe wrHeadBranch runs)
                        verdict <- case branches of
                            [b] -> pure (Just b)
                            [] -> Nothing <$ logInfo ("[OTA] no build runs recorded for " <> sha <> " — branch stays unresolved")
                            bs ->
                                Nothing
                                    <$ logInfo
                                        ("[OTA] ambiguous build branches for " <> sha <> " (" <> T.intercalate ", " bs <> ") — leaving to the picker")
                        cachePut branchRunCacheRef key verdict
                        writeVerdict rt verdict
    writeVerdict _ Nothing = pure False
    writeVerdict rt (Just b) = do
        ok <- setTrackerSourceRef (Rel.releaseId rt) b
        when ok $
            logInfo ("[OTA] source_ref auto-resolved via CI run: " <> Rel.appGroup rt <> "/" <> Rel.env rt <> " ← " <> b)
        pure ok

{- | The build anchor: which commit was this row's native binary cut from?
SCC-built rows carry it already; store-sync rows recover it ONCE from the
native tag ledger — consumer (@\<seg\>\/prod\/\<platform\>\/v\<ver\>+\<code\>@)
or provider (@\<App\>-v\<ver\>-\<code\>@) — and backfill the column, the lazy
half of §11b (no bulk job needed).
-}
resolveAnchor :: Maybe GhAppCreds -> Rel.ReleaseTracker -> AppCatalog -> Flow OtaProvAnchor
resolveAnchor mCreds rt ac = case Rel.commitSha rt of
    Just sha -> pure (OtaProvAnchor (Just sha) (Rel.sourceRef rt) "scc")
    Nothing -> do
        neg <- cacheGet anchorNegCacheRef (Rel.releaseId rt)
        case (neg, mCreds) of
            (Just _, _) -> pure noAnchor
            (_, Nothing) -> pure noAnchor
            (Nothing, Just creds) -> do
                -- Consumer tags: <seg>/prod/<platform>/v<ver>+<code>;
                -- provider tags: <AppName>-v<ver>-<code>.
                let (owner, repo) = splitRepo (acGithubRepo ac)
                    isDriver = acSurface ac == "driver"
                    prefix
                        | isDriver = acName ac <> "-v" <> Rel.newVersion rt <> "-"
                        | otherwise =
                            normalizeAppSegment (acName ac)
                                <> "/prod/"
                                <> acPlatform ac
                                <> "/v"
                                <> Rel.newVersion rt
                eTags <- listTagsWithShas creds owner repo prefix
                case eTags of
                    Left err -> do
                        logWarning ("[OTA] anchor tag lookup failed: " <> err)
                        pure noAnchor -- transient: NOT negative-cached
                    Right tags -> do
                        let coded
                                | isDriver = [(n, sha) | (n, sha) <- tags, prefix `T.isPrefixOf` n]
                                | otherwise = [(n, sha) | (n, sha) <- tags, n == prefix || (prefix <> "+") `T.isPrefixOf` n]
                            exactName c
                                | isDriver = prefix <> T.pack (show c)
                                | otherwise = prefix <> "+" <> T.pack (show c)
                            hit = case Rel.versionCode rt of
                                Just c -> lookup (exactName c) coded
                                -- code unknown: highest code wins (selectBuildTag rule)
                                Nothing -> case coded of
                                    [] -> Nothing
                                    _ -> Just (snd (last coded))
                        case hit of
                            Just sha -> do
                                backfillTrackerCommitSha (Rel.releaseId rt) sha
                                logInfo ("[OTA] anchored " <> Rel.appGroup rt <> "/" <> Rel.env rt <> " v" <> Rel.newVersion rt <> " @ " <> T.take 9 sha)
                                pure (OtaProvAnchor (Just sha) (Rel.sourceRef rt) "native-tag")
                            Nothing -> do
                                cachePut anchorNegCacheRef (Rel.releaseId rt) ()
                                pure noAnchor
  where
    noAnchor = OtaProvAnchor Nothing (Rel.sourceRef rt) "none"

{- | Resolve the anchor for ONE mobile build row — group- and OTA-free. The
resolve NULL-only backfills @commit_sha@, so the GitHub tag lookup runs at
most once per row; afterwards the row itself carries the sha.
-}
releaseProvenanceH :: AuthedPerson -> Text -> Flow ReleaseProvResp
releaseProvenanceH _ap rid = do
    mRel <- findMobileReleaseById rid
    (row, _) <- maybe (throwM (NotFound ("Mobile release not found: " <> rid))) pure mRel
    ac <- appCatalogForRowRaw row
    mCreds <- (Just <$> loadGhCreds) `catch` \(_ :: SomeException) -> pure Nothing
    OtaProvAnchor mSha mRef via <- resolveAnchor mCreds (rowToDomain row) ac
    -- Tier-1 branch resolution: with a commit but no branch, the build's own
    -- CI run names the branch (head_branch) — NULL-only backfilled, so both
    -- fields land in one page-open round trip.
    mRef' <- case (mSha, mRef) of
        (Just sha, Nothing) -> do
            let rt' = (rowToDomain row){Rel.commitSha = Just sha}
            wrote <- resolveMissingBranchesViaRuns [(rt', ac)]
            if wrote
                then do
                    mFresh <- findMobileReleaseById rid
                    pure ((\(r, _) -> Rel.sourceRef (rowToDomain r)) =<< mFresh)
                else pure mRef
        _ -> pure mRef
    prev <- case mCreds of
        Just creds -> resolvePreviousTag creds (rowToDomain row) ac
        Nothing -> pure Nothing
    pure ReleaseProvResp{commitSha = mSha, sourceRef = mRef', resolvedVia = via, previousTag = prev}



{- | Record the USER's branch pick on a row with no source_ref. Server-side
re-validates containment of the anchor commit before writing — the pick must
be true, not just picked. NULL-only write; SCC-built rows are never rewritten.
-}
adoptReleaseBranchH :: AuthedPerson -> Text -> ReleaseAdoptBranchReq -> Flow OtaProvAnchor
adoptReleaseBranchH ap rid ReleaseAdoptBranchReq{branch = pick, acknowledgeMismatch = mAck} = do
    mRel <- findMobileReleaseById rid
    (row, _) <- maybe (throwM (NotFound ("Mobile release not found: " <> rid))) pure mRel
    ac <- appCatalogForRowRaw row
    requireAppPerm (Proxy @'AP_MOBILE_APP_MANAGE) ap (acName ac) (acPlatform ac)
    verifyAndAdoptBranch ap (rowToDomain row) ac pick mAck

{- | Shared adopt core (release- and OTA-scoped routes): resolve the anchor,
verify the picked branch contains it, write source_ref. No anchor commit ⇒
refuse — an unverifiable pick is never silently recorded.
-}
verifyAndAdoptBranch :: AuthedPerson -> Rel.ReleaseTracker -> AppCatalog -> Text -> Maybe Bool -> Flow OtaProvAnchor
verifyAndAdoptBranch ap rt ac pick mAck = do
    when (isJust (Rel.sourceRef rt)) $
        throwM (BadRequest "row already has a source branch")
    mCreds <- (Just <$> loadGhCreds) `catch` \(_ :: SomeException) -> pure Nothing
    creds <- maybe (throwM (InternalError "GitHub credentials unavailable")) pure mCreds
    anchorRes <- resolveAnchor mCreds rt ac
    base <-
        maybe (throwM (BadRequest "no anchor commit for this build — cannot validate the branch")) pure $
            (\(OtaProvAnchor s _ _) -> s) anchorRes
    let (owner, repo) = splitRepo (acGithubRepo ac)
    -- Branch heads move: validate against the name directly, uncached.
    eCmp <- compareCommits creds owner repo base pick
    let contained cc = ccStatus cc `elem` (["identical", "ahead"] :: [Text])
        ack = mAck == Just True
        adopt warned = do
            ok <- setTrackerSourceRef (Rel.releaseId rt) pick
            unless ok $ throwM (Conflict "source branch was set concurrently — reload")
            (if warned then logWarning else logInfo) $
                "[OTA] "
                    <> apEmail ap
                    <> " adopted branch "
                    <> pick
                    <> " for "
                    <> Rel.appGroup rt
                    <> "/"
                    <> Rel.env rt
                    <> (if warned then " DESPITE the branch not containing the build commit" else "")
            pure (OtaProvAnchor (Just base) (Just pick) "adopted")
    case eCmp of
        Left err -> throwM (BadRequest ("cannot validate branch " <> pick <> ": " <> err))
        Right cc
            | contained cc -> adopt False
            -- Acknowledged mismatch: legitimate after a squash-merge (the
            -- original sha survives on no branch) — the user owns the call.
            | ack -> adopt True
            | otherwise ->
                throwM
                    ( ConflictWithPayload
                        "BRANCH_NOT_CONTAINING"
                        ("branch " <> pick <> " does not contain this build's commit — likely squash-merged, or the wrong branch")
                        (object ["relation" .= ccStatus cc, "aheadBy" .= ccAheadBy cc, "behindBy" .= ccBehindBy cc])
                    )
