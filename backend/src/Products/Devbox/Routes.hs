{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

{- | Devbox Releases API: list / get / branch-status / create / stop.

Create pins each branch to its latest commit on GitHub, stores the release
(rules enforced in "Products.Devbox.Queries"), then dispatches nammayatri's
@.github/workflows/devbox.yaml@ with @action=spawn@. Stop dispatches the same
workflow with @action=stop@. Progress comes back through the poller, which
follows the stored GitHub run.
-}
module Products.Devbox.Routes (DevboxAPI, devboxServer) where

import Control.Monad (forM_, unless, when)
import Control.Monad.Catch (throwM)
import Control.Monad.IO.Class (liftIO)
import Core.AppError (APIError (..))
import Core.Auth.Protected (AuthedPerson (..), Protected)
import Core.Auth.Queries (computeEffectivePermissions, findPersonById)
import Core.Auth.Types (ProductAccess (..))
import Core.Environment (Flow)
import Data.Aeson (FromJSON (..), Value (..), object, withObject, (.!=), (.:), (.:?), (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.Char (isAlphaNum)
import Data.List (find)
import Data.Maybe (fromMaybe, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Products.Autopilot.Mobile.Github (cancelRun)
import Products.Autopilot.Mobile.Github.Auth (loadGhCreds)
import Products.Devbox.Github (appRepo, backendRepo, ccRepo, dispatch, pin)
import Products.Devbox.Queries
import Products.Devbox.Types
import Products.Devbox.Types.Permission (DevboxPermission (..))
import Servant
import Shared.Config.Runtime (getConfigIntForProduct)

type DevboxAPI =
    "devbox" :> Protected 'DEVBOX_VIEW :> "releases" :> QueryParam "filter" Text :> QueryParam "q" Text :> QueryParam "page" Int :> QueryParam "count" Int :> Get '[JSON] Value
        :<|> "devbox" :> Protected 'DEVBOX_VIEW :> "releases" :> Capture "id" Text :> Get '[JSON] Value
        :<|> "devbox" :> Protected 'DEVBOX_VIEW :> "branch-status" :> QueryParam' '[Required, Strict] "branch" Text :> Get '[JSON] Value
        :<|> "devbox" :> Protected 'DEVBOX_RELEASE_CREATE :> "releases" :> ReqBody '[JSON] CreateReq :> Post '[JSON] Value
        -- STOP is the floor; stopping someone else's release also needs STOP_ANY (checked in the handler).
        :<|> "devbox" :> Protected 'DEVBOX_RELEASE_STOP :> "releases" :> Capture "id" Text :> "stop" :> Post '[JSON] Value

devboxServer :: ServerT DevboxAPI Flow
devboxServer = listH :<|> getH :<|> branchStatusH :<|> createH :<|> stopH

-- ─── Read ──────────────────────────────────────────────────────────

listH :: AuthedPerson -> Maybe Text -> Maybe Text -> Maybe Int -> Maybe Int -> Flow Value
listH _ap mFilter mQ mPage mCount = do
    sf <- case mFilter of
        Nothing -> pure FilterAll
        Just f -> maybe (throwM (BadRequest ("unknown filter " <> f <> " (all, running, in_progress, stopped)"))) pure (textToStatusFilter f)
    let page = max 1 (fromMaybe 1 mPage)
        count = min 100 (max 1 (fromMaybe 20 mCount))
        q = mfilterEmpty (T.strip <$> mQ)
    (rows, total) <- listReleases sf q page count
    counts <- filterCounts
    pure $ object ["releases" .= rows, "total" .= total, "counts" .= counts, "page" .= page, "count" .= count]

getH :: AuthedPerson -> Text -> Flow Value
getH ap rid = do
    r <- getRelease rid >>= maybe (throwM (NotFound ("no devbox release " <> rid))) pure
    events <- releaseEvents rid
    builds <- releaseBuilds rid
    stoppable <- canStop ap r
    pure $ object ["release" .= r, "events" .= events, "builds" .= builds, "canStop" .= stoppable]

branchStatusH :: AuthedPerson -> Text -> Flow Value
branchStatusH _ap branch = do
    active <- activeForBranch (T.strip branch)
    pure $ object ["branch" .= branch, "active" .= active]

-- ─── Create ────────────────────────────────────────────────────────

-- | The New release form.
data CreateReq = CreateReq
    { crBackendBranch :: Text
    , crCcBranch :: Maybe Text
    , crFrontendBranch :: Maybe Text
    , crBuildAndroid :: Bool
    , crBuildIos :: Bool
    , crDataSource :: Text
    , crDataVersion :: Maybe Text
    , crWorkspace :: Maybe Text
    }

instance FromJSON CreateReq where
    parseJSON = withObject "CreateReq" $ \o ->
        CreateReq
            <$> o .: "backendBranch"
            <*> o .:? "ccBranch"
            <*> o .:? "frontendBranch"
            <*> o .:? "buildAndroid" .!= False
            <*> o .:? "buildIos" .!= False
            <*> o .: "dataSource"
            <*> o .:? "dataVersion"
            <*> o .:? "workspace"

createH :: AuthedPerson -> CreateReq -> Flow Value
createH ap req = do
    let backendBranch = T.strip (crBackendBranch req)
        ccBranch = mfilterEmpty (T.strip <$> crCcBranch req)
        frontendBranch = mfilterEmpty (T.strip <$> crFrontendBranch req)
        workspace = fromMaybe (nameFromBranch backendBranch) (mfilterEmpty (T.strip <$> crWorkspace req))
        dataVersion = mfilterEmpty (T.strip <$> crDataVersion req)
    when (T.null backendBranch) $ throwM (BadRequest "backendBranch is required")
    unless (validName workspace) $
        throwM (BadRequest ("workspace name " <> workspace <> " must be 1-40 letters, digits, - or _"))
    unless (crDataSource req `elem` ["master", "prod", "prod_international"]) $
        throwM (BadRequest "dataSource must be master, prod or prod_international")
    forM_ dataVersion $ \v ->
        unless (validVersion v) $ throwM (BadRequest ("dataVersion " <> v <> " must look like v14"))
    when (isNothing frontendBranch && (crBuildAndroid req || crBuildIos req)) $
        throwM (BadRequest "Android / iOS builds need an app (frontend) branch")

    -- Pin every branch to the commit it points at now: the release tests exactly these.
    creds <- loadGhCreds
    backendSha <- pin creds backendRepo backendBranch
    ccSha <- traverse (pin creds ccRepo) ccBranch
    frontendSha <- traverse (pin creds appRepo) frontendBranch

    maxActive <- getConfigIntForProduct "devbox_max_active_per_user" (Just "devbox") 2
    lifetime <- getConfigIntForProduct "devbox_lifetime_days" (Just "devbox") 3
    rid <- liftIO (UUID.toText <$> UUID.nextRandom)
    let nr =
            NewRelease
                { nrId = rid
                , nrWorkspace = workspace
                , nrBackendBranch = backendBranch
                , nrBackendSha = backendSha
                , nrCcBranch = ccBranch
                , nrCcSha = ccSha
                , nrFrontendBranch = frontendBranch
                , nrFrontendSha = frontendSha
                , nrBuildAndroid = crBuildAndroid req
                , nrBuildIos = crBuildIos req
                , nrDataSource = crDataSource req
                , nrDataVersion = dataVersion
                , nrCreatedBy = apEmail ap
                }
    created <-
        createRelease maxActive lifetime nr >>= \case
            Right r -> pure r
            Left (TooManyActive n) ->
                throwM (Conflict ("you already have " <> tshow n <> " active devbox releases; stop one first"))
            Left (BranchActive r) ->
                throwM (ConflictWithPayload "BRANCH_ACTIVE" (backendBranch <> " is already running as " <> drWorkspace r <> " (" <> drCreatedBy r <> "); stop it first") (object ["release" .= r]))
            Left (WorkspaceActive r) ->
                throwM (ConflictWithPayload "WORKSPACE_ACTIVE" ("the name " <> workspace <> " is used by an active release; pick another") (object ["release" .= r]))
    insertEvent rid "preparing" "info" (object ["createdBy" .= apEmail ap]) Nothing

    let inputs =
            KM.fromList
                [ ("action", String "spawn")
                , ("workspace", String workspace)
                , ("backend_ref", String backendSha)
                , ("cc_ref", String (fromMaybe "" ccSha))
                , ("data_from", String (crDataSource req))
                , ("data_version", String (fromMaybe "" dataVersion))
                , ("release_id", String rid)
                , ("owner", String (apEmail ap))
                ]
    dispatch creds rid "spawn" inputs
    final <- getRelease rid
    pure $ object ["release" .= fromMaybe created final]

-- ─── Stop ──────────────────────────────────────────────────────────

stopH :: AuthedPerson -> Text -> Flow Value
stopH ap rid = do
    r <- getRelease rid >>= maybe (throwM (NotFound ("no devbox release " <> rid))) pure
    unless (drStatus r `elem` ["QUEUED", "RUNNING", "READY", "FAILED"]) $
        throwM (Conflict ("release is already " <> T.toLower (drStatus r)))
    allowed <- canStop ap r
    unless allowed $
        throwM (Forbidden ("only " <> drCreatedBy r <> " or a Devbox manager can stop this release"))
    creds <- loadGhCreds
    case (drDevboxHost r, drDevboxUser r) of
        (Just host, Just user) -> do
            -- The workspace exists on a known dev-box: the workflow removes it.
            _ <- setStopping rid (apEmail ap)
            insertEvent rid "stop" "started" (object ["by" .= apEmail ap]) Nothing
            dispatch creds rid "stop" $
                KM.fromList
                    [ ("action", String "stop")
                    , ("workspace", String (drWorkspace r))
                    , ("release_id", String rid)
                    , ("owner", String (drCreatedBy r))
                    , ("devbox_host", String host)
                    , ("devbox_user", String user)
                    ]
        _ -> do
            -- Still building: the dev-box is only known once the run reports
            -- back, so cancel the run. A half-made workspace is left to the
            -- expiry sweep, which finds workspaces by their release id.
            forM_ (drGhRunId r) $ \runId -> do
                res <- cancelRun creds (fst backendRepo) (snd backendRepo) (tshow runId)
                either (\e -> insertEvent rid "stop" "info" (object ["cancelError" .= e]) Nothing) pure res
            _ <- setStopping rid (apEmail ap)
            _ <- setStopped rid "user"
            insertEvent rid "stop" "done" (object ["by" .= apEmail ap, "note" .= ("run cancelled before a dev-box was assigned" :: Text)]) Nothing
    final <- getRelease rid
    pure $ object ["release" .= fromMaybe r final]

-- ─── Helpers ───────────────────────────────────────────────────────

-- | The owner with STOP, or anyone with STOP_ANY (superadmins always).
canStop :: AuthedPerson -> DevboxRelease -> Flow Bool
canStop ap r
    | apIsSuperadmin ap = pure True
    | otherwise = do
        perms <- devboxPerms ap
        pure $
            "DEVBOX_RELEASE_STOP_ANY" `elem` perms
                || (drCreatedBy r == apEmail ap && "DEVBOX_RELEASE_STOP" `elem` perms)

-- | This person's effective permissions on the devbox product.
devboxPerms :: AuthedPerson -> Flow [Text]
devboxPerms ap = case find ((== "devbox") . paProductSlug) (apProductAccesses ap) of
    Nothing -> pure []
    Just pa ->
        findPersonById (apPersonId ap) >>= \case
            Nothing -> pure []
            Just person -> computeEffectivePermissions person "devbox" (paRoleId pa)

-- | 'feat/fare-fix' → 'fare-fix': the last path part, unsafe characters as '-'.
nameFromBranch :: Text -> Text
nameFromBranch b =
    T.take 40 . T.dropAround (== '-') $
        T.map (\c -> if isAlphaNum c || c == '-' || c == '_' then c else '-') (snd (T.breakOnEnd "/" b))

validName :: Text -> Bool
validName n = not (T.null n) && T.length n <= 40 && T.all (\c -> isAlphaNum c || c == '-' || c == '_') n

validVersion :: Text -> Bool
validVersion v = case T.uncons v of
    Just ('v', rest) -> not (T.null rest) && T.all (`elem` ['0' .. '9']) rest
    _ -> False

mfilterEmpty :: Maybe Text -> Maybe Text
mfilterEmpty = \case
    Just t | not (T.null t) -> Just t
    _ -> Nothing

tshow :: (Show a) => a -> Text
tshow = T.pack . show
