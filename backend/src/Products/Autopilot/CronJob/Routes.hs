{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

{- | CronJob manager HTTP API. Mounted as a suffix of 'CoreAPI' like the HPA
panel, so RBAC, logging and middleware stay on the one Servant tree.

Reads (@CRONJOB_VIEW@) list the CronJobs of a namespace and show one in detail.
Writes are split so access can be granted narrowly: create is @CRONJOB_CREATE@;
schedule, suspend and env edits are @CRONJOB_EDIT@; delete is @CRONJOB_DELETE@ (withheld from
Manager).

Only namespaces that some product's Deployment Config names are reachable, so
the panel cannot be pointed at @kube-system@.

Nothing is created or changed without passing "Products.Autopilot.CronJob.Validate":
no inline credentials, and every Secret / ConfigMap (and key) the pod refers to
must exist. Edits are read-modify-@replace@, so the object's @resourceVersion@
turns a concurrent edit into a 409 instead of an overwrite. Secret values never
leave kubectl: lookups print key names only, and env values that look like
credentials are masked in the detail view.
-}
module Products.Autopilot.CronJob.Routes (
    CronJobAPI,
    cronJobServer,
) where

import Control.Monad (unless, when)
import Control.Monad.Catch (throwM)
import Control.Monad.IO.Class (liftIO)
import Core.Admin.Queries (writeAuditLog)
import Core.AppError (APIError (..))
import Core.Auth.Protected (AuthedPerson (..), Protected)
import Core.Environment (Flow, getConfig)
import Data.Aeson (FromJSON (..), Value (..), object, (.!=), (.:), (.:?), (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key (Key)
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Char (isAlphaNum)
import Data.List (findIndex, nub, sort, sortOn)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Vector qualified as V
import Data.Yaml qualified as Y
import Products.Autopilot.CronJob.Validate
import Products.Autopilot.Hpa.Kube (Kube (..), KubeErr (..), asciiJson, classifyKubeError, kubeErrText, mkKube)
import Products.Autopilot.Queries.ProductService (getProductNamespace, listProducts)
import Products.Autopilot.Types.Permission (AutopilotPermission (..))
import Servant
import Shared.API.Response (APISuccess (..))

-- ---------------------------------------------------------------------------
-- API

type CronJobAPI =
    "cronjob-namespaces" :> Protected 'AP_CRONJOB_VIEW :> Get '[JSON] Value
        :<|> "cronjobs" :> Protected 'AP_CRONJOB_VIEW :> QueryParam "namespace" Text :> Get '[JSON] Value
        :<|> "cronjobs" :> Protected 'AP_CRONJOB_VIEW :> Capture "name" Text :> QueryParam "namespace" Text :> Get '[JSON] Value
        :<|> "cronjobs" :> Protected 'AP_CRONJOB_CREATE :> "validate" :> ReqBody '[JSON] ManifestReq :> Post '[JSON] Value
        :<|> "cronjobs" :> Protected 'AP_CRONJOB_CREATE :> ReqBody '[JSON] ManifestReq :> Post '[JSON] Value
        :<|> "cronjobs" :> Protected 'AP_CRONJOB_EDIT :> Capture "name" Text :> "schedule" :> ReqBody '[JSON] ScheduleReq :> Put '[JSON] APISuccess
        :<|> "cronjobs" :> Protected 'AP_CRONJOB_EDIT :> Capture "name" Text :> "suspend" :> ReqBody '[JSON] SuspendReq :> Put '[JSON] APISuccess
        :<|> "cronjobs" :> Protected 'AP_CRONJOB_EDIT :> Capture "name" Text :> "env" :> ReqBody '[JSON] EnvReq :> Put '[JSON] APISuccess
        :<|> "cronjobs" :> Protected 'AP_CRONJOB_DELETE :> Capture "name" Text :> QueryParam "namespace" Text :> QueryParam "force" Bool :> Delete '[JSON] APISuccess

cronJobServer :: ServerT CronJobAPI Flow
cronJobServer =
    namespacesH
        :<|> listH
        :<|> getH
        :<|> validateH
        :<|> createH
        :<|> scheduleH
        :<|> suspendH
        :<|> envH
        :<|> deleteH

-- ---------------------------------------------------------------------------
-- Request bodies

-- | @namespace@, @yaml@.
data ManifestReq = ManifestReq Text Text

instance FromJSON ManifestReq where
    parseJSON = A.withObject "ManifestReq" $ \o -> ManifestReq <$> o .: "namespace" <*> o .: "yaml"

-- | @timeZone@: absent leaves it alone, empty string clears it.
data ScheduleReq = ScheduleReq Text Text (Maybe Text)

instance FromJSON ScheduleReq where
    parseJSON = A.withObject "ScheduleReq" $ \o -> ScheduleReq <$> o .: "namespace" <*> o .: "schedule" <*> o .:? "timeZone"

data SuspendReq = SuspendReq Text Bool

instance FromJSON SuspendReq where
    parseJSON = A.withObject "SuspendReq" $ \o -> SuspendReq <$> o .: "namespace" <*> o .: "suspend"

{- | Fields: namespace, container, @set@, @remove@. @set@ upserts env entries (@{name, value}@ or @{name, valueFrom}@), @remove@
drops entries by name. @container@ defaults to the first one.
-}
data EnvReq = EnvReq Text (Maybe Text) [Value] [Text]

instance FromJSON EnvReq where
    parseJSON = A.withObject "EnvReq" $ \o ->
        EnvReq <$> o .: "namespace" <*> o .:? "container" <*> o .:? "set" .!= [] <*> o .:? "remove" .!= []

-- ---------------------------------------------------------------------------
-- Cluster access

kubeOf :: Flow Kube
kubeOf = mkKube <$> getConfig

cronJobRes :: String
cronJobRes = "cronjobs.v1.batch"

kubeJson :: Kube -> [String] -> Maybe Text -> IO (Either KubeErr Value)
kubeJson k args stdin = do
    r <- runKubectl k args stdin
    pure $ case r of
        Left e -> Left (classifyKubeError e)
        Right out -> maybe (Left (KubeFailed "kubectl returned invalid JSON")) Right (A.decodeStrict' (encodeUtf8 out))

kubeFail :: KubeErr -> Flow a
kubeFail (KubeNotFound t) = throwM (NotFound t)
kubeFail (KubeConflict t) = throwM (Conflict t)
kubeFail (KubeFailed t) = throwM (InternalError t)

fetchCronJob :: Kube -> Text -> Text -> Flow Value
fetchCronJob k ns name = liftIO (kubeJson k ["-n", T.unpack ns, "get", cronJobRes, T.unpack name, "-o", "json"] Nothing) >>= either kubeFail pure

{- | Key names (never values) of a Secret or ConfigMap: the go-template runs
inside kubectl, so the values are not even read into this process.
-}
lookupKeys :: Kube -> Text -> RefKind -> Text -> IO (Either LookupErr [Text])
lookupKeys k ns kind name = do
    let (res, tmpl) = case kind of
            RkSecret -> ("secret", "{{range $k,$v := .data}}{{$k}}{{\"\\n\"}}{{end}}")
            RkConfigMap -> ("configmap", "{{range $k,$v := .data}}{{$k}}{{\"\\n\"}}{{end}}{{range $k,$v := .binaryData}}{{$k}}{{\"\\n\"}}{{end}}")
    r <- runKubectl k ["-n", T.unpack ns, "get", res, T.unpack name, "-o", "go-template=" <> tmpl] Nothing
    pure $ case r of
        Right out -> Right (filter (not . T.null) (map T.strip (T.lines out)))
        Left e -> case classifyKubeError e of
            KubeNotFound _ -> Left RefNotFound
            other -> Left (RefUnreadable (kubeErrText other))

validateManifest :: Kube -> Text -> Value -> IO [Issue]
validateManifest k ns v = do
    refIssues <- checkRefs (lookupKeys k ns) (collectManifestRefs v)
    pure (validateStructure ns v ++ scanManifestSecrets v ++ refIssues)

-- | Read-modify-replace. Returns the object before and after the change.
modifyCronJob :: Kube -> Text -> Text -> (Value -> Either Text Value) -> Flow (Value, Value)
modifyCronJob k ns name f = do
    cur <- fetchCronJob k ns name
    new <- either (throwM . BadRequest) pure (f cur)
    r <- liftIO (runKubectl k ["-n", T.unpack ns, "replace", "-f", "-"] (Just (asciiJson new)))
    either (kubeFail . classifyKubeError) (const (pure (cur, new))) r

-- ---------------------------------------------------------------------------
-- Guards

-- | Namespaces named by some product's Deployment Config.
knownNamespaces :: Flow [Text]
knownNamespaces = do
    ps <- listProducts
    pure (sort (nub (filter (not . T.null) (map getProductNamespace ps))))

requireNamespace :: Text -> Flow Text
requireNamespace ns = do
    known <- knownNamespaces
    unless (ns `elem` known) $ throwM (BadRequest ("Unknown namespace: " <> ns))
    pure ns

requireQueryNamespace :: Maybe Text -> Flow Text
requireQueryNamespace = maybe (throwM (BadRequest "namespace is required")) requireNamespace

-- | CronJob names go on a kubectl command line, so a leading '-' must never get through.
requireName :: Text -> Flow Text
requireName n = do
    unless (isDnsName n) $ throwM (BadRequest ("Invalid CronJob name: " <> n))
    pure n

audit :: AuthedPerson -> Text -> Text -> Text -> Value -> Flow ()
audit ap action ns name details =
    writeAuditLog (apPersonId ap) action (Just "cronjob") (Just (ns <> "/" <> name)) (Just details)

failOnErrors :: [Issue] -> Flow ()
failOnErrors issues =
    when (hasErrors issues) $
        throwM (BadRequest (T.intercalate "\n" [issueText i | i <- issues, issueSeverity i == SevError]))

-- ---------------------------------------------------------------------------
-- Reads

namespacesH :: AuthedPerson -> Flow Value
namespacesH _ = do
    ns <- knownNamespaces
    pure (object ["namespaces" .= ns])

listH :: AuthedPerson -> Maybe Text -> Flow Value
listH _ mNs = do
    ns <- requireQueryNamespace mNs
    k <- kubeOf
    v <- liftIO (kubeJson k ["-n", T.unpack ns, "get", cronJobRes, "-o", "json"] Nothing) >>= either kubeFail pure
    let items = arr (getK "items" v)
        rows = sortOn (str . getK "name") (map summarize items)
    pure (object ["namespace" .= ns, "cronjobs" .= rows])

getH :: AuthedPerson -> Text -> Maybe Text -> Flow Value
getH _ name mNs = do
    ns <- requireQueryNamespace mNs
    n <- requireName name
    k <- kubeOf
    detail <$> fetchCronJob k ns n

at :: [Key] -> Value -> Value
at path v = fromMaybe Null (getPath path v)

summarize :: Value -> Value
summarize cj =
    object
        [ "name" .= at ["metadata", "name"] cj
        , "schedule" .= at ["spec", "schedule"] cj
        , "timeZone" .= at ["spec", "timeZone"] cj
        , "suspend" .= suspended cj
        , "concurrencyPolicy" .= at ["spec", "concurrencyPolicy"] cj
        , "lastScheduleTime" .= at ["status", "lastScheduleTime"] cj
        , "lastSuccessfulTime" .= at ["status", "lastSuccessfulTime"] cj
        , "active" .= length (arr (getPath ["status", "active"] cj))
        , "images" .= [i | c <- containersOf cj, Just i <- [str (getK "image" c)]]
        , "createdAt" .= at ["metadata", "creationTimestamp"] cj
        ]

suspended :: Value -> Bool
suspended cj = case getPath ["spec", "suspend"] cj of
    Just (Bool b) -> b
    _ -> False

containersOf :: Value -> [Value]
containersOf = arr . getPath containersPath

detail :: Value -> Value
detail cj =
    object
        [ "summary" .= summarize cj
        , "resourceVersion" .= at ["metadata", "resourceVersion"] cj
        , "startingDeadlineSeconds" .= at ["spec", "startingDeadlineSeconds"] cj
        , "successfulJobsHistoryLimit" .= at ["spec", "successfulJobsHistoryLimit"] cj
        , "failedJobsHistoryLimit" .= at ["spec", "failedJobsHistoryLimit"] cj
        , "activeJobs" .= [n | a <- arr (getPath ["status", "active"] cj), Just n <- [str (getK "name" a)]]
        , "containers" .= map container (containersOf cj)
        ]
  where
    container c =
        object
            [ "name" .= at ["name"] c
            , "image" .= at ["image"] c
            , "command" .= at ["command"] c
            , "args" .= at ["args"] c
            , "env" .= map maskEnv (arr (getK "env" c))
            , "envFrom" .= map envFromEntry (arr (getK "envFrom" c))
            ]
    envFromEntry f
        | isJust (getK "secretRef" f) = object ["kind" .= ("Secret" :: Text), "name" .= at ["secretRef", "name"] f]
        | otherwise = object ["kind" .= ("ConfigMap" :: Text), "name" .= at ["configMapRef", "name"] f]

{- | An inline value that reads as a credential is not sent to the browser
(@masked@ is set instead); the editor can still overwrite it.
-}
maskEnv :: Value -> Value
maskEnv e@(Object o) = case (str (getK "name" e), str (getK "value" e)) of
    (Just n, Just v) | isSensitiveName n || isJust (looksLikeSecretValue v) -> Object (KM.insert "masked" (Bool True) (KM.delete "value" o))
    _ -> e
maskEnv e = e

-- ---------------------------------------------------------------------------
-- Create

{- | Parse the pasted YAML; drops server-populated fields (so an exported manifest
can be pasted back) and pins the namespace to the selected one.
-}
parseManifest :: Text -> Text -> Either Text Value
parseManifest ns yamlTxt = case Y.decodeEither' (encodeUtf8 yamlTxt) :: Either Y.ParseException Value of
    Left e -> Left (T.pack (Y.prettyPrintParseException e))
    Right (Object o) -> Right (normalise o)
    Right _ -> Left "The YAML must be a single CronJob object"
  where
    normalise o =
        let o1 = KM.delete "status" o
            meta = case KM.lookup "metadata" o1 of
                Just (Object m) -> m
                _ -> mempty
            meta1 = foldr KM.delete meta ["uid", "resourceVersion", "creationTimestamp", "generation", "managedFields", "selfLink", "deletionTimestamp"]
            meta2 = if KM.member "namespace" meta1 then meta1 else KM.insert "namespace" (String ns) meta1
         in Object (KM.insert "metadata" (Object meta2) o1)

validateH :: AuthedPerson -> ManifestReq -> Flow Value
validateH _ (ManifestReq nsT yamlT) = do
    ns <- requireNamespace nsT
    case parseManifest ns yamlT of
        Left e -> pure (verdict Nothing [Issue SevError "bad-yaml" "" e])
        Right m -> do
            k <- kubeOf
            issues <- liftIO (validateManifest k ns m)
            pure (verdict (Just m) issues)
  where
    verdict m issues =
        object
            [ "valid" .= not (hasErrors issues)
            , "issues" .= issues
            , "name" .= (m >>= str . getPath ["metadata", "name"])
            , "schedule" .= (m >>= str . getPath ["spec", "schedule"])
            ]

createH :: AuthedPerson -> ManifestReq -> Flow Value
createH ap (ManifestReq nsT yamlT) = do
    ns <- requireNamespace nsT
    m <- either (throwM . BadRequest) pure (parseManifest ns yamlT)
    k <- kubeOf
    issues <- liftIO (validateManifest k ns m)
    failOnErrors issues
    let name = fromMaybe "" (str (getPath ["metadata", "name"] m))
    r <- liftIO (runKubectl k ["-n", T.unpack ns, "create", "-f", "-"] (Just (asciiJson m)))
    case r of
        Left e
            | "already exists" `T.isInfixOf` T.toLower e -> throwM (Conflict ("CronJob " <> name <> " already exists in " <> ns))
            | otherwise -> kubeFail (classifyKubeError e)
        Right _ -> do
            audit ap "CRONJOB_CREATE" ns name (object ["schedule" .= at ["spec", "schedule"] m, "suspend" .= suspended m])
            pure (object ["name" .= name, "namespace" .= ns, "warnings" .= issues])

-- ---------------------------------------------------------------------------
-- Schedule / suspend

overSpec :: (KM.KeyMap Value -> KM.KeyMap Value) -> Value -> Value
overSpec f (Object o) = case KM.lookup "spec" o of
    Just (Object s) -> Object (KM.insert "spec" (Object (f s)) o)
    _ -> Object o
overSpec _ v = v

scheduleH :: AuthedPerson -> Text -> ScheduleReq -> Flow APISuccess
scheduleH ap name (ScheduleReq nsT sched mTz) = do
    ns <- requireNamespace nsT
    n <- requireName name
    let s = T.strip sched
    either (throwM . BadRequest) pure (validateCron s)
    case mTz of
        Just tz | not (T.null tz) && not (validTimeZone tz) -> throwM (BadRequest ("Invalid time zone: " <> tz))
        _ -> pure ()
    k <- kubeOf
    (old, new) <-
        modifyCronJob k ns n $ \cj ->
            Right . overSpec (tzEdit mTz) $ setPath ["spec", "schedule"] (String s) cj
    audit
        ap
        "CRONJOB_SCHEDULE"
        ns
        n
        ( object
            [ "from" .= at ["spec", "schedule"] old
            , "to" .= at ["spec", "schedule"] new
            , "timeZone" .= at ["spec", "timeZone"] new
            ]
        )
    pure Success
  where
    tzEdit Nothing = id
    tzEdit (Just tz)
        | T.null tz = KM.delete "timeZone"
        | otherwise = KM.insert "timeZone" (String tz)
    validTimeZone tz = T.length tz <= 64 && T.all (\c -> isAlphaNum c || c `elem` ("_+-/" :: String)) tz

suspendH :: AuthedPerson -> Text -> SuspendReq -> Flow APISuccess
suspendH ap name (SuspendReq nsT want) = do
    ns <- requireNamespace nsT
    n <- requireName name
    k <- kubeOf
    (old, _) <- modifyCronJob k ns n (Right . setPath ["spec", "suspend"] (Bool want))
    audit ap (if want then "CRONJOB_SUSPEND" else "CRONJOB_RESUME") ns n (object ["wasSuspended" .= suspended old])
    pure Success

-- ---------------------------------------------------------------------------
-- Env

-- | Shape check for one env entry in a request.
validateEnvEntry :: Value -> Either Text ()
validateEnvEntry e = case e of
    Object o -> do
        name <- maybe (Left "every env entry needs a name") Right (str (getK "name" e))
        unless (isEnvName name) $ Left ("Invalid env var name: " <> name)
        case [key | key <- KM.keys o, key `notElem` ["name", "value", "valueFrom"]] of
            [] -> Right ()
            _ -> Left (name <> ": only name, value and valueFrom are allowed")
        case (KM.lookup "value" o, KM.lookup "valueFrom" o) of
            (Just (String _), Nothing) -> Right ()
            (Nothing, Just vf) -> valueFrom name vf
            _ -> Left (name <> ": give exactly one of value (a string) or valueFrom")
    _ -> Left "env entries must be objects"
  where
    valueFrom name vf = case vf of
        Object v -> case KM.toList v of
            [(key, ref)]
                | key `elem` ["secretKeyRef", "configMapKeyRef"] ->
                    if isJust (str (getK "name" ref)) && isJust (str (getK "key" ref))
                        then Right ()
                        else Left (name <> ": " <> K.toText key <> " needs a name and a key")
                | key `elem` ["fieldRef", "resourceFieldRef"] -> Right ()
            _ -> Left (name <> ": valueFrom must have exactly one of secretKeyRef, configMapKeyRef, fieldRef, resourceFieldRef")
        _ -> Left (name <> ": valueFrom must be an object")

-- | Upsert @sets@ and drop @removes@ in one container's env, in place where possible.
applyEnvEdit :: Maybe Text -> [Value] -> [Text] -> Value -> Either Text Value
applyEnvEdit mContainer sets removes cj = do
    cs <- case getPath containersPath cj of
        Just (Array a) | not (V.null a) -> Right (V.toList a)
        _ -> Left "The CronJob has no containers"
    idx <- case mContainer of
        Nothing -> Right 0
        Just c -> maybe (Left ("No container named " <> c)) Right (findIndex ((== Just c) . str . getK "name") cs)
    let c = cs !! idx
        env0 = arr (getK "env" c)
        nameOf = str . getK "name"
        present = [n | e <- env0, Just n <- [nameOf e]]
    case [r | r <- removes, r `notElem` present] of
        [] -> Right ()
        missing -> Left ("No such env var: " <> T.intercalate ", " missing)
    let env1 = filter ((`notElem` map Just removes) . nameOf) env0
        upsert acc s
            | nameOf s `elem` map nameOf acc = [if nameOf e == nameOf s then s else e | e <- acc]
            | otherwise = acc ++ [s]
        env2 = foldl upsert env1 sets
        c' = case c of
            Object o -> Object (KM.insert "env" (Array (V.fromList env2)) o)
            other -> other
        cs' = take idx cs ++ [c'] ++ drop (idx + 1) cs
    Right (setPath containersPath (Array (V.fromList cs')) cj)

envH :: AuthedPerson -> Text -> EnvReq -> Flow APISuccess
envH ap name (EnvReq nsT mContainer sets removes) = do
    ns <- requireNamespace nsT
    n <- requireName name
    when (null sets && null removes) $ throwM (BadRequest "Nothing to change")
    mapM_ (either (throwM . BadRequest) pure . validateEnvEntry) sets
    k <- kubeOf
    -- Only what this request writes is checked: existing entries may predate these rules and must not block an unrelated edit.
    let pfx = "container " <> fromMaybe "(first)" mContainer
    refIssues <- liftIO (checkRefs (lookupKeys k ns) (refsOfEnvEntries pfx sets))
    failOnErrors (scanEnvEntries pfx sets ++ refIssues)
    _ <- modifyCronJob k ns n (applyEnvEdit mContainer sets removes)
    audit
        ap
        "CRONJOB_ENV"
        ns
        n
        ( object
            [ "container" .= mContainer
            , "set" .= [nm | e <- sets, Just nm <- [str (getK "name" e)]]
            , "removed" .= removes
            ]
        )
    pure Success

-- ---------------------------------------------------------------------------
-- Delete

{- | Deleting a CronJob also deletes the Jobs (and so the pods) it owns. If any
are running that needs @force@; suspending is the gentle alternative.
-}
deleteH :: AuthedPerson -> Text -> Maybe Text -> Maybe Bool -> Flow APISuccess
deleteH ap name mNs mForce = do
    ns <- requireQueryNamespace mNs
    n <- requireName name
    k <- kubeOf
    cj <- fetchCronJob k ns n
    let running = length (arr (getPath ["status", "active"] cj))
    when (running > 0 && mForce /= Just True) $
        throwM
            ( Conflict
                ( "CronJob "
                    <> n
                    <> " has "
                    <> T.pack (show running)
                    <> " running job(s); deleting it will terminate them. Suspend it instead, or confirm to delete anyway."
                )
            )
    r <- liftIO (runKubectl k ["-n", T.unpack ns, "delete", cronJobRes, T.unpack n] Nothing)
    either (kubeFail . classifyKubeError) (const (pure ())) r
    audit ap "CRONJOB_DELETE" ns n (object ["schedule" .= at ["spec", "schedule"] cj, "runningJobs" .= running, "forced" .= (mForce == Just True)])
    pure Success
