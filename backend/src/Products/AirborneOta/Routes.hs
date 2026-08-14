{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

{- | Airborne OTA proxy routes. The app list is driven live off airborne (no
local mapping table): each per-app handler splits the URL @:app@ composite ref
@\<org\>~\<app\>@ into the @x-organisation@/@x-application@ pair via 'resolveApp'
(in-process, no DB), enforces app-level RBAC with 'requireDeploymentPermission'
(the URL's app segment is enforced server-side, never just filtered in the UI),
then forwards to airborne_server with the bot token. Mutations are audited into
airborne_events with the SCC actor, and the actor is stamped into
Superposition's change_reason upstream.
-}
module Products.AirborneOta.Routes (AirborneAPI, airborneServer) where

import Control.Monad (unless)
import Control.Monad.Catch (SomeException, catch, throwM)
import Core.AppError (APIError (..))
import Core.Auth.Protected (AuthedPerson (..), KnownPermission, Protected, requireDeploymentPermissionScopes)
import Core.Auth.Queries (computeEffectivePermissions, computeEffectivePermissionsForAppGroups, findPersonById)
import Core.Auth.Types (ProductAccess (..))
import Core.Config (airborneAnalyticsUrl)
import Core.Environment (Flow, getConfig, logWarning)
import Core.Http.Client qualified as Http
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types qualified as AT
import Data.List (find, nub)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.HTTP.Types.URI (urlEncode)
import Products.AirborneOta.Client (
    KeepaliveOutcome (..),
    UpstreamResult (..),
    airborneConfigured,
    airborneRequest,
    analyticsRequest,
    expectOk,
    fetchUpstreamApps,
    readKeepalive,
 )
import Products.AirborneOta.Chime (chimeConfigured)
import Products.AirborneOta.Queries (AirborneEventRow (..), insertAirborneEvent, listAirborneEvents)
import Products.AirborneOta.Types (AppRef (..), ConcludeReq (..), CreateAppReq (..), RampReq (..))
import Products.AirborneOta.Types.Permission (OtaPermission (..))
import Products.Autopilot.Mobile.Queries.AppCatalog (appGrantKey, findAppByAirborneRef, listAppCatalog)
import Products.Autopilot.Mobile.Types.Storage (AppCatalogT (..))
import Products.Types (allPermissionsText)
import Servant

-- Literal segments ("health", "access", "apps") are declared before the
-- Capture "app" routes — Servant tries alternatives in order. The @:app@
-- segment is the composite ref @\<org\>~\<app\>@ (no local slug; refs always
-- contain '~', so they never collide with the literals).
type AirborneAPI =
    "airborne" :> Protected 'OTA_VIEW :> "health" :> Get '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_VIEW :> "access" :> Get '[JSON] Value
        -- Full upstream app list, for admins granting scoped access to others.
        :<|> "airborne" :> Protected 'OTA_APP_MANAGE :> "apps" :> Get '[JSON] Value
        -- Org-scoped upstream (allow_app=false): gated by a PRODUCT-level
        -- OTA_APP_MANAGE check, never the per-app deployment fallback.
        :<|> "airborne" :> Protected 'OTA_APP_MANAGE :> "apps" :> "create" :> ReqBody '[JSON] CreateAppReq :> Post '[JSON] Value
        -- (Chime fleet campaigns moved to the mobile product —
        -- /mobile/apps/:appId/chime/*, "Products.Autopilot.Mobile.Handlers.Chime".)
        :<|> "airborne" :> Protected 'OTA_VIEW :> Capture "app" Text :> "releases" :> QueryParam "page" Int :> QueryParam "count" Int :> QueryParam "status" Text :> Header "x-dimension" Text :> Get '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_VIEW :> Capture "app" Text :> "releases" :> Capture "releaseId" Text :> Get '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_RELEASE_RAMP :> Capture "app" Text :> "releases" :> Capture "releaseId" Text :> "ramp" :> ReqBody '[JSON] RampReq :> Post '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_RELEASE_CONCLUDE :> Capture "app" Text :> "releases" :> Capture "releaseId" Text :> "conclude" :> ReqBody '[JSON] ConcludeReq :> Post '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_RELEASE_DISCARD :> Capture "app" Text :> "releases" :> Capture "releaseId" Text :> "discard" :> Post '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_VIEW :> Capture "app" Text :> "packages" :> QueryParam "page" Int :> QueryParam "count" Int :> QueryParam "search" Text :> Get '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_VIEW :> Capture "app" Text :> "files" :> QueryParam "page" Int :> QueryParam "count" Int :> QueryParam "search" Text :> QueryParam "tag" Text :> Get '[JSON] Value
        -- Files grouped by path with their version history + the distinct tag
        -- list — what the airborne dashboard's Files page is built on.
        :<|> "airborne" :> Protected 'OTA_VIEW :> Capture "app" Text :> "files" :> "groups" :> QueryParam "page" Int :> QueryParam "count" Int :> QueryParam "search" Text :> QueryParam "tags" Text :> Get '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_VIEW :> Capture "app" Text :> "files" :> "tags" :> QueryParam "page" Int :> QueryParam "count" Int :> Get '[JSON] Value
        -- Phase 2 create flows: bodies are Value passthroughs of airborne's own
        -- request shapes (CreateReleaseRequest / CreatePackageInput / FileRequest),
        -- gated by product permissions + audited SCC-side.
        :<|> "airborne" :> Protected 'OTA_RELEASE_CREATE :> Capture "app" Text :> "releases" :> "create" :> ReqBody '[JSON] Value :> Post '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_RELEASE_CREATE :> Capture "app" Text :> "releases" :> Capture "releaseId" Text :> "update" :> ReqBody '[JSON] Value :> Put '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_VIEW :> Capture "app" Text :> "serve-config" :> Header "x-dimension" Text :> Get '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_PACKAGE_MANAGE :> Capture "app" Text :> "packages" :> "create" :> ReqBody '[JSON] Value :> Post '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_VIEW :> Capture "app" Text :> "packages" :> "detail" :> QueryParam "package_key" Text :> Get '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_FILE_MANAGE :> Capture "app" Text :> "files" :> "create" :> ReqBody '[JSON] Value :> Post '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_FILE_MANAGE :> Capture "app" Text :> "files" :> "tag" :> Capture "fileKey" Text :> ReqBody '[JSON] Value :> Post '[JSON] Value
        -- Phase 3 targeting & config: dimensions, cohorts, properties schema,
        -- release views. Reads are OTA_VIEW; every mutation is OTA_CONFIG_MANAGE.
        :<|> "airborne" :> Protected 'OTA_VIEW :> Capture "app" Text :> "dimensions" :> QueryParam "page" Int :> QueryParam "count" Int :> Get '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_CONFIG_MANAGE :> Capture "app" Text :> "dimensions" :> "create" :> ReqBody '[JSON] Value :> Post '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_CONFIG_MANAGE :> Capture "app" Text :> "dimensions" :> Capture "dimension" Text :> ReqBody '[JSON] Value :> Put '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_VIEW :> Capture "app" Text :> "dimensions" :> Capture "dimension" Text :> "cohort" :> Get '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_CONFIG_MANAGE :> Capture "app" Text :> "dimensions" :> Capture "dimension" Text :> "cohort" :> "checkpoint" :> ReqBody '[JSON] Value :> Post '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_CONFIG_MANAGE :> Capture "app" Text :> "dimensions" :> Capture "dimension" Text :> "cohort" :> "group" :> ReqBody '[JSON] Value :> Post '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_VIEW :> Capture "app" Text :> "dimensions" :> Capture "dimension" Text :> "cohort" :> "priority" :> Get '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_CONFIG_MANAGE :> Capture "app" Text :> "dimensions" :> Capture "dimension" Text :> "cohort" :> "priority" :> ReqBody '[JSON] Value :> Put '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_VIEW :> Capture "app" Text :> "properties" :> "schema" :> Header "x-dimension" Text :> Get '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_CONFIG_MANAGE :> Capture "app" Text :> "properties" :> "schema" :> ReqBody '[JSON] Value :> Put '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_VIEW :> Capture "app" Text :> "properties" :> "list" :> Header "x-dimension" Text :> Get '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_VIEW :> Capture "app" Text :> "views" :> QueryParam "page" Int :> QueryParam "count" Int :> Get '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_CONFIG_MANAGE :> Capture "app" Text :> "views" :> "create" :> ReqBody '[JSON] Value :> Post '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_CONFIG_MANAGE :> Capture "app" Text :> "views" :> Capture "viewId" Text :> ReqBody '[JSON] Value :> Put '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_CONFIG_MANAGE :> Capture "app" Text :> "views" :> Capture "viewId" Text :> Delete '[JSON] Value
        -- Phase 4 analytics: proxied to the SEPARATE unauthenticated analytics host
        -- (org/app as query params, no PAT). All reads, OTA_VIEW, not audited.
        :<|> "airborne" :> Protected 'OTA_VIEW :> Capture "app" Text :> "analytics" :> "adoption" :> QueryParam "interval" Text :> QueryParam "start_date" Text :> QueryParam "end_date" Text :> QueryParam "date" Text :> QueryParam "release_id" Text :> Get '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_VIEW :> Capture "app" Text :> "analytics" :> "versions" :> QueryParam "days" Int :> Get '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_VIEW :> Capture "app" Text :> "analytics" :> "active-devices" :> QueryParam "days" Int :> Get '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_VIEW :> Capture "app" Text :> "analytics" :> "failures" :> QueryParam "days" Int :> QueryParam "release_id" Text :> Get '[JSON] Value
        :<|> "airborne" :> Protected 'OTA_VIEW :> Capture "app" Text :> "analytics" :> "performance" :> QueryParam "days" Int :> QueryParam "release_id" Text :> Get '[JSON] Value
        -- SCC's own audit trail for this app (airborne_events). Upstream has
        -- no per-actor trail for most mutations, so this IS the attribution.
        :<|> "airborne" :> Protected 'OTA_VIEW :> Capture "app" Text :> "events" :> QueryParam "page" Int :> QueryParam "count" Int :> QueryParam "action" Text :> Get '[JSON] Value

airborneServer :: ServerT AirborneAPI Flow
airborneServer =
    healthH
        :<|> accessH
        :<|> listAllAppsH
        :<|> createAppH
        :<|> listReleasesH
        :<|> getReleaseH
        :<|> rampH
        :<|> concludeH
        :<|> discardH
        :<|> listPackagesH
        :<|> listFilesH
        :<|> listFileGroupsH
        :<|> listFileTagsH
        :<|> createReleaseH
        :<|> updateReleaseH
        :<|> serveConfigH
        :<|> createPackageH
        :<|> getPackageH
        :<|> createFileH
        :<|> updateFileTagH
        :<|> listDimensionsH
        :<|> createDimensionH
        :<|> updateDimensionH
        :<|> getCohortH
        :<|> createCheckpointH
        :<|> createGroupH
        :<|> getCohortPriorityH
        :<|> updateCohortPriorityH
        :<|> getPropertiesSchemaH
        :<|> putPropertiesSchemaH
        :<|> listPropertiesH
        :<|> listViewsH
        :<|> createViewH
        :<|> updateViewH
        :<|> deleteViewH
        :<|> analyticsAdoptionH
        :<|> analyticsVersionsH
        :<|> analyticsActiveDevicesH
        :<|> analyticsFailuresH
        :<|> analyticsPerformanceH
        :<|> listEventsH

-- ─── Health ────────────────────────────────────────────────────────

{- | Never throws — every probe is folded into the body so the status banner
can name the actual cause in one round-trip. @status@ is:

* @not-configured@ — PAT secrets unset (a setup state, NOT an outage)
* @down@ — the control plane could not be reached
* @degraded@ — the host answers but the authenticated path is broken
  (dying PAT / Keycloak / airborne DB), which the shallow ping cannot see
* @ok@ — both probes pass

Two upstream probes, deliberately layered. Airborne's @\/api\/health@ is a
STATIC 200 from a handler holding no app state (@main.rs:457-463@): it proves
the process is listening and nothing more — Postgres, Keycloak and
Superposition can all be down while it stays green. @deep@ therefore probes
@\/api\/users@ (the app list the proxy already uses), which exercises PAT mint
+ Keycloak JWKS + airborne's DB + authz in one call. The cheap ping is kept
because it is the only signal that still works with no credentials.
-}
healthH :: AuthedPerson -> Flow Value
healthH _ap = do
    configured <- airborneConfigured
    ePing <- tryProbe (expectOk =<< airborneRequest Http.GET "/api/health" [] [] Nothing)
    -- Only worth probing when credentials exist; without them it can only
    -- restate "not configured".
    eDeep <-
        if configured
            then Just <$> tryProbe (fetchUpstreamApps >> pure Null)
            else pure Nothing
    analytics <- probeAnalyticsHealth
    keepalive <- keepaliveStatus
    -- Chime is presence-only here (no upstream probe): the FE uses it to gate
    -- the fleet-campaign UI ("key missing" card vs live card).
    chime <- (\c -> object ["configured" .= c]) <$> chimeConfigured
    let pingOk = either (const False) (const True) ePing
        deepOk = maybe False (either (const False) (const True)) eDeep
        status :: Text
        status
            | not configured = "not-configured"
            | not pingOk = "down"
            | not deepOk = "degraded"
            | otherwise = "ok"
    pure $
        object
            [ "status" .= status
            , "configured" .= configured
            , "upstream" .= either (const Null) id ePing
            , "upstreamError" .= either Just (const Nothing) ePing
            , "deep" .= object ["checked" .= configured, "ok" .= deepOk, "error" .= deepErr eDeep]
            , "analytics" .= analytics
            , "keepalive" .= keepalive
            , "chime" .= chime
            ]
  where
    deepErr = maybe Nothing (either Just (const Nothing))

-- | Run a probe, trapping any failure as its message. Never rethrows.
tryProbe :: Flow a -> Flow (Either Text a)
tryProbe act =
    (Right <$> act) `catch` \(e :: SomeException) -> pure (Left (T.take 300 (T.pack (show e))))

{- | Last daily PAT re-issue (Keepalive.hs). @unknown@ until the first tick of
this process — the banner must stay silent on @unknown@ so a cold start never
flashes an alarm. Process-local, so under multiple replicas this reflects
whichever replica served the request.
-}
keepaliveStatus :: Flow Value
keepaliveStatus = do
    mKo <- readKeepalive
    pure $ case mKo of
        Nothing -> object ["state" .= ("unknown" :: Text)]
        Just ko ->
            object
                [ "state" .= (if koOk ko then "ok" else "failed" :: Text)
                , "at" .= koAt ko
                , "error" .= koError ko
                ]

{- | Never throws: reports {configured, ok}. Not-configured is not an alarm
(analytics is an optional deployment); configured-but-down is.
-}
probeAnalyticsHealth :: Flow Value
probeAnalyticsHealth = do
    cfg <- getConfig
    if null (airborneAnalyticsUrl cfg)
        then pure $ object ["configured" .= False, "ok" .= False]
        else
            ( do
                r <- analyticsRequest Http.GET "/analytics/health" []
                -- Analytics health is HTTP 200 even when unhealthy; the status
                -- field is the real signal.
                let statusOk = case urBody r of
                        Object o -> AT.parseMaybe (A.withObject "h" (A..: "status")) (Object o) == Just ("healthy" :: Text)
                        _ -> False
                pure $ object ["configured" .= True, "ok" .= (urStatus r < 400 && statusOk)]
            )
                `catch` \(_ :: SomeException) -> pure (object ["configured" .= True, "ok" .= False])

-- ─── Access list (drives the app selector) ─────────────────────────

{- | The apps the caller can see — the LIVE airborne app list (bot's
@/api/users@ tree), filtered to those the caller has @OTA_VIEW@ on, each with
its effective permission set (so the frontend gates buttons without extra
calls). No local mapping: an app appears here the moment it exists upstream.
If airborne is unreachable the list is empty with @upstreamReachable=false@.
-}
accessH :: AuthedPerson -> Flow Value
accessH ap = do
    mUpstream <- upstreamAppsSafe
    case mUpstream of
        Nothing -> pure $ object ["apps" .= ([] :: [Value]), "upstreamReachable" .= False]
        Just upstream -> do
            -- One batched RBAC pass over the whole fleet rather than a per-app query.
            let refs = [(org, app, appRefOf org app) | (org, app) <- upstream]
            permsByRef <-
                if apIsSuperadmin ap
                    then pure (\_ -> allPermissionsText "airborne-ota")
                    else do
                        pairs <- computeEffectivePermissionsForAppGroups (apPersonId ap) "airborne-ota" [r | (_, _, r) <- refs]
                        -- Unified per-app grants: OTA_* perms carried by an
                        -- autopilot "<name>/<platform>" grant on the mapped app.
                        catalog <- listAppCatalog
                        let keysFor ref = [appGrantKey (acName a) (acPlatform a) | a <- catalog, acAirborneAppRef a == Just ref]
                            uniKeys = nub (concatMap (\(_, _, r) -> keysFor r) refs)
                        uniPairs <- computeEffectivePermissionsForAppGroups (apPersonId ap) "mobile" uniKeys
                        let uniFor ref = [p | k <- keysFor ref, p <- fromMaybe [] (lookup k uniPairs), "OTA_" `T.isPrefixOf` p]
                        pure (\ref -> nub (fromMaybe [] (lookup ref pairs) <> uniFor ref))
            let visible =
                    [ object ["appRef" .= ref, "org" .= org, "app" .= app, "permissions" .= perms]
                    | (org, app, ref) <- refs
                    , let perms = permsByRef ref
                    , "OTA_VIEW" `elem` perms
                    ]
            pure $ object ["apps" .= visible, "upstreamReachable" .= True]

{- | Full upstream app list (unfiltered by per-app grants) for admins granting
scoped access to others. Unlike per-app routes this is intentionally NOT
narrowed to the caller's own accessible apps, so it requires a PRODUCT-level
@OTA_APP_MANAGE@ grant — not a per-app deployment grant (the route-level
'Protected' would accept the deployment fallback, which must not let a per-app
admin enumerate the whole fleet). See 'requireProductLevelAppManage'.
-}
listAllAppsH :: AuthedPerson -> Flow Value
listAllAppsH ap = do
    requireProductLevelAppManage ap
    mUpstream <- upstreamAppsSafe
    case mUpstream of
        Nothing -> pure $ object ["apps" .= ([] :: [Value]), "upstreamReachable" .= False]
        Just upstream ->
            pure $
                object
                    [ "apps" .= [object ["appRef" .= appRefOf o a, "org" .= o, "app" .= a] | (o, a) <- upstream]
                    , "upstreamReachable" .= True
                    ]

{- | Create an airborne application. Upstream is ORG-scoped
(@allow_org=true, allow_app=false@; org roles owner|admin) so it is gated by
the PRODUCT-level check, never 'requireDeploymentPermission' — there is no app
ref to scope to, the app is what we are creating.

Sends @x-organisation@ ONLY: airborne's auth middleware 403s any request
carrying @x-application@ when the subject has no membership for it, and the
app does not exist yet. Upstream validates the name (<=50 chars, @a-z0-9-_.@),
so we do not duplicate that rule here beyond a trim/empty check — the live
fleet predates the validator and contains names it would now reject.
-}
createAppH :: AuthedPerson -> CreateAppReq -> Flow Value
createAppH ap req = do
    requireProductLevelAppManage ap
    let org = T.strip (caOrg req)
        app = T.strip (caApp req)
    unless (not (T.null org) && not (T.null app)) $
        throwM (BadRequest "org and app are required")
    -- The ref is split on the first '~', so a '~' in either half would make
    -- the app unaddressable afterwards.
    unless (not (T.isInfixOf "~" org) && not (T.isInfixOf "~" app)) $
        throwM (BadRequest "org and app must not contain '~' (reserved as the app-ref separator)")
    let endpoint = "/api/organisations/applications/create"
        body = object ["application" .= app]
    r <- airborneRequest Http.POST endpoint [("x-organisation", org)] [] (Just body)
    insertAirborneEvent (apEmail ap) (appRefOf org app) "APP_CREATE" endpoint (Just body) (urStatus r) (urRequestId r)
    expectOk r

{- | Require a PRODUCT-level OTA_APP_MANAGE grant, ignoring the per-app
deployment fallback that route-level 'Protected' would accept. Recomputed from
the person's product-access role so a deployment-scoped Admin on one app can't
enumerate the whole fleet via GET /airborne/apps.
-}
requireProductLevelAppManage :: AuthedPerson -> Flow ()
requireProductLevelAppManage ap
    | apIsSuperadmin ap = pure ()
    | otherwise = do
        granted <- case find (\pa -> paProductSlug pa == "airborne-ota") (apProductAccesses ap) of
            Nothing -> pure False
            Just pa -> do
                mPerson <- findPersonById (apPersonId ap)
                case mPerson of
                    Nothing -> pure False
                    Just person -> ("OTA_APP_MANAGE" `elem`) <$> computeEffectivePermissions person "airborne-ota" (paRoleId pa)
        unless granted $
            throwM (Forbidden "listing all Airborne apps requires a product-level Airborne OTA admin grant")

-- ─── Releases ──────────────────────────────────────────────────────

listReleasesH :: AuthedPerson -> Text -> Maybe Int -> Maybe Int -> Maybe Text -> Maybe Text -> Flow Value
listReleasesH ap app page count status mDim = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_VIEW) ap app
    r <-
        airborneRequest
            Http.GET
            "/api/releases/list"
            (scopeHeaders row <> dimHeader mDim)
            -- airborne's ReleaseStatus deserializes lowercase; lower here so the UI
            -- can send any casing.
            [("page", tshow <$> page), ("count", tshow <$> count), ("status", T.toLower <$> status)]
            Nothing
    expectOk r

getReleaseH :: AuthedPerson -> Text -> Text -> Flow Value
getReleaseH ap app rid = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_VIEW) ap app
    r <- airborneRequest Http.GET ("/api/releases/" <> pathSeg rid) (scopeHeaders row) [] Nothing
    expectOk r

rampH :: AuthedPerson -> Text -> Text -> RampReq -> Flow Value
rampH ap app rid req = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_RELEASE_RAMP) ap app
    preflightRamp row rid req
    let body =
            object
                [ "traffic_percentage" .= rampTrafficPercentage req
                , "change_reason" .= stampReason ap ("ramp to " <> tshow (rampTrafficPercentage req) <> "%") (rampChangeReason req)
                ]
        endpoint = "/api/releases/" <> pathSeg rid <> "/ramp"
    r <- airborneRequest Http.POST endpoint (scopeHeaders row) [] (Just body)
    insertAirborneEvent (apEmail ap) app "RAMP" endpoint (Just body) (urStatus r) (urRequestId r)
    expectOk r

{- | Pre-flight for a ramp: range check, terminal-state guard, and an optional
clobber guard against the traffic % the operator was shown.

NOT an atomic compare-and-set — airborne exposes no ETag/version/@updated_at@
on the ramp path, so this is read-then-write: it shrinks the clobber window to
one round-trip, it cannot close it. Fails closed (an unreadable upstream
aborts the ramp), which is the right trade for a guard whose whole job is to
stop a silent overwrite.

The terminal guard also matters on its own: airborne's @ramp_release@ never
reads the experiment, so ramping a CONCLUDED release flattens to an opaque
upstream 500 instead of a clear refusal.
-}
preflightRamp :: AppRef -> Text -> RampReq -> Flow ()
preflightRamp row rid req = do
    let pct = rampTrafficPercentage req
    unless (pct >= 0 && pct <= 50) $
        throwM (BadRequest "trafficPercentage must be between 0 and 50 (100% only via conclude)")
    cur <-
        expectOk
            =<< airborneRequest Http.GET ("/api/releases/" <> pathSeg rid) (scopeHeaders row) [] Nothing
    let parsed =
            AT.parseMaybe
                ( A.withObject "release" $ \o -> do
                    e <- o A..: "experiment"
                    st <- e A..:? "status"
                    tp <- e A..:? "traffic_percentage"
                    pure (st :: Maybe Text, tp :: Maybe Int)
                )
                cur
        (mStatus, mActual) = case parsed of
            Just (s, t) -> (T.toUpper <$> s, t)
            Nothing -> (Nothing, Nothing)
    case mStatus of
        Just s
            | s `elem` (["CONCLUDED", "DISCARDED"] :: [Text]) ->
                throwM . InvalidTransition $
                    "release is " <> s <> "; traffic can no longer be ramped"
        _ -> pure ()
    case (rampExpectedCurrent req, mActual) of
        (Just expected, Just actual)
            | expected /= actual ->
                throwM . Conflict $
                    "traffic changed upstream (now "
                        <> tshow actual
                        <> "%, you were shown "
                        <> tshow expected
                        <> "%) — reload and try again"
        _ -> pure ()

concludeH :: AuthedPerson -> Text -> Text -> ConcludeReq -> Flow Value
concludeH ap app rid req = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_RELEASE_CONCLUDE) ap app
    let body =
            object
                [ "chosen_variant" .= concChosenVariant req
                , "change_reason" .= stampReason ap ("conclude with " <> concChosenVariant req) (concChangeReason req)
                ]
        endpoint = "/api/releases/" <> pathSeg rid <> "/conclude"
    r <- airborneRequest Http.POST endpoint (scopeHeaders row) [] (Just body)
    insertAirborneEvent (apEmail ap) app "CONCLUDE" endpoint (Just body) (urStatus r) (urRequestId r)
    expectOk r

discardH :: AuthedPerson -> Text -> Text -> Flow Value
discardH ap app rid = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_RELEASE_DISCARD) ap app
    let body = object ["change_reason" .= stampReason ap "discard" Nothing]
        endpoint = "/api/releases/" <> pathSeg rid <> "/discard"
    r <- airborneRequest Http.POST endpoint (scopeHeaders row) [] (Just body)
    insertAirborneEvent (apEmail ap) app "DISCARD" endpoint (Just body) (urStatus r) (urRequestId r)
    expectOk r

-- ─── Packages / files (read-only) ──────────────────────────────────

-- | @search@ is a substring match on the package's index file name upstream.
listPackagesH :: AuthedPerson -> Text -> Maybe Int -> Maybe Int -> Maybe Text -> Flow Value
listPackagesH ap app page count search = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_VIEW) ap app
    r <-
        airborneRequest
            Http.GET
            "/api/packages/list"
            (scopeHeaders row)
            [("page", tshow <$> page), ("count", tshow <$> count), ("search", search)]
            Nothing
    expectOk r

listFilesH :: AuthedPerson -> Text -> Maybe Int -> Maybe Int -> Maybe Text -> Maybe Text -> Flow Value
listFilesH ap app page count search tag = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_VIEW) ap app
    r <-
        airborneRequest
            Http.GET
            "/api/file/list"
            (scopeHeaders row)
            [ ("page", tshow <$> page)
            , ("per_page", tshow <$> count)
            , ("search", search)
            , ("tags", tag)
            ]
            Nothing
    expectOk r

{- | Files grouped by path, newest version first, each with its version
history and tag list. Upstream paginates by GROUP (not by version), which is
why the flat @\/api\/file\/list@ cannot be grouped client-side: one file's
versions would straddle page boundaries.

@tags@ is a comma-separated filter, forwarded verbatim.
-}
listFileGroupsH ::
    AuthedPerson -> Text -> Maybe Int -> Maybe Int -> Maybe Text -> Maybe Text -> Flow Value
listFileGroupsH ap app page count search tags = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_VIEW) ap app
    r <-
        airborneRequest
            Http.GET
            "/api/file/groups"
            (scopeHeaders row)
            [ ("page", tshow <$> page)
            , ("count", tshow <$> count)
            , ("search", search)
            , ("tags", tags)
            ]
            Nothing
    expectOk r

-- | Distinct tags with usage counts — feeds the Files page tag filter.
listFileTagsH :: AuthedPerson -> Text -> Maybe Int -> Maybe Int -> Flow Value
listFileTagsH ap app page count = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_VIEW) ap app
    r <-
        airborneRequest
            Http.GET
            "/api/file/tags"
            (scopeHeaders row)
            [("page", tshow <$> page), ("count", tshow <$> count)]
            Nothing
    expectOk r

-- ─── Create flows (Phase 2) ────────────────────────────────────────

{- | Run a proxied mutation and audit it. If the upstream call throws
mid-flight (timeout/unreachable) the request may still have applied, so record
an intent row (status 0) before re-raising — otherwise audit the real status.
-}
runMutation ::
    AuthedPerson -> Text -> Text -> Text -> Maybe Value -> Flow UpstreamResult -> Flow Value
runMutation ap app action endpoint mBody act = do
    r <-
        act `catch` \(e :: SomeException) -> do
            insertAirborneEvent (apEmail ap) app action endpoint mBody 0 Nothing
            throwM e
    insertAirborneEvent (apEmail ap) app action endpoint mBody (urStatus r) (urRequestId r)
    expectOk r

createReleaseH :: AuthedPerson -> Text -> Value -> Flow Value
createReleaseH ap app body = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_RELEASE_CREATE) ap app
    runMutation ap app "RELEASE_CREATE" "/api/releases" (Just body) $
        airborneRequest Http.POST "/api/releases" (scopeHeaders row) [] (Just body)

updateReleaseH :: AuthedPerson -> Text -> Text -> Value -> Flow Value
updateReleaseH ap app rid body = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_RELEASE_CREATE) ap app
    let endpoint = "/api/releases/" <> pathSeg rid
    runMutation ap app "RELEASE_UPDATE" endpoint (Just body) $
        airborneRequest Http.PUT endpoint (scopeHeaders row) [] (Just body)

{- | Preview the config an SDK would resolve (public serve endpoint, scoped by
org/app path segments). x-dimension narrows to a targeted variant.
-}
serveConfigH :: AuthedPerson -> Text -> Maybe Text -> Flow Value
serveConfigH ap app mDim = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_VIEW) ap app
    let endpoint = "/api/releases/" <> pathSeg (arOrg row) <> "/" <> pathSeg (arApp row)
    r <- airborneRequest Http.GET endpoint (dimHeader mDim) [] Nothing
    expectOk r

createPackageH :: AuthedPerson -> Text -> Value -> Flow Value
createPackageH ap app body = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_PACKAGE_MANAGE) ap app
    runMutation ap app "PACKAGE_CREATE" "/api/packages" (Just body) $
        airborneRequest Http.POST "/api/packages" (scopeHeaders row) [] (Just body)

getPackageH :: AuthedPerson -> Text -> Maybe Text -> Flow Value
getPackageH ap app pkgKey = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_VIEW) ap app
    key <- maybe (throwM (BadRequest "package_key is required")) pure pkgKey
    r <- airborneRequest Http.GET "/api/packages" (scopeHeaders row) [("package_key", Just key)] Nothing
    expectOk r

createFileH :: AuthedPerson -> Text -> Value -> Flow Value
createFileH ap app body = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_FILE_MANAGE) ap app
    runMutation ap app "FILE_CREATE" "/api/file" (Just body) $
        airborneRequest Http.POST "/api/file" (scopeHeaders row) [] (Just body)

updateFileTagH :: AuthedPerson -> Text -> Text -> Value -> Flow Value
updateFileTagH ap app fileKey body = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_FILE_MANAGE) ap app
    let endpoint = "/api/file/" <> pathSeg fileKey
    runMutation ap app "FILE_TAG" endpoint (Just body) $
        airborneRequest Http.PATCH endpoint (scopeHeaders row) [] (Just body)

-- ─── Targeting & config (Phase 3) ──────────────────────────────────

-- Upstream mounts all of these under /api/organisations/applications/…;
-- org/app scoping rides the x-organisation/x-application headers.

dimensionBase :: Text
dimensionBase = "/api/organisations/applications/dimension"

listDimensionsH :: AuthedPerson -> Text -> Maybe Int -> Maybe Int -> Flow Value
listDimensionsH ap app page count = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_VIEW) ap app
    -- page/count <= 0 upstream is a Superposition 400 flattened to a 500.
    r <-
        airborneRequest
            Http.GET
            (dimensionBase <> "/list")
            (scopeHeaders row)
            [("page", tshow . max 1 <$> page), ("count", tshow . max 1 <$> count)]
            Nothing
    expectOk r

createDimensionH :: AuthedPerson -> Text -> Value -> Flow Value
createDimensionH ap app body = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_CONFIG_MANAGE) ap app
    -- "release-view" collides with upstream's dimension/release-view sub-router
    -- (registered before the /{dimension}/cohort scope) — GET .../release-view/cohort
    -- would resolve as a release-view lookup, not this dimension's cohort schema.
    case KM.lookup "dimension" =<< objectOf body of
        Just (String "release-view") ->
            throwM (BadRequest "\"release-view\" is reserved and cannot be used as a dimension name")
        _ -> pure ()
    let endpoint = dimensionBase <> "/create"
    runMutation ap app "DIMENSION_CREATE" endpoint (Just body) $
        airborneRequest Http.POST endpoint (scopeHeaders row) [] (Just body)

{- | Position is the only mutable dimension field upstream. change_reason is a
required upstream body field — stamp the SCC actor into it either way.
-}
updateDimensionH :: AuthedPerson -> Text -> Text -> Value -> Flow Value
updateDimensionH ap app dim body = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_CONFIG_MANAGE) ap app
    let stamped = stampBodyReason ap ("update dimension " <> dim) body
        endpoint = dimensionBase <> "/" <> pathSeg dim
    runMutation ap app "DIMENSION_UPDATE" endpoint (Just stamped) $
        airborneRequest Http.PUT endpoint (scopeHeaders row) [] (Just stamped)

getCohortH :: AuthedPerson -> Text -> Text -> Flow Value
getCohortH ap app dim = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_VIEW) ap app
    r <- airborneRequest Http.GET (dimensionBase <> "/" <> pathSeg dim <> "/cohort") (scopeHeaders row) [] Nothing
    expectOk r

createCheckpointH :: AuthedPerson -> Text -> Text -> Value -> Flow Value
createCheckpointH ap app dim body = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_CONFIG_MANAGE) ap app
    let endpoint = dimensionBase <> "/" <> pathSeg dim <> "/cohort/checkpoint"
    runMutation ap app "COHORT_CHECKPOINT_CREATE" endpoint (Just body) $
        airborneRequest Http.POST endpoint (scopeHeaders row) [] (Just body)

createGroupH :: AuthedPerson -> Text -> Text -> Value -> Flow Value
createGroupH ap app dim body = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_CONFIG_MANAGE) ap app
    let endpoint = dimensionBase <> "/" <> pathSeg dim <> "/cohort/group"
    runMutation ap app "COHORT_GROUP_CREATE" endpoint (Just body) $
        airborneRequest Http.POST endpoint (scopeHeaders row) [] (Just body)

getCohortPriorityH :: AuthedPerson -> Text -> Text -> Flow Value
getCohortPriorityH ap app dim = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_VIEW) ap app
    r <- airborneRequest Http.GET (dimensionBase <> "/" <> pathSeg dim <> "/cohort/group/priority") (scopeHeaders row) [] Nothing
    expectOk r

updateCohortPriorityH :: AuthedPerson -> Text -> Text -> Value -> Flow Value
updateCohortPriorityH ap app dim body = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_CONFIG_MANAGE) ap app
    let endpoint = dimensionBase <> "/" <> pathSeg dim <> "/cohort/group/priority"
    runMutation ap app "COHORT_PRIORITY_UPDATE" endpoint (Just body) $
        airborneRequest Http.PUT endpoint (scopeHeaders row) [] (Just body)

propertiesBase :: Text
propertiesBase = "/api/organisations/applications/properties"

getPropertiesSchemaH :: AuthedPerson -> Text -> Maybe Text -> Flow Value
getPropertiesSchemaH ap app mDim = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_VIEW) ap app
    r <- airborneRequest Http.GET (propertiesBase <> "/schema") (scopeHeaders row <> dimHeader mDim) [] Nothing
    expectOk r

{- | Upstream semantics are FULL-REPLACE: properties absent from the body are
deleted. The UI always sends the complete desired map (read-modify-write).
-}
putPropertiesSchemaH :: AuthedPerson -> Text -> Value -> Flow Value
putPropertiesSchemaH ap app body = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_CONFIG_MANAGE) ap app
    let endpoint = propertiesBase <> "/schema"
    runMutation ap app "PROPERTIES_SCHEMA_UPDATE" endpoint (Just body) $
        airborneRequest Http.PUT endpoint (scopeHeaders row) [] (Just body)

listPropertiesH :: AuthedPerson -> Text -> Maybe Text -> Flow Value
listPropertiesH ap app mDim = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_VIEW) ap app
    r <- airborneRequest Http.GET (propertiesBase <> "/list") (scopeHeaders row <> dimHeader mDim) [] Nothing
    expectOk r

viewsBase :: Text
viewsBase = "/api/organisations/applications/dimension/release-view"

listViewsH :: AuthedPerson -> Text -> Maybe Int -> Maybe Int -> Flow Value
listViewsH ap app page count = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_VIEW) ap app
    -- count <= 0 upstream is a division-by-zero/Postgres error, not a 400.
    r <-
        airborneRequest
            Http.GET
            (viewsBase <> "/list")
            (scopeHeaders row)
            [("page", tshow <$> page), ("count", tshow . max 1 <$> count)]
            Nothing
    expectOk r

createViewH :: AuthedPerson -> Text -> Value -> Flow Value
createViewH ap app body = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_CONFIG_MANAGE) ap app
    runMutation ap app "VIEW_CREATE" viewsBase (Just body) $
        airborneRequest Http.POST viewsBase (scopeHeaders row) [] (Just body)

updateViewH :: AuthedPerson -> Text -> Text -> Value -> Flow Value
updateViewH ap app viewId body = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_CONFIG_MANAGE) ap app
    let endpoint = viewsBase <> "/" <> pathSeg viewId
    runMutation ap app "VIEW_UPDATE" endpoint (Just body) $
        airborneRequest Http.PUT endpoint (scopeHeaders row) [] (Just body)

deleteViewH :: AuthedPerson -> Text -> Text -> Flow Value
deleteViewH ap app viewId = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_CONFIG_MANAGE) ap app
    let endpoint = viewsBase <> "/" <> pathSeg viewId
    runMutation ap app "VIEW_DELETE" endpoint Nothing $
        airborneRequest Http.DELETE endpoint (scopeHeaders row) [] Nothing

-- ─── Analytics (Phase 4) ───────────────────────────────────────────

{- | The analytics host takes org/app as QUERY params (org_id/app_id), never
headers, and no PAT — so these go through analyticsRequest, not
airborneRequest. Reads only, so no audit.
-}
analyticsScope :: AppRef -> [(Text, Maybe Text)]
analyticsScope ref =
    [ ("org_id", Just (arOrg ref))
    , ("app_id", Just (arApp ref))
    ]

{- | Adoption is release-scoped: interval must be DAY|HOUR, dates are epoch
millis, release_id filters events (defaults upstream to "default"). The
frontend supplies all of these; we pass them through verbatim.
-}
analyticsAdoptionH ::
    AuthedPerson -> Text -> Maybe Text -> Maybe Text -> Maybe Text -> Maybe Text -> Maybe Text -> Flow Value
analyticsAdoptionH ap app interval startDate endDate date releaseId = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_VIEW) ap app
    r <-
        analyticsRequest
            Http.GET
            "/analytics/adoption"
            ( analyticsScope row
                <> [ ("interval", interval)
                   , ("start_date", startDate)
                   , ("end_date", endDate)
                   , ("date", date)
                   , ("release_id", releaseId)
                   ]
            )
    expectOk r

analyticsVersionsH :: AuthedPerson -> Text -> Maybe Int -> Flow Value
analyticsVersionsH ap app days = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_VIEW) ap app
    r <- analyticsRequest Http.GET "/analytics/versions" (analyticsScope row <> [("days", tshow <$> days)])
    expectOk r

analyticsActiveDevicesH :: AuthedPerson -> Text -> Maybe Int -> Flow Value
analyticsActiveDevicesH ap app days = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_VIEW) ap app
    r <- analyticsRequest Http.GET "/analytics/active-devices" (analyticsScope row <> [("days", tshow <$> days)])
    expectOk r

analyticsFailuresH :: AuthedPerson -> Text -> Maybe Int -> Maybe Text -> Flow Value
analyticsFailuresH ap app days releaseId = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_VIEW) ap app
    r <-
        analyticsRequest
            Http.GET
            "/analytics/failures"
            (analyticsScope row <> [("days", tshow <$> days), ("release_id", releaseId)])
    expectOk r

{- | Average download/apply time. Upstream currently stubs this (returns 0.0);
we still proxy it so the tile reflects real data once airborne implements it.
-}
analyticsPerformanceH :: AuthedPerson -> Text -> Maybe Int -> Maybe Text -> Flow Value
analyticsPerformanceH ap app days releaseId = do
    row <- resolveApp app
    requireOtaPermission (Proxy @'OTA_VIEW) ap app
    r <-
        analyticsRequest
            Http.GET
            "/analytics/performance"
            (analyticsScope row <> [("days", tshow <$> days), ("release_id", releaseId)])
    expectOk r

-- ─── Helpers ───────────────────────────────────────────────────────

{- | The @:app@ segment is the composite ref @\<org\>~\<app\>@; split it into
the airborne org/app pair (no DB — the app list is live). A malformed ref
(no '~', or an empty side) is a 400. Whether the app actually exists upstream
is decided by airborne's own response to the proxied call.
-}
resolveApp :: Text -> Flow AppRef
resolveApp ref = case T.breakOn "~" ref of
    (org, rest)
        | not (T.null org)
        , Just app <- T.stripPrefix "~" rest
        , not (T.null app) ->
            pure (AppRef org app)
    _ -> throwM (BadRequest ("invalid OTA app ref (expected <org>~<app>): " <> ref))

-- | Compose the composite ref from an org/app pair (inverse of 'resolveApp').
appRefOf :: Text -> Text -> Text
appRefOf org app = org <> "~" <> app

{- | Per-app OTA permission check honouring BOTH grant vocabularies: the
legacy per-ref airborne-ota grant, and the unified per-app autopilot grant
keyed @\<name\>\/\<platform\>@ (resolved through app_catalog.airborne_app_ref;
refs with no catalog row simply have no alias and fall back to legacy-only).
-}
requireOtaPermission ::
    forall perm. (KnownPermission perm) => Proxy perm -> AuthedPerson -> Text -> Flow ()
requireOtaPermission proxy ap ref = do
    mApp <- findAppByAirborneRef ref
    let unified = [("mobile", appGrantKey (acName a) (acPlatform a)) | Just a <- [mApp]]
    requireDeploymentPermissionScopes proxy ap (("airborne-ota", ref) : unified)

scopeHeaders :: AppRef -> [(Text, Text)]
scopeHeaders ref =
    [ ("x-organisation", arOrg ref)
    , ("x-application", arApp ref)
    ]

dimHeader :: Maybe Text -> [(Text, Text)]
dimHeader = maybe [] (\d -> [("x-dimension", d)])

{- | Actor always lands in Superposition's change_reason, with the user's
optional note appended.
-}
stampReason :: AuthedPerson -> Text -> Maybe Text -> Text
stampReason ap action mNote =
    action <> " by " <> apEmail ap <> " via SCC" <> maybe "" (": " <>) mNote

{- | Same stamping for passthrough bodies: overwrite change_reason with the
actor-stamped form, keeping any client-supplied note as the suffix.
-}
stampBodyReason :: AuthedPerson -> Text -> Value -> Value
stampBodyReason ap action (Object o) =
    let note = case KM.lookup "change_reason" o of
            Just (String s) | not (T.null s) -> Just s
            _ -> Nothing
     in Object (KM.insert "change_reason" (String (stampReason ap action note)) o)
stampBodyReason _ _ v = v

objectOf :: Value -> Maybe (KM.KeyMap Value)
objectOf (Object o) = Just o
objectOf _ = Nothing

{- | Upstream (org, app) pairs, 'Nothing' when airborne is unreachable so the
selector/admin views degrade gracefully. Wraps the throwing Client helper.
-}
upstreamAppsSafe :: Flow (Maybe [(Text, Text)])
upstreamAppsSafe =
    (Just <$> fetchUpstreamApps)
        `catch` \(e :: SomeException) -> do
            logWarning ("[airborne] access-map fetch failed: " <> T.pack (show e))
            pure Nothing

pathSeg :: Text -> Text
pathSeg = TE.decodeUtf8 . urlEncode False . TE.encodeUtf8

tshow :: (Show a) => a -> Text
tshow = T.pack . show

-- ─── Audit trail (SCC-side) ────────────────────────────────────────

-- Response bodies are unbounded JSONB (a release-create carries the whole
-- file split), so the page size is clamped hard.
eventsMaxCount :: Int
eventsMaxCount = 100

{- | This app's proxied-mutation audit trail. Scoped to the captured app and
gated per-app, so a grant on one app can never read another's history.

Attribution note: airborne accepts a @change_reason@ on only four endpoints
(ramp/conclude/discard/update-dimension) and hardcodes its own reason
everywhere else, so for most mutations THIS is the only record of who acted.
-}
listEventsH :: AuthedPerson -> Text -> Maybe Int -> Maybe Int -> Maybe Text -> Flow Value
listEventsH ap app mPage mCount mAction = do
    _ <- resolveApp app
    requireOtaPermission (Proxy @'OTA_VIEW) ap app
    let page = max 1 (fromMaybe 1 mPage)
        count = max 1 (min eventsMaxCount (fromMaybe 20 mCount))
    rows <- listAirborneEvents (Just app) mAction page count
    let total = case rows of
            (r : _) -> aeTotal r
            [] -> 0
        totalPages = max 1 ((total + fromIntegral count - 1) `div` fromIntegral count)
    pure $
        object
            [ "data" .= map eventJson rows
            , "total_items" .= total
            , "total_pages" .= totalPages
            , "page" .= page
            ]

{- | @upstream_status = 0@ is NOT an HTTP status: 'runMutation' writes an
intent row with 0 when the upstream call throws mid-flight, meaning the
mutation may or may not have applied. Surfaced as @outcome: "unknown"@ so the
UI can never render it as a plain failure.
-}
eventJson :: AirborneEventRow -> Value
eventJson r =
    object
        [ "id" .= aeId r
        , "actor" .= aeActor r
        , "org" .= aeOrg r
        , "app" .= aeApp r
        , "action" .= aeAction r
        , "endpoint" .= aeEndpoint r
        , "request" .= aeRequest r
        , "upstreamStatus" .= aeUpstreamStatus r
        , "upstreamRequestId" .= aeUpstreamRequestId r
        , "createdAt" .= aeCreatedAt r
        , "outcome" .= outcome
        ]
  where
    outcome :: Text
    outcome = case aeUpstreamStatus r of
        Nothing -> "unknown"
        Just 0 -> "unknown"
        Just s | s >= 200 && s < 300 -> "ok"
        _ -> "failed"
