{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE TypeApplications #-}

{- | Chime (appmonitor) fleet campaigns + adoption, addressed by app-catalog
id — a mobile-product surface with @MB_*@ RBAC, deliberately decoupled from
airborne. Chime's data is its own (device SDK events); nothing here calls
airborne. Role\/platform\/package derive from the catalog row server-side, so
the browser sends only intent (launch\/cancel\/read). The one airborne-shaped
input is the adoption org label: the org half of 'acAirborneAppRef' when
present — a string parse, folded to @{recorded: false}@ when absent.

Chime's envelope is @{status, data}@; non-error outcomes like @skipped@ (one
campaign per (role, platform, package)) ride the 2xx path untouched — the FE
interprets them; only HTTP errors become typed 'APIError's (in "Chime").
-}
module Products.Autopilot.Mobile.Handlers.Chime (
    chimeLaunchH,
    chimeJobsH,
    chimeJobStatusH,
    chimeJobFunnelH,
    chimeCancelH,
    chimeAdoptionH,
) where

import Control.Monad (unless)
import Control.Monad.Catch (throwM)
import Core.AppError (APIError (..))
import Core.Auth.Protected (AuthedPerson, KnownPermission)
import Core.Environment (Flow, logWarning)
import Core.Http.Client qualified as Http
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.Int (Int32)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Products.AirborneOta.Chime (chimeRequest, expectChimeOk)
import Products.AirborneOta.Client (UpstreamResult (..))
import Products.Autopilot.Mobile.Auth (requireAppPerm)
import Products.Autopilot.Mobile.Queries.AppCatalog (findAppCatalogById)
import Products.Autopilot.Mobile.Types.Storage
import Products.Mobile.Types.Permission (MobilePermission (..))

-- | Chime coordinates of a catalog app: role (surface: driver→bpp, else
-- bap), platform, store package. Campaigns are keyed by exactly this triple.
data ChimeApp = ChimeApp
    { caRow :: AppCatalog
    , caRole :: Text
    , caPlatform :: Text
    , caPackage :: Text
    }

-- | Resolve the catalog row and enforce the caller's PER-APP grant (the
-- route-level Protected only proves product presence — same split as the
-- rollout handlers).
resolveChimeApp ::
    (KnownPermission perm) => Proxy perm -> AuthedPerson -> Int32 -> Flow ChimeApp
resolveChimeApp proxy ap aid = do
    mApp <- findAppCatalogById aid
    a <- maybe (throwM (NotFound ("app not found: " <> tshow aid))) pure mApp
    requireAppPerm proxy ap (acName a) (acPlatform a)
    rawPkg <-
        maybe
            (throwM (BadRequest "app has no package_name — set it in the app catalog to enable campaigns"))
            pure
            (acPackageName a)
    -- role/platform/package are interpolated into the upstream PATH — keep
    -- them segment-safe even though they come from the (admin-managed) catalog.
    pkg <- needSeg "package" (Just rawPkg)
    platform <- needSeg "platform" (Just (acPlatform a))
    let role = if acSurface a == "driver" then "bpp" else "bap"
    pure ChimeApp{caRow = a, caRole = role, caPlatform = platform, caPackage = pkg}

{- | POST \/mobile\/apps\/:appId\/chime\/launch — start (or dry-run) a push
campaign. A 200 @skipped@ (one already in flight for this target) passes
through as a normal body — the FE renders the conflict card, it is NOT an
error.
-}
chimeLaunchH :: AuthedPerson -> Int32 -> Maybe Bool -> Flow Value
chimeLaunchH ap aid mDry = do
    ChimeApp{caRole, caPlatform, caPackage} <- resolveChimeApp (Proxy @'MB_RELEASE_ROLLOUT) ap aid
    r <-
        chimeRequest
            Http.POST
            ("/chime/" <> caRole <> "/" <> caPlatform <> "/" <> caPackage)
            [("dry_run", boolParam <$> mDry)]
            Nothing
    expectChimeOk r

-- | GET \/mobile\/apps\/:appId\/chime\/jobs — campaign history for the app's
-- (role, os, package), newest first.
chimeJobsH :: AuthedPerson -> Int32 -> Maybe Text -> Maybe Int -> Maybe Int -> Flow Value
chimeJobsH ap aid mStatus mLimit mOffset = do
    ChimeApp{caRole, caPlatform, caPackage} <- resolveChimeApp (Proxy @'MB_RELEASE_VIEW) ap aid
    r <-
        chimeRequest
            Http.GET
            "/chime/jobs"
            [ ("role", Just caRole)
            , ("os", Just caPlatform)
            , ("package", Just caPackage)
            , ("status", mStatus)
            , ("limit", tshow <$> mLimit)
            , ("offset", tshow <$> mOffset)
            ]
            Nothing
    expectChimeOk r

chimeJobStatusH :: AuthedPerson -> Int32 -> Text -> Flow Value
chimeJobStatusH ap aid jobId = do
    ca <- resolveChimeApp (Proxy @'MB_RELEASE_VIEW) ap aid
    jid <- needSeg "jobId" (Just jobId)
    r <- chimeRequest Http.GET ("/chime/status/" <> jid) [] Nothing
    v <- expectChimeOk r
    v <$ requireJobMatch ca jid v

chimeJobFunnelH :: AuthedPerson -> Int32 -> Text -> Flow Value
chimeJobFunnelH ap aid jobId = do
    ca <- resolveChimeApp (Proxy @'MB_RELEASE_VIEW) ap aid
    jid <- needSeg "jobId" (Just jobId)
    r <- chimeRequest Http.GET ("/chime/jobs/" <> jid <> "/funnel") [] Nothing
    v <- expectChimeOk r
    v <$ requireJobMatch ca jid v

chimeCancelH :: AuthedPerson -> Int32 -> Text -> Flow Value
chimeCancelH ap aid jobId = do
    ca <- resolveChimeApp (Proxy @'MB_RELEASE_ROLLOUT) ap aid
    jid <- needSeg "jobId" (Just jobId)
    -- Ownership check BEFORE the mutation: fetch the job's own record and
    -- match it to this app's triple, so a jobId from another app 404s here.
    st <- chimeRequest Http.GET ("/chime/status/" <> jid) [] Nothing
    sv <- expectChimeOk st
    requireJobMatch ca jid sv
    r <- chimeRequest Http.POST ("/chime/cancel/" <> jid) [] Nothing
    expectChimeOk r

{- | A jobId is caller-supplied and Chime's job endpoints are global (one
shared API key), so per-app RBAC is only real if the job provably belongs to
the addressed app. Chime stamps every job record with its target triple —
require the package to match (and role\/platform when present); fail closed
as a 404 when the fields are missing so a foreign job never leaks or cancels.
-}
requireJobMatch :: ChimeApp -> Text -> Value -> Flow ()
requireJobMatch ChimeApp{caRole, caPlatform, caPackage} jid v = do
    let field k = case v of
            Object o
                | Just (Object d) <- KM.lookup "data" o
                , Just (String s) <- KM.lookup k d ->
                    Just s
            _ -> Nothing
        owned =
            field "package_name" == Just caPackage
                && maybe True (== caRole) (field "role")
                && maybe True (== caPlatform) (field "platform")
    unless owned $ throwM (NotFound ("no such campaign job for this app: " <> jid))

{- | GET \/mobile\/apps\/:appId\/chime\/adoption?version= — active users on
one bundle version. Chime scopes the count by org; that label is the org half
of the app's airborne ref when set. No ref → honest @{recorded: false}@, same
fold as Chime's own 404 ("nothing recorded for that key yet").
-}
chimeAdoptionH :: AuthedPerson -> Int32 -> Maybe Text -> Flow Value
chimeAdoptionH ap aid mVersion = do
    ChimeApp{caRow, caPlatform, caPackage} <- resolveChimeApp (Proxy @'MB_RELEASE_VIEW) ap aid
    ver <- needSeg "version" mVersion
    case T.takeWhile (/= '~') <$> acAirborneAppRef caRow of
        Just org | not (T.null org) -> do
            r <-
                chimeRequest
                    Http.GET
                    "/chime/versions/users"
                    [("package", Just caPackage), ("version", Just ver), ("os", Just caPlatform), ("org", Just org)]
                    Nothing
            if urStatus r == 404
                then pure notRecorded
                else expectChimeOk r
        _ -> pure notRecorded
  where
    notRecorded = object ["status" .= ("success" :: Text), "data" .= object ["recorded" .= False]]

-- | Require a present, path-safe parameter (path segments are interpolated
-- into the upstream URL; query params ride renderQuery but stay uniform).
needSeg :: Text -> Maybe Text -> Flow Text
needSeg name mv = case mv of
    Nothing -> throwM (BadRequest (name <> " is required"))
    Just v
        | T.null v || T.any (`elem` ("/?#%&\n\r " :: String)) v ->
            throwM (BadRequest ("invalid " <> name))
        | otherwise -> pure v

boolParam :: Bool -> Text
boolParam b = if b then "true" else "false"

tshow :: (Show a) => a -> Text
tshow = T.pack . show
