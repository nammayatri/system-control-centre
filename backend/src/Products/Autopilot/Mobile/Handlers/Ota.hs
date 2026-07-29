{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | OTA releases inside mobile releases
(docs\/OTA_MOBILE_RELEASE_INTEGRATION.md — the doc is the spec).

Push = dispatch the airborne CI workflow on the group's branch and track
expectation rows in @ota_push@, converged on GET (Decision A/D/E). Release
creation is the one composed mutation (Decision B): conflict preflight →
upstream create → link row → audit → optional ramp. Everything else about
releases is served by the airborne BFF, not here.

Build verbs are autopilot RBAC ('AP_MOBILE_DISPATCH'); release creation
checks airborne-ota grants per ref in-handler — no permission bridge.
-}
module Products.Autopilot.Mobile.Handlers.Ota (
    getGroupOtaH,
    dispatchOtaH,
    releaseOtaH,
    releaseOtaPackageH,
    cancelOtaPushH,
    otaPushJobsH,
    attachPackageH,
    resolveOtaProvenanceH,
    adoptOtaBranchH,
) where

import Control.Monad (forM, forM_, unless, void, when)
import Control.Monad.Catch (SomeException, catch, throwM)
import Control.Monad.IO.Class (liftIO)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import System.IO.Unsafe (unsafePerformIO)
import Core.AppError (APIError (..))
import Core.Auth.Protected (AuthedPerson (..), KnownPermission, requireDeploymentPermissionScopes)
import Core.Environment (Flow, logInfo, logWarning)
import Core.Http.Client qualified as Http
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson.Key qualified as AK
import Data.Aeson.KeyMap qualified as KM
import Data.List (find, nub, sortOn)
import Data.Ord (Down (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, listToMaybe, mapMaybe)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime, diffUTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Text.Read (readMaybe)
import Products.AirborneOta.Client (UpstreamResult (..), airborneRequest, expectOk)
import Products.AirborneOta.Queries (insertAirborneEvent)
import Products.AirborneOta.Types.Permission (OtaPermission (..))
import Products.Autopilot.Mobile.Github (
    CommitComparison (..),
    WorkflowDispatchReq (..),
    WorkflowRun (..),
    compareCommits,
    dispatchRunCandidates,
    dispatchWorkflow,
    findRunWithJob,
    jCompletedAt,
    jConclusion,
    jHtmlUrl,
    jName,
    jStartedAt,
    jStatus,
    jSteps,
    jsCompletedAt,
    jsConclusion,
    jsName,
    jsStartedAt,
    jsStatus,
    cancelRun,
    listJobs,
    listTagsWithShas,
    listWorkflowRuns,
    listWorkflowRunsForSha,
 )
import Products.Autopilot.Mobile.Github.Auth (GhAppCreds, loadGhCreds)
import Products.Autopilot.Mobile.Auth (requireAppPerm, requireAppPermAll)
import Products.Autopilot.Mobile.Queries.AppCatalog (appGrantKey, findAppByAirborneRef, listAppCatalog, listEnabledAppCatalog, normalizeAppSegment)
import Products.Autopilot.Types.Permission (AutopilotPermission (..))
import Products.Autopilot.Mobile.Queries.OtaPush
import Products.Autopilot.Mobile.Queries.StoreStatus (StoreCell (..), storeCellsForApp)
import Products.Autopilot.Mobile.Types (MobileBuildTargetState (..), isDebugBuildType, mbcBuildType)
import Products.Autopilot.Mobile.Types.Ota
import Products.Autopilot.Mobile.Types.Storage (AppCatalog, AppCatalogT (..))
import Products.Autopilot.Mobile.Workflow (tryAdvisoryLockShared)
import Products.Autopilot.Queries.ReleaseTracker (findReleaseTrackersByGroupId)
import Products.Autopilot.Types.Release qualified as Rel
import Products.Autopilot.Types.Target (TargetState (..))

-- ─── Constants & small helpers ─────────────────────────────────────

otaWorkflowFile :: Text
otaWorkflowFile = ".github/workflows/consumer-airborne-ota.yaml"

{- | SCC app_catalog name → catalyst.yaml matrix key. Identical except for
casing divergences; catalyst lookups are case-sensitive, so this map is
load-bearing for both @app_variants@ and matrix job names.
-}
catalystKey :: Text -> Text
catalystKey "BharatTaxi" = "bharatTaxi"
catalystKey n = n

-- | Matrix job name for one (app, platform): @"<catalystKey>-<Android|iOS>"@.
otaJobName :: Text -> Text -> Text
otaJobName app plat = catalystKey app <> "-" <> platLabel
  where
    platLabel = if plat == "ios" then "iOS" else "Android"

refParts :: Text -> (Text, Text)
refParts ref = case T.breakOn "~" ref of
    (o, rest) | not (T.null rest) -> (o, T.drop 1 rest)
    _ -> ("", ref)

scopeHdrs :: Text -> [(Text, Text)]
scopeHdrs ref = let (o, a) = refParts ref in [("x-organisation", o), ("x-application", a)]

{- | OTA permission on a ref, satisfied by the legacy per-ref airborne-ota
grant OR the unified per-app autopilot grant (@\<name\>\/\<platform\>@ via
app_catalog.airborne_app_ref).
-}
requireOtaPerm :: forall perm. (KnownPermission perm) => Proxy perm -> AuthedPerson -> Text -> Flow ()
requireOtaPerm proxy ap ref = do
    mApp <- findAppByAirborneRef ref
    let unified = [("autopilot", appGrantKey (acName a) (acPlatform a)) | Just a <- [mApp]]
    requireDeploymentPermissionScopes proxy ap (("airborne-ota", ref) : unified)

nsOf :: Text -> Text
nsOf = snd . refParts

runsBaseFor :: Text -> Text
runsBaseFor ownerRepo = "https://github.com/" <> ownerRepo <> "/actions/runs"

splitRepo :: Text -> (Text, Text)
splitRepo ownerRepo = case T.breakOn "/" ownerRepo of
    (o, rest) | not (T.null rest) -> (o, T.drop 1 rest)
    _ -> (ownerRepo, "")

-- JSON spelunking on opaque upstream bodies.
vKey :: Text -> Value -> Maybe Value
vKey k (Object o) = KM.lookup (AK.fromText k) o
vKey _ _ = Nothing

vText :: Value -> Maybe Text
vText (String t) = Just t
vText _ = Nothing

vInt :: Value -> Maybe Int
vInt (Number n) = Just (round n)
vInt _ = Nothing

vArr :: Value -> Maybe [Value]
vArr (Array xs) = Just (foldr (:) [] xs)
vArr _ = Nothing

-- | Releases array from the list endpoint (@data@, falling back to @releases@).
releasesOf :: Value -> [Value]
releasesOf body =
    fromMaybe [] $
        (vKey "data" body >>= vArr) `orElse` (vKey "releases" body >>= vArr)
  where
    orElse a b = maybe b Just a

-- | Packages array from the packages list (@packages@ falling back to @data@).
packagesOf :: Value -> [Value]
packagesOf body =
    fromMaybe [] $
        (vKey "packages" body >>= vArr) `orElse` (vKey "data" body >>= vArr)
  where
    orElse a b = maybe b Just a

-- | Targeting map of a release item/detail, normalized for set equality.
dimsOf :: Value -> Map.Map Text Value
dimsOf v = case vKey "dimensions" v of
    Just (Object o) -> Map.fromList [(AK.toText k, x) | (k, x) <- KM.toList o]
    _ -> Map.empty

-- | Release status lives under @experiment.status@ (top-level as fallback);
-- upstream casing varies, so normalize to upper.
statusOf :: Value -> Text
statusOf v =
    T.toUpper . fromMaybe "" $
        (vKey "experiment" v >>= vKey "status" >>= vText)
            `orElse` (vKey "status" v >>= vText)
  where
    orElse a b = maybe b Just a

-- ─── Group context assembly ────────────────────────────────────────

data GroupCtx = GroupCtx
    { gcMembers :: [(Rel.ReleaseTracker, Maybe TargetState)]
    , gcDebug :: Bool
    , gcSourceRef :: Maybe Text
    , gcCapable :: [(Rel.ReleaseTracker, AppCatalog)]
    }

loadGroupCtx :: Text -> Flow GroupCtx
loadGroupCtx gid = do
    rows <- findReleaseTrackersByGroupId gid
    when (null rows) $ throwM (NotFound ("release group not found: " <> gid))
    let members = [p | (_, _, p) <- rows]
        contexts = mapMaybe (\(_, mts) -> mts >>= mobileCtx) members
        debug = case contexts of
            (c : _) -> isDebugBuildType (mbcBuildType (mbContext c))
            [] -> False
        srcRef = listToMaybe (mapMaybe (Rel.sourceRef . fst) members)
    catalog <- listEnabledAppCatalog
    let capable =
            [ (rt, ac)
            | (rt, _) <- members
            , Just ac <-
                [ find
                    ( \a ->
                        acName a == Rel.appGroup rt
                            && acSurface a == Rel.service rt
                            && acPlatform a == Rel.env rt
                            && isJust (acAirborneAppRef a)
                    )
                    catalog
                ]
            ]
    pure GroupCtx{gcMembers = members, gcDebug = debug, gcSourceRef = srcRef, gcCapable = capable}
  where
    mobileCtx = \case
        MobileBuildState s -> Just s
        _ -> Nothing

{- | Distribution push gate (Part 2.2, widened 2026-07-24): pushable when the
build has (or is about to have) an install base — currently on a store track,
superseded (stragglers still run it; the straggler-hotfix case), or in store
review (pre-positioning a package is harmless: a version-targeted release
serves nobody until the build rolls). Returns (eligible, reason, superseded)
— the superseded flag drives the composer's version-targeting nudge.
-}
pushEligibility :: Rel.ReleaseTracker -> AppCatalog -> Flow (Bool, Maybe Text, Bool)
pushEligibility rt ac
    | Nothing <- Rel.sourceRef rt = pure (False, Just "imported from store — no source branch", False)
    | otherwise = do
        cells <- storeCellsForApp (acId ac)
        let versionMatches c = case (scCode c, Rel.versionCode rt) of
                (Just sc, Just vc) -> sc == vc
                _ -> scVersion c == Just (Rel.newVersion rt)
            servingProd c =
                scTrack c == "production"
                    && maybe False (`elem` (["live", "completed", "inProgress", "halted"] :: [Text])) (scStatus c)
            onInternal c = scTrack c `elem` (["internal", "testflight"] :: [Text])
            onStore = any (\c -> versionMatches c && (onInternal c || servingProd c)) cells
        (mRoll, mReview) <- getTrackerRolloutMeta (Rel.releaseId rt)
        let superseded = mRoll == Just "superseded"
            inReview = mReview `elem` ([Just "in_review", Just "submitted", Just "approved"] :: [Maybe Text])
        if onStore || superseded || inReview
            then pure (True, Nothing, superseded)
            else
                pure
                    ( False
                    , Just "build not distributed yet — push unlocks once it reaches a store track or review"
                    , False
                    )

capableAppsResp :: GroupCtx -> Flow [OtaCapableApp]
capableAppsResp ctx =
    forM (gcCapable ctx) $ \(rt, ac) -> do
        (elig, reason, sup) <- pushEligibility rt ac
        pure
            OtaCapableApp
                { appName = Rel.appGroup rt
                , platform = Rel.env rt
                , airborneAppRef = fromMaybe "" (acAirborneAppRef ac)
                , pushEligible = elig
                , ineligibleReason = reason
                , superseded = sup
                }

-- ─── GET /mobile/groups/:gid/ota ───────────────────────────────────

getGroupOtaH :: AuthedPerson -> Text -> Flow OtaGroupResp
getGroupOtaH _ap gid = do
    ctx <- loadGroupCtx gid
    if gcDebug ctx
        then
            pure
                OtaGroupResp
                    { available = False
                    , groupSourceRef = Nothing
                    , activePush = Nothing
                    , rows = []
                    , links = []
                    , capableApps = []
                    }
        else do
            -- Convergence is global (dispatch is globally serialized) and
            -- best-effort: the GET never fails on upstream trouble.
            convergeActiveOta
                `catch` \(e :: SomeException) ->
                    logWarning ("[OTA] convergence error (ignored): " <> T.pack (show e))
            -- Lazy provenance backfill — anchors (commit from the native tag
            -- ledger) then branches (from CI run records); both are BUILD
            -- concerns, not OTA ones, so every member row participates
            -- (provider apps, disabled apps included). Reload after writes so
            -- THIS response already carries the resolved facts.
            fullCatalog <- listAppCatalog
            let memberPairs c =
                    [ (rt, ac)
                    | (rt, _) <- gcMembers c
                    , Just ac <-
                        [ find
                            ( \a ->
                                acName a == Rel.appGroup rt
                                    && acSurface a == Rel.service rt
                                    && acPlatform a == Rel.env rt
                            )
                            fullCatalog
                        ]
                    ]
            wroteAnchor <-
                ( do
                    let anchorless = [(rt, ac) | (rt, ac) <- memberPairs ctx, Nothing <- [Rel.commitSha rt]]
                    if null anchorless
                        then pure False
                        else do
                            mCreds <- (Just <$> loadGhCreds) `catch` \(_ :: SomeException) -> pure Nothing
                            results <- forM anchorless $ \(rt, ac) -> resolveAnchor mCreds rt ac
                            pure (or [True | OtaProvAnchor (Just _) _ _ <- results])
                )
                    `catch` \(e :: SomeException) ->
                        False <$ logWarning ("[OTA] anchor recovery error (ignored): " <> T.pack (show e))
            ctxA <- if wroteAnchor then loadGroupCtx gid else pure ctx
            wroteBranch <-
                resolveMissingBranchesViaRuns (memberPairs ctxA)
                    `catch` \(e :: SomeException) ->
                        False <$ logWarning ("[OTA] branch resolution error (ignored): " <> T.pack (show e))
            ctx' <- if wroteBranch then loadGroupCtx gid else pure ctxA
            pushes <- listOtaPushesForGroup gid
            let refs = nub (mapMaybe (acAirborneAppRef . snd) (gcCapable ctx'))
                runsBase = runsBaseFor <$> listToMaybe (map (acGithubRepo . snd) (gcCapable ctx'))
            linkRows <- listLinksForRefs refs
            active <- findActivePush
            capable <- capableAppsResp ctx'
            pure
                OtaGroupResp
                    { available = not (null (gcCapable ctx'))
                    , groupSourceRef = gcSourceRef ctx'
                    , activePush =
                        ( \p ->
                            OtaActivePush
                                { groupId = opGroupId p
                                , dispatchedBy = opDispatchedBy p
                                , dispatchedAt = opDispatchedAt p
                                }
                        )
                            <$> active
                    , rows = map (pushToResp runsBase) pushes
                    , links = map linkToResp linkRows
                    , capableApps = capable
                    }

-- ─── Convergence (Decision A/D/E — GET-driven, no poller) ──────────

runLookupTimeout, runningStaleTimeout, dispatchSettle :: NominalDiffTime
runLookupTimeout = 15 * 60
runningStaleTimeout = 90 * 60
dispatchSettle = 30

convergeActiveOta :: Flow ()
convergeActiveOta = do
    activeRows <- listActivePushRows
    unresolved <- listUnresolvedPushes
    when (not (null activeRows) || not (null unresolved)) $ do
        catalog <- listEnabledAppCatalog
        let repoOf p =
                maybe "nammayatri/ny-react-native" acGithubRepo $
                    find (\a -> acName a == opAppName p && acSurface a == "customer" && acPlatform a == opPlatform p) catalog
        now <- liftIO getCurrentTime
        creds <- loadGhCreds
        let batches = Map.toList (Map.fromListWith (++) [(opDispatchBatchId p, [p]) | p <- activeRows])
        forM_ batches $ \(batchId, batchRows) ->
            convergeBatch creds now batchId batchRows (repoOf (head batchRows))
                `catch` \(e :: SomeException) ->
                    logWarning ("[OTA] batch " <> batchId <> " convergence error: " <> T.pack (show e))
        forM_ unresolved $ \p ->
            resolvePackageFor creds p (repoOf p)
                `catch` \(e :: SomeException) ->
                    logWarning ("[OTA] package resolution error for " <> opId p <> ": " <> T.pack (show e))

convergeBatch :: GhAppCreds -> UTCTime -> Text -> [OtaPush] -> Text -> Flow ()
convergeBatch creds now batchId batchRows ownerRepo = do
    let (owner, repo) = splitRepo ownerRepo
        dispatched = [p | p <- batchRows, opStatus p == "DISPATCHED"]
        running = [p | p <- batchRows, opStatus p == "RUNNING"]
        anchor = head batchRows
        age = diffUTCTime now (opDispatchedAt anchor)
    -- Phase 1: bind the batch to its CI run.
    when (not (null dispatched) && age > dispatchSettle) $ do
        eRuns <- listWorkflowRuns creds owner repo otaWorkflowFile
        case eRuns of
            Left err -> logWarning ("[OTA] listWorkflowRuns: " <> err)
            Right runs -> do
                let cands =
                        [ r
                        | r <- dispatchRunCandidates (opDispatchedAt anchor) runs
                        , maybe True (== opSourceRef anchor) (wrHeadBranch r)
                        ]
                mRun <- findRunWithJob creds owner repo (otaJobName (opAppName anchor) (opPlatform anchor)) cands
                case mRun of
                    Just r -> do
                        updateOtaPushRun batchId (wrId r) (wrHeadSha r)
                        logInfo ("[OTA] batch " <> batchId <> " bound to run " <> T.pack (show (wrId r)))
                    Nothing ->
                        when (age > runLookupTimeout) $
                            markBatchFailed batchId "run_lookup_timeout"
    -- Phase 2: track jobs of the bound run.
    when (age > runningStaleTimeout && not (null running)) $
        markBatchFailed batchId "stale (no completion after 90m)"
    forM_ (listToMaybe (mapMaybe opExternalRunId running)) $ \runId -> do
        eJobs <- listJobs creds owner repo (T.pack (show runId))
        case eJobs of
            Left err -> logWarning ("[OTA] listJobs: " <> err)
            Right jobs ->
                forM_ running $ \p ->
                    case find ((== otaJobName (opAppName p) (opPlatform p)) . jName) jobs of
                        Nothing -> pure () -- matrix still expanding
                        Just j
                            | jStatus j /= "completed" -> pure ()
                            | jConclusion j == Just "success" -> resolvePackageFor creds p ownerRepo
                            | jConclusion j == Just "cancelled" -> markOtaPushStatus (opId p) "FAILED" (Just "cancelled (superseded by a newer dispatch)")
                            | otherwise ->
                                markOtaPushStatus
                                    (opId p)
                                    "FAILED"
                                    (Just ("job " <> fromMaybe "failed" (jConclusion j)))

{- | Decision E: tag-correlated package resolution, baseline fallback.
On success the row goes BUNDLE_PUSHED with the resolved version; when only
the job succeeded but no package can be identified yet, the row still goes
BUNDLE_PUSHED with NULL package fields and is retried on later GETs.
-}
resolvePackageFor :: GhAppCreds -> OtaPush -> Text -> Flow ()
resolvePackageFor creds p ownerRepo = do
    let (owner, repo) = splitRepo ownerRepo
        ns = nsOf (opAirborneAppRef p)
        prefix = "ota/" <> ns <> "/"
    eTags <- listTagsWithShas creds owner repo prefix
    resolved <- case (eTags, opCommitSha p) of
        (Right tags, Just sha) -> do
            let vers =
                    [ T.drop (T.length prefix) name
                    | (name, target) <- tags
                    , target == sha
                    , prefix `T.isPrefixOf` name
                    ]
                -- a ".N" re-tag suffix means the package tag may be the base version.
                -- NEWEST version first: re-pushing the same commit mints another
                -- ota tag on the SAME sha, so listing order could resolve the
                -- push to the OLD package (v8 when CI just built v9).
                verKey = map (\seg -> fromMaybe (0 :: Int) (readMaybe (T.unpack seg))) . T.splitOn "."
                candidates =
                    sortOn (Down . verKey) (nub (concatMap (\v -> [v, dropRetagSuffix v]) vers))
            tryCandidates candidates
        _ -> pure Nothing
    case resolved of
        Just (pkgVersion, tagVersion) ->
            setResolvedPackage (opId p) pkgVersion (Just tagVersion) "tag"
        Nothing -> do
            mBaseline <- baselineFallback
            case mBaseline of
                Just pkgVersion -> setResolvedPackage (opId p) pkgVersion Nothing "baseline"
                Nothing ->
                    -- job succeeded; leave the row BUNDLE_PUSHED-with-null so
                    -- the attach verb / later GETs can finish the job.
                    when (opStatus p /= "BUNDLE_PUSHED") $
                        markOtaPushStatus (opId p) "BUNDLE_PUSHED" Nothing
  where
    hdrs = scopeHdrs (opAirborneAppRef p)
    tryCandidates [] = pure Nothing
    tryCandidates (v : vs) = do
        r <-
            (Just <$> (expectOk =<< airborneRequest Http.GET "/api/packages" hdrs [("package_key", Just ("tag:" <> v))] Nothing))
                `catch` \(_ :: SomeException) -> pure Nothing
        case r >>= vKey "version" >>= vInt of
            Just ver -> pure (Just (ver, v))
            Nothing -> tryCandidates vs
    dropRetagSuffix v = case T.breakOnEnd "." v of
        (base, suf)
            | not (T.null base)
            , T.all (`elem` ("0123456789" :: String)) suf ->
                T.dropEnd 1 base
        _ -> v
    baselineFallback = case opBaselinePackageVersion p of
        Nothing -> pure Nothing
        Just baseline -> do
            r <-
                (Just <$> (expectOk =<< airborneRequest Http.GET "/api/packages/list" hdrs [("page", Just "1"), ("count", Just "50")] Nothing))
                    `catch` \(_ :: SomeException) -> pure Nothing
            let versions = maybe [] (mapMaybe (\v -> vKey "version" v >>= vInt) . packagesOf) r
                newer = [v | v <- versions, v > baseline]
            pure $ if null newer then Nothing else Just (minimum newer)

-- ─── POST /mobile/groups/:gid/ota/dispatch ─────────────────────────

dispatchOtaH :: AuthedPerson -> Text -> OtaDispatchReq -> Flow OtaDispatchResp
dispatchOtaH ap gid OtaDispatchReq{versionBump = bump, apps = mApps, platforms = mPlats, notifySlack = mSlack, runner = mRunner} = do
    unless (bump `elem` (["patch", "minor", "major"] :: [Text])) $
        throwM (BadRequest "versionBump must be patch | minor | major")
    ctx <- loadGroupCtx gid
    when (gcDebug ctx) $ throwM (BadRequest "OTA is available for production groups only")
    srcRef <- maybe (throwM (BadRequest "group has no source branch")) pure (gcSourceRef ctx)
    when (null (gcCapable ctx)) $ throwM (BadRequest "no app in this group has an airborne mapping")
    -- Resolve targets: explicit selections must exist and be eligible.
    let wanted (rt, _) =
            maybe True (Rel.appGroup rt `elem`) mApps
                && maybe True (Rel.env rt `elem`) mPlats
        selected = filter wanted (gcCapable ctx)
    forM_ (fromMaybe [] mApps) $ \a ->
        unless (any (\(rt, _) -> Rel.appGroup rt == a) (gcCapable ctx)) $
            throwM (BadRequest ("app has no airborne mapping in this group: " <> a))
    when (null selected) $ throwM (BadRequest "selection matches no capable app")
    gated <- forM selected $ \(rt, ac) -> do
        (elig, reason, _) <- pushEligibility rt ac
        pure (rt, ac, elig, reason)
    let ineligible = [(rt, reason) | (rt, _, False, reason) <- gated]
    unless (null ineligible) $
        throwM . BadRequest $
            "not eligible for OTA push: "
                <> T.intercalate
                    "; "
                    [ Rel.appGroup rt <> "/" <> Rel.env rt <> " (" <> fromMaybe "not on store" r <> ")"
                    | (rt, r) <- ineligible
                    ]
    requireAppPermAll (Proxy @'AP_MOBILE_DISPATCH) ap [(Rel.appGroup rt, Rel.env rt) | (rt, _, True, _) <- gated]
    -- Global serialization (Decision D): advisory lock around check+insert+dispatch.
    gotLock <- tryAdvisoryLockShared "ota-dispatch"
    unless gotLock $ throwM (Conflict "another OTA dispatch is being processed — retry in a moment")
    active <- findActivePush
    forM_ active $ \p ->
        throwM . Conflict $
            "an OTA push is already active (group "
                <> opGroupId p
                <> ", by "
                <> opDispatchedBy p
                <> ") — wait for it to finish or abandon it"
    -- Best-effort per-namespace baseline watermark (NULL only disables the fallback resolver).
    targets <- forM [(rt, ac) | (rt, ac, True, _) <- gated] $ \(rt, ac) -> do
        let ref = fromMaybe "" (acAirborneAppRef ac)
        baseline <-
            ( do
                    body <- expectOk =<< airborneRequest Http.GET "/api/packages/list" (scopeHdrs ref) [("page", Just "1"), ("count", Just "50")] Nothing
                    let versions = mapMaybe (\v -> vKey "version" v >>= vInt) (packagesOf body)
                    pure (if null versions then Just 0 else Just (maximum versions))
                )
                `catch` \(_ :: SomeException) -> pure Nothing
        pure (Rel.appGroup rt, Rel.env rt, ref, baseline)
    -- Runner comes from the UI selector; absent/empty falls back to ios-debug
    -- (the UI always sends one — the fallback covers bare API calls).
    let runnerPool = case mRunner >>= (\r -> if T.null (T.strip r) then Nothing else Just (T.strip r)) of
            Just r -> r
            Nothing -> "ios-debug"
    batchId <- liftIO (UUID.toText <$> UUID.nextRandom)
    inserted <- insertOtaPushes gid srcRef batchId "Production" bump (apEmail ap) targets
    -- CI inputs mirror consumer-airborne-ota.yaml verbatim (values are strings on the wire).
    let appVariants = T.intercalate "," (nub [catalystKey a | (a, _, _, _) <- targets])
        plats = nub [p | (_, p, _, _) <- targets]
        platform = case plats of
            ["android"] -> "android"
            ["ios"] -> "ios"
            _ -> "both"
        inputs =
            KM.fromList
                [ ("platform", String platform)
                , ("app_variants", String appVariants)
                , ("env", String "Production")
                , ("version_bump", String bump)
                , ("notify_slack", String (if fromMaybe True mSlack then "true" else "false"))
                , ("runner", String runnerPool)
                ]
    let ownerRepo = fromMaybe "nammayatri/ny-react-native" (listToMaybe [acGithubRepo ac | (_, ac) <- selected])
        (owner, repo) = splitRepo ownerRepo
    creds <- loadGhCreds
    eDispatch0 <- dispatchWorkflow creds owner repo otaWorkflowFile (WorkflowDispatchReq srcRef inputs)
    -- GH validates inputs against the workflow file AT THE DISPATCHED REF —
    -- release branches carrying an older consumer-airborne-ota.yaml may not
    -- declare `runner` yet. On that exact 422, retry once without it (the
    -- workflow's own default runner applies).
    eDispatch <- case eDispatch0 of
        Left err
            | "Unexpected inputs" `T.isInfixOf` err && "runner" `T.isInfixOf` err -> do
                logWarning ("[OTA] " <> srcRef <> " workflow predates the runner input — retrying without it")
                dispatchWorkflow creds owner repo otaWorkflowFile (WorkflowDispatchReq srcRef (KM.delete "runner" inputs))
        other -> pure other
    case eDispatch of
        Left err -> do
            markBatchFailed batchId ("dispatch failed: " <> err)
            throwM (InternalError ("OTA workflow dispatch failed: " <> err))
        Right () -> do
            logInfo ("[OTA] dispatched " <> appVariants <> " (" <> platform <> ") on " <> srcRef <> " batch " <> batchId)
            pure
                OtaDispatchResp
                    { dispatched = length inserted
                    , rows = map (pushToResp (Just (runsBaseFor ownerRepo))) inserted
                    }

-- ─── POST /mobile/ota/pushes/:pushId/release ───────────────────────
-- ─── Release creation (shared core; push-born and package-born) ────

{- | Everything after "which package, for which build": RBAC on the ref,
first-release handling, exact-set conflict preflight, dashboard-parity
compose, create, link row (with provenance), audit, optional ramp.
-}
composeReleaseCore ::
    AuthedPerson ->
    Text -> -- airborne ref
    Text -> -- mobile release group id
    Maybe Text -> -- source_ref provenance for the link
    Maybe Text -> -- push id (Nothing = package-born)
    Int -> -- package version
    OtaReleaseReq ->
    Flow OtaReleaseResp
composeReleaseCore ap ref gid mSrcRef mPushId pkgVersion OtaReleaseReq{dimensions = mDims, initialTrafficPercent = mTraffic, config = mCfg, lazyFiles = mLazy} = do
    let hdrs = scopeHdrs ref
        traffic = fromMaybe 0 mTraffic
    unless (traffic >= 0 && traffic <= 50) $
        throwM (BadRequest "initialTrafficPercent must be between 0 and 50 (100% only via conclude)")
    -- Release-side RBAC: legacy per-ref grant OR unified per-app grant.
    requireOtaPerm (Proxy @'OTA_VIEW) ap ref
    requireOtaPerm (Proxy @'OTA_RELEASE_CREATE) ap ref
    when (traffic > 0) $ requireOtaPerm (Proxy @'OTA_RELEASE_RAMP) ap ref
    -- Live release history: first-release detection + conflict preflight.
    listBody <-
        expectOk
            =<< airborneRequest Http.GET "/api/releases/list" hdrs [("page", Just "1"), ("count", Just "100")] Nothing
    let releases = releasesOf listBody
        firstRelease = null releases
        reqDims = maybe Map.empty (Map.filter (/= Null)) mDims
    when (firstRelease && not (Map.null reqDims)) $
        throwM (BadRequest "the first release for an app must be untargeted (bootstrap release)")
    when (firstRelease && traffic > 0) $
        throwM (BadRequest "the first release auto-concludes upstream; initial traffic is not applicable")
    let ongoing = [r | r <- releases, statusOf r `elem` (["CREATED", "INPROGRESS"] :: [Text])]
        conflicting = [r | r <- ongoing, dimsOf r == reqDims]
    unless (null conflicting) $ do
        payload <- forM conflicting $ \r -> do
            let rid = fromMaybe "" (vKey "id" r >>= vText)
            mLink <- findLinkByRef ref rid
            pure
                OtaOngoingRelease
                    { airborneReleaseId = rid
                    , status = statusOf r
                    , packageVersion =
                        (vKey "experiment" r >>= vKey "package_version" >>= vInt)
                            `orElseM` (vKey "package" r >>= vKey "version" >>= vInt)
                    , trafficPercentage = vKey "experiment" r >>= vKey "traffic_percentage" >>= vInt
                    , dimensions = vKey "dimensions" r
                    , link = linkToResp <$> mLink
                    }
        throwM
            ( ConflictWithPayload
                "ONGOING_RELEASE_EXISTS"
                "an ongoing release already targets this exact dimension set"
                (object ["ongoing" .= payload])
            )
    -- Compose the create body from the package detail (dashboard-parity shape).
    pkgBody <-
        expectOk
            =<< airborneRequest Http.GET "/api/packages" hdrs [("package_key", Just ("version:" <> tshow pkgVersion))] Nothing
    let allFiles = maybe [] (mapMaybe vText) (vKey "files" pkgBody >>= vArr)
        lazySet = fromMaybe [] mLazy
        important = [f | f <- allFiles, f `notElem` lazySet]
        cfgBoot = fromMaybe 0 (mCfg >>= \c -> cfgBootTimeout c)
        cfgRct = fromMaybe 0 (mCfg >>= \c -> cfgReleaseConfigTimeout c)
        mProps = mCfg >>= cfgProperties
        createBody =
            object $
                [ "config"
                    .= object
                        ( [ "boot_timeout" .= cfgBoot
                          , "release_config_timeout" .= cfgRct
                          ]
                            <> maybe [] (\props -> ["properties" .= props]) mProps
                        )
                , "package_id" .= ("version:" <> tshow pkgVersion)
                , "package" .= object ["important" .= important, "lazy" .= lazySet]
                ]
                    <> (["dimensions" .= reqDims | not (Map.null reqDims)])
    createRes <- airborneRequest Http.POST "/api/releases" hdrs [] (Just createBody)
    insertAirborneEvent (apEmail ap) ref "RELEASE_CREATE" "/api/releases" (Just createBody) (urStatus createRes) (urRequestId createRes)
    created <- expectOkMappingConflict createRes
    releaseId <-
        maybe (throwM (InternalError "airborne create returned no release id")) pure (vKey "id" created >>= vText)
    void $
        insertOtaReleaseLink
            mPushId
            ref
            releaseId
            pkgVersion
            (if Map.null reqDims then Nothing else Just (toJSON reqDims))
            (apEmail ap)
            gid
            mSrcRef
    linkRow <-
        findLinkByRef ref releaseId
            >>= maybe (throwM (InternalError "link row missing after insert")) pure
    -- Optional initial ramp; a failure here is recoverable via the inline verb.
    rampedOk <-
        if traffic > 0 && not firstRelease
            then do
                let rampBody =
                        object
                            [ "traffic_percentage" .= traffic
                            , "change_reason" .= ("via SCC mobile release " <> gid <> " by " <> apEmail ap)
                            ]
                    rampPath = "/api/releases/" <> releaseId <> "/ramp"
                r <- airborneRequest Http.POST rampPath hdrs [] (Just rampBody)
                insertAirborneEvent (apEmail ap) ref "RAMP" rampPath (Just rampBody) (urStatus r) (urRequestId r)
                if urStatus r < 400
                    then pure True
                    else do
                        logWarning ("[OTA] post-create ramp failed (" <> T.pack (show (urStatus r)) <> ") for release " <> releaseId)
                        pure False
            else pure False
    pure
        OtaReleaseResp
            { released = True
            , ramped = rampedOk
            , airborneReleaseId = releaseId
            , link = linkToResp linkRow
            , firstRelease = if firstRelease then Just True else Nothing
            }
  where
    tshow = T.pack . show
    orElseM a b = maybe b Just a
    cfgBootTimeout (OtaReleaseConfig bt _ _) = bt
    cfgReleaseConfigTimeout (OtaReleaseConfig _ rct _) = rct
    cfgProperties (OtaReleaseConfig _ _ pr) = pr
    -- The preflight races upstream state; if the create still hits the
    -- exact-set guard, upstream answers a generic 400/AB_005 whose message we
    -- match as a backstop and convert to the same 409 shape (minus detail).
    expectOkMappingConflict r
        | urStatus r == 400
        , Just msg <- vKey "message" (urBody r) >>= vText
        , "already an ongoing release" `T.isInfixOf` msg =
            throwM
                ( ConflictWithPayload
                    "ONGOING_RELEASE_EXISTS"
                    msg
                    (object ["ongoing" .= ([] :: [Value])])
                )
        | otherwise = expectOk r

-- | Push-born release: the push row supplies package + provenance.
releaseOtaH :: AuthedPerson -> Text -> OtaReleaseReq -> Flow OtaReleaseResp
releaseOtaH ap pid req = do
    p <- findOtaPushById pid >>= maybe (throwM (NotFound "OTA push not found")) pure
    when (opStatus p /= "BUNDLE_PUSHED") $
        throwM (BadRequest ("push is " <> opStatus p <> ", not BUNDLE_PUSHED"))
    pkgVersion <-
        maybe (throwM (BadRequest "push has no resolved package — use attach-package first")) pure (opPackageVersion p)
    composeReleaseCore ap (opAirborneAppRef p) (opGroupId p) (Just (opSourceRef p)) (Just pid) pkgVersion req

{- | Package-born release (no push row): allowed ONLY when git proves the
package's commit is this build's commit or a descendant of it (§11b) — the
same lineage the badges show. Anything else is refused with the relation.
-}
releaseOtaPackageH :: AuthedPerson -> Text -> OtaPackageReleaseReq -> Flow OtaReleaseResp
releaseOtaPackageH ap gid OtaPackageReleaseReq{airborneAppRef = reqRef, packageVersion = pkgVersion, packageTag = mTag, dimensions = mDims, initialTrafficPercent = mTraffic, config = mCfg, lazyFiles = mLazy} = do
    ctx <- loadGroupCtx gid
    (rt, ac) <-
        maybe (throwM (NotFound ("no app with airborne ref " <> reqRef <> " in this group"))) pure $
            find (\(_, a) -> acAirborneAppRef a == Just reqRef) (gcCapable ctx)
    mCreds <- (Just <$> loadGhCreds) `catch` \(_ :: SomeException) -> pure Nothing
    anchorRes <- resolveAnchor mCreds rt ac
    base <-
        maybe
            (throwM (BadRequest "this build has no anchor commit — package lineage cannot be verified"))
            pure
            ((\(OtaProvAnchor s _ _) -> s) anchorRes)
    let ownerRepo = acGithubRepo ac
    -- Package commit: SCC push log → mem cache → one tag listing.
    pushShas <- findPushCommitsByRefVersions reqRef [pkgVersion]
    mPkgSha <- case pushShas of
        ((_, sha) : _) -> pure (Just sha)
        [] -> do
            cached <- cacheGet pkgShaCacheRef (reqRef, pkgVersion)
            case cached of
                Just (_, mSha) -> pure mSha
                Nothing -> case (mCreds, mTag) of
                    (Just creds, Just t) -> do
                        let (owner, repo) = splitRepo ownerRepo
                            otaPrefix = "ota/" <> nsOf reqRef <> "/"
                        eTags <- listTagsWithShas creds owner repo otaPrefix
                        case eTags of
                            Left err -> do
                                logWarning ("[OTA] tag listing failed: " <> err)
                                pure Nothing
                            Right tags -> do
                                let exact = otaPrefix <> t
                                    retag = exact <> "."
                                    hit =
                                        lookup exact tags
                                            `orElseM` listToMaybe [sha | (n, sha) <- tags, retag `T.isPrefixOf` n]
                                cachePut pkgShaCacheRef (reqRef, pkgVersion) (Just exact, hit)
                                pure hit
                    _ -> pure Nothing
    pkgSha <-
        maybe
            (throwM (BadRequest ("package v" <> tshow pkgVersion <> " has no identifiable source commit — release it from the Airborne product instead")))
            pure
            mPkgSha
    (relation, _, _) <- ancestryFor mCreds ownerRepo base pkgSha
    unless (relation `elem` (["identical", "ahead"] :: [Text])) $
        throwM
            ( BadRequest
                ("package v" <> tshow pkgVersion <> " is '" <> relation <> "' relative to this build — only this-build packages (identical/ahead) are releasable here")
            )
    composeReleaseCore
        ap
        reqRef
        gid
        (Rel.sourceRef rt)
        Nothing
        pkgVersion
        OtaReleaseReq{dimensions = mDims, initialTrafficPercent = mTraffic, config = mCfg, lazyFiles = mLazy}
  where
    tshow = T.pack . show
    orElseM a b = maybe b Just a


-- ─── POST /mobile/ota/pushes/:pushId/cancel ────────────────────────

{- | Cancel a stuck\/unwanted push: best-effort cancels the bound GitHub run,
then marks the row FAILED — which releases the per-group dispatch lock. A
run-cancel failure (run already finished, creds unavailable) must not keep
the queue locked, so it's logged and ignored.
-}
cancelOtaPushH :: AuthedPerson -> Text -> Flow OtaPushResp
cancelOtaPushH ap pid = do
    p <- findOtaPushById pid >>= maybe (throwM (NotFound "OTA push not found")) pure
    requireAppPerm (Proxy @'AP_MOBILE_DISPATCH) ap (opAppName p) (opPlatform p)
    when (opStatus p `elem` (["BUNDLE_PUSHED", "FAILED"] :: [Text])) $
        throwM (BadRequest "push is already terminal")
    forM_ (opExternalRunId p) $ \runId ->
        ( do
            catalog <- listAppCatalog
            let ownerRepo =
                    maybe "nammayatri/ny-react-native" acGithubRepo $
                        find (\a -> acName a == opAppName p && acPlatform a == opPlatform p) catalog
                (owner, repo) = splitRepo ownerRepo
            creds <- loadGhCreds
            res <- cancelRun creds owner repo (T.pack (show runId))
            case res of
                Left err -> logWarning ("[OTA] cancelRun failed (ignored): " <> err)
                Right () -> logInfo ("[OTA] cancelled CI run " <> T.pack (show runId) <> " for push " <> pid)
        )
            `catch` \(e :: SomeException) ->
                logWarning ("[OTA] cancelRun error (ignored): " <> T.pack (show e))
    markOtaPushStatus pid "FAILED" (Just ("cancelled by " <> apEmail ap))
    p' <- findOtaPushById pid >>= maybe (throwM (NotFound "OTA push not found")) pure
    pure (pushToResp Nothing p')

-- ─── GET /mobile/ota/pushes/:pushId/jobs ───────────────────────────

{- | The push's CI run matrix, proxied live from GitHub — build progress
without leaving SCC. Read-only; the frontend polls it while the push is
DISPATCHED\/RUNNING.
-}
otaPushJobsH :: AuthedPerson -> Text -> Flow OtaRunJobsResp
otaPushJobsH _ap pid = do
    p <- findOtaPushById pid >>= maybe (throwM (NotFound "OTA push not found")) pure
    runId <- maybe (throwM (BadRequest "push has no CI run resolved yet")) pure (opExternalRunId p)
    catalog <- listAppCatalog
    let ownerRepo =
            maybe "nammayatri/ny-react-native" acGithubRepo $
                find (\a -> acName a == opAppName p && acPlatform a == opPlatform p) catalog
        (owner, repo) = splitRepo ownerRepo
    creds <- loadGhCreds
    eJobs <- listJobs creds owner repo (T.pack (show runId))
    case eJobs of
        Left err -> throwM (InternalError ("job listing failed: " <> err))
        Right jobs ->
            pure $
                OtaRunJobsResp
                    [ OtaRunJob
                        { name = jName j
                        , status = jStatus j
                        , conclusion = jConclusion j
                        , htmlUrl = jHtmlUrl j
                        , startedAt = jStartedAt j
                        , completedAt = jCompletedAt j
                        , steps =
                            [ OtaRunStep
                                { name = jsName s
                                , status = jsStatus s
                                , conclusion = jsConclusion s
                                , startedAt = jsStartedAt s
                                , completedAt = jsCompletedAt s
                                }
                            | s <- jSteps j
                            ]
                        }
                    | j <- jobs
                    ]

-- ─── POST /mobile/ota/pushes/:pushId/attach-package ────────────────

attachPackageH :: AuthedPerson -> Text -> OtaAttachReq -> Flow OtaPushResp
attachPackageH ap pid (OtaAttachReq pkgVersion) = do
    p <- findOtaPushById pid >>= maybe (throwM (NotFound "OTA push not found")) pure
    requireAppPerm (Proxy @'AP_MOBILE_DISPATCH) ap (opAppName p) (opPlatform p)
    let hdrs = scopeHdrs (opAirborneAppRef p)
    -- Validate against the live package list before trusting the operator.
    body <-
        expectOk
            =<< airborneRequest Http.GET "/api/packages" hdrs [("package_key", Just ("version:" <> T.pack (show pkgVersion)))] Nothing
    case vKey "version" body >>= vInt of
        Just v | v == pkgVersion -> pure ()
        _ -> throwM (BadRequest ("package version " <> T.pack (show pkgVersion) <> " not found upstream"))
    setResolvedPackage pid pkgVersion Nothing "manual"
    logInfo ("[OTA] " <> apEmail ap <> " attached package v" <> T.pack (show pkgVersion) <> " to push " <> pid)
    p' <- findOtaPushById pid >>= maybe (throwM (NotFound "OTA push not found")) pure
    pure (pushToResp Nothing p')


-- ─── Provenance (git-tag ledger, doc §11b) ─────────────────────────
--
-- No provenance tables: durable facts live in EXISTING columns
-- (release_tracker.commit_sha / source_ref, ota_push.commit_sha); everything
-- derivable from git is derived on demand and held in process-local caches —
-- both shas of an ancestry pair are immutable, so entries never invalidate.

{-# NOINLINE pkgShaCacheRef #-}

-- | (appRef, packageVersion) → (repoTag, commitSha). Negative results are
-- cached too (Nothing sha) — retried only after a restart, when a late tag
-- could have appeared.
pkgShaCacheRef :: IORef (Map.Map (Text, Int) (Maybe Text, Maybe Text))
pkgShaCacheRef = unsafePerformIO (newIORef Map.empty)

{-# NOINLINE ancestryCacheRef #-}

-- | (repo, baseSha, headSha) → (relation, aheadBy, behindBy). Immutable pair.
ancestryCacheRef :: IORef (Map.Map (Text, Text, Text) (Text, Maybe Int, Maybe Int))
ancestryCacheRef = unsafePerformIO (newIORef Map.empty)

{-# NOINLINE anchorNegCacheRef #-}

-- | Release ids whose native-tag anchor lookup came up empty this process.
anchorNegCacheRef :: IORef (Map.Map Text ())
anchorNegCacheRef = unsafePerformIO (newIORef Map.empty)

{-# NOINLINE branchRunCacheRef #-}

{- | (repo, workflowPath, sha) → run-derived branch verdict. @Just b@ = the
sha's build runs unanimously name branch b; @Nothing@ = no runs or
disagreeing branches (retried only after a restart — a late run for an old
sha is not a thing). Run facts are immutable, so entries never invalidate.
-}
branchRunCacheRef :: IORef (Map.Map (Text, Text, Text) (Maybe Text))
branchRunCacheRef = unsafePerformIO (newIORef Map.empty)

cacheGet :: (Ord k) => IORef (Map.Map k v) -> k -> Flow (Maybe v)
cacheGet ref k = Map.lookup k <$> liftIO (readIORef ref)

cachePut :: (Ord k) => IORef (Map.Map k v) -> k -> v -> Flow ()
cachePut ref k v = liftIO (atomicModifyIORef' ref (\m -> (Map.insert k v m, ())))

{- | Tier-1 branch resolution (§11b follow-up): a build's workflow run
records @head_branch@ — the branch the build was ACTUALLY created from, not
a containment guess. For every capable row with an anchor commit but no
source_ref, look up the app's own workflow runs for that exact sha; when
every run agrees on one branch, backfill @release_tracker.source_ref@
(NULL-only). No runs / disagreeing runs (a same-sha rebuild off another
branch) → leave NULL for the human picker. Returns True if anything was
written, so the caller can reload the group view.
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

-- | Ancestry of @headSha@ relative to @base@ — cached forever (immutable pair).
ancestryFor :: Maybe GhAppCreds -> Text -> Text -> Text -> Flow (Text, Maybe Int, Maybe Int)
ancestryFor mCreds ownerRepo base headSha
    | base == headSha = pure ("identical", Nothing, Nothing)
    | otherwise = do
        cached <- cacheGet ancestryCacheRef (ownerRepo, base, headSha)
        case (cached, mCreds) of
            (Just v, _) -> pure v
            (Nothing, Nothing) -> pure unknown
            (Nothing, Just creds) -> do
                let (owner, repo) = splitRepo ownerRepo
                eCmp <- compareCommits creds owner repo base headSha
                case eCmp of
                    Left err -> do
                        logWarning ("[OTA] compare failed: " <> err)
                        pure unknown -- transient: not cached
                    Right cc -> do
                        let v = (ccStatus cc, Just (ccAheadBy cc), Just (ccBehindBy cc))
                        cachePut ancestryCacheRef (ownerRepo, base, headSha) v
                        pure v
  where
    unknown = ("unknown", Nothing, Nothing)

resolveOtaProvenanceH :: AuthedPerson -> Text -> OtaProvReq -> Flow OtaProvResp
resolveOtaProvenanceH _ap gid OtaProvReq{airborneAppRef = reqRef, packages = reqPkgs} = do
    ctx <- loadGroupCtx gid
    (rt, ac) <-
        maybe (throwM (NotFound ("no app with airborne ref " <> reqRef <> " in this group"))) pure $
            find (\(_, a) -> acAirborneAppRef a == Just reqRef) (gcCapable ctx)
    mCreds <- (Just <$> loadGhCreds) `catch` \(_ :: SomeException) -> pure Nothing
    anchorRes <- resolveAnchor mCreds rt ac
    let ownerRepo = acGithubRepo ac
        versions = [v | OtaProvPkgReq{version = v} <- reqPkgs]
    -- Package commits: SCC's own push log first (free), then the mem cache,
    -- then ONE tag listing for whatever is still unknown.
    pushShas <- Map.fromListWith (\_new old -> old) <$> findPushCommitsByRefVersions reqRef versions
    memHits <-
        Map.fromList . mapMaybe (\(k, mv) -> (,) k <$> mv)
            <$> mapM (\v -> (,) v <$> cacheGet pkgShaCacheRef (reqRef, v)) versions
    let known v = Map.member v pushShas || Map.member v memHits
        missing = [p | p@OtaProvPkgReq{version = v} <- reqPkgs, not (known v)]
        ns = nsOf reqRef
        otaPrefix = "ota/" <> ns <> "/"
    freshMap <- case (missing, mCreds) of
        ([], _) -> pure Map.empty
        (_, Nothing) -> pure Map.empty
        (_, Just creds) -> do
            eTags <- listTagsWithShas creds (fst (splitRepo ownerRepo)) (snd (splitRepo ownerRepo)) otaPrefix
            case eTags of
                Left err -> do
                    logWarning ("[OTA] package tag listing failed: " <> err)
                    pure Map.empty
                Right tags -> do
                    entries <- forM missing $ \OtaProvPkgReq{version = v, tag = mTag} -> do
                        let resolved = case mTag of
                                Nothing -> (Nothing, Nothing)
                                Just t ->
                                    let exact = otaPrefix <> t
                                        retag = exact <> "."
                                     in case lookup exact tags of
                                            Just sha -> (Just exact, Just sha)
                                            Nothing -> case [(n, sha) | (n, sha) <- tags, retag `T.isPrefixOf` n] of
                                                ((n, sha) : _) -> (Just n, Just sha)
                                                [] -> (Nothing, Nothing)
                        cachePut pkgShaCacheRef (reqRef, v) resolved
                        pure (v, resolved)
                    pure (Map.fromList entries)
    pkgResps <- forM reqPkgs $ \OtaProvPkgReq{version = v} -> do
        let (repoTag, pkgSha) = case Map.lookup v pushShas of
                Just sha -> (Nothing, Just sha)
                Nothing -> fromMaybe (Nothing, Nothing) (Map.lookup v memHits `orElseM` Map.lookup v freshMap)
        (relation, aheadN, behindN) <- case (anchorCommit anchorRes, pkgSha) of
            (Just base, Just h) -> ancestryFor mCreds ownerRepo base h
            _ -> pure ("unknown", Nothing, Nothing)
        pure
            OtaProvPkgResp
                { packageVersion = v
                , commitSha = pkgSha
                , repoTag = repoTag
                , relation = relation
                , aheadBy = aheadN
                , behindBy = behindN
                }
    pure OtaProvResp{anchor = anchorRes, packages = pkgResps}
  where
    orElseM a b = maybe b Just a
    anchorCommit (OtaProvAnchor s _ _) = s

{- | Record the USER's branch pick on a row with no source_ref (store-sync).
Server-side re-validates containment before writing — the pick must be true,
not just picked. NULL-only write; SCC-built rows are never rewritten.
-}
adoptOtaBranchH :: AuthedPerson -> Text -> OtaAdoptBranchReq -> Flow OtaProvAnchor
adoptOtaBranchH ap gid OtaAdoptBranchReq{airborneAppRef = reqRef, branch = pick, acknowledgeMismatch = mAck} = do
    ctx <- loadGroupCtx gid
    (rt, ac) <-
        maybe (throwM (NotFound ("no app with airborne ref " <> reqRef <> " in this group"))) pure $
            find (\(_, a) -> acAirborneAppRef a == Just reqRef) (gcCapable ctx)
    requireAppPerm (Proxy @'AP_MOBILE_APP_MANAGE) ap (acName ac) (acPlatform ac)
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
